"""Phase 6 — map data, connectors, matching and the deal scout (SPEC §3.6, §3.7), at API level.

Open-data APIs are mocked in spec/mocks.py (EPC register, Land Registry Price Paid, Companies House,
postcodes.io). Covers: connectors (sealed keys, stubs), the EPC lookup filling a new property by itself
(SPEC §5 #2: the register runs first), sold-price comparables on the card, map layers (radius + polygon),
CSV import, matching with a breakdown and deal-breakers, configurable weights, a deal pack through an
approval, Companies House checks, saved searches and the deal scout's alerts, "book nearest", isolation.
"""
import json
import os
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pdtest import API, P, USERS, call, check, expect, finish, sql, workspace  # noqa: E402

MOCK = os.environ["PD_MOCK"]
M = "http://pd-mock:8080"


def mock(method, path, body=None):
    req = urllib.request.Request(MOCK + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read() or b"null")


def data(res, status, name):
    return expect(name, res, status).get("data") or {}


def poll(fn, timeout=25):
    deadline = time.time() + timeout
    while time.time() < deadline:
        v = fn()
        if v:
            return v
        time.sleep(0.5)
    return fn()


mock("POST", "/_ctl", {"reset_all": True})
S = workspace("owner_s", "Data Buyers Ltd", "data-buyers")
expect("enable the plugin", call("PUT", API + "/api/v2/namespace/plugins/property_deals", "owner_s", S, {"enabled": True}), 200)
expect("setup", call("POST", P + "/setup", "owner_s", S), 200)
roles = expect("roles", call("GET", API + "/api/v2/namespace/roles", "owner_s", S), 200)
roles = roles.get("data") or roles
roles = roles if isinstance(roles, list) else roles.get("roles", [])
role_id = {r["role_name"]: r["id"] for r in roles}
for user, role in (("manager_s", "pd_manager"), ("operator_s", "pd_operator")):
    expect(f"add {user} as {role}", call("POST", API + "/api/v2/namespace/members", "owner_s", S,
           {"email": USERS[user][1], "role_ids": [role_id[role]]}), 201)
expect("workspace SMTP → the sink", call("PUT", API + "/api/v2/namespace/mail-settings", "owner_s", S,
       {"host": "pd-mock", "port": 2525, "security": "none", "from_email": "deals@data-buyers.test"}), 200)

# --- Connectors ---------------------------------------------------------------------------------------------
C = P + "/connectors"
res = call("POST", C, "operator_s", S, {"kind": "epc", "name": "EPC"})
check("operators can't add connectors (403)", res[0] == 403, res)
res = call("POST", C, "manager_s", S, {"kind": "zoopla_scraper", "name": "x"})
check("unknown connector kind → 422", res[0] == 422 and "kind" in res[1]["details"], res)
pcs = data(call("POST", C, "manager_s", S, {"kind": "postcodes", "name": "Postcodes", "config": {"base_url": M + "/pc"}}),
           201, "postcode lookup connector")
epc = data(call("POST", C, "manager_s", S, {"kind": "epc", "name": "EPC register", "secret": "epc-key",
           "config": {"base_url": M + "/epc", "email": "epc@data-buyers.test"}}), 201, "EPC connector")
pp = data(call("POST", C, "manager_s", S, {"kind": "price_paid", "name": "Price Paid", "config": {"base_url": M + "/lr"},
          "sync_enabled": True}), 201, "Price Paid connector")
chc = data(call("POST", C, "manager_s", S, {"kind": "companies_house", "name": "Companies House", "secret": "ch-key",
           "config": {"base_url": M + "/ch"}}), 201, "Companies House connector")
stub = data(call("POST", C, "manager_s", S, {"kind": "propertydata", "name": "PropertyData", "secret": "pd-key"}), 201,
            "paid feed (stub)")
listed = data(call("GET", C, "manager_s", S), 200, "list connectors")
check("keys never returned; has_secret instead", "epc-key" not in json.dumps(listed) and "ch-key" not in json.dumps(listed)
      and epc["has_secret"] and not pp["has_secret"], listed)
check("stored sealed", sql(f"SELECT LEFT(secret_sealed, 5) FROM property_deals_connectors WHERE uuid = '{epc['uuid']}'") == ["gcm1:"])
res = call("POST", C + f"/{stub['uuid']}/run", "manager_s", S, {"postcode": "YO1 7AA"})
check("a stub feed says so (501) and points at CSV import", res[0] == 501 and "CSV" in res[1]["error"], res)

# --- SPEC §5 #2: the EPC register runs first ----------------------------------------------------------------------------
prop = data(call("POST", P + "/properties", "operator_s", S, {"address_line1": "7 Mill Lane", "town": "York",
            "postcode": "YO1 7AA", "tenure": "leasehold", "lease_years_left": 70, "property_type": "terraced",
            "bedrooms": 3, "est_market_value": 150000, "est_rent_pcm": 900, "condition": "needs_work"}), 201, "a new property")
got = poll(lambda: sql(f"SELECT epc_rating || '|' || epc_expires_on || '|' || round(lat::numeric, 2) FROM property_deals_properties WHERE uuid = '{prop['uuid']}' AND epc_rating IS NOT NULL") or None)
check("2. new property: EPC register looked up by itself — latest certificate C, valid to 2032; postcode geocoded",
      got == ["C|2032-03-01|53.96"], got)
p_now = data(call("GET", P + f"/properties/{prop['uuid']}", "operator_s", S), 200, "property")
check("EPC certificate number and source recorded", p_now.get("epc_certificate_number") == "1234-5678-9012-3456-7890"
      and p_now["metadata"].get("epc_source"), p_now)
sold = data(call("GET", P + "/market-records?record_type=sold_price&postcode=YO1 7AA".replace(" ", "%20"), "operator_s", S), 200,
            "sold prices")
check("sold prices fetched for the postcode and geocoded", len(sold) == 3 and all(r.get("lat") for r in sold), sold)
r = data(call("POST", C + f"/{pp['uuid']}/run", "manager_s", S, {"postcode": "YO1 7AA"}), 200, "run Price Paid again")
check("re-running stores nothing new", r["fetched"] == 3 and r["stored"] == 0, r)
res = call("PUT", C + f"/{epc['uuid']}", "manager_s", S, {"secret": "wrong"})
res = call("POST", C + f"/{epc['uuid']}/run", "manager_s", S, {"postcode": "YO1 7AA"})
check("a bad key fails clearly (502) and is recorded", res[0] == 502 and "401" in res[1]["error"]
      and data(call("GET", C + f"/{epc['uuid']}", "manager_s", S), 200, "epc")["last_error"], res)
call("PUT", C + f"/{epc['uuid']}", "manager_s", S, {"secret": "epc-key"})
en = data(call("POST", P + f"/properties/{prop['uuid']}/enrich", "operator_s", S), 200, "enrich on demand")
check("enrich: EPC + comps (sales in the last 24 months only)", en["epc"]["rating"] == "C" and en["comps"]["count"] == 2
      and en["comps"]["median"] == 155000, en)

# --- CSV import, map layers, card ----------------------------------------------------------------------------------------
csv = ("external_id,address,postcode,price,property_type,bedrooms,status,cash_only,url\n"
       "L1,\"12 Mill Lane, York\",YO1 7AA,\"£140,000\",terraced,3,for_sale,no,https://example.invalid/l1\n"
       "L2,1 Station Rd,YO1 9AB,120000,flat,2,for_sale,yes,\n"
       "L3,Far Away House,SW1A 1AA,900000,detached,5,for_sale,no,\n"
       ",,,,,,,,\n")
imp = data(call("POST", P + "/market-records/import", "operator_s", S, {"record_type": "listing", "csv": csv, "source": "agent_feed"}),
           200, "import listings")
check("CSV: 3 stored, blank row skipped, money parsed", imp == {"rows": 4, "stored": 3, "skipped": 1}
      and sql("SELECT price::int FROM property_deals_market_records WHERE external_id = 'L1'") == ["140000"], imp)
data(call("POST", P + "/market-records/import", "operator_s", S, {"record_type": "auction_lot",
     "csv": "lot,address,postcode,price,date\n7,Old Chapel,YO10 5DD,95000,2026-11-20\n"}), 200, "import an auction lot")
res = call("POST", P + "/market-records/import", "operator_s", S, {"record_type": "rumour", "csv": "a\n1"})
check("bad record type → 422", res[0] == 422, res)
mp = data(call("GET", P + "/map?lat=53.96&lng=-1.08&radius_miles=5&layers=properties,sold_prices,epc,listings,auction_lots",
               "operator_s", S), 200, "map with market layers")
check("map: sold prices, EPCs, listings (not the London one), auction lots, the property",
      mp["counts"].get("sold_prices") == 3 and mp["counts"].get("epc") == 3 and mp["counts"].get("listings") == 2
      and mp["counts"].get("auction_lots") == 1 and mp["counts"].get("properties") == 1, mp["counts"])
cash = [f for f in mp["features"] if f["layer"] == "listings" and f.get("cash_only")]
check("listing features carry price, url, cash_only", len(cash) == 1 and cash[0]["price"] == 120000, cash)
poly = data(call("GET", P + "/map?polygon=53.95,-1.084;53.97,-1.084;53.97,-1.07;53.95,-1.07&layers=sold_prices,listings",
                 "operator_s", S), 200, "map polygon")
check("polygon query", poly["counts"].get("sold_prices") == 3 and poly["counts"].get("listings") == 1, poly["counts"])
res = call("GET", P + "/map?lat=53.96&lng=-1.08&layers=rightmove", "operator_s", S)
check("unknown layer → 422", res[0] == 422, res)
card = data(call("GET", P + f"/properties/{prop['uuid']}/card", "operator_s", S), 200, "property card")
check("card: comparables and discount vs comps (£150k vs a £155k median = 3.2%)", card["comps"]["count"] == 2
      and card["comps"]["median"] == 155000 and card.get("discount_vs_comps_pct") == 3.2, card)

# --- Matching ------------------------------------------------------------------------------------------------------------
def buyer(first, email, profile):
    c = expect("contact " + first, call("POST", API + "/api/v2/crm/contacts", "operator_s", S,
               {"first_name": first, "last_name": "Buyer", "email": email}), 201)
    c = c.get("data") or c
    profile["contact_uuid"] = c["uuid"]
    return data(call("POST", P + "/buyer-profiles", "operator_s", S, profile), 201, "buyer profile " + first)


york = [{"type": "radius", "lat": 53.96, "lng": -1.08, "miles": 10, "name": "York"}]
b1 = buyer("Ann", "ann@buyers.test", {"price_min": 100000, "price_max": 200000, "areas": york, "strategies": ["btl", "brr"],
           "min_yield_pct": 6, "refurb_appetite": "medium", "funding_route": "cash"})
b2 = buyer("Ben", "ben@buyers.test", {"price_max": 200000, "areas": york, "deal_breakers": ["short_lease"]})
b3 = buyer("Cat", "cat@buyers.test", {"price_min": 100000, "price_max": 200000, "strategies": ["btl"], "refurb_appetite": "heavy",
           "min_yield_pct": 5,
           "areas": [{"type": "radius", "lat": 51.5, "lng": -0.12, "miles": 10, "name": "London"}]})
sc = data(call("POST", P + "/matches/recompute", "operator_s", S, {"property_uuid": prop["uuid"]}), 200, "score the property")
check("scored against every active buyer", sc["scored"] == 3, sc)
ms = data(call("GET", P + f"/properties/{prop['uuid']}/matches", "operator_s", S), 200, "property's matches")
by = {m["buyer_name"].split()[0]: m for m in ms}
bd = by["Ann"]["breakdown"]
check("Ann is the best match with a full breakdown", ms[0]["buyer_name"].startswith("Ann") and float(by["Ann"]["score"]) > 90
      and set(bd) >= {"budget", "area", "strategy", "yield", "condition", "deal_breakers"} and bd["yield"]["why"].startswith("yield 7.2%"), ms[0])
check("the breakdown explains each factor", bd["budget"]["why"] == "Within budget" and bd["strategy"]["why"].startswith("Suits")
      and bd["budget"]["weight"] == 30 and bd["area"]["points"] == 20, bd)
check("a deal-breaker (short lease) scores 0 and says why", float(by["Ben"]["score"]) == 0
      and by["Ben"]["breakdown"]["deal_breakers"] == ["short_lease"], by["Ben"])
check("out-of-area buyer scores lower", float(by["Cat"]["score"]) < float(by["Ann"]["score"]) and by["Cat"]["breakdown"]["area"]["fit"] == 0,
      by["Cat"])
expect("weights are settings: area weight to 0", call("PUT", API + "/api/v2/namespace/plugins/property_deals", "owner_s", S,
       {"settings": {"match_w_area": 0}}), 200)
data(call("POST", P + "/matches/recompute", "operator_s", S, {}), 200, "re-score the workspace")
cat = [m for m in data(call("GET", P + f"/buyer-profiles/{b3['uuid']}/matches", "operator_s", S), 200, "Cat's matches")
       if m["property_uuid"] == prop["uuid"]][0]
check("with area weight 0, Cat's area no longer counts", cat["breakdown"]["area"]["weight"] == 0 and float(cat["score"]) > 90, cat)
call("PUT", API + "/api/v2/namespace/plugins/property_deals", "owner_s", S, {"settings": {"match_w_area": 20}})
data(call("PUT", P + f"/buyer-profiles/{b2['uuid']}", "operator_s", S, {"deal_breakers": []}), 200, "Ben drops his deal-breaker")
ben = poll(lambda: [m for m in data(call("GET", P + f"/buyer-profiles/{b2['uuid']}/matches", "operator_s", S), 200, "Ben")
                    if float(m["score"]) > 0] or None)
check("a profile change re-scores by itself (event)", ben and ben[0]["breakdown"]["deal_breakers"] == [], ben)
card = data(call("GET", P + f"/properties/{prop['uuid']}/card", "operator_s", S), 200, "card")
check("card: top 3 matching buyers with breakdown", len(card["top_matches"]) == 3 and card["top_matches"][0]["breakdown"], card["top_matches"])

# Deal pack via approval.
mA = by["Ann"]
data(call("PUT", P + f"/buyer-profiles/{b2['uuid']}", "operator_s", S, {"deal_breakers": ["short_lease"]}), 200, "Ben's deal-breaker back")
data(call("POST", P + "/matches/recompute", "operator_s", S, {"buyer_profile_uuid": b2["uuid"]}), 200, "re-score Ben")
res = call("POST", P + f"/matches/{by['Ben']['uuid']}/send", "operator_s", S, {})
check("can't send a home that hits the buyer's deal-breakers (409)", res[0] == 409, res)
ap = data(call("POST", P + f"/matches/{mA['uuid']}/send", "operator_s", S, {}), 201, "send Ann the deal pack")
check("sending is an approval addressed to the buyer", ap["action"] == "send_deal_pack" and ap["payload"]["to"] == "ann@buyers.test", ap)
check("nothing sent yet", [m for m in mock("GET", "/_smtp") if "ann@buyers.test" in json.dumps(m["to"])] == [])
done = data(call("POST", P + f"/approvals/{ap['uuid']}/decide", "manager_s", S, {"decision": "approve"}), 200, "manager approves")
check("approved → emailed, match marked sent", done["status"] == "executed"
      and len([m for m in mock("GET", "/_smtp") if "ann@buyers.test" in json.dumps(m["to"])]) == 1
      and data(call("GET", P + f"/matches/{mA['uuid']}", "operator_s", S), 200, "m")["status"] == "sent", done)

# --- Companies House -------------------------------------------------------------------------------------------------------
found = data(call("GET", P + "/companies/search?q=acme", "operator_s", S), 200, "Companies House search")
check("search", found and found[0]["company_number"] == "01234567", found)
co = expect("company buyer", call("POST", API + "/api/v2/crm/accounts", "operator_s", S, {"name": "Acme Homes Ltd"}), 201)
co = co.get("data") or co
b4 = data(call("POST", P + "/buyer-profiles", "operator_s", S, {"account_uuid": co["uuid"], "entity_type": "ltd_spv"}), 201, "SPV buyer")
chk = data(call("POST", P + f"/buyer-profiles/{b4['uuid']}/company-check", "operator_s", S, {"company_number": "01234567"}), 200,
           "Companies House check")
check("check: name, active officers only, flags", chk["name"] == "ACME HOMES LTD" and len(chk["officers"]) == 1
      and chk["flags"] == ["accounts overdue"], chk)
check("saved on the profile", sql(f"SELECT company_number || '|' || (company_check->>'name') FROM property_deals_buyer_profiles WHERE uuid = '{b4['uuid']}'")
      == ["01234567|ACME HOMES LTD"])
res = call("POST", P + f"/buyer-profiles/{b4['uuid']}/company-check", "operator_s", S, {"company_number": "99999999"})
check("unknown company → 404", res[0] == 404, res)

# --- Saved searches + deal scout ------------------------------------------------------------------------------------------------
ss = data(call("POST", P + "/saved-searches", "operator_s", S, {"name": "York under £200k", "lat": 53.96, "lng": -1.08,
          "radius_miles": 10, "filters": {"max_price": 200000}, "owner_user_uuid": USERS["operator_s"][0]}), 201, "saved search")
first = data(call("POST", P + f"/saved-searches/{ss['uuid']}/run", "operator_s", S), 200, "first run")
check("first run: baseline (no 'new' flood); the cash-only listing is flagged", first == {"new": 0, "reduced": 0, "stale": 0, "cash_only": 1},
      first)
time.sleep(1)
data(call("POST", P + "/market-records/import", "operator_s", S, {"record_type": "listing", "source": "agent_feed",
     "csv": "external_id,address,postcode,price\nL1,\"12 Mill Lane, York\",YO1 7AA,130000\nL4,2 New St,YO1 9AB,99000\nL5,Big House,YO1 9AB,450000\n"}),
     200, "feed: a price cut, a new listing, one over budget")
second = data(call("POST", P + f"/saved-searches/{ss['uuid']}/run", "operator_s", S), 200, "second run")
check("second run: 1 new (in budget), 1 reduced", second == {"new": 1, "reduced": 1, "stale": 0, "cash_only": 0}, second)
third = data(call("POST", P + f"/saved-searches/{ss['uuid']}/run", "operator_s", S), 200, "third run")
check("re-runs are quiet", third == {"new": 0, "reduced": 0, "stale": 0, "cash_only": 0}, third)
sql("UPDATE property_deals_market_records SET first_seen_at = NOW() - interval '120 days' WHERE external_id = 'L2'")
out = data(call("POST", P + "/engine/run", "manager_s", S, {"checks": ["scout"]}), 200, "deal scout job")
check("scout job: stale alert, owner notified; sync fetched for the deal/search postcodes",
      out["scout"]["alerts"] == 1 and out["scout"]["synced"]["connectors"] == 1, out)
alerts = data(call("GET", P + "/scout-alerts?unseen=true", "operator_s", S), 200, "alerts")
kinds = sorted(a["kind"] for a in alerts)
check("alerts listed with the home and why", kinds == ["cash_only", "new", "reduced", "stale"]
      and any(a["kind"] == "reduced" and a["detail"] == "£140000 → £130000" for a in alerts), alerts)
st, notes = call("GET", API + "/api/v2/notifications?limit=50", "operator_s", S)
check("owner got a deal scout notification", any(n.get("title", "").startswith("Deal scout") for n in (notes.get("notifications") or [])))
seen = data(call("POST", P + "/scout-alerts/seen", "operator_s", S, {}), 200, "mark all seen")
check("mark seen", seen["updated"] == 4 and not data(call("GET", P + "/scout-alerts?unseen=true", "operator_s", S), 200, "a"))
res = call("POST", P + "/saved-searches", "operator_s", S, {"name": "nowhere"})
check("a saved search needs a pin or a polygon (422)", res[0] == 422, res)

# --- Book nearest ----------------------------------------------------------------------------------------------------------------
for name, lat in (("Next Door EPC", 53.961), ("County EPC", 54.1)):
    data(call("POST", P + "/suppliers", "operator_s", S, {"name": name, "email": f"{name[:4].lower()}@s.test",
         "kinds": ["epc_assessor"], "base_lat": lat, "base_lng": -1.08}), 201, "supplier " + name)
near = data(call("POST", P + "/suppliers/nearest", "operator_s", S, {"kind": "epc_assessor", "property_uuid": prop["uuid"]}), 200,
            "book nearest (property)")
check("nearest first, with distance", [n["name"] for n in near] == ["Next Door EPC", "County EPC"] and near[0]["distance_miles"] < 1, near)
near = data(call("POST", P + "/suppliers/nearest", "operator_s", S, {"kind": "epc_assessor", "lat": 54.1, "lng": -1.08, "limit": 1}),
            200, "book nearest (pin)")
check("from a pin, limit respected", [n["name"] for n in near] == ["County EPC"], near)
res = call("POST", P + "/suppliers/nearest", "operator_s", S, {"kind": "epc_assessor"})
check("needs a place (422)", res[0] == 422, res)

# --- Isolation ----------------------------------------------------------------------------------------------------------------------
B = sql("SELECT uuid FROM namespaces WHERE slug = 'other-co'")[0]
for path in (f"/connectors/{epc['uuid']}", f"/saved-searches/{ss['uuid']}", f"/matches/{mA['uuid']}"):
    res = call("GET", P + path, "owner_b", B)
    check(f"other workspace: {path.split('/')[1]} not found", res[0] == 404, res)
other = data(call("GET", P + "/map?lat=53.96&lng=-1.08&radius_miles=5&layers=sold_prices,listings", "owner_b", B), 200, "other map")
check("other workspace's map has none of this market data", other["features"] == [], other["counts"])
res = call("POST", P + "/market-records/import", "owner_b", B, {"record_type": "listing", "csv": "external_id,address,postcode\nL1,x,YO1 7AA\n"})
check("same external id in another workspace is its own row", res[0] == 200
      and sql("SELECT COUNT(*) FROM property_deals_market_records WHERE external_id = 'L1'") == ["2"], res)

sys.exit(finish())

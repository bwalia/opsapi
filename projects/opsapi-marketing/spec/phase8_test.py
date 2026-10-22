#!/usr/bin/env python3
"""Phase 8: website pixel, click tracking, bot filtering, conversion attribution,
analytics (funnel/revenue/top links/A-B), server-side forwarding (dry run)."""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mktest import (  # noqa: E402
    API, P, USERS, call, check, enable, expect, finish, new_uuid, sql, workspace,
)

HUMAN_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 Safari/605.1.15"
PUB = P + "/public"
RUN = new_uuid()[:8]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def raw(method, url, body=None, headers=None):
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(req, timeout=30) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def beacon(key, ev, ua=HUMAN_UA):
    st, _, b = raw("POST", PUB + "/px/e?k=" + key, json.dumps(ev).encode(),
                   {"Content-Type": "text/plain;charset=UTF-8", "User-Agent": ua})
    try:
        return st, json.loads(b or b"null")
    except ValueError:
        return st, b


def data(res):
    """Unwrap {success, data} from an expect() body or a call() (status, body) tuple."""
    b = res[1] if isinstance(res, tuple) else res
    if not isinstance(b, dict):
        return b
    return b.get("data") if "data" in b else b


A = workspace("owner_a", "Mkt Pixel", "mkt-px-" + new_uuid()[:8])
enable("owner_a", A)
expect("settings", call("PUT", API + "/api/v2/namespace/plugins/opsapi_marketing", "owner_a", A, {
    "settings": {"dry_run": True, "quiet_hours_from": "00:00", "quiet_hours_to": "00:00",
                 "public_base_url": API, "meta_pixel_id": "1234567890",
                 "meta_capi_access_token": "test-token", "ga4_measurement_id": "G-TEST123",
                 "ga4_api_secret": "ga4-secret", "marketing_frequency_cap_count": 50},
}), 200)

owner = USERS["owner_a"][0]
contacts = [new_uuid() for _ in range(4)]
emails = [f"buyer{i}@px.invalid" for i in range(4)]
for cu, em in zip(contacts, emails):
    sql(f"""
    INSERT INTO crm_contacts (uuid, namespace_id, first_name, last_name, email, owner_user_uuid, status, created_at, updated_at)
    SELECT '{cu}', id, 'Buyer', 'Px', '{em}', '{owner}', 'active', now(), now()
    FROM namespaces WHERE uuid = '{A}' LIMIT 1;
    """)
    expect(f"opt-in {em}", call("POST", P + "/consent/opt-in", "owner_a", A, {
        "contact_uuid": cu, "channel": "email", "source": "form", "legal_basis": "consent",
    }), 200)

# --- Pixel CRUD + snippet + script ---------------------------------------------------
px = data(expect("create pixel", call("POST", P + "/pixels", "owner_a", A, {
    "name": "Shop", "allowed_domains": ["https://shop.example.com/", "*.example.org"],
    "attribution_window_days": 7,
}), 201))
pid, key = px.get("uuid"), px.get("public_key")
check("pixel key format", bool(re.match(r"^px_[0-9a-f]{32}$", key or "")), px)
check("domains normalised", px.get("allowed_domains") == ["shop.example.com", "example.org"], px)
check("install status waiting", px.get("install_status") == "waiting", px)
r = call("POST", P + "/pixels", "owner_a", A, {"name": "Bad", "attribution_window_days": 500})
check("window out of range → 400", r[0] == 400, r)

snip = data(expect("snippet", call("GET", P + f"/pixels/{pid}/snippet", "owner_a", A), 200))
check("snippet has key + loader", key in (snip.get("html") or "") and "mkt('init'" in snip.get("html", ""), snip)
check("snippet uses public base", (snip.get("script_url") or "").startswith(API), snip)

st, hdr, js = raw("GET", PUB + "/px.js?k=" + key)
check("px.js 200 javascript", st == 200 and "javascript" in hdr.get("Content-Type", ""), (st, hdr))
check("px.js embeds key + endpoint", key.encode() in js and b"/public/px/e" in js and b"sendBeacon" in js)
st, _, js = raw("GET", PUB + "/px.js?k=px_deadbeef")
check("px.js unknown key → no-op stub", st == 200 and b"unknown" in js, js[:80])

# --- Campaign send: link rewrite, UTM, preheader --------------------------------------
lst = data(expect("list", call("POST", P + "/lists", "owner_a", A, {
    "name": "Buyers", "list_type": "static", "channel": "email"}), 201))
for cu in contacts:
    expect("member", call("POST", P + f"/lists/{lst['uuid']}/members", "owner_a", A, {"contact_uuid": cu}), 201)

camp = data(expect("campaign", call("POST", P + "/campaigns", "owner_a", A, {
    "name": "Summer Sale 2026", "channel": "email", "message_type": "marketing",
    "subject": "Sale {{contact.first_name}}", "preview_text": "48 hours only",
    "body_html": '<p>Hi</p><a href="https://shop.example.com/sale?ref=email&amp;x=1">Shop</a> '
                 '<a data-mkt-notrack href="https://shop.example.com/terms">Terms</a> '
                 '<a href="mailto:help@shop.example.com">Mail</a>'
                 '<a href="{{unsubscribe_url}}">Unsubscribe</a>',
    "body_text": "Shop https://shop.example.com/sale. {{unsubscribe_url}}",
    "tracking": {"goal_event": "purchase", "utm": {"source": "newsletter"}},
}), 201))
cid = camp["uuid"]
send = data(expect("send", call("POST", P + f"/campaigns/{cid}/schedule", "owner_a", A,
                                {"list_uuid": lst["uuid"], "send_now": True}), 200))
check("queued 4", send.get("queued") == 4, send)

# Drain the queue (the job runs every minute; dispatch is idempotent).
deadline = time.time() + 90
while time.time() < deadline:
    n = sql(f"SELECT count(*) FROM mkt_deliveries d JOIN mkt_campaigns c ON c.id = d.campaign_id "
            f"WHERE c.uuid = '{cid}' AND d.state = 'accepted'")
    if n == ["4"]:
        break
    time.sleep(3)
check("all 4 accepted (dry run)", n == ["4"], n)

row = sql(f"SELECT d.uuid || '|' || d.contact_uuid || '|' || replace(d.body_html, E'\\n', ' ') FROM mkt_deliveries d "
          f"JOIN mkt_campaigns c ON c.id = d.campaign_id WHERE c.uuid = '{cid}' AND d.contact_uuid = '{contacts[0]}'")
d_uuid, d_contact, html = row[0].split("|", 2)
links = re.findall(r'href="([^"]+)"', html)
tracked = [l for l in links if "/public/c?t=" in l]
check("one tracked link", len(tracked) == 1, links)
check("tracked link absolute", tracked and tracked[0].startswith(API), tracked)
check("notrack link untouched", "https://shop.example.com/terms" in links, links)
check("mailto untouched", "mailto:help@shop.example.com" in links, links)
check("unsubscribe not wrapped", any("/public/unsubscribe" in l for l in links), links)
check("open pixel present", "/public/o.gif?t=" in html)
check("preheader injected", "48 hours only" in html.split("<p>Hi</p>")[0], html[:300])
text = sql(f"SELECT body_text FROM mkt_deliveries WHERE uuid = '{d_uuid}'")[0]
check("text link tracked", "/public/c?t=" in text and text.rstrip().find("sale.") == -1 or "/public/c?t=" in text, text)

click_url = tracked[0].replace("&amp;", "&")

# Bot click (security scanner) → redirect, but not counted
st, hdr, _ = raw("GET", click_url, headers={"User-Agent": "Barracuda Sentinel (EE)"})
check("bot click redirects", st == 302, (st, hdr))
check("bot redirect has no _mkt", "_mkt=" not in hdr.get("Location", ""), hdr.get("Location"))
cl = sql(f"SELECT COALESCE(clicked_at::text, 'null') FROM mkt_deliveries WHERE uuid = '{d_uuid}'")
check("bot click not counted", cl == ["null"], cl)

# Too-fast click (< 3 s after hand-off) also flagged
sql(f"UPDATE mkt_deliveries SET accepted_at = NOW() WHERE uuid = '{d_uuid}'")
raw("GET", click_url, headers={"User-Agent": HUMAN_UA})
cl = sql(f"SELECT COALESCE(clicked_at::text, 'null') FROM mkt_deliveries WHERE uuid = '{d_uuid}'")
check("too-fast click not counted", cl == ["null"], cl)

# Human click
sql(f"UPDATE mkt_deliveries SET accepted_at = NOW() - interval '10 minutes' WHERE uuid = '{d_uuid}'")
st, hdr, _ = raw("GET", click_url, headers={"User-Agent": HUMAN_UA})
loc = hdr.get("Location", "")
q = urllib.parse.parse_qs(urllib.parse.urlparse(loc).query)
check("human click 302", st == 302, (st, hdr))
check("dest keeps original params", q.get("ref") == ["email"] and q.get("x") == ["1"], loc)
check("utm_source override", q.get("utm_source") == ["newsletter"], loc)
check("utm_medium/campaign defaults", q.get("utm_medium") == ["email"] and q.get("utm_campaign") == ["summer-sale-2026"], loc)
check("utm_id = campaign uuid", q.get("utm_id") == [cid], loc)
check("_mkt attribution token", bool(q.get("_mkt")), loc)
cl = sql(f"SELECT (clicked_at IS NOT NULL AND opened_at IS NOT NULL)::text FROM mkt_deliveries WHERE uuid = '{d_uuid}'")
check("human click counted (+implied open)", cl == ["true"], cl)

# Open pixel: scanner vs human
opix = re.search(r'src="([^"]*/public/o\.gif\?t=[^"]+)"', html).group(1).replace("&amp;", "&")
d2 = sql(f"SELECT d.uuid FROM mkt_deliveries d JOIN mkt_campaigns c ON c.id = d.campaign_id "
         f"WHERE c.uuid = '{cid}' AND d.contact_uuid = '{contacts[1]}'")[0]
html2 = sql(f"SELECT body_html FROM mkt_deliveries WHERE uuid = '{d2}'")[0]
opix2 = re.search(r'src="([^"]*/public/o\.gif\?t=[^"]+)"', html2).group(1).replace("&amp;", "&")
raw("GET", opix2, headers={"User-Agent": "python-requests/2.31"})
check("scanner open not counted", sql(f"SELECT (opened_at IS NULL)::text FROM mkt_deliveries WHERE uuid = '{d2}'") == ["true"])
raw("GET", opix2, headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) GoogleImageProxy"})
check("gmail proxy open counted", sql(f"SELECT (opened_at IS NOT NULL)::text FROM mkt_deliveries WHERE uuid = '{d2}'") == ["true"])
assert opix

# --- Pixel events: stitching + conversion -------------------------------------------
vid = "v" + new_uuid().replace("-", "")[:20]
landing = loc
st, b = beacon(key, {"e": "page_view", "u": landing, "vid": vid, "id": "pv-" + vid})
check("page_view accepted 202", st == 202 and b.get("accepted") == 1, (st, b))
vis = sql(f"SELECT COALESCE(contact_uuid, 'null') FROM mkt_visitors WHERE visitor_key = '{vid}'")
check("visitor stitched to clicking contact", vis == [contacts[0]], vis)

# Later purchase on another page (no _mkt in URL) — attributed via the visitor's touch
st, b = beacon(key, {"e": "purchase", "u": "https://shop.example.com/thanks", "vid": vid,
                     "v": 49.99, "cur": "gbp", "oid": "ORDER-1-" + RUN, "id": "buy-" + vid})
check("purchase accepted", st == 202, (st, b))
conv = sql(f"SELECT c.uuid || '|' || cv.value || '|' || cv.currency || '|' || (cv.delivery_id IS NOT NULL)::text "
           f"FROM mkt_conversions cv JOIN mkt_campaigns c ON c.id = cv.campaign_id WHERE cv.order_id = 'ORDER-1-" + RUN + "'")
check("conversion attributed to campaign + delivery", conv == [f"{cid}|49.99|GBP|true"], conv)
dv = sql(f"SELECT (converted_at IS NOT NULL)::text || '|' || conversion_value FROM mkt_deliveries WHERE uuid = '{d_uuid}'")
check("delivery marked converted", dv == ["true|49.99"], dv)

# Dedupe: same event_id, and a new event with the same order id
beacon(key, {"e": "purchase", "u": "https://shop.example.com/thanks", "vid": vid, "v": 49.99, "oid": "ORDER-1-" + RUN,
             "id": "buy-" + vid})
beacon(key, {"e": "purchase", "u": "https://shop.example.com/thanks", "vid": vid, "v": 49.99, "oid": "ORDER-1-" + RUN,
             "id": "buy2-" + vid})
check("conversions deduped by event_id + order_id",
      sql("SELECT count(*) FROM mkt_conversions WHERE order_id = 'ORDER-1-" + RUN + "'") == ["1"])

# Batch + domain allow-list
st, b = beacon(key, {"events": [{"e": "view_content", "u": "https://www.example.org/p/1", "vid": vid},
                                {"e": "add_to_cart", "u": "https://www.example.org/p/1", "vid": vid}]})
check("batch accepted (subdomain allowed)", st == 202 and b.get("accepted") == 2, (st, b))
st, b = beacon(key, {"e": "page_view", "u": "https://evil.test/x", "vid": vid})
check("foreign domain → 403", st == 403, (st, b))
st, b = beacon(key, {"e": "bad name!", "u": "https://shop.example.com/"})
check("invalid event name → 400", st == 400, (st, b))
st, b = beacon("px_" + "0" * 32, {"e": "page_view", "u": "https://shop.example.com/"})
check("unknown key → 404", st == 404, (st, b))

# Bot UA never attributes or converts
bvid = "b" + new_uuid().replace("-", "")[:20]
beacon(key, {"e": "page_view", "u": landing, "vid": bvid}, ua="Mozilla/5.0 (compatible; Googlebot/2.1)")
beacon(key, {"e": "purchase", "u": "https://shop.example.com/thanks", "vid": bvid, "v": 10, "oid": "BOT-1-" + RUN},
       ua="HeadlessChrome/120")
check("bot purchase not converted", sql("SELECT count(*) FROM mkt_conversions WHERE order_id = 'BOT-1-" + RUN + "'") == ["0"])
check("bot visitor not created", sql(f"SELECT count(*) FROM mkt_visitors WHERE visitor_key = '{bvid}'") == ["0"])

# Cross-device: contact 2 clicks, then buys on a new device after identify()
d3 = sql(f"SELECT d.uuid FROM mkt_deliveries d JOIN mkt_campaigns c ON c.id = d.campaign_id "
         f"WHERE c.uuid = '{cid}' AND d.contact_uuid = '{contacts[2]}'")[0]
html3 = sql(f"SELECT body_html FROM mkt_deliveries WHERE uuid = '{d3}'")[0]
click3 = re.search(r'href="([^"]*/public/c\?t=[^"]+)"', html3).group(1).replace("&amp;", "&")
sql(f"UPDATE mkt_deliveries SET accepted_at = NOW() - interval '1 hour' WHERE uuid = '{d3}'")
raw("GET", click3, headers={"User-Agent": HUMAN_UA})
vid2 = "w" + new_uuid().replace("-", "")[:20]
beacon(key, {"e": "page_view", "u": "https://shop.example.com/", "vid": vid2})
beacon(key, {"e": "identify", "u": "https://shop.example.com/login", "vid": vid2, "em": emails[2].upper()})
check("identify stitched visitor", sql(f"SELECT contact_uuid FROM mkt_visitors WHERE visitor_key = '{vid2}'") == [contacts[2]])
beacon(key, {"e": "purchase", "u": "https://shop.example.com/thanks", "vid": vid2, "v": 100, "cur": "GBP", "oid": "ORDER-2-" + RUN})
conv2 = sql(f"SELECT c.uuid FROM mkt_conversions cv JOIN mkt_campaigns c ON c.id = cv.campaign_id WHERE cv.order_id = 'ORDER-2-" + RUN + "'")
check("cross-device conversion attributed via contact click", conv2 == [cid], conv2)
check("identify email not stored in props",
      sql(f"SELECT count(*) FROM mkt_web_events WHERE properties::text ILIKE '%px.invalid%'") == ["0"])

# utm_id fallback for anonymous visitor
vid3 = "u" + new_uuid().replace("-", "")[:20]
beacon(key, {"e": "lead", "u": f"https://shop.example.com/form?utm_id={cid}", "vid": vid3})
conv3 = sql(f"SELECT c.uuid || '|' || (cv.delivery_id IS NULL)::text FROM mkt_conversions cv "
            f"JOIN mkt_visitors v ON v.id = cv.visitor_id JOIN mkt_campaigns c ON c.id = cv.campaign_id "
            f"WHERE v.visitor_key = '{vid3}'")
check("utm_id fallback attributes campaign (no delivery)", conv3 == [f"{cid}|true"], conv3)

# Unattributed conversion
beacon(key, {"e": "purchase", "u": "https://shop.example.com/thanks", "vid": "z" + new_uuid().replace("-", "")[:20],
             "v": 5, "oid": "ORDER-ORGANIC-" + RUN})
check("organic conversion unattributed",
      sql("SELECT (campaign_id IS NULL)::text FROM mkt_conversions WHERE order_id = 'ORDER-ORGANIC-" + RUN + "'") == ["true"])

# noscript GIF
st, hdr, _ = raw("GET", PUB + "/px.gif?k=" + key + "&e=page_view&u=" + urllib.parse.quote("https://shop.example.com/ns"),
                 headers={"User-Agent": HUMAN_UA})
check("px.gif returns gif", st == 200 and hdr.get("Content-Type") == "image/gif", (st, hdr))
check("px.gif recorded", sql("SELECT count(*) FROM mkt_web_events WHERE url = 'https://shop.example.com/ns'") == ["1"])

# --- Dashboard APIs: debugger, test event, stats, analytics --------------------------
ev = data(expect("events debugger", call("GET", P + f"/pixels/{pid}/events?limit=100", "owner_a", A), 200))
check("debugger lists events newest first", isinstance(ev, list) and len(ev) >= 8 and ev[0]["id"] > ev[-1]["id"], len(ev or []))
check("debugger shows campaign attribution", any(e.get("campaign_uuid") == cid for e in ev))
last_id = ev[0]["id"]
te = data(expect("test event", call("POST", P + f"/pixels/{pid}/test-event", "owner_a", A, {}), 200))
check("test event ok, not converted", te.get("conversion") is False, te)
newer = data(call("GET", P + f"/pixels/{pid}/events?after_id={last_id}", "owner_a", A))
check("after_id returns only the new test event", len(newer) == 1 and newer[0]["is_test"] is True, newer)

px2 = data(call("GET", P + f"/pixels/{pid}", "owner_a", A))
check("install status active", px2.get("install_status") == "active", px2)
stats = data(expect("pixel stats", call("GET", P + f"/pixels/{pid}/stats?days=7", "owner_a", A), 200))
tot = stats.get("totals") or {}
check("stats conversions = 4 (bots/tests excluded)", tot.get("conversions") == 4, tot)
check("stats revenue 154.99", abs((tot.get("revenue") or 0) - 154.99) < 0.001, tot)
check("stats top pages", isinstance(stats.get("top_pages"), list) and len(stats["top_pages"]) > 0, stats)

an = data(expect("campaign analytics", call("GET", P + f"/analytics/campaigns/{cid}", "owner_a", A), 200))
dl, cv, rt = an.get("deliveries") or {}, an.get("conversions") or {}, an.get("rates") or {}
check("analytics sent 4", dl.get("sent") == 4, dl)
check("analytics clicked 2 (humans only)", dl.get("clicked") == 2, dl)
check("analytics converted deliveries 2", dl.get("converted") == 2, dl)
check("analytics conversions 3 incl. utm fallback", cv.get("conversions") == 3, cv)
check("analytics revenue 149.99", abs((cv.get("revenue") or 0) - 149.99) < 0.001, cv)
check("click rate 50%", rt.get("click_rate") == 50, rt)
check("bot clicks reported", (an.get("tracking") or {}).get("bot_clicks", 0) >= 2, an.get("tracking"))
tl = an.get("top_links") or []
check("top link is the sale URL (tagged)", tl and tl[0]["url"].startswith("https://shop.example.com/sale") and tl[0]["clicks"] == 2, tl)
check("funnel has 4 stages", [f["stage"] for f in an.get("funnel", [])] == ["sent", "opened", "clicked", "converted"], an.get("funnel"))
check("timeline buckets", isinstance(an.get("timeline"), list) and len(an["timeline"]) >= 1, an.get("timeline"))

att = data(expect("attribution report", call("GET", P + "/analytics/attribution?days=30", "owner_a", A), 200))
row = next((c for c in att.get("campaigns", []) if c["uuid"] == cid), {})
check("attribution row revenue", abs((row.get("revenue") or 0) - 149.99) < 0.001, row)
check("unattributed revenue 5", abs(((att.get("unattributed") or {}).get("revenue") or 0) - 5) < 0.001, att.get("unattributed"))
ov = data(expect("overview", call("GET", P + "/analytics/overview", "owner_a", A), 200))
check("overview conversions_30d", (ov.get("conversions_30d") or {}).get("conversions") == 4, ov.get("conversions_30d"))
check("overview top campaigns", any(c["uuid"] == cid for c in ov.get("top_campaigns") or []), ov.get("top_campaigns"))

ct = data(expect("contact timeline", call("GET", P + f"/analytics/contacts/{contacts[0]}", "owner_a", A), 200))
check("timeline has web events", any(e["event_name"] == "purchase" for e in ct.get("web_events") or []), ct.get("web_events"))

# --- A/B winner -----------------------------------------------------------------------
ab = data(expect("ab campaign", call("POST", P + "/campaigns", "owner_a", A, {
    "name": "AB", "channel": "email", "subject": "s", "body_html": '<a href="https://shop.example.com/">x</a>',
    "body_text": "x"}), 201))
expect("set ab", call("PUT", P + f"/campaigns/{ab['uuid']}/ab-config", "owner_a", A, {
    "enabled": True, "variants": [{"key": "A", "subject": "A"}, {"key": "B", "subject": "B"}]}), 200)
abid = sql(f"SELECT id FROM mkt_campaigns WHERE uuid = '{ab['uuid']}'")[0]
nsid = sql(f"SELECT id FROM namespaces WHERE uuid = '{A}'")[0]
sql(f"""INSERT INTO mkt_deliveries (namespace_id, campaign_id, contact_uuid, channel, address, attempt_key, state,
        variant_key, clicked_at, accepted_at)
        SELECT {nsid}, {abid}, gen_random_uuid()::text, 'email', 'x' || g || '@ab.invalid', '1', 'accepted',
               CASE WHEN g % 2 = 0 THEN 'A' ELSE 'B' END,
               CASE WHEN (g % 2 = 0 AND g % 4 = 0) OR (g % 2 = 1 AND g % 20 = 1) THEN NOW() END, NOW()
        FROM generate_series(1, 400) g""")
abn = data(call("GET", P + f"/analytics/campaigns/{ab['uuid']}", "owner_a", A))
w = abn.get("ab_winner") or {}
check("A/B winner A, significant", w.get("variant") == "A" and w.get("significant") is True and w.get("confidence", 0) >= 99, w)

# --- Forwarding (dry run) --------------------------------------------------------------
pend = sql("SELECT count(*) FROM mkt_web_events e JOIN mkt_pixels p ON p.id = e.pixel_id "
           f"WHERE p.uuid = '{pid}' AND (e.forward_pending OR EXISTS (SELECT 1 FROM mkt_pixel_forwards f WHERE f.web_event_id = e.id))")
check("conversions queued for forwarding", int(pend[0]) >= 4, pend)
deadline = time.time() + 90
fw = []
while time.time() < deadline:
    fw = data(call("GET", P + "/pixel-forwards?limit=200", "owner_a", A)) or []
    if any(f["destination"] == "meta" for f in fw) and any(f["destination"] == "ga4" for f in fw):
        break
    time.sleep(5)
check("forwarded to meta + ga4 (dry run)", any(f["destination"] == "meta" and f["status"] == "dry_run" for f in fw)
      and any(f["destination"] == "ga4" and f["status"] == "dry_run" for f in fw), fw[:3])
meta = next((f for f in fw if f["destination"] == "meta" and "ORDER-1-" + RUN in (f["response"] or "")), None)
check("meta payload hashed email + Purchase", meta and '"Purchase"' in meta["response"] and '"em"' in meta["response"]
      and "px.invalid" not in meta["response"], meta)
check("no page_view forwarded by default", not any(f["event_name"] == "page_view" for f in fw))

# --- Isolation + key rotation ----------------------------------------------------------
B = workspace("owner_b", "Mkt Px B", "mkt-pxb-" + new_uuid()[:8])
enable("owner_b", B)
r = call("GET", P + f"/pixels/{pid}", "owner_b", B)
check("other tenant cannot read pixel", r[0] == 404, r)
r = call("GET", P + f"/pixels/{pid}/events", "owner_b", B)
check("other tenant cannot read events", r[0] == 404, r)
rot = data(expect("rotate key", call("POST", P + f"/pixels/{pid}/rotate-key", "owner_a", A, {}), 200))
check("new key differs", rot.get("public_key") != key, rot)
st, b = beacon(key, {"e": "page_view", "u": "https://shop.example.com/"})
check("old key rejected", st == 404, (st, b))
expect("deactivate", call("PUT", P + f"/pixels/{pid}", "owner_a", A, {"is_active": False}), 200)
st, b = beacon(rot["public_key"], {"e": "page_view", "u": "https://shop.example.com/"})
check("inactive pixel rejected", st == 404, (st, b))
expect("delete pixel", call("DELETE", P + f"/pixels/{pid}", "owner_a", A), 200)

sys.exit(finish())

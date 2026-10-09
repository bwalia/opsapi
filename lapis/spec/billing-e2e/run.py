"""End-to-end, data only: an app configured purely through the API, sold, activated offline, managed by its customer."""
import json, os, re, time, hashlib, glob, email, urllib.request, urllib.error
def mail_text(path):
    msg = email.message_from_bytes(open(path, "rb").read())
    parts = [p.get_payload(decode=True).decode("utf-8", "replace") for p in msg.walk() if p.get_content_maintype() == "text"]
    return "\n".join(f"{k}: {v}" for k, v in msg.items()) + "\n" + "\n".join(parts)
B = "http://e2e-api"; OWNER = open("/e2e/owner.jwt").read().strip(); OUT = "/e2e/out"
fails = []
def check(name, ok, detail=""):
    print(("  ok   " if ok else "  FAIL ") + name + ("" if ok else f"   {str(detail)[:300]}"))
    if not ok: fails.append(name)
def req(method, path, body=None, token=OWNER, ns="e2e", headers=None):
    h = {"Content-Type": "application/json"}
    if token: h["Authorization"] = "Bearer " + token
    if ns and token == OWNER: h["X-Namespace-Slug"] = ns
    h.update(headers or {})
    r = urllib.request.Request(B + path, data=json.dumps(body).encode() if body is not None else None, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=30) as x:
            raw = x.read(); return x.status, (json.loads(raw) if raw else None), dict(x.headers)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try: return e.code, json.loads(raw), dict(e.headers)
        except Exception: return e.code, raw[:200], dict(e.headers)
def pub(method, path, body=None, headers=None): return req(method, path, body, token=None, headers=headers)

print("setup (data only, through the API)")
st, _, _ = req("POST", "/api/v2/user/namespaces", {"name": "E2E", "slug": "e2e"}, ns=None); check("workspace", st == 201, st)
st, m, _ = req("PUT", "/api/v2/namespace/mail-settings", {"host": "e2e-smtp", "port": 2525, "security": "none", "from_email": "billing@e2e.test", "from_name": "E2E"})
check("workspace SMTP saved (password never returned)", st == 200 and m["data"]["configured"] and "password" not in m["data"], m)
st, a, _ = req("POST", "/api/v2/billing/apps", {"name": "Notes Pro", "kind": "desktop", "settings": {
    "allowed_origins": ["https://notes.example"], "allowed_redirect_urls": ["https://notes.example/account"],
    "lockout": {"failures": 3}, "display_name": "Notes Pro", "accent_color": "#16a34a", "support_email": "help@notes.example",
    "rate_limits": {"access_link_per_email_per_hour": 2}}})
check("desktop app", st == 201 and a["data"]["settings"]["grace_days"] == 30 and a["data"]["settings"]["max_activations"] == 3, a)
APP, PK, SALT = a["data"]["uuid"], a["data"]["publishable_key"], a["data"]["settings"]["fingerprint_salt"]
for f in [{"key": "export_pdf", "name": "Export PDF"}, {"key": "projects", "name": "Projects", "type": "limit"},
          {"key": "ai_assist", "name": "AI assist", "released_at": "2025-01-01T00:00:00Z"},
          {"key": "cloud_sync", "name": "Cloud sync", "released_at": "2030-01-01T00:00:00Z"}]:
    st, _, _ = req("POST", f"/api/v2/billing/apps/{APP}/features", f); check("feature " + f["key"], st == 201, st)
plans = [
    {"name": "Free", "plan_key": "free", "purchase_type": "one_time", "amount": 0, "is_default": True, "features": {"projects": 3}},
    {"name": "Lifetime", "plan_key": "lifetime", "purchase_type": "one_time", "amount": 9900, "updates_days": 365,
     "features": {"export_pdf": True, "ai_assist": True, "cloud_sync": True, "projects": None}},
    {"name": "30-day pass", "plan_key": "pass_30", "purchase_type": "fixed_term", "amount": 900, "term_days": 30,
     "features": {"export_pdf": True, "projects": 20}, "store_products": {"app_store": "com.notes.pass30"}},
]
for p in plans:
    st, r, _ = req("POST", "/api/v2/billing/plans", dict(p, app=APP)); check("plan " + p["plan_key"], st == 201, r)
st, _, _ = req("POST", f"/api/v2/billing/apps/{APP}/upgrades", {"from_plan": "pass_30", "to_plan": "lifetime"}); check("upgrade path", st == 201, st)
st, _, _ = req("POST", "/api/v2/billing/coupons", {"code": "LAUNCH25", "discount_type": "percent", "percent_off": 25, "max_redemptions": 10, "app": APP}); check("coupon", st == 201, st)

print("sale")
st, sale, _ = req("POST", "/api/v2/subscriptions/purchases", {"app": APP, "customer_external_id": "user-1", "email": "ann@buyer.test", "plan": "lifetime", "coupon": "launch25"})
check("manual lifetime sale with coupon -> licence key once", st == 201 and sale["data"].get("key") and sale["data"]["purchase"]["amount"] == 7425, sale)
KEY, CUST = sale["data"]["key"], sale["data"]["license"]["customer_uuid"]

print("public app info + licences (no secret, publishable key only)")
st, info, hdr = pub("GET", f"/api/v2/public/billing/apps/{PK}")
check("app info by pk, cacheable", st == 200 and info["data"]["fingerprint_salt"] == SALT and "max-age" in hdr.get("Cache-Control", ""), (st, hdr.get("Cache-Control")))
st, _, _ = pub("GET", f"/api/v2/public/billing/apps/{PK}", headers={"If-None-Match": hdr.get("ETag")}); check("ETag -> 304", st == 304, st)
fp = lambda m: hashlib.sha256(f"{SALT}:{m}".encode()).hexdigest()
FP1 = fp("machine-a")
act = {"pk": PK, "license_key": KEY.lower(), "fingerprint_hash": FP1, "app_version": "3.2.0", "name": "Ann's Mac", "platform": "macos"}
st, r1, h1 = pub("POST", "/api/v2/public/licenses/activate", act, headers={"Idempotency-Key": "act-1"})
check("activate -> licence file", st == 200 and r1["data"]["license_file"].count(".") == 2, r1)
st, r2, h2 = pub("POST", "/api/v2/public/licenses/activate", act, headers={"Idempotency-Key": "act-1"})
check("same Idempotency-Key replays the same answer", st == 200 and r2 == r1 and h2.get("Idempotent-Replayed") == "true", h2)
st, r3, _ = pub("POST", "/api/v2/public/licenses/activate", dict(act, name="other"), headers={"Idempotency-Key": "act-1"})
check("same key, different body -> 409", st == 409 and r3["code"] == "idempotency_mismatch", r3)
open(f"{OUT}/licence_file.txt", "w").write(r1["data"]["license_file"])
st, r, _ = pub("POST", "/api/v2/public/licenses/activate", {"pk": PK, "license_key": KEY, "fingerprint_hash": "abc", "app_version": "1"})
check("raw machine id refused (hash only)", st == 400 and r["code"] == "invalid_fingerprint", r)
for i, m in enumerate(["machine-b", "machine-c"]):
    st, _, _ = pub("POST", "/api/v2/public/licenses/activate", dict(act, fingerprint_hash=fp(m), name=m)); check("activate " + m, st == 200, st)
st, r, _ = pub("POST", "/api/v2/public/licenses/activate", dict(act, fingerprint_hash=fp("machine-d")))
check("4th device -> activation_limit (default 3 for desktop)", st == 409 and r["code"] == "activation_limit", r)
st, r, _ = pub("POST", "/api/v2/public/licenses/validate", {"pk": PK, "license_key": KEY, "fingerprint_hash": FP1, "app_version": "3.2.1"})
check("validate -> fresh file", st == 200, r)
st, r, h = pub("POST", "/api/v2/public/licenses/validate", {"pk": PK, "license_key": KEY, "fingerprint_hash": FP1, "app_version": "3"}, headers={"Origin": "https://evil.example"})
check("browser from another origin -> 403", st == 403 and r["code"] == "origin_not_allowed", (st, r))
st, r, h = pub("POST", "/api/v2/public/licenses/validate", {"pk": PK, "license_key": KEY, "fingerprint_hash": FP1, "app_version": "3"}, headers={"Origin": "https://notes.example"})
check("browser from an allowed origin -> CORS header", st == 200 and h.get("Access-Control-Allow-Origin") == "https://notes.example", h.get("Access-Control-Allow-Origin"))

print("runtime (secret key) + cache")
st, k, _ = req("POST", "/api/v2/api-keys", {"name": "server", "scopes": {"entitlements": ["read", "create"]}}); SECRET = k["data"]["key"]
st, e, _ = req("GET", f"/api/v2/entitlements/{APP}/customers/user-1", token=SECRET)
check("entitlements: lifetime, cloud_sync (released after updates_until) excluded",
      st == 200 and e["data"]["entitlements"]["features"] == {"export_pdf": True, "ai_assist": True, "cloud_sync": False, "projects": None}, e)
open(f"{OUT}/entitlement_token.txt", "w").write(e["data"]["token"])
st, e2, _ = req("GET", f"/api/v2/entitlements/{APP}/customers/user-1", token=SECRET)
check("second call served from cache (same token)", e2["data"]["token"] == e["data"]["token"], "")
st, g, _ = req("POST", "/api/v2/subscriptions/grants", {"app": APP, "customer": CUST, "features": {"cloud_sync": True}})
st, e3, _ = req("GET", f"/api/v2/entitlements/{APP}/customers/user-1", token=SECRET)
check("a grant busts the cache at once", st == 200 and e3["data"]["entitlements"]["features"]["cloud_sync"] is True, e3)
st, sp, _ = req("POST", f"/api/v2/entitlements/{APP}/purchases", {"source": "app_store", "customer_external_id": "user-2", "email": "bo@buyer.test",
    "store_product_id": "com.notes.pass30", "external_transaction_id": "tx-1001"}, token=SECRET, headers={"Idempotency-Key": "store-1"})
check("store purchase recorded (by store product id) + licence", st == 201 and sp["data"]["purchase"]["source"] == "app_store" and sp["data"].get("key"), sp)
st, sp2, _ = req("POST", f"/api/v2/entitlements/{APP}/purchases", {"source": "app_store", "customer_external_id": "user-2",
    "store_product_id": "com.notes.pass30", "external_transaction_id": "tx-1001"}, token=SECRET)
check("same transaction again -> duplicate, no second licence", st == 201 and sp2["data"].get("duplicate") and not sp2["data"].get("key"), sp2)
st, v, _ = req("POST", f"/api/v2/entitlements/{APP}/purchases/verify", {"source": "app_store", "payload": {}}, token=SECRET)
check("App Store verifier stub -> 501 not_implemented", st == 501 and v["code"] == "not_implemented", v)
st, _, _ = req("GET", "/api/v2/billing/apps", token=SECRET); check("entitlements key can't manage apps", st == 403, st)

print("access link -> session -> my licences")
st, r, _ = pub("POST", "/api/v2/public/billing/access-link", {"pk": PK, "email": "ANN@buyer.test"})
check("access link -> 202", st == 202, r)
st, r2, _ = pub("POST", "/api/v2/public/billing/access-link", {"pk": PK, "email": "nobody@buyer.test"})
check("unknown email -> the same 202 (no enumeration)", st == 202 and r2 == r, r2)
st, r, _ = pub("POST", "/api/v2/public/billing/access-link", {"pk": PK, "email": "ann@buyer.test", "return_url": "https://evil.example/x"})
check("return_url not allowed -> 422", st == 422 and r["code"] == "redirect_not_allowed", r)
token = None
for _ in range(20):
    for f in glob.glob("/mail/*.eml"):
        m = re.search(r"#token=([A-Za-z0-9_\-]+)", mail_text(f))
        if m: token = m.group(1)
    if token: break
    time.sleep(1)
check("email delivered via workspace SMTP with the link (outbox)", token is not None, os.listdir("/mail"))
mail = mail_text(sorted(glob.glob("/mail/*.eml"))[-1]) if glob.glob("/mail/*.eml") else ""
check("email branded: from Notes Pro, Reply-To support, link to hosted page", "From: Notes Pro" in mail and "Reply-To: help@notes.example" in mail and "https://hosted.e2e.test/b/" in mail, mail[:600])
st, s, _ = pub("POST", "/api/v2/public/billing/sessions", {"pk": PK, "token": token})
check("link -> session", st == 201 and s["data"]["session"], s)
st, again, _ = pub("POST", "/api/v2/public/billing/sessions", {"pk": PK, "token": token})
check("link is single-use", st == 401, again)
SES = {"X-Billing-Session": s["data"]["session"]}
st, me, _ = pub("GET", f"/api/v2/public/billing/me?pk={PK}", headers=SES)
check("my licences: 1 licence, 3 devices, purchases", st == 200 and len(me["data"]["licences"]) == 1 and len([d for d in me["data"]["licences"][0]["activations"] if not d.get("deactivated_at")]) == 3 and len(me["data"]["purchases"]) == 1, me)
LIC = me["data"]["licences"][0]["uuid"]
st, ri, _ = pub("POST", f"/api/v2/public/billing/me/licenses/{LIC}/reissue?pk={PK}", {}, headers=SES)
NEW = ri["data"]["key"]
check("reissue -> a new key once", st == 200 and NEW and NEW != KEY, ri)
st, r, _ = pub("POST", "/api/v2/public/licenses/validate", {"pk": PK, "license_key": KEY, "fingerprint_hash": FP1, "app_version": "3"})
check("old key stops working", st == 404 and r["code"] == "invalid_license", r)
st, r, _ = pub("POST", "/api/v2/public/licenses/validate", {"pk": PK, "license_key": NEW, "fingerprint_hash": FP1, "app_version": "3"})
check("new key works on the same device (devices kept)", st == 200, r)
dev = [d for d in me["data"]["licences"][0]["activations"] if d["name"] == "machine-b"][0]["uuid"]
st, r, _ = pub("DELETE", f"/api/v2/public/billing/me/licenses/{LIC}/activations/{dev}?pk={PK}", headers=SES)
check("customer frees a device", st == 200, r)
st, r, _ = pub("GET", f"/api/v2/public/billing/me?pk={PK}", headers={"X-Billing-Session": "x" * 40})
check("bad session -> 401", st == 401, r)

print("upgrade + history + privacy")
st, q, _ = req("POST", "/api/v2/subscriptions/upgrade?quote=1", {"app": APP, "customer_external_id": "user-2", "to_plan": "lifetime"})
check("upgrade quote: price difference 9900-900", st == 200 and q["data"]["amount"] == 9000, q)
st, up, _ = req("POST", "/api/v2/subscriptions/upgrade", {"app": APP, "customer_external_id": "user-2", "to_plan": "lifetime"})
check("upgrade: same licence moves to lifetime (no new key)", st == 200 and up["data"]["license"]["plan_key"] == "lifetime" and not up["data"].get("key"), up)
st, hist, _ = req("GET", f"/api/v2/subscriptions/plan-changes?app={APP}")
check("history: new, new, upgrade", st == 200 and sorted(h["kind"] for h in hist["data"]) == ["new", "new", "upgrade"], hist)
st, ex, _ = req("GET", f"/api/v2/customers/{CUST}/billing-export")
check("export", st == 200 and ex["data"]["customer"]["email"] == "ann@buyer.test" and len(ex["data"]["devices"]) >= 3, ex)
st, er, _ = req("DELETE", f"/api/v2/customers/{CUST}/billing-data")
check("delete: revoked + anonymised, accounting kept", st == 200 and er["data"]["erased"], er)
st, r, _ = pub("POST", "/api/v2/public/licenses/validate", {"pk": PK, "license_key": NEW, "fingerprint_hash": FP1, "app_version": "3"})
check("after delete the licence no longer works", st == 403 and r["code"] == "license_revoked", r)
st, ex2, _ = req("GET", f"/api/v2/customers/{CUST}/billing-export")
check("after delete: no email, purchases kept", ex2["data"]["customer"]["email"].startswith("deleted+") and len(ex2["data"]["purchases"]) == 1, ex2["data"]["customer"])

print("abuse limits")
for i in range(3):
    pub("POST", "/api/v2/public/licenses/validate", {"pk": PK, "license_key": "AAAAA-AAAAA-AAAAA-AAAAA-AAAA" + str(i), "fingerprint_hash": FP1, "app_version": "3"})
st, r, _ = pub("POST", "/api/v2/public/licenses/validate", {"pk": PK, "license_key": "AAAAA-AAAAA-AAAAA-AAAAA-AAAAZ", "fingerprint_hash": FP1, "app_version": "3"})
check("3 bad keys -> locked out (429)", st == 429 and r["code"] == "locked_out", r)
for i in range(2): pub("POST", "/api/v2/public/billing/access-link", {"pk": PK, "email": "carl@buyer.test"})
st, r, _ = pub("POST", "/api/v2/public/billing/access-link", {"pk": PK, "email": "carl@buyer.test"})
check("access links per email limited (2/h here)", st == 429 and r["code"] == "rate_limited", r)

json.dump({"app": APP, "iss": "https://billing.e2e.test", "fingerprint_hash": FP1, "jwks": pub("GET", "/api/v2/public/billing/jwks.json")[1]},
          open(f"{OUT}/context.json", "w"))
print("\nFAILURES:", len(fails), fails)

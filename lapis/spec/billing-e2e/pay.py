"""Payments end to end (docs/BILLING_ENTITLEMENTS.md §10, §13), against stripe-mock (Stripe's own API mock,
which validates every parameter we send) at api.stripe.com inside the sandbox. Stripe's webhooks are
simulated: signed here with the endpoint secrets, carrying the metadata OpsAPI puts on its sessions."""
import json, time, hmac, hashlib, glob, email, re, base64, urllib.request, urllib.error

B = "http://e2e-api"; OWNER = open("/e2e/owner.jwt").read().strip()
SECRETS = ["whsec_e2e_platform", "whsec_e2e_connect"]
fails = []
def check(name, ok, detail=""):
    print(("  ok   " if ok else "  FAIL ") + name + ("" if ok else f"   {str(detail)[:400]}"))
    if not ok: fails.append(name)
RUN = str(int(time.time()))
WS = "pay" + RUN  # a fresh workspace every run
def req(method, path, body=None, token=OWNER, ns=WS, headers=None, raw=None):
    h = {"Content-Type": "application/json"}
    if token: h["Authorization"] = "Bearer " + token
    if ns and token: h["X-Namespace-Slug"] = ns
    h.update(headers or {})
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    r = urllib.request.Request(B + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=30) as x:
            out = x.read(); return x.status, (json.loads(out) if out else None), dict(x.headers)
    except urllib.error.HTTPError as e:
        out = e.read()
        try: return e.code, json.loads(out), dict(e.headers)
        except Exception: return e.code, out[:300], dict(e.headers)
def pub(method, path, body=None, headers=None): return req(method, path, body, token=None, headers=headers)
n = [0]
def key():
    n[0] += 1; return f"e2e-{time.time()}-{n[0]}"
def hook(etype, obj, secret=SECRETS[0], eid=None, sig=None):
    payload = json.dumps({"id": eid or f"evt_{key()}", "type": etype, "api_version": "2023-10-16", "livemode": False,
                          "data": {"object": obj}}).encode()
    t = int(time.time())
    s = sig or hmac.new(secret.encode(), f"{t}.".encode() + payload, hashlib.sha256).hexdigest()
    return req("POST", "/api/v2/public/billing/stripe/webhook", token=None, raw=payload,
               headers={"Stripe-Signature": f"t={t},v1={s}"})
def claims(jwt):
    p = jwt.split(".")[1]; return json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
def buyer(name): return f"{name}.{RUN}@buyer.test"
def mails_to(addr):
    out = []
    for f in sorted(glob.glob("/mail/*.eml")):
        m = email.message_from_bytes(open(f, "rb").read())
        if addr in (m.get("To") or ""):
            out.append("\n".join(p.get_payload(decode=True).decode("utf-8", "replace") for p in m.walk()
                                 if p.get_content_maintype() == "text"))
    return out

print("setup")
st, _, _ = req("POST", "/api/v2/user/namespaces", {"name": "Pay " + RUN, "slug": WS}, ns=None); check("workspace", st == 201, st)
NS = [w for w in req("GET", "/api/v2/user/namespaces", ns=None)[1]["data"] if w["slug"] == WS][0]["id"]
st, _, _ = req("PUT", "/api/v2/namespace/mail-settings", {"host": "e2e-smtp", "port": 2525, "security": "none", "from_email": "shop@pay.test"})
check("workspace SMTP", st == 200, st)
st, a, _ = req("POST", "/api/v2/billing/apps", {"name": "Draw", "kind": "desktop", "settings": {
    "allowed_redirect_urls": ["https://shop.example/"], "automatic_tax": True}})
check("desktop app (Stripe Tax on)", st == 201, a)
APP, PK = a["data"]["uuid"], a["data"]["publishable_key"]
PLANS = {}
for p in [{"name": "Basic", "plan_key": "basic", "purchase_type": "one_time", "amount": 2900},
          {"name": "Lifetime", "plan_key": "lifetime", "purchase_type": "one_time", "amount": 9900},
          {"name": "Pro yearly", "plan_key": "pro", "purchase_type": "recurring", "amount": 1200, "billing_interval": "year"},
          {"name": "Team yearly", "plan_key": "team", "purchase_type": "recurring", "amount": 3000, "billing_interval": "year"}]:
    p.update({"app": APP, "currency": "gbp", "is_public": True})
    st, r, _ = req("POST", "/api/v2/billing/plans", p); check("plan " + p["plan_key"], st == 201, r)
    PLANS[p["plan_key"]] = r["data"]["uuid"]
for f, t in (("basic", "lifetime"), ("pro", "team")):
    st, _, _ = req("POST", f"/api/v2/billing/apps/{APP}/upgrades", {"from_plan": f, "to_plan": t}); check(f"upgrade path {f} -> {t}", st == 201, st)
st, c, _ = req("POST", "/api/v2/billing/coupons", {"code": "SAVE10", "discount_type": "percent", "percent_off": 10, "app": APP})
check("coupon", st == 201, c); COUPON = c["data"]["uuid"]

print("Stripe Connect")
st, c, _ = req("GET", "/api/v2/billing/connect"); check("not connected yet", st == 200 and c["data"]["connected"] is False, c)
st, r, _ = pub("POST", "/api/v2/public/billing/checkout", {"pk": PK, "plan_key": "lifetime"}, {"Idempotency-Key": key()})
check("checkout before onboarding -> 409 payments_not_ready", st == 409 and r.get("code") == "payments_not_ready", r)
st, o, _ = req("POST", "/api/v2/billing/connect/onboard", {"country": "GB"})
check("onboard -> Stripe onboarding URL", st == 200 and o["data"]["url"].startswith("http"), o)
ACCT = o["data"]["account"]["account"]
st, r, _ = hook("account.updated", {"id": ACCT, "charges_enabled": True, "payouts_enabled": True, "details_submitted": True},
                secret=SECRETS[1])
check("account.updated (connected-account endpoint secret)", st == 200, r)
st, c, _ = req("GET", "/api/v2/billing/connect")
check("connected and able to charge", c["data"]["connected"] and c["data"]["charges_enabled"] and c["data"]["platform_fee_percent"] == 10, c)
st, i, _ = pub("GET", f"/api/v2/public/billing/apps/{PK}"); check("app info says payments are on", i["data"]["payments"] is True, i)

print("webhook security")
st, _, _ = hook("account.updated", {"id": ACCT}, sig="0" * 64); check("bad signature -> 400", st == 400, st)
st, _, _ = hook("account.updated", {"id": ACCT}, secret="whsec_wrong"); check("unknown secret -> 400", st == 400, st)
st, r, _ = hook("checkout.session.completed", {"id": "cs_test_other", "payment_status": "paid", "metadata": {"namespace_id": "1"}})
check("someone else's checkout (tax app) -> ignored", st == 200, r)

print("checkout (hosted Stripe page)")
k = key()
body = {"pk": PK, "plan_key": "lifetime", "coupon": "save10", "email": buyer("ann"), "success_url": "https://shop.example/thanks"}
st, r, _ = pub("POST", "/api/v2/public/billing/checkout", body)
check("Idempotency-Key required", st == 400 and r.get("code") == "idempotency_key_required", r)
st, r, _ = pub("POST", "/api/v2/public/billing/checkout", dict(body, success_url="https://evil.example/"), {"Idempotency-Key": key()})
check("success_url outside the allow-list -> 422", st == 422 and r.get("code") == "redirect_not_allowed", r)
st, r, _ = pub("POST", "/api/v2/public/billing/checkout", body, {"Idempotency-Key": k})
check("one-time checkout with coupon -> Stripe URL (params accepted by Stripe's spec)", st == 201 and r["data"]["url"] and r["data"]["session_id"], r)
st2, r2, h2 = pub("POST", "/api/v2/public/billing/checkout", body, {"Idempotency-Key": k})
check("same key -> replayed", st2 == 201 and h2.get("Idempotent-Replayed") == "true" and r2 == r, (st2, h2))
st, r, _ = pub("POST", "/api/v2/public/billing/checkout", {"pk": PK, "plan_key": "pro", "email": buyer("bob")}, {"Idempotency-Key": key()})
check("subscription checkout (price created on Stripe)", st == 201 and r["data"]["url"], r)
st, r, _ = pub("POST", "/api/v2/public/billing/checkout", {"pk": PK, "plan_key": "nope"}, {"Idempotency-Key": key()})
check("unknown plan -> 404", st == 404, r)
st, r, _ = pub("POST", "/api/v2/public/billing/checkout", {"pk": PK, "plan_key": "lifetime", "coupon": "NOPE"}, {"Idempotency-Key": key()})
check("bad coupon -> 422 coupon_not_found", st == 422 and r.get("code") == "coupon_not_found", r)
st, r, _ = req("POST", "/api/v2/subscriptions/checkout", {"app": APP, "plan": "basic", "customer_external_id": "srv-1",
    "email": buyer("srv")}, headers={"Idempotency-Key": key()})
check("server-side checkout (secret key / JWT)", st == 201 and r["data"]["url"], r)

def session_event(sid, plan, email_addr, amount, extra=None, meta=None):
    m = {"opsapi": "billing", "ns": str(NS), "app": APP, "plan": PLANS[plan], "kind": "new"}
    m.update(meta or {})
    o = {"id": sid, "object": "checkout.session", "payment_status": "paid", "currency": "gbp", "amount_total": amount,
         "total_details": {"amount_discount": 0, "amount_tax": 0}, "customer_details": {"email": email_addr},
         "metadata": m}
    o.update(extra or {})
    return o

print("fulfilment by webhook")
s1 = session_event("cs_test_e2e_life1_" + RUN, "lifetime", buyer("ann"), 8910,
                   {"payment_intent": "pi_e2e_1_" + RUN, "total_details": {"amount_discount": 990, "amount_tax": 0}},
                   {"coupon": COUPON})
st, r, _ = pub("GET", f"/api/v2/public/billing/checkout/cs_test_e2e_life1_{RUN}?pk={PK}")
check("before the webhook: pending", st == 200 and r["data"]["status"] == "pending", r)
EVT = f"evt_{key()}"
st, r, _ = hook("checkout.session.completed", s1, eid=EVT); check("checkout.session.completed -> 200", st == 200, r)
st, r, _ = hook("checkout.session.completed", s1, eid=EVT); check("same event again -> duplicate", st == 200 and r.get("duplicate"), r)
st, r, _ = hook("checkout.session.completed", s1); check("same session, new event id -> no second sale", st == 200, r)
st, o, _ = pub("GET", f"/api/v2/public/billing/checkout/cs_test_e2e_life1_{RUN}?pk={PK}")
KEY = o["data"].get("key")
check("success page: complete, the key shown once", o["data"]["status"] == "complete" and KEY and o["data"]["license"]["key_prefix"] == KEY[:5], o)
st, o2, _ = pub("GET", f"/api/v2/public/billing/checkout/cs_test_e2e_life1_{RUN}?pk={PK}")
check("second look: no key", o2["data"]["status"] == "complete" and not o2["data"].get("key"), o2)
st, pl, _ = req("GET", f"/api/v2/subscriptions/purchases?app={APP}")
ann = [p for p in pl["data"] if p["customer_email"] == buyer("ann")]
check("one purchase: source stripe, 89.10 after the coupon", len(ann) == 1 and ann[0]["source"] == "stripe" and ann[0]["amount"] == 8910
      and ann[0]["coupon_code"] == "SAVE10", ann)
st, red, _ = req("GET", f"/api/v2/billing/coupons/{COUPON}/redemptions"); check("coupon redemption recorded", len(red["data"]) == 1, red)
fp = hashlib.sha256(b"salt:machine").hexdigest()
st, act, _ = pub("POST", "/api/v2/public/licenses/activate", {"pk": PK, "license_key": KEY, "fingerprint_hash": fp, "app_version": "1.0.0"},
                 {"Idempotency-Key": key()})
check("the bought key activates", st == 200 and act["data"]["license_file"], act)
for _ in range(20):
    if mails_to(buyer("ann")): break
    time.sleep(1)
m = mails_to(buyer("ann"))
check("licence key emailed (outbox, workspace SMTP)", any(KEY in x for x in m), len(m))

print("refunds")
st, r, _ = req("POST", f"/api/v2/subscriptions/purchases/{ann[0]['uuid']}/refund", {})
check("refund sent to Stripe", st == 200 and r["data"]["refund"], r)
st, r, _ = hook("charge.refunded", {"id": "ch_e2e_1_" + RUN, "payment_intent": "pi_e2e_1_" + RUN, "refunded": True, "amount": 8910, "amount_refunded": 8910})
check("charge.refunded -> 200", st == 200, r)
st, pl, _ = req("GET", f"/api/v2/subscriptions/purchases?app={APP}&customer={ann[0]['customer_uuid']}")
check("purchase refunded (refund_policy revoke)", pl["data"][0]["status"] == "refunded" and pl["data"][0]["refunded_amount"] == 8910, pl)
st, v, _ = pub("POST", "/api/v2/public/licenses/validate", {"pk": PK, "license_key": KEY, "fingerprint_hash": fp, "app_version": "1.0.0"},
               {"Idempotency-Key": key()})
check("licence revoked", st == 403 and v.get("code") == "license_revoked", v)

print("subscription")
s2 = session_event("cs_test_e2e_sub1_" + RUN, "pro", buyer("bob"), 1200, {"mode": "subscription", "subscription": "sub_e2e_1_" + RUN,
                                                                         "customer": "cus_e2e_1_" + RUN})
st, r, _ = hook("checkout.session.completed", s2); check("subscription checkout completed", st == 200, r)
st, o, _ = pub("GET", f"/api/v2/public/billing/checkout/cs_test_e2e_sub1_{RUN}?pk={PK}")
SUBKEY = o["data"].get("key")
check("subscription order: complete, licence key once", o["data"]["status"] == "complete" and o["data"].get("subscription") and SUBKEY, o)
st, subs, _ = req("GET", f"/api/v2/subscriptions?app={APP}")
bob = [s for s in subs["data"] if s.get("customer_email") == buyer("bob")]
check("subscription row: stripe, active", len(bob) == 1 and bob[0]["status"] == "active", subs)
future = int(time.time()) + 365 * 86400
st, r, _ = hook("customer.subscription.updated", {"id": "sub_e2e_1_" + RUN, "object": "subscription", "status": "active",
    "current_period_end": future, "cancel_at_period_end": False, "metadata": {"opsapi": "billing", "plan": PLANS["pro"]}})
check("renewal (subscription.updated)", st == 200, r)
st, v, _ = pub("POST", "/api/v2/public/licenses/activate", {"pk": PK, "license_key": SUBKEY, "fingerprint_hash": fp, "app_version": "1.0.0"},
               {"Idempotency-Key": key()})
check("subscription licence works until the period end", st == 200 and abs(claims(v["data"]["license_file"])["access_until"] - future) < 5, v)
BOB = bob[0]["customer_uuid"] if "customer_uuid" in bob[0] else bob[0]["customer"]["uuid"]
st, r, _ = req("POST", "/api/v2/subscriptions/portal", {"app": APP, "customer": BOB})
check("Customer Portal URL", st == 200 and r["data"]["url"], r)
st, r, _ = req("POST", "/api/v2/subscriptions/upgrade", {"app": APP, "customer": BOB, "to_plan": "team"})
check("admin switches the Stripe subscription (prorated)", st == 200, r)
st, h, _ = req("GET", f"/api/v2/subscriptions/plan-changes?app={APP}&customer={BOB}")
check("plan change recorded: upgrade via stripe, prorated", any(x["kind"] == "upgrade" and x["source"] == "stripe" for x in h["data"]), h)
st, r, _ = pub("POST", "/api/v2/public/billing/checkout", {"pk": PK, "plan_key": "team", "license_key": SUBKEY}, {"Idempotency-Key": key()})
check("a second subscription is refused", st == 409 and r.get("code") == "already_subscribed", r)
st, r, _ = hook("customer.subscription.deleted", {"id": "sub_e2e_1_" + RUN, "status": "canceled", "ended_at": int(time.time()) - 5,
    "metadata": {"opsapi": "billing", "plan": PLANS["team"]}})
check("subscription.deleted -> 200", st == 200, r)
st, v, _ = pub("POST", "/api/v2/public/licenses/validate", {"pk": PK, "license_key": SUBKEY, "fingerprint_hash": fp, "app_version": "1.0.0"},
               {"Idempotency-Key": key()})
check("ended subscription: licence access over", st == 403 and v.get("code") in ("access_ended", "subscription_inactive"), v)

print("customer upgrades from the account page")
s3 = session_event("cs_test_e2e_basic1_" + RUN, "basic", buyer("cy"), 2900, {"payment_intent": "pi_e2e_3_" + RUN})
st, _, _ = hook("checkout.session.completed", s3); check("Basic bought", st == 200, st)
st, o, _ = pub("GET", f"/api/v2/public/billing/checkout/cs_test_e2e_basic1_{RUN}?pk={PK}"); CYKEY = o["data"].get("key")
st, _, _ = pub("POST", "/api/v2/public/billing/access-link", {"pk": PK, "email": buyer("cy")}, {"Idempotency-Key": key()})
tok = None
for _ in range(20):
    for body_ in mails_to(buyer("cy")):
        mt = re.search(r"#token=([A-Za-z0-9_-]+)", body_)
        if mt: tok = mt.group(1)
    if tok: break
    time.sleep(1)
st, s, _ = pub("POST", "/api/v2/public/billing/sessions", {"pk": PK, "token": tok})
SESSION = {"X-Billing-Session": s["data"]["session"]}
st, me, _ = pub("GET", f"/api/v2/public/billing/me?pk={PK}", headers=SESSION)
up = me["data"]["upgrades"]
check("my account: Lifetime offered at the difference (70.00)", me["data"]["current_plan"]["key"] == "basic"
      and len(up) == 1 and up[0]["plan_key"] == "lifetime" and up[0]["amount"] == 7000, me)
st, r, _ = pub("POST", "/api/v2/public/billing/me/upgrade", {"pk": PK, "to_plan": "lifetime"}, dict(SESSION, **{"Idempotency-Key": key()}))
check("upgrade -> Stripe Checkout for the difference", st == 201 and r["data"]["url"], r)
st, r, _ = pub("POST", "/api/v2/public/billing/me/upgrade", {"pk": PK, "to_plan": "team"}, dict(SESSION, **{"Idempotency-Key": key()}))
check("no path -> 422 no_upgrade_path", st == 422 and r.get("code") == "no_upgrade_path", r)
s4 = session_event("cs_test_e2e_up1_" + RUN, "lifetime", buyer("cy"), 7000, {"payment_intent": "pi_e2e_4_" + RUN},
                   {"kind": "upgrade", "from_plan": PLANS["basic"]})
st, _, _ = hook("checkout.session.completed", s4); check("upgrade paid", st == 200, st)
st, o, _ = pub("GET", f"/api/v2/public/billing/checkout/cs_test_e2e_up1_{RUN}?pk={PK}")
check("upgrade order: no new key (same licence)", o["data"]["status"] == "complete" and not o["data"].get("key"), o)
st, v, _ = pub("POST", "/api/v2/public/licenses/activate", {"pk": PK, "license_key": CYKEY, "fingerprint_hash": fp, "app_version": "1.0.0"},
               {"Idempotency-Key": key()})
check("the original key now carries Lifetime", st == 200 and claims(v["data"]["license_file"])["plan_key"] == "lifetime", v)
st, r, _ = pub("POST", "/api/v2/public/billing/me/portal", {"pk": PK}, SESSION)
check("portal without a subscription -> 404 no_subscription", st == 404 and r.get("code") == "no_subscription", r)

json.dump({"app": APP, "pk": PK, "ws": WS}, open("/e2e/out/pay.json", "w"))  # for sdk.mjs
print("\nFAILURES:", len(fails), fails)

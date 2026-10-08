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
T0 = int(time.time())
def hook(etype, obj, secret=SECRETS[0], eid=None, sig=None, created=None, livemode=False):
    n[0] += 1  # events are created in order, a second apart
    payload = json.dumps({"id": eid or f"evt_{key()}", "type": etype, "api_version": "2023-10-16", "livemode": livemode,
                          "created": created or T0 + n[0], "data": {"object": obj}}).encode()
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
check("admin switch sent to Stripe: pending until the prorated invoice is paid (B9)", st == 200 and r["data"].get("pending") is True, r)
st, h, _ = req("GET", f"/api/v2/subscriptions/plan-changes?app={APP}&customer={BOB}")
check("... nothing recorded or switched yet", not any(x["kind"] == "upgrade" for x in h["data"]), h)
st, r, _ = hook("customer.subscription.updated", {"id": "sub_e2e_1_" + RUN, "object": "subscription", "status": "active",
    "current_period_end": future, "items": {"data": [{"id": "si_1", "price": {"id": "price_not_ours"}}]},
    "metadata": {"opsapi": "billing", "plan": PLANS["team"]}})
st, h, _ = req("GET", f"/api/v2/subscriptions/plan-changes?app={APP}&customer={BOB}")
check("the webhook applies the switch and records it (upgrade via stripe)", any(x["kind"] == "upgrade" and x["source"] == "stripe"
    and x.get("to_plan_uuid") == PLANS["team"] for x in h["data"]), h)
st, r, _ = pub("POST", "/api/v2/public/billing/checkout", {"pk": PK, "plan_key": "team", "license_key": SUBKEY}, {"Idempotency-Key": key()})
check("a second subscription is refused", st == 409 and r.get("code") == "already_subscribed", r)
st, r, _ = hook("customer.subscription.deleted", {"id": "sub_e2e_1_" + RUN, "status": "canceled", "ended_at": int(time.time()) - 5,
    "metadata": {"opsapi": "billing", "plan": PLANS["team"]}})
check("subscription.deleted -> 200", st == 200, r)
st, v, _ = pub("POST", "/api/v2/public/licenses/validate", {"pk": PK, "license_key": SUBKEY, "fingerprint_hash": fp, "app_version": "1.0.0"},
               {"Idempotency-Key": key()})
check("ended subscription: licence access over", st == 403 and v.get("code") in ("access_ended", "subscription_inactive"), v)
st, r, _ = hook("customer.subscription.updated", {"id": "sub_e2e_1_" + RUN, "object": "subscription", "status": "active",
    "current_period_end": future, "metadata": {"opsapi": "billing", "plan": PLANS["team"]}})
st, v, _ = pub("POST", "/api/v2/public/licenses/validate", {"pk": PK, "license_key": SUBKEY, "fingerprint_hash": fp, "app_version": "1.0.0"},
               {"Idempotency-Key": key()})
check("a late 'updated' after 'deleted' doesn't revive it (B5)", st == 403, v)

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

print("review fixes (2026-10-08)")
# B1: coupon limits hold across parallel checkouts; abandoned ones give their use back.
st, c1, _ = req("POST", "/api/v2/billing/coupons", {"code": "FREE" + RUN, "discount_type": "percent", "percent_off": 100,
    "max_redemptions": 1, "app": APP})
check("single-use 100% coupon", st == 201, c1)
ca = {"pk": PK, "plan_key": "lifetime", "coupon": "FREE" + RUN, "email": buyer("free1")}
st, ra, _ = pub("POST", "/api/v2/public/billing/checkout", ca, {"Idempotency-Key": key()})
check("B1 first checkout reserves the only use", st == 201, ra)
st, rb, _ = pub("POST", "/api/v2/public/billing/checkout", dict(ca, email=buyer("free2")), {"Idempotency-Key": key()})
check("B1 a second checkout while the first is open -> 422 coupon_exhausted", st == 422 and rb.get("code") == "coupon_exhausted", rb)
st, _, _ = hook("checkout.session.expired", {"id": ra["data"]["session_id"], "object": "checkout.session", "metadata": {"opsapi": "billing"}})
st, rc, _ = pub("POST", "/api/v2/public/billing/checkout", dict(ca, email=buyer("free3")), {"Idempotency-Key": key()})
check("B1 the expired session gave its use back", st == 201, rc)
st, c2, _ = req("POST", "/api/v2/billing/coupons", {"code": "ONCE" + RUN, "discount_type": "percent", "percent_off": 50,
    "per_customer_limit": 1, "app": APP})
cb = {"pk": PK, "plan_key": "lifetime", "coupon": "ONCE" + RUN}
st, r, _ = pub("POST", "/api/v2/public/billing/checkout", cb, {"Idempotency-Key": key()})
check("B1 per-customer coupon without an email -> 422 email_required", st == 422 and r.get("code") == "email_required", r)
st, r, _ = pub("POST", "/api/v2/public/billing/checkout", dict(cb, email=buyer("once")), {"Idempotency-Key": key()})
check("B1 first use for that email", st == 201, r)
st, r, _ = pub("POST", "/api/v2/public/billing/checkout", dict(cb, email=buyer("ONCE").upper()), {"Idempotency-Key": key()})
check("B1 the same email again (any case) -> coupon_customer_limit", st == 422 and r.get("code") == "coupon_customer_limit", r)

# B2: subscriptions not from Stripe end with their period.
st, r, _ = req("POST", "/api/v2/subscriptions/purchases", {"app": APP, "customer_external_id": "lapsed-" + RUN,
    "email": buyer("lapsed"), "plan": "pro", "expires_at": "not-a-date"})
check("B19 an invalid expires_at -> 4xx, not 500", 400 <= st < 500, (st, r))
st, r, _ = req("POST", "/api/v2/subscriptions/purchases", {"app": APP, "customer_external_id": "lapsed-" + RUN,
    "email": buyer("lapsed"), "plan": "pro", "expires_at": "2020-01-01T00:00:00Z"})
check("a manual subscription whose period has ended", st == 201, r)
st, subs, _ = req("GET", f"/api/v2/subscriptions?app={APP}")
lapsed = [x for x in subs["data"] if x.get("customer_email") == buyer("lapsed")]
st, e, _ = req("GET", f"/api/v2/subscriptions/entitlements?app={APP}&customer={lapsed[0]['customer_uuid']}")
check("B2 ... no longer entitles", st == 200 and (e["data"].get("plan") or {}).get("key") != "pro", e)

# B3: the past-due grace counts from the failed payment, not the (moved) period end.
s6 = session_event("cs_test_e2e_sub3_" + RUN, "pro", buyer("eve"), 1200, {"mode": "subscription", "subscription": "sub_e2e_3_" + RUN,
                                                                        "customer": "cus_e2e_3_" + RUN})
st, _, _ = hook("checkout.session.completed", s6)
st, _, _ = hook("customer.subscription.updated", {"id": "sub_e2e_3_" + RUN, "object": "subscription", "status": "past_due",
    "current_period_end": future, "metadata": {"opsapi": "billing", "plan": PLANS["pro"]}})
st, subs, _ = req("GET", f"/api/v2/subscriptions?app={APP}")
eve = [x for x in subs["data"] if x.get("customer_email") == buyer("eve")][0]
st, e, _ = req("GET", f"/api/v2/subscriptions/entitlements?app={APP}&customer={eve['customer_uuid']}")
check("past_due within its grace still entitles", (e["data"].get("plan") or {}).get("key") == "pro", e)
st, _, _ = req("PUT", f"/api/v2/billing/apps/{APP}", {"settings": {"past_due_grace_days": 0}})
st, e, _ = req("GET", f"/api/v2/subscriptions/entitlements?app={APP}&customer={eve['customer_uuid']}")
check("B3 grace 0: past_due ends access although the period end is a year away", (e["data"].get("plan") or {}).get("key") != "pro", e)
st, _, _ = req("PUT", f"/api/v2/billing/apps/{APP}", {"settings": {"past_due_grace_days": 7}})
st, _, _ = hook("customer.subscription.updated", {"id": "sub_e2e_3_" + RUN, "object": "subscription", "status": "active",
    "current_period_end": future, "metadata": {"opsapi": "billing", "plan": PLANS["pro"]}}, created=T0 - 1000)
st, subs, _ = req("GET", f"/api/v2/subscriptions?app={APP}")
eve = [x for x in subs["data"] if x.get("customer_email") == buyer("eve")][0]
check("B5 an older event than the last one applied is skipped", eve["status"] == "past_due", eve)

# B6b: a replayed reissue never gives the key again (it isn't stored).
CYLIC = me["data"]["licences"][0]["uuid"]
k6 = key()
st, r1, _ = pub("POST", f"/api/v2/public/billing/me/licenses/{CYLIC}/reissue?pk={PK}", {}, dict(SESSION, **{"Idempotency-Key": k6}))
CYKEY = r1["data"]["key"] if st == 200 else CYKEY
st, r2, h2 = pub("POST", f"/api/v2/public/billing/me/licenses/{CYLIC}/reissue?pk={PK}", {}, dict(SESSION, **{"Idempotency-Key": k6}))
check("B6b replay: same answer without the key (key_redacted)", st == 200 and h2.get("Idempotent-Replayed") == "true"
      and r2["data"].get("key") is None and r2["data"].get("key_redacted") is True, r2)

# B11: releasing a device doesn't free its seat for the hold period; an admin release does.
fps = {n_: hashlib.sha256(f"salt:{n_}".encode()).hexdigest() for n_ in ("d1", "d2", "d3", "d4")}
# Three seats: the device activated earlier, d1 and d2.
for n_ in ("d1", "d2"):
    st, r, _ = pub("POST", "/api/v2/public/licenses/activate", {"pk": PK, "license_key": CYKEY, "fingerprint_hash": fps[n_],
        "app_version": "1.0.0", "name": n_}, {"Idempotency-Key": key()})
    check("activate " + n_, st == 200, r)
st, r, _ = pub("POST", "/api/v2/public/licenses/deactivate", {"pk": PK, "license_key": CYKEY, "fingerprint_hash": fps["d2"]},
               {"Idempotency-Key": key()})
check("a device releases its own seat", st == 200, r)
st, r, _ = pub("POST", "/api/v2/public/licenses/activate", {"pk": PK, "license_key": CYKEY, "fingerprint_hash": fps["d4"],
    "app_version": "1.0.0", "name": "d4"}, {"Idempotency-Key": key()})
check("B11 ... but it still counts: a new device is refused (no activate/deactivate cycling)", st == 409 and r.get("code") == "activation_limit", r)
st, lic, _ = req("GET", f"/api/v2/licenses/{CYLIC}")
d1 = [a_ for a_ in lic["data"]["activations"] if a_.get("name") == "d1" and not a_.get("deactivated_at")]
st, r, _ = req("DELETE", f"/api/v2/licenses/{CYLIC}/activations/{d1[0]['uuid']}")
st, r, _ = pub("POST", "/api/v2/public/licenses/activate", {"pk": PK, "license_key": CYKEY, "fingerprint_hash": fps["d4"],
    "app_version": "1.0.0", "name": "d4"}, {"Idempotency-Key": key()})
check("B11 a seat an admin frees is free at once", st == 200, r)

# B12 / B13 / B16: a second app, plans behind billing.read, per-app transaction ids, account pages stay in their app.
st, ak, _ = req("POST", "/api/v2/api-keys", {"name": "ent-" + RUN, "scopes": {"entitlements": ["read", "create"]}})
EKEY = ak["data"]["key"]
st, r, _ = req("GET", f"/api/v2/billing/plans?app={APP}", token=EKEY)
check("B12 an entitlements-only key can't read an app's plans", st == 403, (st, r))
st, two, _ = req("POST", "/api/v2/billing/apps", {"name": "Two " + RUN, "kind": "desktop"})
TWO = two["data"]["uuid"]
st, _, _ = req("POST", "/api/v2/billing/plans", {"app": TWO, "name": "One", "plan_key": "one", "purchase_type": "one_time",
    "amount": 100, "currency": "gbp"})
st, _, _ = req("POST", "/api/v2/billing/plans", {"app": APP, "name": "Ext", "plan_key": "ext", "purchase_type": "one_time",
    "amount": 100, "currency": "gbp"})
ext = {"customer_external_id": "ext-" + RUN, "email": buyer("ext"), "source": "external", "external_transaction_id": "txn-" + RUN}
st, r1, _ = req("POST", f"/api/v2/entitlements/{APP}/purchases", dict(ext, plan_key="ext"), token=EKEY, headers={"Idempotency-Key": key()})
st2, r2, _ = req("POST", f"/api/v2/entitlements/{TWO}/purchases", dict(ext, plan_key="one"), token=EKEY, headers={"Idempotency-Key": key()})
check("B13 the same store transaction id in two apps: two purchases", st == 201 and st2 == 201 and not r2["data"].get("duplicate"), (r1, r2))
st, pl, _ = req("GET", f"/api/v2/subscriptions/purchases?app={APP}")
cyu = [p_ for p_ in pl["data"] if p_["customer_email"] == buyer("cy")][0]["customer_uuid"]
st, il, _ = req("POST", "/api/v2/licenses", {"app": TWO, "customer": cyu})
st, r, _ = pub("POST", f"/api/v2/public/billing/me/licenses/{il['data']['license']['uuid']}/reissue?pk={PK}", {}, dict(SESSION, **{"Idempotency-Key": key()}))
check("B16 an account session can't reissue a licence of another app", st == 404, (st, r))

# B17 / B19 smaller items.
for bad in ("https://shop.example.evil.com/x", "https://shop.example/a/../b", "https://shop.example/a/%2e%2e/b"):
    st, r, _ = pub("POST", "/api/v2/public/billing/checkout", {"pk": PK, "plan_key": "lifetime", "success_url": bad}, {"Idempotency-Key": key()})
    check(f"B17 redirect {bad} -> 422", st == 422 and r.get("code") == "redirect_not_allowed", r)
st, r, _ = req("PUT", f"/api/v2/billing/apps/{APP}", {"settings": {"allowed_origins": ["http://localhost.evil.com"]}})
check("B19 http://localhost.evil.com is not localhost", st in (400, 422), (st, r))
st, r, _ = req("PUT", f"/api/v2/billing/plans/{PLANS['lifetime']}", {"plan_type": "subscription"})
check("B19 plan_type can't contradict purchase_type", st in (400, 422), (st, r))
st, r, _ = hook("account.updated", {"id": ACCT}, livemode=True)
check("B19 a live event to a test deployment -> 400", st == 400, r)
s7 = session_event("cs_test_e2e_fay1_" + RUN, "basic", buyer("fay"), 2900, {"payment_intent": "pi_e2e_7_" + RUN})
st, _, _ = hook("checkout.session.completed", s7)
st, r, _ = hook("charge.dispute.closed", {"id": "dp_1", "status": "lost", "payment_intent": "pi_e2e_7_" + RUN, "amount": 2900})
st, pl, _ = req("GET", f"/api/v2/subscriptions/purchases?app={APP}")
fay = [p_ for p_ in pl["data"] if p_["customer_email"] == buyer("fay")][0]
check("B19 a lost dispute follows refund_policy (revoke)", fay["status"] == "refunded", fay)
st, r, _ = req("DELETE", f"/api/v2/customers/{fay['customer_uuid']}")
check("B19 deleting a customer who has purchases -> 409 (not 500)", st == 409, (st, r))
st, r, _ = pub("POST", "/api/v2/public/billing/access-link", {"pk": PK, "email": buyer("nobody")}, {"Idempotency-Key": key()})
check("access link for an unknown email: the same 202", st == 202, r)

# B7: refunds undo what each purchase granted (cy: Basic, then the Lifetime upgrade).
st, r, _ = hook("charge.refunded", {"id": "ch_3", "payment_intent": "pi_e2e_3_" + RUN, "refunded": True, "amount": 2900, "amount_refunded": 2900})
st, v, _ = pub("POST", "/api/v2/public/licenses/validate", {"pk": PK, "license_key": CYKEY, "fingerprint_hash": fps["d4"], "app_version": "1.0.0"},
               {"Idempotency-Key": key()})
check("B7 refunding the original purchase leaves the upgrade's access", st == 200 and claims(v["data"]["license_file"])["plan_key"] == "lifetime", v)
st, r, _ = hook("charge.refunded", {"id": "ch_4", "payment_intent": "pi_e2e_4_" + RUN, "refunded": True, "amount": 7000, "amount_refunded": 7000})
st, v, _ = pub("POST", "/api/v2/public/licenses/validate", {"pk": PK, "license_key": CYKEY, "fingerprint_hash": fps["d4"], "app_version": "1.0.0"},
               {"Idempotency-Key": key()})
check("B7 refunding the upgrade too: nothing left, the licence is revoked", st == 403 and v.get("code") == "license_revoked", v)

print("privacy delete")
s5 = session_event("cs_test_e2e_sub2_" + RUN, "pro", buyer("dee"), 1200, {"mode": "subscription", "subscription": "sub_e2e_2_" + RUN,
                                                                        "customer": "cus_e2e_2_" + RUN})
st, _, _ = hook("checkout.session.completed", s5); check("Dee subscribes", st == 200, st)
st, subs, _ = req("GET", f"/api/v2/subscriptions?app={APP}")
dee = [x for x in subs["data"] if x.get("customer_email") == buyer("dee")]
st, r, _ = req("DELETE", f"/api/v2/customers/{dee[0]['customer_uuid']}/billing-data")
check("delete: the Stripe subscription is cancelled at Stripe, then the customer erased", st == 200 and r["data"]["erased"], r)
st, subs, _ = req("GET", f"/api/v2/subscriptions?app={APP}&status=canceled")
check("her subscription is cancelled here too", any(x["uuid"] == dee[0]["uuid"] for x in subs["data"]), subs)

json.dump({"app": APP, "pk": PK, "ws": WS}, open("/e2e/out/pay.json", "w"))  # for sdk.mjs
print("\nFAILURES:", len(fails), fails)

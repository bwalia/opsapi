#!/usr/bin/env python3
"""VIP price-lock membership end-to-end checks (driven by run.sh in a throwaway sandbox).

Usage: check.py <api_url> <shop_bff_key> <webhook_secret> <postgres_container> <smtp_sink_container>
Calls the public shop API as the shop BFF does, sends Stripe webhooks signed with the sandbox secret,
reads the sign-in email from the SMTP sink and checks the database with psql in the sandbox Postgres.
"""
import email, hashlib, hmac, json, re, subprocess, sys, time, urllib.request, urllib.error, secrets
from email import policy

API, KEY, WHSEC, PG, SMTP = sys.argv[1:6]
BASE = API + "/api/v2/public/shop/workstation"
HOOK = API + "/api/v2/public/shop/stripe/webhook"
RUN = secrets.token_hex(3)
passed = failed = 0


def check(name, cond, detail=None):
    global passed, failed
    if cond:
        passed += 1
        print("ok   -", name)
    else:
        failed += 1
        print("FAIL -", name, f"[{detail}]" if detail is not None else "")


def sql(q):
    out = subprocess.run(["docker", "exec", "-i", PG, "psql", "-At", "-F", "|", "-U", "postgres", "-d", "e2e"],
                         input=q, capture_output=True, text=True)
    if out.returncode != 0 or "ERROR" in out.stderr:
        raise RuntimeError(out.stderr)
    return [l for l in out.stdout.strip().splitlines() if l]


def call(method, path, body=None, member=None, cart=None, base=BASE):
    h = {"X-Shop-Key": KEY, "Content-Type": "application/json"}
    if member: h["X-Member-Token"] = member
    if cart: h["X-Cart-Token"] = cart
    req = urllib.request.Request(base + path, method=method, headers=h,
                                 data=None if body is None else json.dumps(body).encode())
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def hook(etype, obj):
    payload = json.dumps({"id": "evt_" + secrets.token_hex(8), "type": etype, "data": {"object": obj}})
    t = str(int(time.time()))
    sig = hmac.new(WHSEC.encode(), f"{t}.{payload}".encode(), hashlib.sha256).hexdigest()
    req = urllib.request.Request(HOOK, method="POST", data=payload.encode(),
                                 headers={"Stripe-Signature": f"t={t},v1={sig}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code


def join(email, interval="month"):
    return call("POST", "/membership/checkout", {
        "email": email, "interval": interval, "accept_terms": True, "terms_version": "2026-10",
        "success_url": "https://shop.e2e.test/vip/welcome", "cancel_url": "https://shop.e2e.test/vip"})


def membership(email):
    rows = sql(f"select uuid,tier,status,net_minor,fees_paid_net_minor,fees_credited_net_minor,billing_subscription_id is not null,"
               f"cancel_at_period_end from shop_memberships where email='{email}' order by id desc limit 1")
    return rows[0].split("|") if rows else None


def cart_with(qty, slug="rtx-pro-6000-blackwell-workstation", member=None):
    _, c = call("POST", "/carts", {})
    tok = c["data"]["token"]
    st, _ = call("POST", "/cart/lines", {"product_slug": slug, "qty": qty}, cart=tok, member=member)
    return tok, st


A, B, C, D, X = (f"{n}.{RUN}@vip-test.example" for n in ("alice", "bob", "carol", "dan", "xena"))

# --- closed by default -----------------------------------------------------------------
st, r = join(A)
check("closed: checkout refused until enabled", st == 409 and r.get("code") == "MEMBERSHIP_CLOSED", r)

sql("INSERT INTO shop_membership_settings (namespace_id, enabled, founding_cap) SELECT id, true, 2 FROM namespaces "
    "WHERE slug='workstation' ON CONFLICT (namespace_id) DO UPDATE SET enabled=true, founding_cap=2;")

# --- validation ----------------------------------------------------------------------------
st, r = call("POST", "/membership/checkout", {"email": A, "interval": "month", "accept_terms": False, "terms_version": "2026-10",
                                              "success_url": "https://shop.e2e.test/a", "cancel_url": "https://shop.e2e.test/b"})
check("terms: must be accepted", st == 400 and r.get("code") == "TERMS_NOT_ACCEPTED", r)
st, r = call("POST", "/membership/checkout", {"email": A, "interval": "month", "accept_terms": True, "terms_version": "old",
                                              "success_url": "https://shop.e2e.test/a", "cancel_url": "https://shop.e2e.test/b"})
check("terms: stale version refused", st == 409 and r.get("code") == "TERMS_CHANGED", r)

# --- founding cap (cap 2) ----------------------------------------------------------------------
st, a = join(A)
check("cap: 1st joiner gets founding £75", st == 201 and a["data"]["tier"] == "founding" and a["data"]["net_minor"] == 7500, a)
check("checkout: Stripe URL returned", a["data"].get("checkout_url", "").startswith("http"), a)
st, b = join(B, "year")
check("cap: 2nd joiner gets founding yearly £750", b["data"]["tier"] == "founding" and b["data"]["net_minor"] == 75000, b)
_, offer = call("GET", "/membership")
check("cap: spots left is 0 while two checkouts hold spots", offer["data"]["founding"]["spots_left"] == 0, offer["data"]["founding"])
check("cap: public price is now the standard price", offer["data"]["tier"] == "standard"
      and offer["data"]["price"]["month"]["net_minor"] == 9975, offer["data"]["price"])
st, c = join(C)
check("cap: 3rd joiner really pays +33% (£99.75)", c["data"]["tier"] == "standard" and c["data"]["net_minor"] == 9975, c)

sql(f"UPDATE shop_memberships SET reserve_expires_at = NOW() - interval '1 minute' WHERE email = '{A}';")
_, offer = call("GET", "/membership")
check("cap: an expired checkout frees its spot", offer["data"]["founding"]["spots_left"] == 1, offer["data"]["founding"])
st, d = join(D)
check("cap: next joiner gets the freed founding spot", d["data"]["tier"] == "founding", d)
check("cap: expired reservation marked abandoned", membership(A)[2] == "abandoned", membership(A))

# --- activation via webhook ----------------------------------------------------------------------
mb = membership(B)
st = hook("checkout.session.completed", {"id": "cs_b", "object": "checkout.session", "mode": "subscription",
                                          "payment_status": "paid", "client_reference_id": mb[0], "subscription": f"sub_b_{RUN}",
                                          "customer": "cus_b", "metadata": {"membership_uuid": mb[0], "source": "workstation-shop-vip"}})
check("webhook: session completed accepted", st == 200, st)
mb = membership(B)
check("webhook: membership active", mb[2] == "active", mb)
check("billing: mirrored into billing_subscriptions", mb[6] == "t", mb)
bs = sql(f"select bs.status, bp.plan_key, c.email from billing_subscriptions bs join billing_plans bp on bp.id = bs.plan_id "
         f"join customers c on c.id = bs.customer_id where bs.stripe_subscription_id = 'sub_b_{RUN}'")
check("billing: active founding-yearly plan for the customer", bs and bs[0] == f"active|vip-founding-year|{B}", bs)
lead = sql(f"select notes from crm_leads where lower(email) = '{B}'")
check("crm: join noted on the lead", lead and "Joined VIP membership" in lead[0], lead)

inv = {"id": f"in_b1_{RUN}", "object": "invoice", "subscription": f"sub_b_{RUN}", "amount_paid": 90000,
       "subscription_details": {"metadata": {"membership_uuid": mb[0], "source": "workstation-shop-vip"}},
       "lines": {"data": [{"period": {"end": int(time.time()) + 365 * 86400}}]}}
hook("invoice.paid", inv)
hook("invoice.paid", inv)  # same invoice, new event id → must not double count
check("fees: invoice counted once, ex VAT (£750)", membership(B)[4] == "75000", membership(B))

# --- sign-in ------------------------------------------------------------------------------------------
st, r = call("POST", "/member/login", {"email": B})
same_st, same_r = call("POST", "/member/login", {"email": X})
check("sign-in: same answer for members and non-members", st == 200 and same_st == 200 and r == same_r, (r, same_r))
check("sign-in: a link token was created for the member only",
      sql(f"select count(*) from shop_member_tokens where email='{B}' and kind='link'") == ["1"]
      and sql(f"select count(*) from shop_member_tokens where email='{X}'") == ["0"])
def mails():
    """Every message the SMTP sink has received (read inside the sink container)."""
    out = subprocess.run(["docker", "exec", SMTP, "sh", "-c", 'for f in /mail/*.eml; do [ -f "$f" ] && cat "$f" && printf "\\n@@EML@@\\n"; done'],
                         capture_output=True)
    return [email.message_from_bytes(raw, policy=policy.default) for raw in out.stdout.split(b"\n@@EML@@\n") if raw.strip()]


def sign_in_link(to):
    for _ in range(40):
        for msg in mails():
            if to in str(msg.get("To", "")):
                body = msg.get_body(preferencelist=("html", "plain")).get_content()
                m = re.search(r"/members/verify\?t=([A-Za-z0-9_-]+)", body)
                if m:
                    return msg, m.group(1)
        time.sleep(0.25)
    return None, None

msg, link = sign_in_link(B)
check("sign-in: email delivered with a one-time link", link is not None)
check("sign-in: link points at the shop", msg is not None and "https://shop.e2e.test/members/verify?t=" in
      msg.get_body(preferencelist=("html", "plain")).get_content())
check("sign-in: no email for non-members", not any(X in str(m.get("To", "")) for m in mails()))
st, v = call("POST", "/member/verify", {"token": link})
check("sign-in: link gives a session", st == 200 and v["data"]["email"] == B, v)
st, v2 = call("POST", "/member/verify", {"token": link})
check("sign-in: link works only once", st == 410, v2)
session = v["data"]["session_token"]
st, me = call("GET", "/member", member=session)
check("member page: active founding yearly", me["data"]["active"] and me["data"]["membership"]["tier"] == "founding"
      and me["data"]["membership"]["interval"] == "year", me)
st, _ = call("GET", "/member", member="x" * 40)
check("member page: bad session → 401", st == 401)

# --- price lock ------------------------------------------------------------------------------------------
def quote(email, member=None):
    tok, _ = cart_with(1, member=member)
    st, q = call("POST", "/quotes", {"from": "cart", "customer": {"name": "Bob", "email": email}, "source": "cart"},
                 cart=tok, member=member)
    return st, q["data"]

def days_valid(q):
    return round(int(sql(f"select extract(epoch from valid_until - created_at) from shop_quotes where uuid='{q['uuid']}'")[0]
                     .split('.')[0]) / 86400)

st, q1 = quote(B, member=session)
check("lock: member's own quote locked for 90 days", q1["price_locked"] is True and days_valid(q1) == 90, (q1.get("price_locked"), days_valid(q1)))
st, q2 = quote(B)
check("lock: same email without sign-in → normal 30 days", q2["price_locked"] is False and days_valid(q2) == 30)
st, q3 = quote(X, member=session)
check("lock: member signed in, someone else's email → 30 days", q3["price_locked"] is False and days_valid(q3) == 30)
sql("UPDATE shop_membership_settings SET lock_days = 120;")
st, q4 = quote(B, member=session)
check("lock: 120-day setting honoured", days_valid(q4) == 120)
sql("UPDATE shop_membership_settings SET lock_days = 90;")
# price change after the quote: checkout still uses the quote's price
before = int(sql(f"select subtotal_minor from shop_quotes where uuid='{q1['uuid']}'")[0])
sql("UPDATE shop_products SET base_price_minor = base_price_minor + 100000 WHERE slug='rtx-pro-6000-blackwell-workstation';")
qt = sql(f"select access_token from shop_quotes where uuid='{q1['uuid']}'")[0]
st, co = call("POST", "/checkout", {"from": "quote", "quote_uuid": q1["uuid"], "quote_token": qt,
                                     "success_url": "https://shop.e2e.test/ok", "cancel_url": "https://shop.e2e.test/no"}, member=session)
paid_sub = int(sql(f"select subtotal_minor from shop_orders where uuid='{co['data']['order_uuid']}'")[0]) if st == 201 or st == 200 else None
check("lock: price rise after the quote doesn't change the locked price", paid_sub == before, (st, co, paid_sub, before))
sql("UPDATE shop_products SET base_price_minor = base_price_minor - 100000 WHERE slug='rtx-pro-6000-blackwell-workstation';")
hook("checkout.session.expired", {"id": "cs_x", "object": "checkout.session", "metadata": {"order_uuid": co["data"]["order_uuid"]}})

# --- refund credit on a £100k+ order -----------------------------------------------------------------------
tok, _ = cart_with(8, member=session)   # 8 × £12,999 = £103,992 ex VAT
st, big = call("POST", "/checkout", {"from": "cart", "email": B, "success_url": "https://shop.e2e.test/ok",
                                      "cancel_url": "https://shop.e2e.test/no"}, cart=tok, member=session)
check("refund: big order checkout started", st in (200, 201), big)
hook("checkout.session.completed", {"id": "cs_big", "object": "checkout.session", "mode": "payment", "payment_status": "paid",
                                    "metadata": {"order_uuid": big["data"]["order_uuid"]}, "customer_details": {"email": B}})
cr = sql(f"select amount_minor, source, status from shop_credits where email='{B}' and source='vip_refund'")
check("refund: fees (£750 ex VAT) returned as credit", cr == ["75000|vip_refund|available"], cr)
check("refund: fees marked as credited", membership(B)[5] == "75000", membership(B))
# second qualifying order: nothing new to refund
tok, _ = cart_with(8, member=session)
st, big2 = call("POST", "/checkout", {"from": "cart", "email": B, "success_url": "https://shop.e2e.test/ok",
                                       "cancel_url": "https://shop.e2e.test/no"}, cart=tok, member=session)
# (this checkout uses the credit; expire it so the credit returns)
hook("checkout.session.expired", {"id": "cs_big2", "object": "checkout.session", "metadata": {"order_uuid": big2["data"]["order_uuid"]}})
check("credit: released when the checkout expires",
      sql(f"select status from shop_credits where email='{B}' and source='vip_refund' and created_by='system'") == ["available"])
# small order below threshold from non-member: no credit
tok, _ = cart_with(8)
st, nm = call("POST", "/checkout", {"from": "cart", "email": X, "success_url": "https://shop.e2e.test/ok",
                                     "cancel_url": "https://shop.e2e.test/no"}, cart=tok)
hook("checkout.session.completed", {"id": "cs_nm", "object": "checkout.session", "mode": "payment", "payment_status": "paid",
                                    "metadata": {"order_uuid": nm["data"]["order_uuid"]}, "customer_details": {"email": X}})
check("refund: non-members get no credit", sql(f"select count(*) from shop_credits where email='{X}'") == ["0"])

# --- applying credit ------------------------------------------------------------------------------------------
tok, _ = cart_with(1, member=session)  # £12,999 ex VAT
st, co = call("POST", "/checkout", {"from": "cart", "email": B, "success_url": "https://shop.e2e.test/ok",
                                     "cancel_url": "https://shop.e2e.test/no"}, cart=tok, member=session)
row = sql(f"select subtotal_minor, vat_minor, total_minor, credit_minor, stripe_coupon_id is not null from shop_orders "
          f"where uuid='{co['data']['order_uuid']}'")[0].split("|")
check("credit: £750 off the subtotal ex VAT", row[0] == str(1299900 - 75000) and row[3] == "75000", row)
check("credit: VAT recomputed on the reduced subtotal", row[1] == str(round((1299900 - 75000) * 0.2)), row)
check("credit: applied via a one-off Stripe coupon", row[4] == "t", row)
check("credit: reserved while paying", sql(f"select status from shop_credits where email='{B}' and source='vip_refund'") == ["reserved"])
st, other = call("POST", "/checkout", {"from": "cart", "email": X, "success_url": "https://shop.e2e.test/ok",
                                        "cancel_url": "https://shop.e2e.test/no"}, cart=cart_with(1)[0], member=session)
orow = sql(f"select credit_minor from shop_orders where uuid='{other['data']['order_uuid']}'")
check("credit: never applied to someone else's email", orow == ["0"], orow)
hook("checkout.session.completed", {"id": "cs_cr", "object": "checkout.session", "mode": "payment", "payment_status": "paid",
                                    "metadata": {"order_uuid": co["data"]["order_uuid"]}, "customer_details": {"email": B}})
check("credit: used once the order is paid", sql(f"select status from shop_credits where email='{B}' and source='vip_refund'") == ["used"])

# --- early access -------------------------------------------------------------------------------------------------
slug = "rtx-pro-4500-blackwell"
sql(f"UPDATE shop_products SET public_launch_at = NOW() + interval '12 hours' WHERE slug = '{slug}';")
st, _ = call("GET", f"/products/{slug}")
check("early access: hidden from the public before launch", st == 404, st)
st, p = call("GET", f"/products/{slug}", member=session)
check("early access: members see it 24 h early", st == 200 and p["data"]["public_launch_at"] is not None, st)
st, ea = call("GET", "/member/early-access", member=session)
check("early access: listed on the member page", any(x["slug"] == slug for x in ea["data"]), ea)
_, cartp = call("POST", "/carts", {})
st, _ = call("POST", "/cart/lines", {"product_slug": slug, "qty": 1}, cart=cartp["data"]["token"])
check("early access: public can't add it to a basket", st == 404, st)
st, _ = call("POST", "/cart/lines", {"product_slug": slug, "qty": 1}, cart=cartp["data"]["token"], member=session)
check("early access: members can pre-order it", st == 201, st)
sql(f"UPDATE shop_products SET public_launch_at = NOW() + interval '48 hours' WHERE slug = '{slug}';")
st, _ = call("GET", f"/products/{slug}", member=session)
check("early access: not before the member window opens", st == 404, st)
sql(f"UPDATE shop_products SET public_launch_at = NULL WHERE slug = '{slug}';")

# --- waitlist ----------------------------------------------------------------------------------------------------------
st, w1 = call("POST", f"/products/{slug}/waitlist", {"email": X})
st2, w2 = call("POST", f"/products/{slug}/waitlist", {"email": B}, member=session)
st3, w3 = call("POST", f"/products/{slug}/waitlist", {"email": D}, member=session)
check("waitlist: non-member joins without priority", w1["data"]["priority"] is False)
check("waitlist: signed-in member gets priority", w2["data"]["priority"] is True)
check("waitlist: member can't give priority to another email", w3["data"]["priority"] is False)
order = sql(f"select w.email from shop_waitlist w join shop_products p on p.id = w.product_id where p.slug='{slug}' "
            f"and w.email like '%{RUN}%' order by w.is_member desc, w.created_at")
check("waitlist: members first", order and order[0] == B, order)

# --- cancel + end -------------------------------------------------------------------------------------------------------
st, me = call("POST", "/member/cancel", member=session)
check("cancel: at the end of the paid period", st == 200 and me["data"]["membership"]["cancel_at_period_end"] is True, me)
hook("customer.subscription.deleted", {"id": f"sub_b_{RUN}", "object": "subscription", "status": "canceled",
                                       "canceled_at": int(time.time()), "metadata": {"membership_uuid": mb[0], "source": "workstation-shop-vip"}})
st, me = call("GET", "/member", member=session)
check("cancel: once ended, no member benefits", st == 200 and me["data"]["active"] is False, me)
check("billing: mirror shows canceled", sql(f"select status from billing_subscriptions where stripe_subscription_id='sub_b_{RUN}'") == ["canceled"])
st, q5 = quote(B, member=session)
check("lock: ex-member's new quotes are normal 30 days", q5["price_locked"] is False and days_valid(q5) == 30)

# --- webhook security ----------------------------------------------------------------------------------------------
bad = urllib.request.Request(HOOK, method="POST", data=b'{"id":"evt_x","type":"invoice.paid","data":{"object":{}}}',
                             headers={"Stripe-Signature": "t=1,v1=deadbeef", "Content-Type": "application/json"})
try:
    urllib.request.urlopen(bad)
    code = 200
except urllib.error.HTTPError as e:
    code = e.code
check("webhook: bad signature rejected", code == 400, code)

st, out = call("POST", "/member/logout", member=session)
st, _ = call("GET", "/member", member=session)
check("sign-out: session ends", st == 401, st)

print(f"\n{passed} passed, {failed} failed  (run {RUN})")
sys.exit(1 if failed else 0)

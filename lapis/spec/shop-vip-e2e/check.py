#!/usr/bin/env python3
"""VIP price-lock membership end-to-end checks (driven by run.sh in a throwaway sandbox).

Usage: check.py <api_url> <shop_bff_key> <webhook_secret> <postgres_container> <smtp_sink_container> <admin_jwt> <feed_container>
Calls the public shop API as the shop BFF does, sends Stripe webhooks signed with the sandbox secret,
reads the sign-in email from the SMTP sink and checks the database with psql in the sandbox Postgres.
"""
import email, hashlib, hmac, http.client, json, re, subprocess, sys, time, urllib.parse, urllib.request, urllib.error, secrets
from email import policy

API, KEY, WHSEC, PG, SMTP, ADMIN, FEED = sys.argv[1:8]
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


def admin(method, path, body=None):
    """Shop admin API as the namespace owner (JWT + namespace slug)."""
    h = {"Authorization": "Bearer " + ADMIN, "X-Namespace-Slug": "workstation", "Content-Type": "application/json"}
    req = urllib.request.Request(API + "/api/v2/shop/admin" + path, method=method, headers=h,
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

st, r = admin("PUT", "/membership/settings", {"lock_days": 45})
check("admin settings: lock must be 90 or 120", st == 400, r)
st, r = admin("PUT", "/membership/settings", {"enabled": True, "founding_cap": 2})
check("admin settings: opened with a cap of 2", st == 200 and r["data"]["enabled"] is True and r["data"]["founding_cap"] == 2, r)

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
check("admin settings: lock set to 120", admin("PUT", "/membership/settings", {"lock_days": 120})[0] == 200)
st, q4 = quote(B, member=session)
check("lock: 120-day setting honoured", days_valid(q4) == 120)
admin("PUT", "/membership/settings", {"lock_days": 90})
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
check("trade: non-members get no trade discount",
      sql(f"select member_discount_minor from shop_orders where uuid='{nm['data']['order_uuid']}'") == ["0"])

# --- applying credit ------------------------------------------------------------------------------------------
tok, _ = cart_with(1, member=session)  # £12,999 ex VAT
st, co = call("POST", "/checkout", {"from": "cart", "email": B, "success_url": "https://shop.e2e.test/ok",
                                     "cancel_url": "https://shop.e2e.test/no"}, cart=tok, member=session)
row = sql(f"select subtotal_minor, vat_minor, total_minor, credit_minor, stripe_coupon_id is not null, member_discount_minor, "
          f"member_discount_pct from shop_orders where uuid='{co['data']['order_uuid']}'")[0].split("|")
# B is a founding Trade member: 5% trade discount first, then the £750 credit on the discounted subtotal.
TRADE5 = round(1299900 * 5 / 100)
check("trade: founding member gets 5% off a basket order", row[5] == str(TRADE5) and float(row[6]) == 5.0, row)
check("trade: checkout response reports the discount", co["data"].get("member_discount_minor") == TRADE5, co["data"])
check("credit: £750 off the discounted subtotal ex VAT", row[0] == str(1299900 - TRADE5 - 75000) and row[3] == "75000", row)
check("credit: VAT recomputed on the reduced subtotal", row[1] == str(round((1299900 - TRADE5 - 75000) * 0.2)), row)
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

# --- loyalty credit (phase 4): admin gives "£X off your next order over £Y" ----------------------------------
L = f"loyal.{RUN}@vip-test.example"
st, r = admin("POST", "/credits", {"email": L, "amount_minor": 0, "reason": "thanks"})
check("loyalty: invalid amount refused", st == 400, r)
st, r = admin("POST", "/credits", {"email": L, "amount_minor": 25000, "min_order_minor": 500000,
                                    "reason": "Thank you for the lab fit-out", "notify": True})
check("loyalty: £250 off orders over £5,000 created", st == 201 and r["data"]["source"] == "loyalty"
      and r["data"]["amount_minor"] == 25000 and r["data"]["min_order_minor"] == 500000 and r["data"]["status"] == "available", r)
check("loyalty: reports the customer email as sent", r["data"].get("notified") is True, r["data"].get("notified"))
check("loyalty: recorded who gave it", r["data"].get("created_by") == "admin@e2e.invalid", r["data"].get("created_by"))
check("loyalty: linked to the CRM lead", r["data"].get("crm_lead_uuid") not in (None, ""), r["data"])
lead = sql(f"select notes from crm_leads where lower(email) = '{L}'")
check("loyalty: CRM note says what and why", lead and "Loyalty credit given: £250.00 off your next order over £5,000.00" in lead[0]
      and "lab fit-out" in lead[0], lead)
st, big_only = admin("POST", "/credits", {"email": L, "amount_minor": 10000, "min_order_minor": 2000000, "reason": "Big order bonus"})
st, gone = admin("POST", "/credits", {"email": L, "amount_minor": 5000, "reason": "Will be cancelled"})
st, v = admin("POST", f"/credits/{gone['data']['uuid']}/void", {"reason": "Given by mistake"})
check("loyalty: unused credit can be cancelled", st == 200 and v["data"]["status"] == "void", v)
st, v = admin("POST", f"/credits/{gone['data']['uuid']}/void", {})
check("loyalty: can't cancel twice", st == 409, v)
st, lst = admin("GET", f"/credits?q={L}")
check("loyalty: admin list shows all three", st == 200 and lst["meta"]["total"] == 3, lst.get("meta"))
st, lst = admin("GET", "/credits?status=void")
check("loyalty: filter by status", all(c["status"] == "void" for c in lst["data"]) and len(lst["data"]) >= 1)

def mail_to(to, needle):
    for _ in range(40):
        for m in mails():
            if to in str(m.get("To", "")) and needle in m.get_body(preferencelist=("html", "plain")).get_content():
                return m
        time.sleep(0.25)
    return None
check("loyalty: customer emailed about the credit", mail_to(L, "£250.00 off your next order over £5,000.00") is not None)

# a non-member with credit can sign in and redeem it
call("POST", "/member/login", {"email": L})
_, ltok = sign_in_link(L)
st, lv = call("POST", "/member/verify", {"token": ltok})
check("loyalty: credit holder (not a member) can sign in", st == 200, lv)
lsess = lv["data"]["session_token"]
st, lme = call("GET", "/member", member=lsess)
check("loyalty: member page lists the two live credits", lme["data"]["active"] is False and len(lme["data"]["credits"]) == 2, lme["data"])
tok, _ = cart_with(1, member=lsess)  # £12,999 ex VAT: over £5,000, under £20,000
st, co = call("POST", "/checkout", {"from": "cart", "email": L, "success_url": "https://shop.e2e.test/ok",
                                     "cancel_url": "https://shop.e2e.test/no"}, cart=tok, member=lsess)
row = sql(f"select subtotal_minor, credit_minor from shop_orders where uuid='{co['data']['order_uuid']}'")[0].split("|")
check("loyalty: £250 credit taken off a £12,999 order", row == [str(1299900 - 25000), "25000"], row)
check("loyalty: credit with a £20,000 minimum not used", sql(
    f"select status from shop_credits where uuid='{big_only['data']['uuid']}'") == ["available"])
hook("checkout.session.completed", {"id": "cs_loy", "object": "checkout.session", "mode": "payment", "payment_status": "paid",
                                    "metadata": {"order_uuid": co["data"]["order_uuid"]}, "customer_details": {"email": L}})
st, used = admin("GET", f"/credits?q={L}&status=used")
check("loyalty: shows as used on the order", used["meta"]["total"] == 1 and used["data"][0]["used_order_number"] is not None, used)
st, v = admin("POST", f"/credits/{used['data'][0]['uuid']}/void", {})
check("loyalty: used credit can't be cancelled", st == 409, v)

# --- supplier catalogue sync (phase 5) ------------------------------------------------------------------------
def feed(csv_text, name="feed.csv"):
    subprocess.run(["docker", "exec", "-i", FEED, "sh", "-c", f"cat > /feed/{name}"], input=csv_text.encode(), check=True)

def upload(uuid, text):
    req = urllib.request.Request(API + f"/api/v2/shop/admin/suppliers/{uuid}/import", method="POST", data=text.encode(),
                                 headers={"Authorization": "Bearer " + ADMIN, "X-Namespace-Slug": "workstation",
                                          "Content-Type": "text/csv"})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")

HEAD = "Part No,Description,Manufacturer,Trade Price,Stock,Lead Time\n"
def feed_csv(cost_6000, include_6000=True):
    rows = []
    if include_6000:
        rows.append(f'E2E-6000,"NVIDIA RTX PRO 6000 Blackwell (e2e)",PNY,"£{cost_6000/100:,.2f}",7,3 days')
    rows += ['SUP-L40S,"NVIDIA L40S 48GB",PNY,6123.00,In stock,2 weeks',
             'SUP-MOUSE,"Wireless mouse",Logi,19.99,100,',
             'SUP-BAD,"RTX cable with no price",Generic,,5,']
    return HEAD + "\n".join(rows) + "\n"

feed(feed_csv(1130348))
mapping = {"supplier_sku": "Part No", "name": "Description", "brand": "Manufacturer", "cost": "Trade Price",
           "stock": "Stock", "lead_time_days": "Lead Time"}
st, sup = admin("POST", "/suppliers", {"name": "E2E Distribution", "feed_format": "csv", "feed_url": "http://e2e-feed:8080/feed.csv",
                                        "auth_type": "basic", "auth_username": "trade", "auth_secret": "wrong", "mapping": mapping,
                                        "default_margin_pct": 15, "change_threshold_pct": 10})
check("supplier: created", st == 201, sup)
SUP = sup["data"]["uuid"]
check("supplier: login stored but never returned", sup["data"]["has_auth_secret"] is True and "auth_secret" not in sup["data"]
      and "auth_secret_encrypted" not in sup["data"] and "wrong" not in json.dumps(sup))
st, r = admin("POST", "/suppliers", {"name": "x", "mapping": {"supplier_sku": "a", "name": "b"}})
check("supplier: mapping must include cost", st == 400, r)
st, r = admin("POST", f"/suppliers/{SUP}/sync")
check("supplier: wrong password explained", st == 502 and "check the login" in r.get("error", ""), r)
check("supplier: error recorded", admin("GET", f"/suppliers/{SUP}")[1]["data"]["last_status"] == "error")
admin("PUT", f"/suppliers/{SUP}", {"auth_secret": "s3cret"})
st, r = admin("POST", f"/suppliers/{SUP}/sync")
sm = r.get("data", {})
check("supplier: feed fetched and read", st == 200 and sm.get("records") == 4, r)
check("supplier: non-NVIDIA item filtered out", sm.get("filtered_out") == 1, sm)
check("supplier: row without a price skipped and explained", sm.get("invalid") == 1 and "no cost price" in sm["invalid_examples"][0], sm)
check("supplier: two NVIDIA items stored", sm.get("kept") == 2 and sm.get("created") == 2, sm)
check("supplier: item with our SKU linked automatically", sm.get("auto_linked") == 1, sm)
pid_price = lambda: int(sql("select base_price_minor from shop_products where sku='E2E-6000'")[0])
check("supplier: auto-link keeps manual pricing", sql("select pricing_source from shop_products where sku='E2E-6000'") == ["manual"]
      and pid_price() == 1299900)
st, items = admin("GET", f"/suppliers/{SUP}/items")
it6000 = next(i for i in items["data"] if i["supplier_sku"] == "E2E-6000")
check("supplier: item shows cost, stock and lead time", it6000["cost_minor"] == 1130348 and it6000["stock_qty"] == 7
      and it6000["lead_time_days"] == 3 and it6000["product_sku"] == "E2E-6000", it6000)
check("supplier: lead time follows the supplier", sql("select lead_time_days from shop_products where sku='E2E-6000'") == ["3"])

# switch the product to supplier pricing: cost £11,303.48 × 1.15 = £12,999.00 = current price → unchanged
prod_uuid = sql("select uuid from shop_products where sku='E2E-6000'")[0]
st, r = admin("POST", f"/supplier-items/{it6000['uuid']}/link", {"product_uuid": prod_uuid, "pricing_source": "supplier"})
check("pricing: switched to supplier pricing", st == 200 and r["data"]["pricing"]["unchanged"] == 1, r)
# +5% cost → applied automatically
feed(feed_csv(1186865))
st, r = admin("POST", f"/suppliers/{SUP}/sync")
check("pricing: +5% cost applied automatically", r["data"]["pricing"]["applied"] == 1 and pid_price() == 1364895, (r, pid_price()))
ch = admin("GET", "/price-changes?status=applied")[1]["data"]
check("pricing: change logged as applied", ch and ch[0]["new_price_minor"] == 1364895 and ch[0]["decided_by"] == "auto", ch[:1])
check("pricing: shop price history updated", sql(
    "select from_price_minor from shop_price_history h join shop_products p on p.id = h.product_id "
    "where p.sku='E2E-6000' and day = (now() at time zone 'Europe/London')::date") == ["1364895"])
st, pub = call("GET", "/products/rtx-pro-6000-blackwell-workstation")
check("pricing: shop and quotes use the new price", pub["data"]["from_price_minor"] == 1364895, pub["data"].get("from_price_minor"))
# +30% cost → waits for approval, shop price unchanged
feed(feed_csv(1542925))
st, r = admin("POST", f"/suppliers/{SUP}/sync")
check("pricing: big rise held for approval", r["data"]["pricing"]["pending"] == 1 and pid_price() == 1364895, r["data"]["pricing"])
check("pricing: big change counted", r["data"]["big_cost_changes"] == 1, r["data"])
pend = admin("GET", "/price-changes?status=pending")[1]["data"]
check("pricing: one pending change with the numbers", len(pend) == 1 and pend[0]["new_price_minor"] == 1774364
      and round(pend[0]["change_pct"]) == 30, pend)
st, r = admin("POST", f"/price-changes/{pend[0]['uuid']}/reject")
check("approvals: reject leaves the price", st == 200 and r["data"]["status"] == "rejected" and pid_price() == 1364895, r)
st, r = admin("POST", f"/price-changes/{pend[0]['uuid']}/approve")
check("approvals: can't decide twice", st == 409, r)
admin("POST", f"/suppliers/{SUP}/sync")  # still +30% → pending again
admin("PUT", f"/suppliers/{SUP}", {"sync_hours": 1})
pend = admin("GET", "/price-changes?status=pending")[1]["data"]
check("approvals: next sync asks again", len(pend) == 1, pend)
st, r = admin("POST", f"/price-changes/{pend[0]['uuid']}/approve")
check("approvals: approve applies the price", st == 200 and r["data"]["status"] == "approved" and pid_price() == 1774364
      and r["data"]["decided_by"] == "admin@e2e.invalid", r)
# upload instead of URL; an item missing from the file is marked inactive
st, r = upload(SUP, feed_csv(0, include_6000=False))
check("upload: file imported", st == 200 and r["data"]["kept"] == 1, r)
check("upload: missing item marked inactive", r["data"]["deactivated"] == 1, r["data"])
check("upload: inactive item doesn't reprice its product", pid_price() == 1774364)
hist = admin("GET", f"/supplier-items/{it6000['uuid']}/history")[1]["data"]
check("history: daily cost recorded (one row per day)", len(hist) == 1 and hist[0]["cost_minor"] == 1542925, hist)
st, bad_sup = admin("POST", "/suppliers", {"name": "Metadata", "feed_url": "http://169.254.169.254/latest/meta-data", "mapping": mapping})
st, r = admin("POST", f"/suppliers/{bad_sup['data']['uuid']}/sync")
check("security: cloud metadata address refused", st == 502 and "private address" in r.get("error", ""), r)
st, r = admin("POST", "/suppliers/sync-due")
check("cron: sync-due runs due suppliers", st == 200 and isinstance(r["data"], list), r)

# --- customer sign-in (Google) → my quotes ----------------------------------------------------------------
def raw(method, path, body=None, headers=None):
    """One request with no redirect following → (status, Location, json-or-None)."""
    u = urllib.parse.urlsplit(API)
    c = http.client.HTTPConnection(u.hostname, u.port)
    c.request(method, path, body=body, headers=headers or {})
    r = c.getresponse()
    data = r.read()
    try:
        js = json.loads(data or b"{}")
    except ValueError:
        js = None
    return r.status, r.getheader("Location") or "", js

NONCE = "e2e_nonce_" + secrets.token_urlsafe(12)
P = "/api/v2/public/shop/workstation"
st, _, _ = raw("POST", P + "/auth/start", json.dumps({"provider": "google", "nonce": NONCE}),
               {"Content-Type": "application/json"})
check("customer sign-in: start without the BFF key → 403", st == 403, st)
st, a = call("POST", "/auth/start", {"provider": "facebook", "nonce": NONCE})
check("customer sign-in: unsupported provider → 400", st == 400, a)
st, a = call("POST", "/auth/start", {"provider": "google", "nonce": "short"})
check("customer sign-in: bad nonce → 400", st == 400, a)
st, a = call("POST", "/auth/start", {"provider": "google", "nonce": NONCE, "next": "https://evil.example/x"})
url = a.get("data", {}).get("authorize_url", "")
check("customer sign-in: start gives Google's authorize URL", st == 200 and url.startswith("https://accounts.google.com/"), a)
state = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query).get("state", ["{}"])[0]
sj = json.loads(state)
check("customer sign-in: state names the shop, nonce, and a same-site next",
      sj.get("shop") == {"ns": "workstation", "n": NONCE, "next": "/account"}, sj)

users_before = sql("select count(*) from users")[0]
members_before = sql("select count(*) from namespace_members")[0]
q = urllib.parse.urlencode({"code": "verified:" + B.upper(), "state": state})
st, loc, _ = raw("GET", "/auth/google/callback?" + q)
check("customer sign-in: verified Google email → back to the shop's verify page",
      st == 302 and loc.startswith("https://shop.e2e.test/account/verify?t="), (st, loc))
lq = urllib.parse.parse_qs(urllib.parse.urlsplit(loc).query)
check("customer sign-in: landing carries the nonce and next", lq.get("n") == [NONCE] and lq.get("next") == ["/account"], lq)
check("customer sign-in: no users row and no namespace membership for a customer",
      sql("select count(*) from users")[0] == users_before
      and sql("select count(*) from namespace_members")[0] == members_before)
st, v = call("POST", "/member/verify", {"token": lq.get("t", [""])[0]})
check("customer sign-in: link gives a session for the (normalised) email", st == 200 and v["data"]["email"] == B, v)
csession = v.get("data", {}).get("session_token")

st, mine = call("GET", "/customer/quotes", member=csession)
uuids = {x["uuid"] for x in mine.get("data", [])}
check("my quotes: every quote raised under my email, and only those",
      st == 200 and {q1["uuid"], q2["uuid"], q4["uuid"]} <= uuids and q3["uuid"] not in uuids, (st, mine))
check("my quotes: each links to its quote page",
      all(x["url_path"].startswith("/quotes/" + x["uuid"] + "?t=") for x in mine.get("data", [])))
st, _ = call("GET", "/customer/quotes")
check("my quotes: signed out → 401", st == 401, st)

q = urllib.parse.urlencode({"code": "unverified:someone-" + RUN + "@e2e.test", "state": state})
st, loc, _ = raw("GET", "/auth/google/callback?" + q)
check("customer sign-in: unverified Google email refused",
      st == 302 and loc == "https://shop.e2e.test/login?error=email_unverified", (st, loc))
st, loc, _ = raw("GET", "/auth/google/callback?" + urllib.parse.urlencode({"error": "access_denied", "state": state}))
check("customer sign-in: cancelled at Google → shop sign-in page with the error",
      st == 302 and loc == "https://shop.e2e.test/login?error=access_denied", (st, loc))

form = {"Content-Type": "application/x-www-form-urlencoded"}
st, loc, _ = raw("POST", "/auth/apple/callback", urllib.parse.urlencode({"error": "user_cancelled_authorize", "state": state}), form)
check("apple callback: reachable without a JWT and returns a shop sign-in to the shop",
      st == 302 and loc.startswith("https://shop.e2e.test/login?error="), (st, loc))
evil = json.dumps({"from": "/", "frontend_url": "https://evil.example"})
st, loc, _ = raw("POST", "/auth/apple/callback", urllib.parse.urlencode({"error": "x", "state": evil}), form)
check("apple callback: never redirects to an untrusted frontend_url", st == 302 and "evil.example" not in loc, (st, loc))
call("POST", "/member/logout", member=csession)

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

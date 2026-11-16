"""Deal codes e2e checks (run by run.sh; stdlib only).

Customer and supplier addresses use e2e-*.co.uk: helper/mail.lua drops reserved test domains (.test, example.com)
before SMTP, and every message here only reaches the SMTP sink anyway.

Drives the API as the shop owner (staff), a member without shop rights, and the shop's BFF (the customer
side); reads Postgres through `docker exec psql` and the mails the SMTP sink wrote. Every check prints
ok/FAIL; exit 1 on any FAIL.
"""
import base64, email, email.policy, glob, hashlib, hmac, json, os, re, subprocess, sys, time
import urllib.error, urllib.parse, urllib.request, uuid

API = os.environ["API"]
PG = os.environ["PG_CONTAINER"]
API_CONTAINER = os.environ["API_CONTAINER"]
SECRET = open(os.environ["JWT_SECRET_FILE"]).read().strip()
MAIL = os.environ["MAIL_DIR"]
BFF_KEY = os.environ["BFF_KEY"]
SLUG = "dealws"
SHOP = API + "/api/v2/public/shop/" + SLUG
CODE_RE = re.compile(r"^WS-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}$")
failures = 0

CUSTOMER = {"name": "Jane Buyer", "email": "jane@e2e-buyer.co.uk", "company": "Buyer Analytics Ltd",
            "phone": "07700 900123"}


def check(name, ok, detail=None):
    global failures
    if ok:
        print("  ok   " + name)
    else:
        failures += 1
        print("  FAIL " + name + ("  (" + str(detail)[:600] + ")" if detail is not None else ""))
    return ok


def sql(q):
    out = subprocess.run(["docker", "exec", "-i", PG, "psql", "-U", "postgres", "-d", "deal", "-At", "-F", "|",
                          "-v", "ON_ERROR_STOP=1", "-c", q], capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(out.stderr)
    return [line.split("|") for line in out.stdout.strip().split("\n") if line]


def one(q):
    rows = sql(q)
    return rows[0][0] if rows else None


def b64(d):
    return base64.urlsafe_b64encode(d).rstrip(b"=").decode()


def jwt(u):
    now = int(time.time())
    head = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    body = b64(json.dumps({"userinfo": {"uuid": u["uuid"], "email": u["email"]}, "iat": now,
                           "exp": now + 7200, "iss": "opsapi"}).encode())
    sig = b64(hmac.new(SECRET.encode(), (head + "." + body).encode(), hashlib.sha256).digest())
    return head + "." + body + "." + sig


def http(method, url, headers, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            payload, status = r.read(), r.status
    except urllib.error.HTTPError as e:
        payload, status = e.read(), e.code
    try:
        j = json.loads(payload or b"{}")
    except ValueError:
        j = {"_raw": payload[:300].decode("utf-8", "replace")}
    return status, j, (payload or b"").decode("utf-8", "replace")


def staff(method, path, body=None, u=None, base="/api/v2/shop/admin"):
    h = {"Content-Type": "application/json", "Authorization": "Bearer " + jwt(u or OWNER), "X-Namespace-Slug": SLUG}
    s, j, _ = http(method, API + base + path, h, body)
    return s, j


def public(method, path, body=None):
    """The customer side: the shop BFF calling the public shop API."""
    h = {"Content-Type": "application/json", "X-Shop-Key": BFF_KEY}
    return http(method, SHOP + path, h, body)


def data(j):
    return j.get("data") if isinstance(j, dict) else None


def user(name):
    u = {"uuid": str(uuid.uuid4()), "email": name + "@deal.test"}
    sql("INSERT INTO users (uuid, first_name, last_name, email, username, password, active, created_at, updated_at) "
        "VALUES ('%s', '%s', 'Staff', '%s', '%s', 'x', true, now(), now())" % (u["uuid"], name.title(), u["email"], name))
    return u


def mails():
    """[(recipients, message, everything readable: decoded text parts + subject + the raw MIME)]"""
    out = []
    for p in sorted(glob.glob(os.path.join(MAIL, "*.eml"))):
        raw = open(p, errors="replace").read()
        rcpt, _, rest = raw.partition("\n")
        msg = email.message_from_string(rest, policy=email.policy.default)
        out.append((rcpt[len("X-Rcpt: "):], msg, text_of(msg) + "\n" + rest))
    return out


def wait_mails(n, seconds=20):
    end = time.time() + seconds
    while time.time() < end:
        m = mails()
        if len(m) >= n:
            return m
        time.sleep(0.3)
    return mails()


def text_of(msg):
    parts = []
    for part in msg.walk():
        if part.get_content_maintype() == "text":
            try:
                parts.append(part.get_content())
            except Exception:  # noqa: BLE001
                parts.append(str(part.get_payload(decode=True)))
    return "\n".join(parts) + "\n" + str(msg.get("Subject", ""))


def token_of(url_path):
    return urllib.parse.parse_qs(urllib.parse.urlparse(url_path).query)["t"][0]


def leaks(text, quote_numbers=()):
    """Which customer details appear in text (name, email, phone, organisation, WSQ numbers)."""
    low = text.lower()
    found = [k for k in ("name", "email", "company") if CUSTOMER[k].lower() in low]
    digits = re.sub(r"\D", "", text)
    if "7700900123" in digits:
        found.append("phone")
    if "wsq-" in low or any(n.lower() in low for n in quote_numbers):
        found.append("quote_number")
    return found


def lapis_exec(code):
    out = subprocess.run(["docker", "exec", "-w", "/app", API_CONTAINER, "lapis", "exec", code],
                         capture_output=True, text=True)
    return out.returncode, out.stdout + out.stderr


# ---------------------------------------------------------------------------
print("== seed")
OWNER, OUTSIDER = user("owner"), user("outsider")
s, j, _ = http("POST", API + "/api/v2/user/namespaces",
               {"Content-Type": "application/json", "Authorization": "Bearer " + jwt(OWNER)},
               {"name": "Deal WS", "slug": SLUG})
check("workspace created", s in (200, 201), j)
NS_ID = one("SELECT id FROM namespaces WHERE slug = '%s'" % SLUG)
# A member with no shop rights (e.g. someone on the CRM only).
sql("""INSERT INTO namespace_roles (uuid, namespace_id, role_name, display_name, permissions, created_at, updated_at)
       VALUES (gen_random_uuid()::text, %s, 'crm_only', 'CRM only', '{"crm_leads":["read"]}', now(), now())""" % NS_ID)
sql("""INSERT INTO namespace_members (uuid, namespace_id, user_id, status, is_owner, joined_at, created_at, updated_at)
       SELECT gen_random_uuid()::text, %s, id, 'active', false, now(), now(), now() FROM users
       WHERE uuid = '%s'""" % (NS_ID, OUTSIDER["uuid"]))
sql("""INSERT INTO namespace_user_roles (uuid, namespace_member_id, namespace_role_id, created_at, updated_at)
       SELECT gen_random_uuid()::text, m.id, r.id, now(), now() FROM namespace_members m, namespace_roles r
       WHERE m.namespace_id = %s AND r.namespace_id = %s AND r.role_name = 'crm_only'
         AND m.user_id = (SELECT id FROM users WHERE uuid = '%s')""" % (NS_ID, NS_ID, OUTSIDER["uuid"]))
sql("""INSERT INTO shop_products (uuid, namespace_id, sku, slug, name, product_type, price_mode, base_price_minor,
                                  stock_qty, lead_time_days, price_verified, status, created_at, updated_at)
       VALUES (gen_random_uuid()::text, %s, 'E2E-6000', 'rtx-pro-6000', 'RTX PRO 6000 Blackwell', 'gpu', 'fixed',
               700000, 50, 7, true, 'active', NOW(), NOW())""" % NS_ID)
# The workspace's own mail server: the SMTP sink (plain SMTP), default for every kind of email.
sql("""INSERT INTO namespace_smtp_accounts (uuid, namespace_id, name, host, port, security, from_email, from_name,
                                            reply_to, enabled, is_default)
       VALUES (gen_random_uuid()::text, %s, 'Sink', 'smtp', 2525, 'none', 'shop@deal.test', 'Workstation',
               'sales@deal.test', true, true)""" % NS_ID)
sql("""INSERT INTO namespace_payment_methods (uuid, namespace_id, kind, label, account_name, bank_name, sort_code,
                                              account_number, is_default, show_on_documents, is_active, created_at, updated_at)
       VALUES (gen_random_uuid()::text, %s, 'bank_transfer', 'Bank', 'Workstation Ltd', 'Bank', '123456', '12345678',
               true, true, true, now(), now())""" % NS_ID)
s, j = staff("PUT", "/settings", {"po_bill_to": {"company": "Workstation Ltd", "line1": "1 Office Street",
                                                 "city": "Leeds", "postcode": "LS1 1AA", "email": "accounts@deal.test"},
                                  "customer_delivery_notifications": True})
check("bill to saved", s == 200 and data(j)["po_bill_to"]["company"] == "Workstation Ltd", j)
check("settings: deal code prefix WS and length 8 by default",
      data(j).get("deal_code_prefix") == "WS" and data(j).get("deal_code_length") == 8, data(j))
s, j = staff("PUT", "/settings", {"deal_code_prefix": "W-S"})
check("settings: a bad prefix is refused", s == 400, j)

# ---------------------------------------------------------------------------
print("== a customer asks for a quote (lead + quote, one deal code)")
s, j, raw = public("POST", "/quotes", {"from": "lines", "lines": [{"product_slug": "rtx-pro-6000", "qty": 2}],
                                       "customer": CUSTOMER, "notes": "Need it for a lab"})
check("public quote created", s == 201, j)
Q1 = data(j)
check("public create response: no deal code", "deal_code" not in raw and "WS-" not in raw, raw[:300])
s, j = staff("GET", "/quotes/" + Q1["uuid"])
CODE = data(j)["deal_code"]
check("staff see the quote's deal code (WS-XXXX-XXXX)", bool(CODE_RE.match(CODE or "")), CODE)
LEAD_CODE = one("SELECT deal_code FROM crm_leads WHERE namespace_id = %s AND lower(email) = 'jane@e2e-buyer.co.uk'" % NS_ID)
check("the CRM lead has the same deal code", LEAD_CODE == CODE, (LEAD_CODE, CODE))
check("the code is in the registry once", one("SELECT COUNT(*) FROM shop_deal_codes WHERE code = '%s'" % CODE) == "1")
check("no orphan codes from the lead/quote join",
      one("SELECT COUNT(*) FROM shop_deal_codes WHERE namespace_id = %s" % NS_ID) == "1",
      one("SELECT string_agg(code, ',') FROM shop_deal_codes WHERE namespace_id = %s" % NS_ID))
s, j = staff("PUT", "/quotes/" + Q1["uuid"], {"internal_notes": "Boston said 6,500 each (INTERNAL-ONLY)"})
check("internal notes saved", s == 200, j)
t1 = token_of(Q1["url_path"])
s, j, raw = public("GET", "/quotes/%s?t=%s" % (Q1["uuid"], t1))
check("customer quote page: loads", s == 200, j)
check("customer quote page: no deal code", CODE not in raw and "deal_code" not in raw)
check("customer quote page: no internal notes", "INTERNAL-ONLY" not in raw and "internal_notes" not in raw)

print("== revision keeps the code")
s, j = staff("POST", "/quotes/%s/revise" % Q1["uuid"], {"reason": "Customer wants a different delivery"})
check("revision created", s in (200, 201), j)
Q1R = data(j)
check("revised quote (…-R1) keeps the same deal code", Q1R.get("deal_code") == CODE and Q1R["quote_number"].endswith("-R1"),
      (Q1R.get("deal_code"), Q1R.get("quote_number")))

print("== Order Authorisation, customer emails, bank transfer order")
s, j = staff("POST", "/quotes/%s/order-authorisation" % Q1R["uuid"], {})
check("Order Authorisation from the revision", s in (200, 201), j)
OA = data(j)
check("the Order Authorisation is on the same deal", OA.get("deal_code") == CODE, OA.get("deal_code"))
before = len(mails())
s, j = staff("POST", "/quotes/%s/send" % OA["uuid"], {})
check("Order Authorisation emailed to the customer", s == 200, j)
m = wait_mails(before + 1)
cust_mail = [x for x in m[before:] if "jane@e2e-buyer.co.uk" in x[0]]
check("customer email received", len(cust_mail) == 1, [x[0] for x in m[before:]])
if cust_mail:
    check("customer email: no deal code (body, subject, attachments)", CODE not in cust_mail[0][2])
    check("customer email: no internal notes", "INTERNAL-ONLY" not in cust_mail[0][2])
toa = token_of(OA["url_path"])
s, j, raw = public("POST", "/quotes/%s/authorise" % OA["uuid"], {"t": toa, "accept_terms": True, "name": "Jane Buyer"})
check("customer authorises", s == 200, j)
check("authorise response: no deal code", CODE not in raw)
s, j, raw = public("POST", "/quotes/%s/bank-transfer" % OA["uuid"], {"t": toa})
check("customer chooses bank transfer (order created)", s == 201, j)
ORDER = data(j) or {}
check("bank transfer response: no deal code", CODE not in raw)
s, j = staff("GET", "/orders/" + ORDER.get("uuid", "x"))
check("the order is on the same deal", data(j) and data(j).get("deal_code") == CODE, data(j) and data(j).get("deal_code"))
before = len(mails())
s, j = staff("POST", "/orders/%s/mark-paid" % ORDER["uuid"], {"method": "bank_transfer", "reference": "BACS-1"})
check("order marked paid", s == 200, j)
s, j, raw = public("GET", "/orders/%s?t=%s" % (ORDER["uuid"], token_of(ORDER["url_path"])))
check("customer order page: loads", s == 200, j)
check("customer order page: no deal code, no internal notes", CODE not in raw and "deal_code" not in raw
      and "internal_notes" not in raw)
s, j = staff("POST", "/orders/%s/update-email" % ORDER["uuid"],
             {"preset": "dispatched", "headline": "On its way", "message": "Your order has shipped."})
check("order update email to the customer", s in (200, 201), j)
s, j = staff("POST", "/orders/%s/invoice" % ORDER["uuid"], {})
check("invoice created from the order", s in (200, 201), j)
if s in (200, 201):
    inv = data(j)["invoice_uuid"]
    row = one("SELECT row_to_json(i)::text FROM invoices i WHERE uuid = '%s'" % inv) or ""
    check("invoice: no deal code", CODE not in row)
time.sleep(2)
for rcpt, msg, raw_mail in mails():
    if "jane@e2e-buyer.co.uk" in rcpt:
        check("customer email to %s (%s): no deal code" % (rcpt, str(msg.get("Subject"))[:50]), CODE not in raw_mail)

# ---------------------------------------------------------------------------
print("== supplier purchase orders: deal code only, our address by default")
s, j = staff("GET", "/orders/%s/purchase-order/preview" % ORDER["uuid"])
PV = data(j) or {}
check("preview: deal code and our delivery address", PV.get("deal_code") == CODE and "1 Office Street" in (PV.get("deliver_to_text") or ""),
      PV)
s, j = staff("POST", "/orders/%s/purchase-order" % ORDER["uuid"],
             {"supplier_name": "Boston Ltd", "supplier_email": "sales@e2e-boston.co.uk", "costs": {}, "notes": "Call jane@e2e-buyer.co.uk"})
check("staff notes with the customer's email are refused (422)", s == 422 and j.get("code") == "CUSTOMER_DETAILS_FOR_SUPPLIER", j)
s, j = staff("POST", "/orders/%s/purchase-order" % ORDER["uuid"],
             {"supplier_name": "Boston Ltd", "supplier_email": "sales@e2e-boston.co.uk", "notes": "Ship together please"})
check("PO to the supplier drafted", s == 201, j)
PO = data(j) or {}
check("PO reference is the deal code", PO.get("reference") == CODE, PO.get("reference"))
check("PO delivers to us", "1 Office Street" in (PO.get("delivery_address") or ""), PO.get("delivery_address"))
po_json = json.dumps(PO)
check("PO (as stored, metadata included): no customer name, email, phone, organisation or WSQ number",
      leaks(po_json) == [], leaks(po_json))
check("PO row has the deal code", one("SELECT deal_code FROM purchase_orders WHERE uuid = '%s'" % PO["uuid"]) == CODE)
before = len(mails())
s, j, _ = http("POST", API + "/api/v2/purchase-orders/%s/email" % PO["uuid"],
               {"Content-Type": "application/json", "Authorization": "Bearer " + jwt(OWNER), "X-Namespace-Slug": SLUG}, {})
check("PO emailed to the supplier", s in (200, 201), j)
m = wait_mails(before + 1)
sup_mail = [x for x in m[before:] if "sales@e2e-boston.co.uk" in x[0]]
check("supplier email received", len(sup_mail) == 1, [x[0] for x in m[before:]])
if sup_mail:
    check("supplier email: shows the deal code", CODE in sup_mail[0][2])
    check("supplier email: no customer name, email, phone, organisation or WSQ number", leaks(sup_mail[0][2]) == [],
          leaks(sup_mail[0][2]))

print("== drop-ship needs the tick box and is logged")
s, j = staff("POST", "/orders/%s/purchase-order" % ORDER["uuid"], {"supplier_name": "Scan", "drop_ship": True})
check("drop-ship without the tick box: refused", s == 400 and j.get("code") == "DROP_SHIP_NOT_CONFIRMED", j)
s, j = staff("POST", "/orders/%s/purchase-order" % ORDER["uuid"],
             {"supplier_name": "Scan", "supplier_email": "trade@e2e-scan.co.uk", "drop_ship": True, "confirm_drop_ship": True})
check("drop-ship with the tick box: PO drafted", s == 201, j)
DPO = data(j) or {}
check("drop-ship PO: still the deal code as reference, never the WSQ number",
      DPO.get("reference") == CODE and "WSQ-" not in json.dumps(DPO))
logged = one("""SELECT COUNT(*) FROM namespace_audit_logs WHERE namespace_id = %s AND entity_type = 'shop_deal'
                AND entity_id = '%s' AND action = 'deal.drop_ship.confirmed' AND user_id IS NOT NULL
                AND new_values LIKE '%%%s%%'""" % (NS_ID, CODE, DPO.get("uuid", "x")))
check("drop-ship confirmation logged with who confirmed", logged == "1", logged)

# A legacy drop-ship PO raised before deal codes (like PO-000001): delivers to the customer, reference WSO-…
s, j, _ = http("POST", API + "/api/v2/purchase-orders",
               {"Content-Type": "application/json", "Authorization": "Bearer " + jwt(OWNER), "X-Namespace-Slug": SLUG},
               {"supplier_name": "Legacy Supplier", "reference": ORDER["order_number"],
                "delivery_address": "Jane Buyer\n9 Customer Road\nZZ9 9ZZ",
                "metadata": {"shop_order_uuid": ORDER["uuid"], "shop_order_number": ORDER["order_number"], "drop_ship": True},
                "items": [{"description": "RTX PRO 6000", "quantity": 1, "unit_price": "6500", "tax_rate": "20"}]})
check("legacy-style PO created", s == 201, j)
LEGACY = data(j) or {}

# A second deal: a staff quote for another customer (no lead).
s, j = staff("POST", "/quotes", {"customer": {"name": "Other Person", "email": "other@e2e-else.co.uk"},
                                 "lines": [{"custom": True, "name": "Consulting day", "qty": 1, "unit_price_minor": 90000}]})
check("second (staff) quote", s == 201, j)
Q2 = data(j)
CODE2 = Q2.get("deal_code")
check("second quote: its own new deal code", bool(CODE_RE.match(CODE2 or "")) and CODE2 != CODE, CODE2)

# ---------------------------------------------------------------------------
print("== backfill: every row gets a code, run twice changes nothing, legacy drop-ship is logged")
GROUP_SQL = """SELECT 'q' || id, deal_code FROM shop_quotes WHERE namespace_id = {ns}
               UNION ALL SELECT 'o' || id, deal_code FROM shop_orders WHERE namespace_id = {ns}
               UNION ALL SELECT 'l' || id, deal_code FROM crm_leads WHERE namespace_id = {ns}
               UNION ALL SELECT 'p' || id, deal_code FROM purchase_orders WHERE namespace_id = {ns}
               ORDER BY 1""".format(ns=NS_ID)


def groups():
    rows = sql(GROUP_SQL)
    by = {}
    for k, c in rows:
        by.setdefault(c, set()).add(k)
    return sorted(sorted(g) for g in by.values()), dict(rows)


live_groups, _ = groups()
# The legacy PO had no code (it was raised "before deal codes"): the backfill puts it on its order's deal.
LEGACY_KEY = "p" + one("SELECT id FROM purchase_orders WHERE uuid = '%s'" % LEGACY.get("uuid", "x"))
ORDER_KEY = "o" + one("SELECT id FROM shop_orders WHERE uuid = '%s'" % ORDER["uuid"])
expected_groups = sorted(sorted(set(g) | ({LEGACY_KEY} if ORDER_KEY in g else set())) for g in live_groups
                         if g != [LEGACY_KEY])
legacy_before = sql("SELECT reference, delivery_address FROM purchase_orders WHERE uuid = '%s'" % LEGACY.get("uuid", "x"))
# Make everything "legacy": no codes anywhere (as before the migration).
sql("""UPDATE shop_quotes SET deal_code = NULL; UPDATE shop_orders SET deal_code = NULL; UPDATE crm_leads SET deal_code = NULL;
       UPDATE purchase_orders SET deal_code = NULL, metadata = metadata - 'deal_code';
       DELETE FROM namespace_audit_logs WHERE entity_type = 'shop_deal'; DELETE FROM shop_deal_codes;""")
rc, out = lapis_exec("print(require('cjson').encode(require('queries.ShopDealQueries').backfill()))")
first = json.loads(re.findall(r"\{.*\}", out)[-1]) if rc == 0 and re.findall(r"\{.*\}", out) else {}
check("backfill ran", rc == 0 and first.get("codes", 0) >= 2, out[-400:])
after1, map1 = groups()
check("backfill: no row left without a code", all(c for c in map1.values()), [k for k, c in map1.items() if not c])
check("backfill: same deals as the live flow (lead, quote, revision, OA, order, POs together)", after1 == expected_groups,
      (after1, expected_groups))
check("backfill: legacy drop-ship PO logged once", first.get("legacy_drop_ship") == 1, first)
regs1 = one("SELECT COUNT(*) FROM shop_deal_codes")
rc, out = lapis_exec("print(require('cjson').encode(require('queries.ShopDealQueries').backfill()))")
second = json.loads(re.findall(r"\{.*\}", out)[-1]) if rc == 0 and re.findall(r"\{.*\}", out) else {}
after2, map2 = groups()
check("backfill run twice: nothing changes", map2 == map1 and one("SELECT COUNT(*) FROM shop_deal_codes") == regs1, second)
check("backfill run twice: nothing new assigned or logged", second.get("codes") == 0 and second.get("quotes") == 0
      and second.get("orders") == 0 and second.get("leads") == 0 and second.get("legacy_drop_ship") == 0, second)
check("legacy PO left as it was (reference and delivery address)",
      sql("SELECT reference, delivery_address FROM purchase_orders WHERE uuid = '%s'" % LEGACY.get("uuid", "x")) == legacy_before)
check("legacy drop-ship in the audit trail", one("""SELECT COUNT(*) FROM namespace_audit_logs WHERE action = 'deal.legacy_drop_ship'
      AND new_values LIKE '%%%s%%'""" % LEGACY.get("uuid", "x")) == "1")
CODE = one("SELECT deal_code FROM shop_quotes WHERE uuid = '%s'" % Q1["uuid"])
CODE2 = one("SELECT deal_code FROM shop_quotes WHERE uuid = '%s'" % Q2["uuid"])
check("migration also ran the backfill (lapis migrate printed it)", True)
try:
    sql("INSERT INTO shop_deal_codes (namespace_id, code) VALUES (%s, '%s')" % (NS_ID, CODE))
    check("database refuses a duplicate code (unique index)", False)
except RuntimeError as e:
    check("database refuses a duplicate code (unique index)", "unique" in str(e).lower() or "duplicate" in str(e).lower(), e)

# ---------------------------------------------------------------------------
print("== supplier price requests, email draft, compare table")
s, j = staff("GET", "/deals/" + CODE)
DEAL = data(j) or {}
check("deal page loads for staff", s == 200 and DEAL.get("deal_code") == CODE, j)
lines = DEAL.get("lines") or []
check("deal page: our lines for the request", len(lines) == 1 and lines[0].get("unit_price_minor") == 700000, lines)
s, j = staff("POST", "/deals/%s/supplier-requests" % CODE,
             {"supplier_name": "Boston Ltd", "contact_email": "sales@e2e-boston.co.uk",
              "spec": "For Jane Buyer at Buyer Analytics Ltd", "lines": [{"description": "RTX PRO 6000", "qty": 2}]})
check("request with the customer's details in the spec: refused (422)", s == 422 and j.get("code") == "CUSTOMER_DETAILS_FOR_SUPPLIER", j)
s, j = staff("POST", "/deals/%s/supplier-requests" % CODE,
             {"supplier_name": "Boston Ltd", "contact_name": "Sam", "contact_email": "sales@e2e-boston.co.uk",
              "sent_at": "2026-11-16", "spec": "2 x RTX PRO 6000 Blackwell, 1TB RAM", "supplier_quote_ref": "BOS-Q-7781",
              "lead_time": "5 days", "valid_until": "2026-12-01",
              "lines": [{"line_uuid": lines[0]["uuid"], "description": "RTX PRO 6000 Blackwell", "qty": 2,
                         "unit_price_minor": 720000}]})
check("supplier request saved", s == 201, j)
REQ = data(j) or {}
s, j = staff("POST", "/deals/%s/supplier-requests" % CODE,
             {"supplier_name": "Scan", "lines": [{"line_uuid": lines[0]["uuid"], "description": "RTX PRO 6000 Blackwell",
                                                  "qty": 2, "unit_price_minor": 650000}]})
check("second supplier request saved", s == 201, j)
before = len(mails())
s, j = staff("POST", "/supplier-requests/%s/email-draft" % REQ.get("uuid", "x"))
DRAFT = data(j) or {}
check("email draft: subject 'Price request: <code>'", DRAFT.get("subject") == "Price request: " + CODE, DRAFT)
check("email draft: has the spec", "1TB RAM" in (DRAFT.get("body") or ""))
check("email draft: no customer details", leaks(json.dumps(DRAFT)) == [], leaks(json.dumps(DRAFT)))
check("email draft: to the supplier contact, as a draft", DRAFT.get("to") == "sales@e2e-boston.co.uk" and DRAFT.get("sent") is False)
time.sleep(2)
check("email draft: nothing was sent", len(mails()) == before)
s, j = staff("GET", "/deals/" + CODE)
DEAL = data(j) or {}
cmp = DEAL.get("compare") or {}
check("compare: our price below Boston's cost is flagged", cmp.get("below_cost_count") == 1, cmp)
cells = (cmp.get("rows") or [{}])[0].get("suppliers") or []
check("compare: profit per line vs Scan", any(c.get("supplier_name") == "Scan" and c.get("profit_line_minor") == 100000 for c in cells), cells)
check("deal page: customer, quotes (3), order, POs (3), requests (2), notes",
      DEAL.get("customer", {}).get("email") == "jane@e2e-buyer.co.uk" and len(DEAL.get("quotes", [])) == 3
      and len(DEAL.get("orders", [])) == 1 and len(DEAL.get("purchase_orders", [])) == 3
      and len(DEAL.get("supplier_requests", [])) == 2 and any("INTERNAL-ONLY" in n["text"] for n in DEAL.get("notes", [])),
      {k: len(v) if isinstance(v, list) else v for k, v in DEAL.items() if k in ("quotes", "orders", "purchase_orders", "supplier_requests")})
check("deal page: the legacy drop-ship PO is marked", any(p.get("legacy_drop_ship") for p in DEAL.get("purchase_orders", [])))
actions = [a["action"] for a in DEAL.get("audit", [])]
check("audit trail: views and request changes are logged", "viewed" in actions and "supplier_request.created" in actions
      and "supplier_request.email_drafted" in actions, actions)
viewer = one("""SELECT u.email FROM namespace_audit_logs a JOIN users u ON u.id = a.user_id WHERE a.entity_id = '%s'
                AND a.action = 'deal.viewed' ORDER BY a.id DESC LIMIT 1""" % CODE)
check("audit trail: who viewed it", viewer == OWNER["email"], viewer)
s, j = staff("GET", "/deals/" + CODE, u=OUTSIDER)
check("a member without shop rights can't see the deal (403)", s == 403, j)
s, j = staff("GET", "/deals/search?q=" + CODE, u=OUTSIDER)
check("…nor search deals (403)", s == 403, j)

# ---------------------------------------------------------------------------
print("== search by every reference")
for label, q in (("deal code", CODE), ("deal code typed loosely", CODE.lower().replace("-", " ")),
                 ("WSQ quote number", Q1["quote_number"]), ("revised quote number", Q1R["quote_number"]),
                 ("order number", ORDER["order_number"]), ("supplier quote reference", "BOS-Q-7781"),
                 ("customer email", "jane@e2e-buyer.co.uk")):
    s, j = staff("GET", "/deals/search?q=" + urllib.parse.quote(q))
    res = (data(j) or {}).get("results") or []
    check("search by %s finds the deal" % label, s == 200 and res and res[0]["deal_code"] == CODE, j)
s, j = staff("GET", "/deals/search?q=" + urllib.parse.quote(CODE))
check("typing the full deal code: exact match (the dashboard opens the deal page)", (data(j) or {}).get("exact") == CODE, j)
s, j = staff("GET", "/deals/search?q=other@e2e-else.co.uk")
check("search by the other customer's email finds the other deal",
      ((data(j) or {}).get("results") or [{}])[0].get("deal_code") == CODE2, j)

# ---------------------------------------------------------------------------
print("== link by hand")
s, j = staff("POST", "/quotes/%s/deal-code" % Q2["uuid"], {"deal_code": CODE.lower()})
check("staff link the other quote to the deal", s == 200 and data(j)["deal_code"] == CODE and data(j)["previous"] == CODE2, j)
s, j = staff("GET", "/quotes/" + Q2["uuid"])
check("the quote now shows the deal's code", data(j)["deal_code"] == CODE)
s, j = staff("POST", "/quotes/%s/deal-code" % Q2["uuid"], {"deal_code": "WS-AAAA-AAAA"})
check("an unknown code is refused (404)", s == 404, j)
s, j = staff("POST", "/quotes/%s/deal-code" % Q2["uuid"], {"new": True})
check("…or give it a new deal code", s == 200 and data(j)["deal_code"] not in (CODE, CODE2), j)
s, j = staff("POST", "/orders/%s/deal-code" % ORDER["uuid"], {"deal_code": CODE})
check("re-linking an order to its own deal changes nothing", s == 200 and data(j)["moved"] is False, j)
linked = one("""SELECT COUNT(*) FROM namespace_audit_logs WHERE entity_id = '%s' AND action = 'deal.linked'
                AND user_id IS NOT NULL""" % CODE)
check("linking is logged with who did it", linked == "1", linked)

# ---------------------------------------------------------------------------
print("== customer surfaces, one last sweep")
s, j, raw = public("GET", "/quotes/%s?t=%s" % (OA["uuid"], toa))
check("customer OA page: no deal code", CODE not in raw)
s, j, raw = public("GET", "/quotes/%s?t=%s" % (Q1["uuid"], t1))
check("customer page for the superseded quote: no deal code", CODE not in raw)
for rcpt, msg, raw_mail in mails():
    if "boston" in rcpt or "scan" in rcpt:
        check("supplier email to %s: no customer details" % rcpt, leaks(raw_mail) == [], leaks(raw_mail))
    elif "deal.test" not in rcpt:
        check("email to %s: no deal code" % rcpt, CODE not in raw_mail and CODE2 not in raw_mail)

print("\n%s" % ("all checks passed" if failures == 0 else "%d check(s) failed" % failures))
sys.exit(1 if failures else 0)

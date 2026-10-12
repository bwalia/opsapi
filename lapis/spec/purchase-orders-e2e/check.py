"""Purchase orders e2e checks (run by run.sh; stdlib only).

Drives the API as an owner and a clerk of workspace A and the owner of
workspace B; reads Postgres through `docker exec psql` and the mails the SMTP
sink wrote. Every check prints ok/FAIL; exit 1 on any FAIL.
"""
import base64, concurrent.futures as cf, email, email.policy, glob, hashlib, hmac, json, os, subprocess, sys, time
import urllib.error, urllib.request, uuid

API = os.environ["API"]
PG = os.environ["PG_CONTAINER"]
API_CONTAINER = os.environ["API_CONTAINER"]
SECRET = open(os.environ["JWT_SECRET_FILE"]).read().strip()
MAIL = os.environ["MAIL_DIR"]
failures = 0


def check(name, ok, detail=None):
    global failures
    if ok:
        print("  ok   " + name)
    else:
        failures += 1
        print("  FAIL " + name + ("  (" + str(detail)[:500] + ")" if detail is not None else ""))
    return ok


def sql(q):
    out = subprocess.run(["docker", "exec", "-i", PG, "psql", "-U", "postgres", "-d", "po", "-At", "-F", "|",
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


def call(method, path, u, ns, body=None, key=None, want_headers=False):
    h = {"Content-Type": "application/json", "Authorization": "Bearer " + jwt(u)}
    if ns:
        h["X-Namespace-Id"] = ns
    if key:
        h["Idempotency-Key"] = key
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            payload, status, headers = r.read(), r.status, dict(r.headers)
    except urllib.error.HTTPError as e:
        payload, status, headers = e.read(), e.code, dict(e.headers)
    try:
        j = json.loads(payload or b"{}")
    except ValueError:
        j = {"_raw": payload[:300]}
    return (status, j, headers) if want_headers else (status, j)


def data(j):
    return j.get("data") or {}


def err(j):
    e = j.get("error")
    return e.get("message") if isinstance(e, dict) else (e or "")


def user(name):
    u = {"uuid": str(uuid.uuid4()), "email": name + "@po.test"}
    sql("INSERT INTO users (uuid, first_name, last_name, email, username, password, active, created_at, updated_at) "
        "VALUES ('%s', '%s', 'Test', '%s', '%s', 'x', true, now(), now())" % (u["uuid"], name, u["email"], name))
    return u


def mails():
    out = []
    for p in sorted(glob.glob(os.path.join(MAIL, "*.eml"))):
        raw = open(p, errors="replace").read()
        rcpt, _, rest = raw.partition("\n")
        out.append((rcpt[len("X-Rcpt: "):], email.message_from_string(rest, policy=email.policy.default)))
    return out


def wait_mails(n, seconds=20):
    end = time.time() + seconds
    while time.time() < end:
        m = mails()
        if len(m) >= n:
            return m
        time.sleep(0.3)
    return mails()


def item(po, desc):
    return next(i for i in po["items"] if i["description"] == desc)


def num(v):
    return round(float(v), 3)


# ---------------------------------------------------------------------------
print("== seed")
owner_a, clerk_a, owner_b = user("ownera"), user("clerka"), user("ownerb")
for u, name, slug in ((owner_a, "PO A", "po-a"), (owner_b, "PO B", "po-b")):
    s, j = call("POST", "/api/v2/user/namespaces", u, "", {"name": name, "slug": slug})
    check("workspace %s created" % slug, s in (200, 201), j)
NS_A = one("SELECT uuid FROM namespaces WHERE slug = 'po-a'")
NS_B = one("SELECT uuid FROM namespaces WHERE slug = 'po-b'")
ID_A = one("SELECT id FROM namespaces WHERE slug = 'po-a'")
# Clerk: full purchase-order rights, no Bookkeeping.
sql("""INSERT INTO namespace_roles (uuid, namespace_id, role_name, display_name, permissions, created_at, updated_at)
       VALUES (gen_random_uuid()::text, %s, 'po_clerk', 'PO clerk',
               '{"purchase_orders":["create","read","update","delete"]}', now(), now())""" % ID_A)
sql("""INSERT INTO namespace_members (uuid, namespace_id, user_id, status, is_owner, joined_at, created_at, updated_at)
       SELECT gen_random_uuid()::text, %s, id, 'active', false, now(), now(), now() FROM users
       WHERE uuid = '%s'""" % (ID_A, clerk_a["uuid"]))
sql("""INSERT INTO namespace_user_roles (uuid, namespace_member_id, namespace_role_id, created_at, updated_at)
       SELECT gen_random_uuid()::text, m.id, r.id, now(), now() FROM namespace_members m, namespace_roles r
       WHERE m.namespace_id = %s AND r.namespace_id = %s AND r.role_name = 'po_clerk'
         AND m.user_id = (SELECT id FROM users WHERE uuid = '%s')""" % (ID_A, ID_A, clerk_a["uuid"]))
# Workspace A sends through its own SMTP (the sink); B uses the platform's.
sql("""INSERT INTO namespace_mail_settings (namespace_id, enabled, host, port, security, from_email, reply_to, updated_at)
       VALUES (%s, true, 'smtp', 2525, 'none', 'buying@a.test', 'accounts@a.test', now())""" % ID_A)
for name, email_ in (("Acme Timber", "sales@acme.test"), ("Bricks R Us", "orders@bricks.test")):
    sql("""INSERT INTO crm_accounts (uuid, namespace_id, name, email, phone, address_line1, city, owner_user_uuid)
           VALUES (gen_random_uuid()::text, %s, '%s', '%s', '0100', '1 High St', 'Leeds', '%s')"""
        % (ID_A, name, email_, owner_a["uuid"]))
ACME = one("SELECT uuid FROM crm_accounts WHERE name = 'Acme Timber'")
BRICKS = one("SELECT uuid FROM crm_accounts WHERE name = 'Bricks R Us'")
check("RBAC module has its category (zzpo7)",
      one("SELECT category FROM modules WHERE machine_name = 'purchase_orders'") == "Finance")

# ---------------------------------------------------------------------------
print("== create, lines, rounding")
LINES = [
    {"description": "Plasterboard", "quantity": 10, "unit_price": 12.5, "tax_rate": 20},
    {"description": "Screws", "quantity": 3, "unit_price": 1.33, "tax_rate": 0},
    {"description": "Washers", "quantity": 1, "unit_price": 0.01, "tax_rate": 0},
]
KEY = str(uuid.uuid4())
body = {"supplier_company_uuid": ACME, "reference": "JOB-1", "items": LINES, "metadata": {"source": "e2e"}}
s, j, h = call("POST", "/api/v2/purchase-orders", owner_a, NS_A, body, key=KEY, want_headers=True)
check("create with items (201)", s == 201, j)
PO = data(j)
P1 = PO.get("uuid")
check("supplier filled from the CRM company", PO.get("supplier_name") == "Acme Timber"
      and PO.get("supplier_email") == "sales@acme.test", PO)
check("totals: 125 + 3.99 + 0.01 net, 25 tax, 154.00 total (qty 3 @ 1.33 = 3.99, not 4.00)",
      num(PO.get("subtotal")) == 129.0 and num(PO.get("tax_total")) == 25.0 and num(PO.get("total")) == 154.0,
      (PO.get("subtotal"), PO.get("tax_total"), PO.get("total")))
s2, j2, h2 = call("POST", "/api/v2/purchase-orders", owner_a, NS_A, body, key=KEY, want_headers=True)
check("same Idempotency-Key replays the first answer", s2 == 201 and data(j2).get("uuid") == P1
      and h2.get("Idempotent-Replayed") == "true", (s2, h2.get("Idempotent-Replayed")))
check("... and creates nothing twice", one("SELECT COUNT(*) FROM purchase_orders WHERE reference = 'JOB-1'") == "1")
s, j = call("POST", "/api/v2/purchase-orders", owner_a, NS_A, dict(body, reference="JOB-X"), key=KEY)
check("same key, different body -> 422", s == 422, (s, j))

for bad, why in (({"quantity": 3, "unit_price": 1.333}, "price with 3 decimals"),
                 ({"quantity": 1.2345, "unit_price": 1}, "quantity with 4 decimals"),
                 ({"quantity": 1, "unit_price": 1.005}, "1.005 (no silent float rounding)"),
                 ({"quantity": 1, "unit_price": -1}, "negative price"),
                 ({"quantity": 1, "unit_price": "1e3"}, "exponent")):
    s, j = call("POST", "/api/v2/purchase-orders", owner_a, NS_A,
                {"supplier_name": "X", "items": [dict(bad, description="L")]})
    check("refused: " + why + " (400)", s == 400, (s, j))
s, j = call("POST", "/api/v2/purchase-orders", owner_a, NS_A, {"supplier_name": "X", "issue_date": "2026-02-30"})
check("impossible date -> 400 (not a 500)", s == 400, (s, j))
s, j = call("POST", "/api/v2/purchase-orders", owner_a, NS_A, {"supplier_name": "X", "currency": "EURO"})
check("currency must be a 3-letter code", s == 400, (s, j))
s, j = call("POST", "/api/v2/purchase-orders", owner_a, NS_A, {"supplier_name": "Tax", "items": [
    {"description": "Tiny", "quantity": 1, "unit_price": 0.05, "tax_rate": 10}]})
check("tax 0.005 rounds half away from zero like Postgres -> 0.01 (line 0.06)",
      s == 201 and num(data(j)["items"][0]["tax_amount"]) == 0.01 and num(data(j)["total"]) == 0.06, j)

# ---------------------------------------------------------------------------
print("== metadata, company switch, currency (draft)")
s, j = call("PUT", "/api/v2/purchase-orders/" + P1, owner_a, NS_A, {"metadata": {
    "receipts": "nope", "bills": {"x": 1}, "bill": {"gross": 1}, "expense_uuid": "forged", "expense_id": 9,
    "closed": True, "cancelled_reason": "x", "colour": "blue"}})
meta = data(j).get("metadata") or {}
check("server-owned metadata keys can't be set by the client", s == 200 and meta.get("colour") == "blue"
      and not any(k in meta for k in ("receipts", "bills", "bill", "expense_uuid", "expense_id", "closed",
                                       "cancelled_reason")), meta)
s, j = call("PUT", "/api/v2/purchase-orders/" + P1, owner_a, NS_A, {
    "supplier_company_uuid": BRICKS, "supplier_name": "Acme Timber", "supplier_email": "sales@acme.test"})
check("switching CRM company refreshes supplier name/email/address", s == 200
      and data(j).get("supplier_name") == "Bricks R Us" and data(j).get("supplier_email") == "orders@bricks.test",
      data(j))
s, j = call("PUT", "/api/v2/purchase-orders/" + P1, owner_a, NS_A, {"supplier_company_uuid": ACME,
                                                                  "supplier_name": "Acme Timber Ltd"})
check("... but a name typed in the same request wins", data(j).get("supplier_name") == "Acme Timber Ltd"
      and data(j).get("supplier_email") == "sales@acme.test", data(j))

# Line edits under the draft lock.
it = item(PO, "Screws")
s, j = call("PUT", "/api/v2/purchase-orders/items/" + it["uuid"], owner_a, NS_A, {"unit_price": 1.33})
check("line update keeps the exact NUMERIC maths", s == 200 and num(data(j)["line_total"]) == 3.99, j)

# ---------------------------------------------------------------------------
print("== email")
before = len(mails())
for bad, why in ((["a@x.test", "b@x.test"], "a list of recipients"), ("a@x.test, b@x.test", "two addresses"),
                 ("Eve <e@x.test>", "a display name"), ("a@x.test\r\nBcc: e@x.test", "a header injection")):
    s, j = call("POST", "/api/v2/purchase-orders/%s/email" % P1, clerk_a, NS_A, {"to": bad})
    check("email refuses " + why + " (400)", s == 400, (s, j))
s, j = call("POST", "/api/v2/purchase-orders/%s/email" % P1, owner_a, NS_A,
            {"pdf_base64": base64.b64encode(b"MZ not a pdf").decode()})
check("email refuses an attachment that isn't a PDF", s == 400, (s, j))
s, j = call("POST", "/api/v2/purchase-orders/%s/email" % P1, owner_a, NS_A, {"subject": "x" * 201})
check("email refuses a 201-character subject", s == 400, (s, j))
check("nothing was sent for the refused requests", len(mails()) == before)
PDF = base64.b64encode(b"%PDF-1.4\n%e2e\n").decode()
EKEY = str(uuid.uuid4())
ebody = {"pdf_base64": PDF, "filename": "../../etc/passwd\r\n.pdf", "subject": "PO\r\nBcc: evil@x.test",
         "message": "Thanks"}
s, j = call("POST", "/api/v2/purchase-orders/%s/email" % P1, owner_a, NS_A, ebody, key=EKEY)
check("email via the workspace's SMTP (200, says handed over, not delivered)", s == 200
      and data(j).get("via") == "workspace" and "delivered" not in data(j).get("message", "")
      and data(j).get("status") == "sent", j)
s, j = call("POST", "/api/v2/purchase-orders/%s/email" % P1, owner_a, NS_A, ebody, key=EKEY)
check("email retried with the same Idempotency-Key isn't sent twice", s == 200)
got = wait_mails(before + 1)
time.sleep(1)
got = mails()
check("exactly one email reached the mail server", len(got) == before + 1, len(got) - before)
if len(got) > before:
    rcpt, msg = got[-1]
    atts = [p for p in msg.iter_attachments()]
    check("sent to the supplier only, from the workspace, replies to the workspace",
          rcpt == "sales@acme.test" and "buying@a.test" in str(msg["From"])
          and "accounts@a.test" in str(msg.get("Reply-To", "")), (rcpt, msg["From"], msg.get("Reply-To")))
    check("subject on one line (no injected Bcc)", "\n" not in str(msg["Subject"]) and msg["Bcc"] is None,
          msg["Subject"])
    check("PDF attached under a safe file name", len(atts) == 1 and atts[0].get_content_type() == "application/pdf"
          and "/" not in (atts[0].get_filename() or "/") and atts[0].get_filename().endswith(".pdf"),
          [a.get_filename() for a in atts])
# Workspace B: no SMTP of its own -> platform queue.
s, j = call("POST", "/api/v2/purchase-orders", owner_b, NS_B, {"supplier_name": "B supplier",
            "supplier_email": "b@b.test", "items": [{"description": "Thing", "quantity": 1, "unit_price": 5}]})
PB = data(j).get("uuid")
s, j = call("POST", "/api/v2/purchase-orders/%s/email" % PB, owner_b, NS_B, {})
check("platform SMTP: 'queued for sending', not 'sent'", s == 200 and data(j).get("via") == "platform"
      and "queued" in data(j).get("message", ""), j)
# Rate limit: 20 per 10 minutes per user (refused ones count too).
codes = [call("POST", "/api/v2/purchase-orders/%s/email" % P1, clerk_a, NS_A, {"to": ["x"]})[0] for _ in range(17)]
check("21st email from one user in 10 minutes -> 429", codes[-1] == 429 and codes[0] == 400, codes)

# ---------------------------------------------------------------------------
print("== receive (quantity received now)")
s, j = call("POST", "/api/v2/purchase-orders/%s/acknowledge" % P1, owner_a, NS_A)
check("acknowledged", s == 200 and data(j).get("status") == "acknowledged", j)
s, j = call("PUT", "/api/v2/purchase-orders/" + P1, owner_a, NS_A, {"currency": "EUR"})
check("currency locked once sent (409)", s == 409, (s, j))
PO = data(call("GET", "/api/v2/purchase-orders/" + P1, owner_a, NS_A)[1])
L1, L2, L3 = item(PO, "Plasterboard")["uuid"], item(PO, "Screws")["uuid"], item(PO, "Washers")["uuid"]
s, j = call("POST", "/api/v2/purchase-orders/%s/receive" % P1, owner_a, NS_A,
            {"items": [{"item_uuid": L1, "received_quantity": 4}]})
check("old running-total field refused with a clear message", s == 400 and "quantity" in err(j), (s, j))
RKEY = str(uuid.uuid4())
rbody = {"items": [{"item_uuid": L1, "quantity": 4}, {"item_uuid": L3, "quantity": 0.5}], "note": "DN-1"}
s, j = call("POST", "/api/v2/purchase-orders/%s/receive" % P1, owner_a, NS_A, rbody, key=RKEY)
check("receive 4 boards + half a washer -> partially_received", s == 200
      and data(j).get("status") == "partially_received" and num(item(data(j), "Plasterboard")["received_quantity"]) == 4,
      j)
s, j = call("POST", "/api/v2/purchase-orders/%s/receive" % P1, owner_a, NS_A, rbody, key=RKEY)
check("receive retried with the same key isn't counted twice",
      s == 200 and num(one("SELECT received_quantity FROM purchase_order_items WHERE uuid = '%s'" % L1)) == 4)
s, j = call("POST", "/api/v2/purchase-orders/%s/receive" % P1, owner_a, NS_A, {"items": [{"item_uuid": L1, "quantity": 7}]})
check("receiving more than is outstanding -> 409", s == 409 and "ordered" in err(j), (s, j))

# ---------------------------------------------------------------------------
print("== bill part, receive rest, bill rest")
s, j = call("POST", "/api/v2/purchase-orders/%s/convert-to-bill" % P1, clerk_a, NS_A, {})
check("clerk without Bookkeeping rights can't post to the ledger (403)", s == 403 and "accounting" in err(j), (s, j))
BKEY = str(uuid.uuid4())
s, j = call("POST", "/api/v2/purchase-orders/%s/convert-to-bill" % P1, owner_a, NS_A,
            {"bill_date": "2026-10-01", "notes": "INV-1"}, key=BKEY)
b1 = data(j).get("bill") or {}
check("bill 1 covers what has arrived: 50.01 net, 10 tax, 60.01 (half a 1p washer = 1p)",
      s == 200 and b1.get("net") == 50.01 and b1.get("tax") == 10 and b1.get("gross") == 60.01, b1)
check("PO stays open for more goods after a part bill", data(j).get("status") == "partially_received", j)
check("pending ledger expense for bill 1", b1.get("expense_uuid") and one(
    "SELECT status || ':' || amount FROM accounting_expenses WHERE uuid = '%s'" % b1.get("expense_uuid"))
    == "pending:60.01", b1)
s, j = call("POST", "/api/v2/purchase-orders/%s/convert-to-bill" % P1, owner_a, NS_A,
            {"bill_date": "2026-10-01", "notes": "INV-1"}, key=BKEY)
check("bill retried with the same key: same bill, one expense", data(j).get("bill", {}).get("uuid") == b1.get("uuid")
      and one("SELECT COUNT(*) FROM accounting_expenses WHERE metadata::jsonb->>'purchase_order_uuid' = '%s'" % P1)
      == "1")
s, j = call("POST", "/api/v2/purchase-orders/%s/convert-to-bill" % P1, owner_a, NS_A, {})
check("nothing new received -> nothing to bill (409)", s == 409, (s, j))
s, j = call("POST", "/api/v2/purchase-orders/%s/receive" % P1, owner_a, NS_A, {"receive_all": True})
check("receive the rest -> received", s == 200 and data(j).get("status") == "received", j)
s, j = call("POST", "/api/v2/purchase-orders/%s/convert-to-bill" % P1, owner_a, NS_A, {})
b2 = data(j).get("bill") or {}
check("bill 2 = the rest: 78.99 net (the second half washer bills 0.00)", s == 200 and b2.get("net") == 78.99
      and b2.get("tax") == 15 and b2.get("gross") == 93.99, b2)
check("fully received and billed -> billed", data(j).get("status") == "billed", data(j).get("status"))
check("bills add up to the PO to the penny (129.00 net, 154.00 gross)",
      round(b1["net"] + b2["net"], 2) == 129.0 and round(b1["gross"] + b2["gross"], 2) == 154.0)
check("no numeric expense id stored", "expense_id" not in (data(j).get("metadata") or {}))
s, j = call("POST", "/api/v2/purchase-orders/%s/receive" % P1, owner_a, NS_A, {"items": [{"item_uuid": L2, "quantity": 1}]})
check("billed PO takes no more receipts (409)", s == 409, (s, j))

# ---------------------------------------------------------------------------
print("== void a bill")
s, j = call("POST", "/api/v2/purchase-orders/%s/bills/%s/void" % (P1, b2["uuid"]), clerk_a, NS_A, {})
check("clerk can't void (needs accounting delete) (403)", s == 403, (s, j))
s, j = call("POST", "/api/v2/purchase-orders/%s/bills/%s/void" % (P1, b2["uuid"]), owner_a, NS_A,
            {"reason": "Supplier invoice was wrong"})
check("void bill 2 (expense pending) -> received again", s == 200 and data(j).get("status") == "received", (s, j))
check("its expense is removed from the ledger",
      one("SELECT deleted_at IS NOT NULL FROM accounting_expenses WHERE uuid = '%s'" % b2["expense_uuid"]) == "t")
check("billed quantities rolled back to bill 1's",
      num(one("SELECT billed_quantity FROM purchase_order_items WHERE uuid = '%s'" % L1)) == 4)
voided = [b for b in data(j)["metadata"]["bills"] if b["uuid"] == b2["uuid"]][0]
check("voided bill kept with who/when/why", voided.get("voided_at") and voided.get("void_reason"), voided)
s, j = call("POST", "/api/v2/purchase-orders/%s/bills/%s/void" % (P1, b2["uuid"]), owner_a, NS_A, {})
check("voiding twice -> 409", s == 409, (s, j))
s, j = call("POST", "/api/v2/purchase-orders/%s/convert-to-bill" % P1, owner_a, NS_A, {})
b3 = data(j).get("bill") or {}
check("re-bill after the void gives the same amounts", s == 200 and b3.get("gross") == 93.99
      and data(j).get("status") == "billed", b3)
sql("UPDATE accounting_expenses SET status = 'approved' WHERE uuid = '%s'" % b3["expense_uuid"])
s, j = call("POST", "/api/v2/purchase-orders/%s/bills/%s/void" % (P1, b3["uuid"]), owner_a, NS_A, {})
check("approved expense: void refused with a clear message (409)", s == 409 and "Bookkeeping" in err(j), (s, j))
sql("UPDATE accounting_expenses SET status = 'rejected' WHERE uuid = '%s'" % b1["expense_uuid"])
s, j = call("POST", "/api/v2/purchase-orders/%s/bills/%s/void" % (P1, b1["uuid"]), owner_a, NS_A, {})
check("rejected expense: the bill can be voided", s == 200 and data(j).get("status") == "received", (s, j))

# ---------------------------------------------------------------------------
print("== close short")


def new_po(u=owner_a, ns=NS_A, currency="GBP", lines=None):
    s, j = call("POST", "/api/v2/purchase-orders", u, ns, {"supplier_name": "Short Co", "currency": currency,
                "items": lines or [{"description": "A", "quantity": 10, "unit_price": 2, "tax_rate": 20},
                                   {"description": "B", "quantity": 5, "unit_price": 3}]})
    p = data(j)
    call("POST", "/api/v2/purchase-orders/%s/send" % p["uuid"], u, ns)
    return p


P2 = new_po()
A2 = item(P2, "A")["uuid"]
call("POST", "/api/v2/purchase-orders/%s/receive" % P2["uuid"], owner_a, NS_A, {"items": [{"item_uuid": A2, "quantity": 6}]})
call("POST", "/api/v2/purchase-orders/%s/convert-to-bill" % P2["uuid"], owner_a, NS_A, {})
s, j = call("POST", "/api/v2/purchase-orders/%s/close" % P2["uuid"], owner_a, NS_A, {})
check("close short needs a reason (400)", s == 400, (s, j))
s, j = call("POST", "/api/v2/purchase-orders/%s/close" % P2["uuid"], owner_a, NS_A, {"reason": "Rest discontinued"})
check("close short with everything received billed -> billed", s == 200 and data(j).get("status") == "billed"
      and data(j)["metadata"]["closed"]["reason"] == "Rest discontinued", j)
P3 = new_po()
call("POST", "/api/v2/purchase-orders/%s/receive" % P3["uuid"], owner_a, NS_A,
     {"items": [{"item_uuid": item(P3, "A")["uuid"], "quantity": 2}]})
s, j = call("POST", "/api/v2/purchase-orders/%s/close" % P3["uuid"], owner_a, NS_A, {"reason": "Enough"})
check("close short with goods unbilled -> received (bill the rest)", data(j).get("status") == "received", j)
s, j = call("POST", "/api/v2/purchase-orders/%s/convert-to-bill" % P3["uuid"], owner_a, NS_A, {})
check("... then billing it finishes it", data(j).get("status") == "billed" and data(j)["bill"]["gross"] == 4.8, j)
s, j = call("POST", "/api/v2/purchase-orders/%s/receive" % P3["uuid"], owner_a, NS_A, {"receive_all": True})
check("closed PO takes no more goods (409)", s == 409, (s, j))
P4 = new_po()
s, j = call("POST", "/api/v2/purchase-orders/%s/close" % P4["uuid"], owner_a, NS_A, {"reason": "x"})
check("nothing received: close short refused, cancel instead (409)", s == 409, (s, j))

# ---------------------------------------------------------------------------
print("== currency")
PE = new_po(currency="EUR")
call("POST", "/api/v2/purchase-orders/%s/receive" % PE["uuid"], owner_a, NS_A, {"receive_all": True})
s, j = call("POST", "/api/v2/purchase-orders/%s/convert-to-bill" % PE["uuid"], owner_a, NS_A, {})
be = data(j).get("bill") or {}
check("EUR PO billed without a GBP ledger expense, flagged", s == 200 and not be.get("expense_uuid")
      and "GBP" in (be.get("ledger_note") or "") and data(j).get("accounting_expense_created") is False, be)

# ---------------------------------------------------------------------------
print("== concurrency")
P5 = new_po(lines=[{"description": "C", "quantity": 10, "unit_price": 1}])
C5 = item(P5, "C")["uuid"]
path = "/api/v2/purchase-orders/%s/receive" % P5["uuid"]
with cf.ThreadPoolExecutor(8) as ex:
    res = list(ex.map(lambda _: call("POST", path, owner_a, NS_A, {"items": [{"item_uuid": C5, "quantity": 6}]}),
                      range(2)))
check("two parallel receives of 6 (10 ordered): one wins, one 409",
      sorted(r[0] for r in res) == [200, 409], [r[0] for r in res])
with cf.ThreadPoolExecutor(8) as ex:
    res = list(ex.map(lambda _: call("POST", path, owner_a, NS_A, {"items": [{"item_uuid": C5, "quantity": 1}]}),
                      range(4)))
check("four parallel receives of 1: none lost (6 + 4 = 10)", all(r[0] == 200 for r in res)
      and num(one("SELECT received_quantity FROM purchase_order_items WHERE uuid = '%s'" % C5)) == 10,
      [r[0] for r in res])
bpath = "/api/v2/purchase-orders/%s/convert-to-bill" % P5["uuid"]
with cf.ThreadPoolExecutor(8) as ex:
    res = list(ex.map(lambda _: call("POST", bpath, owner_a, NS_A, {}), range(3)))
check("three parallel bills: exactly one bill", sorted(r[0] for r in res) == [200, 409, 409]
      and one("SELECT jsonb_array_length(metadata->'bills') FROM purchase_orders WHERE uuid = '%s'" % P5["uuid"]) == "1",
      [r[0] for r in res])
CKEY = str(uuid.uuid4())
cbody = {"supplier_name": "Race Ltd", "reference": "RACE-1"}
with cf.ThreadPoolExecutor(8) as ex:
    res = list(ex.map(lambda _: call("POST", "/api/v2/purchase-orders", owner_a, NS_A, cbody, key=CKEY), range(4)))
check("four parallel creates with one Idempotency-Key: one PO",
      one("SELECT COUNT(*) FROM purchase_orders WHERE reference = 'RACE-1'") == "1", [r[0] for r in res])
D6 = new_po(lines=[{"description": "D", "quantity": 1, "unit_price": 1}])
sql("UPDATE purchase_orders SET status = 'draft' WHERE uuid = '%s'" % D6["uuid"])
with cf.ThreadPoolExecutor(8) as ex:
    res = list(ex.map(lambda f: f(), [
        lambda: call("POST", "/api/v2/purchase-orders/%s/send" % D6["uuid"], owner_a, NS_A),
        lambda: call("POST", "/api/v2/purchase-orders/%s/items" % D6["uuid"], owner_a, NS_A,
                     {"description": "Late", "quantity": 1, "unit_price": 1})]))
final = data(call("GET", "/api/v2/purchase-orders/" + D6["uuid"], owner_a, NS_A)[1])
late_added = any(i["description"] == "Late" for i in final["items"])
check("send vs add-line race: a line is never added to a sent PO (both locked)",
      final["status"] == "sent" and (late_added == (res[1][0] == 201)), (final["status"], [r[0] for r in res]))

# ---------------------------------------------------------------------------
print("== stats")
s, j = call("GET", "/api/v2/purchase-orders/stats", owner_a, NS_A)
st = data(j)
cur = {c["currency"]: c for c in st.get("by_currency", [])}
check("values per currency, never mixed", s == 200 and set(cur) == {"GBP", "EUR"} and "total_value" not in st, st)
check("to_bill counts part-received unbilled goods (P1: bill 1 voided -> 60.01 to bill)",
      cur.get("GBP", {}).get("to_bill_value") == 60.01 and cur["GBP"]["to_bill_count"] == 1, cur.get("GBP"))
s, j = call("POST", "/api/v2/purchase-orders/%s/convert-to-bill" % P1, owner_a, NS_A, {})
active = [b for b in data(j)["metadata"]["bills"] if not b.get("voided_at")]
check("re-billing after voiding an earlier bill keeps every penny (bills add up to 154.00)",
      data(j).get("bill", {}).get("gross") == 60.01 and round(sum(b["gross"] for b in active), 2) == 154.0,
      [b["gross"] for b in active])

# ---------------------------------------------------------------------------
print("== other workspace")
for method, path, body in (("GET", "/api/v2/purchase-orders/" + P1, None),
                           ("PUT", "/api/v2/purchase-orders/" + P1, {"notes": "x"}),
                           ("POST", "/api/v2/purchase-orders/%s/receive" % P1, {"receive_all": True}),
                           ("POST", "/api/v2/purchase-orders/%s/convert-to-bill" % P1, {}),
                           ("POST", "/api/v2/purchase-orders/%s/bills/%s/void" % (P1, b1["uuid"]), {}),
                           ("POST", "/api/v2/purchase-orders/%s/close" % P1, {"reason": "x"}),
                           ("POST", "/api/v2/purchase-orders/%s/email" % P1, {}),
                           ("PUT", "/api/v2/purchase-orders/items/" + L1, {"quantity": 1}),
                           ("DELETE", "/api/v2/purchase-orders/items/" + L1, None)):
    s, j = call(method, path, owner_b, NS_B, body)
    check("workspace B: %s %s -> 404" % (method, path.split("/")[-1] if len(path) < 60 else path[-30:]), s == 404,
          (s, j))
s, j = call("GET", "/api/v2/purchase-orders", owner_b, NS_B)
check("workspace B lists only its own PO", [p["uuid"] for p in j.get("data", [])] == [PB], j)

# ---------------------------------------------------------------------------
print("== data migration (zzpo6) on an old single-bill PO")
OLD = str(uuid.uuid4())
sql("""INSERT INTO purchase_orders (uuid, namespace_id, po_number, status, supplier_name, currency, total, metadata,
                                    billed_at)
       VALUES ('%s', %s, 'PO-OLD', 'billed', 'Legacy', 'GBP', 12, '{"bill": {"net": 10, "tax": 2, "gross": 12,
               "expense_uuid": "exp-old"}, "expense_id": 7, "expense_uuid": "exp-old"}', now())""" % (OLD, ID_A))
sql("""INSERT INTO purchase_order_items (uuid, purchase_order_id, namespace_id, description, quantity, unit_price,
                                         tax_rate, tax_amount, line_total, received_quantity)
       SELECT gen_random_uuid()::text, id, namespace_id, 'Old line', 2, 5, 20, 2, 12, 2 FROM purchase_orders
       WHERE uuid = '%s'""" % OLD)
sql("DELETE FROM lapis_migrations WHERE name = 'zzpo6_purchase_orders_billed_quantity'")
out = subprocess.run(["docker", "exec", "-w", "/app", API_CONTAINER, "lapis", "migrate"], capture_output=True,
                     text=True)
check("zzpo6 re-runs cleanly", out.returncode == 0, out.stdout[-500:] + out.stderr[-500:])
s, j = call("GET", "/api/v2/purchase-orders/" + OLD, owner_a, NS_A)
m = data(j).get("metadata") or {}
bills = m.get("bills") or []
check("old bill moved to bills[0] with its expense uuid and lines; expense_id gone",
      len(bills) == 1 and bills[0].get("expense_uuid") == "exp-old" and bills[0].get("gross") == 12
      and len(bills[0].get("lines") or []) == 1 and "expense_id" not in m and "bill" not in m, m)
check("old billed lines marked billed",
      num(one("SELECT billed_quantity FROM purchase_order_items WHERE description = 'Old line'")) == 2)

print("\n%s" % ("All checks passed." if failures == 0 else "%d check(s) FAILED." % failures))
sys.exit(1 if failures else 0)

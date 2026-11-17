"""Supplier portal e2e checks (run by run.sh; stdlib only).

Drives the real API as the workspace owner (staff), two supplier portal logins (supplier A and supplier B) and an
anonymous browser (download links); reads Postgres through `docker exec psql` and the mails the SMTP sink wrote.
All documents are made-up sample files generated here. Every check prints ok/FAIL; exit 1 on any FAIL.
"""
import base64, email, email.policy, glob, hashlib, hmac, json, os, re, struct, subprocess, sys, time, zlib
import urllib.error, urllib.parse, urllib.request, uuid
import secrets
# Throwaway password for the test-only supplier login, made fresh every run (never a fixed literal).
SUPPLIER_PW = "Sp-" + secrets.token_urlsafe(18) + "9a"

API = os.environ["API"]
PG = os.environ["PG_CONTAINER"]
SECRET = open(os.environ["JWT_SECRET_FILE"]).read().strip()
MAIL = os.environ["MAIL_DIR"]
SLUG = "spws"
failures = 0
CUSTOMER = {"first": "Jane", "last": "Buyer", "email": "jane@e2e-buyer.co.uk", "company": "Buyer Analytics Ltd",
            "phone": "07700 900123"}
DEAL = "WS-DT5Z-994X"
TODAY = time.strftime("%Y-%m-%d", time.gmtime())


def check(name, ok, detail=None):
    global failures
    if ok:
        print("  ok   " + name)
    else:
        failures += 1
        print("  FAIL " + name + ("  (" + str(detail)[:700] + ")" if detail is not None else ""))
    return ok


def sql(q):
    out = subprocess.run(["docker", "exec", "-i", PG, "psql", "-U", "postgres", "-d", "sp", "-At", "-F", "|",
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


def multipart(fields, files):
    boundary = "----e2e" + uuid.uuid4().hex
    out = []
    for k, v in fields.items():
        out.append(("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n" % (boundary, k)).encode()
                   + str(v).encode() + b"\r\n")
    for k, (name, content, ctype) in files.items():
        out.append(("--%s\r\nContent-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\nContent-Type: %s\r\n\r\n"
                    % (boundary, k, name, ctype)).encode() + content + b"\r\n")
    out.append(("--%s--\r\n" % boundary).encode())
    return b"".join(out), "multipart/form-data; boundary=" + boundary


def http(method, url, headers=None, body=None, raw=False, form=None, files=None):
    headers = dict(headers or {})
    data = None
    if files is not None or form is not None:
        data, ctype = multipart(form or {}, files or {})
        headers["Content-Type"] = ctype
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            payload, status, hdrs = r.read(), r.status, dict(r.headers)
    except urllib.error.HTTPError as e:
        payload, status, hdrs = e.read(), e.code, dict(e.headers)
    if raw:
        return status, payload, hdrs
    try:
        j = json.loads(payload or b"{}")
    except ValueError:
        j = {"_raw": payload[:300].decode("utf-8", "replace")}
    return status, j


def as_user(u, method, path, body=None, ns=True, **kw):
    h = {"Authorization": "Bearer " + jwt(u)}
    if ns:
        h["X-Namespace-Slug"] = SLUG
    return http(method, API + path, h, body, **kw)


def data(j):
    return j.get("data") if isinstance(j, dict) else None


def mails():
    out = []
    for p in sorted(glob.glob(os.path.join(MAIL, "*.eml"))):
        raw = open(p, errors="replace").read()
        rcpt, _, rest = raw.partition("\n")
        msg = email.message_from_string(rest, policy=email.policy.default)
        out.append((rcpt[len("X-Rcpt: "):], msg))
    return out


def leaks(text):
    low = text.lower()
    found = [k for k in ("email", "company") if CUSTOMER[k].lower() in low]
    if (CUSTOMER["first"] + " " + CUSTOMER["last"]).lower() in low:
        found.append("name")
    if "7700900123" in re.sub(r"\D", "", text):
        found.append("phone")
    return found


# ---------------------------------------------------------------------------
# made-up sample files
def sample_pdf(lines):
    text = "BT /F1 11 Tf 50 780 Td 14 TL " + " ".join("(%s) '" % l.replace("(", "[").replace(")", "]") for l in lines) + " ET"
    objs = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Length %d >>\nstream\n%s\nendstream" % (len(text), text),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    out, offsets = b"%PDF-1.4\n", []
    for i, o in enumerate(objs, 1):
        offsets.append(len(out))
        out += ("%d 0 obj\n%s\nendobj\n" % (i, o)).encode()
    xref = len(out)
    out += ("xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)).encode()
    for off in offsets:
        out += ("%010d 00000 n \n" % off).encode()
    out += ("trailer << /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)).encode()
    return out


def sample_png():
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    raw = b"\x00\xff\xff\xff"
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


PROFORMA = sample_pdf(["SAMPLE - MADE-UP TEST DOCUMENT", "TEST Supplier (int only)", "PROFORMA INVOICE PRF-BUK012611-012",
                       "Date 17/11/2026   Your order PO-000001   Our order SO-BUK012611-063",
                       "1 x NVIDIA DGX Spark  5,256.65", "Net 5,256.65  VAT 1,051.33  Total GBP 6,307.98",
                       "Terms: 100% pre-payment   Incoterm DDP", "Deal code " + DEAL])
PAYMENT_PROOF = sample_pdf(["SAMPLE - MADE-UP TEST DOCUMENT", "Payment confirmation", "Faster Payment GBP 6,307.98",
                            "Paid and cleared 17 Nov 2026", "Reference PRF-BUK012611-012", "Transaction FP-E2E-0001"])
FINAL_INVOICE = sample_pdf(["SAMPLE - MADE-UP TEST DOCUMENT", "VAT INVOICE INV-E2E-0001", "Net 5,256.65 VAT 1,051.33",
                            "Total GBP 6,307.98", "Paid in full"])
POD = sample_png()

# ---------------------------------------------------------------------------
print("== seed")


def user(name, email_addr=None):
    u = {"uuid": str(uuid.uuid4()), "email": email_addr or (name + "@sp.test")}
    sql("INSERT INTO users (uuid, first_name, last_name, email, username, password, active, created_at, updated_at) "
        "VALUES ('%s', '%s', 'Staff', '%s', '%s', 'x', true, now(), now())" % (u["uuid"], name.title(), u["email"], name))
    return u


OWNER = user("owner")
s, j = as_user(OWNER, "POST", "/api/v2/user/namespaces", {"name": "Workstation E2E", "slug": SLUG}, ns=False)
check("workspace created", s in (200, 201), j)
NS = one("SELECT id FROM namespaces WHERE slug = '%s'" % SLUG)
# The workspace's own mail server is the SMTP sink: anything emailed would land there.
sql("""INSERT INTO namespace_smtp_accounts (uuid, namespace_id, name, host, port, security, from_email, from_name,
                                            reply_to, enabled, is_default)
       VALUES (gen_random_uuid()::text, %s, 'Sink', 'smtp', 2525, 'none', 'po@sp.test', 'Workstation', 'po@sp.test',
               true, true)""" % NS)
SUP_A = str(uuid.uuid4())
SUP_B = str(uuid.uuid4())
sql("INSERT INTO shop_suppliers (uuid, namespace_id, name) VALUES ('%s', %s, 'TEST Supplier (int only)'), "
    "('%s', %s, 'Other Supplier Ltd')" % (SUP_A, NS, SUP_B, NS))
# The deal's customer (what the supplier must never see).
sql("INSERT INTO shop_deal_codes (namespace_id, code) VALUES (%s, '%s')" % (NS, DEAL))
sql("""INSERT INTO crm_leads (uuid, namespace_id, first_name, last_name, email, phone, company_name, deal_code)
       VALUES (gen_random_uuid()::text, %s, '%s', '%s', '%s', '%s', '%s', '%s')"""
    % (NS, CUSTOMER["first"], CUSTOMER["last"], CUSTOMER["email"], CUSTOMER["phone"], CUSTOMER["company"], DEAL))
check("settings: supplier portal and its emails are off by default",
      one("SELECT count(*) FROM information_schema.columns WHERE table_name = 'shop_settings' "
          "AND column_name IN ('supplier_portal_enabled', 'supplier_portal_emails_enabled')") == "2")
s, j = as_user(OWNER, "GET", "/api/v2/shop/admin/settings")
check("GET settings shows both off", s == 200 and data(j).get("supplier_portal_enabled") is False
      and data(j).get("supplier_portal_emails_enabled") is False, j)


def new_po(supplier_uuid, deal=None, total_line=("NVIDIA DGX Spark", "1", "5256.65", "20")):
    meta = {"shop_supplier_uuid": supplier_uuid, "drop_ship": False,
            "bill_to": {"company": "Workstation Ltd", "line1": "1 Office Street", "city": "Leeds"},
            "shop_order_uuid": str(uuid.uuid4()), "shop_order_number": "WS-ORD-PRIVATE-1"}
    if deal:
        meta["deal_code"] = deal
    s, j = as_user(OWNER, "POST", "/api/v2/purchase-orders", {
        "supplier_name": "TEST Supplier (int only)" if supplier_uuid == SUP_A else "Other Supplier Ltd",
        "supplier_email": "orders@e2e-supplier.co.uk", "reference": deal or "MANUAL",
        "delivery_address": "Workstation Ltd, 1 Office Street, Leeds LS1 1AA",
        "notes": "Deal code: %s (please quote it on your delivery note and invoice)" % (deal or "-"),
        "metadata": meta,
        "items": [{"description": total_line[0], "quantity": total_line[1], "unit_price": total_line[2],
                   "tax_rate": total_line[3]}]})
    assert s in (200, 201), j
    return data(j)


PO1 = new_po(SUP_A, DEAL)
check("PO-000001: 1 x DGX Spark, 5256.65 + 1051.33 = 6307.98", PO1["po_number"] == "PO-000001"
      and PO1["subtotal"] in ("5256.65", 5256.65) and float(PO1["total"]) == 6307.98, PO1)
if one("SELECT count(*) FROM information_schema.columns WHERE table_name = 'purchase_orders' AND column_name = 'deal_code'") == "1":
    sql("UPDATE purchase_orders SET deal_code = '%s' WHERE uuid = '%s'" % (DEAL, PO1["uuid"]))
PO_B = new_po(SUP_B, None, ("Rack rails", "2", "100.00", "20"))
PO_DRAFT = new_po(SUP_A, None, ("Draft only", "1", "10.00", "20"))
for po in (PO1, PO_B):
    s, j = as_user(OWNER, "POST", "/api/v2/purchase-orders/%s/send" % po["uuid"])
    check("staff mark %s sent" % po["po_number"], s == 200, j)

# ---------------------------------------------------------------------------
print("== supplier logins (invited by staff; nothing is emailed)")
s, j = as_user(OWNER, "POST", "/api/v2/shop/admin/suppliers/%s/portal-users" % SUP_A,
               {"email": "a.contact@e2e-supplier-a.co.uk", "name": "Alex Supplier"})
check("invite supplier A contact", s == 201 and data(j)["set_password_path"].startswith("/reset-password?token="), j)
check("invite says nothing was emailed", data(j)["emailed"] is False and "Nothing has been emailed" in data(j)["message"], j)
A_LINK = data(j)["set_password_path"]
s, j = as_user(OWNER, "POST", "/api/v2/shop/admin/suppliers/%s/portal-users" % SUP_B,
               {"email": "b.contact@e2e-supplier-b.co.uk", "name": "Bea Other"})
check("invite supplier B contact", s == 201, j)
s, j = as_user(OWNER, "POST", "/api/v2/shop/admin/suppliers/%s/portal-users" % SUP_A, {"email": OWNER["email"]})
check("an existing login (e.g. a staff address) can't become a supplier login", s == 409 and j.get("code") == "EMAIL_IN_USE", j)
s, j = as_user(OWNER, "POST", "/api/v2/shop/admin/suppliers/%s/portal-users" % SUP_A,
               {"email": "a.contact@e2e-supplier-a.co.uk"})
check("inviting the same contact twice is refused", s == 409 and j.get("code") == "ALREADY_INVITED", j)
A = {"uuid": one("SELECT u.uuid FROM users u JOIN supplier_portal_users s ON s.user_id = u.id WHERE s.email = "
                 "'a.contact@e2e-supplier-a.co.uk'"), "email": "a.contact@e2e-supplier-a.co.uk"}
B = {"uuid": one("SELECT u.uuid FROM users u JOIN supplier_portal_users s ON s.user_id = u.id WHERE s.email = "
                 "'b.contact@e2e-supplier-b.co.uk'"), "email": "b.contact@e2e-supplier-b.co.uk"}
check("supplier login has only the supplier role, no permissions",
      one("""SELECT string_agg(r.role_name || ':' || r.permissions, ',') FROM namespace_members m
             JOIN namespace_user_roles ur ON ur.namespace_member_id = m.id JOIN namespace_roles r ON r.id = ur.namespace_role_id
             WHERE m.user_id = (SELECT id FROM users WHERE uuid = '%s')""" % A["uuid"]) == "supplier:{}")
token = urllib.parse.parse_qs(urllib.parse.urlparse(A_LINK).query)["token"][0]
s, j = http("POST", API + "/auth/reset-password", {}, {"token": token, "new_password": SUPPLIER_PW})
check("the set-password link works (and is valid for days, not 30 minutes)", s == 200 and
      one("SELECT expires_at > now() + interval '6 days' FROM password_reset_tokens ORDER BY id LIMIT 1") == "t", j)


def sp(u, method, path, body=None, **kw):
    return as_user(u, method, "/api/v2/supplier-portal" + path, body, ns=False, **kw)


s, j = sp(A, "GET", "/me")
check("portal off: supplier login gets 'not available yet'", s == 403 and j.get("code") == "PORTAL_NOT_AVAILABLE"
      and "isn't available yet" in j.get("error", ""), j)
s, j = as_user(OWNER, "PUT", "/api/v2/shop/admin/settings", {"supplier_portal_enabled": True})
check("staff switch the portal on (emails stay off)", s == 200 and data(j)["supplier_portal_enabled"] is True
      and data(j)["supplier_portal_emails_enabled"] is False, j)
s, j = sp(A, "GET", "/me")
check("supplier A: /me", s == 200 and data(j)["supplier"]["name"] == "TEST Supplier (int only)"
      and data(j)["buyer"]["name"] == "Workstation E2E", j)
s, j = sp(OWNER, "GET", "/me")
check("staff aren't supplier logins", s == 403 and j.get("code") == "NOT_A_SUPPLIER", j)

# ---------------------------------------------------------------------------
print("== supplier A sees only its own POs; staff routes are closed to it")
s, j = sp(A, "GET", "/purchase-orders")
ids = [p["id"] for p in data(j) or []]
check("A lists PO-000001 only (not B's, not the draft)", s == 200 and ids == [PO1["uuid"]], j)
s, j = sp(B, "GET", "/purchase-orders")
check("B lists only its own PO", s == 200 and [p["id"] for p in data(j)] == [PO_B["uuid"]], j)

for method, path, body in [
        ("GET", "/purchase-orders/%s", None), ("POST", "/purchase-orders/%s/acknowledge", {}),
        ("POST", "/purchase-orders/%s/dispatch", {"carrier": "DPD"}),
        ("POST", "/purchase-orders/%s/delivered", {"delivered_on": "2026-11-17"}),
        ("POST", "/purchase-orders/%s/messages", {"body": "hello"})]:
    s, j = sp(A, method, path % PO_B["uuid"], body)
    check("A -> B's PO: %s %s is 404" % (method, path.split("/")[-1] if "/" in path[18:] else "detail"), s == 404, j)
    s, j = sp(A, method, path % PO_DRAFT["uuid"], body)
    check("A -> its own draft: %s is 404" % path.split("/")[-1], s == 404, j)
s, j = sp(A, "POST", "/purchase-orders/%s/documents" % PO_B["uuid"], form={"doc_type": "other"},
          files={"file": ("x.pdf", PROFORMA, "application/pdf")})
check("A can't upload to B's PO (404)", s == 404, j)

for path in ["/api/v2/purchase-orders", "/api/v2/purchase-orders/%s" % PO1["uuid"],
             "/api/v2/purchase-orders/%s/portal" % PO1["uuid"], "/api/v2/shop/admin/orders",
             "/api/v2/shop/admin/suppliers", "/api/v2/shop/admin/settings", "/api/v2/users",
             "/api/v2/namespace/members", "/api/v2/user/namespaces", "/api/v2/crm/contacts",
             "/api/v2/shop/admin/suppliers/%s/portal-users" % SUP_A]:
    s, j = as_user(A, "GET", path)
    check("supplier login refused: GET " + path, s == 403 and j.get("code") == "SUPPLIER_PORTAL_ONLY", (s, j))
s, j = as_user(A, "POST", "/api/v2/purchase-orders/%s/portal/payments" % PO1["uuid"],
               {"amount": "1", "method": "bacs", "sent_on": "2026-11-17"})
check("supplier can't record payments (staff route refused)", s == 403, j)
s, j = as_user(A, "GET", "/auth/me", ns=False)
check("supplier may still read its own session", s == 200, (s, j))
# Even if someone gives the supplier login a staff role, it stays a supplier login.
sql("""INSERT INTO namespace_user_roles (uuid, namespace_member_id, namespace_role_id, created_at, updated_at)
       SELECT gen_random_uuid()::text, m.id, r.id, now(), now() FROM namespace_members m, namespace_roles r
        WHERE m.user_id = (SELECT id FROM users WHERE uuid = '%s') AND r.namespace_id = %s AND r.role_name ILIKE 'admin'
        LIMIT 1""" % (A["uuid"], NS))
s, j = as_user(A, "GET", "/api/v2/purchase-orders")
check("...still refused after being given the admin role by mistake", s == 403 and j.get("code") == "SUPPLIER_PORTAL_ONLY", j)

# ---------------------------------------------------------------------------
print("== what supplier A sees: the deal code and the spec, never our customer")
s, j = sp(A, "GET", "/purchase-orders/%s" % PO1["uuid"])
d = data(j)
blob = json.dumps(d)
check("PO detail", s == 200 and d["purchase_order"]["po_number"] == "PO-000001" and d["purchase_order"]["stage"] == "sent", j)
check("deal code and spec shown", d["purchase_order"]["deal_code"] == DEAL
      and d["purchase_order"]["items"][0]["description"] == "NVIDIA DGX Spark")
check("no customer name / email / phone / company anywhere", leaks(blob) == [], leaks(blob))
check("no staff-only data (our customer's order number, creator, metadata)", "WS-ORD-PRIVATE-1" not in blob
      and "created_by_uuid" not in blob and "metadata" not in blob and OWNER["uuid"] not in blob)
check("delivers to us: our address", d["purchase_order"]["delivery_address"].startswith("Workstation Ltd"))
check("can acknowledge", d["can"]["acknowledge"] is True)
check("the view is logged with the IP", one("""SELECT count(*) FROM namespace_audit_logs WHERE entity_id = '%s'
      AND action = 'po.viewed' AND ip_address IS NOT NULL""" % PO1["uuid"]) == "1")

# ---------------------------------------------------------------------------
print("== the purchase: acknowledge -> proforma -> payment -> dispatch -> delivered -> final invoice -> closed")
s, j = sp(A, "POST", "/purchase-orders/%s/acknowledge" % PO1["uuid"], {"note": "Thanks, confirmed"})
check("A acknowledges", s == 200 and data(j)["purchase_order"]["stage"] == "acknowledged", j)
check("the PO's own status follows (acknowledged + time)", one("SELECT status || ':' || (acknowledged_at IS NOT NULL) "
      "FROM purchase_orders WHERE uuid = '%s'" % PO1["uuid"]) == "acknowledged:true")
s, j = sp(A, "POST", "/purchase-orders/%s/acknowledge" % PO1["uuid"], {})
check("acknowledging twice is refused (409)", s == 409 and j.get("code") == "WRONG_STAGE", j)

# upload checks
s, j = sp(A, "POST", "/purchase-orders/%s/documents" % PO1["uuid"], form={"doc_type": "other"},
          files={"file": ("invoice.pdf", b"MZ\x90\x00 not a pdf", "application/pdf")})
check("a disguised executable is refused", s == 400 and j.get("code") == "INVALID_FILE", j)
s, j = sp(A, "POST", "/purchase-orders/%s/documents" % PO1["uuid"], form={"doc_type": "other"},
          files={"file": ("page.html", b"<html><script>alert(1)</script>", "text/html")})
check("HTML is refused", s == 400, j)
s, j = sp(A, "POST", "/purchase-orders/%s/documents" % PO1["uuid"], form={"doc_type": "other"},
          files={"file": ("x.pdf", PROFORMA[:-6] + b"/OpenAction << /S /JavaScript /JS (app.alert(1)) >>\n%%EOF\n",
                          "application/pdf")})
check("a PDF with JavaScript is refused", s == 400, j)
s, j = sp(A, "POST", "/purchase-orders/%s/documents" % PO1["uuid"], form={"doc_type": "other"},
          files={"file": ("big.pdf", b"%PDF-1.4\n" + b"0" * (20 * 1024 * 1024), "application/pdf")})
check("over 20 MB is refused (413)", s == 413, (s, j))
s, j = sp(A, "POST", "/purchase-orders/%s/documents" % PO1["uuid"], form={"doc_type": "payment_proof"},
          files={"file": ("proof.pdf", PAYMENT_PROOF, "application/pdf")})
check("a supplier can't upload payment proofs (only we can)", s == 403, j)
s, j = sp(A, "POST", "/purchase-orders/%s/documents" % PO1["uuid"], form={"doc_type": "proforma"},
          files={"file": ("proforma.pdf", PROFORMA, "application/pdf")})
check("a proforma needs its details", s == 400 and j.get("code") == "VALIDATION_ERROR", j)

PROFORMA_FIELDS = {"number": "PRF-BUK012611-012", "invoice_date": "2026-11-17", "supplier_order_ref": "SO-BUK012611-063",
                   "net": "5256.65", "vat": "1051.33", "total": "6307.98", "payment_terms": "100% pre-payment",
                   "incoterm": "DDP", "bank_details": "SAMPLE Bank, sort 00-00-00, account 00000000"}
s, j = sp(A, "POST", "/purchase-orders/%s/documents" % PO1["uuid"],
          form={"doc_type": "proforma", "invoice": json.dumps(PROFORMA_FIELDS), "note": "Sample proforma"},
          files={"file": ("../../Proforma PRF-BUK012611-012.pdf", PROFORMA, "application/pdf")})
check("A uploads the proforma (sample)", s == 201 and data(j)["invoice"]["number"] == "PRF-BUK012611-012"
      and data(j)["stage"] == "proforma_received", j)
check("file name cleaned", data(j)["document"]["filename"] == "Proforma PRF-BUK012611-012.pdf", data(j))
s, j = sp(A, "POST", "/purchase-orders/%s/documents" % PO1["uuid"],
          form={"doc_type": "proforma", "invoice": json.dumps(PROFORMA_FIELDS)},
          files={"file": ("again.pdf", PROFORMA, "application/pdf")})
check("the same proforma number twice is refused", s == 409 and j.get("code") == "DUPLICATE_NUMBER", j)
check("stored privately in MinIO (key, not a URL), with its hash",
      one("SELECT storage_bucket || ' ' || (storage_key LIKE 'supplier-portal/%%') || ' ' || length(sha256) FROM "
          "purchase_order_documents WHERE doc_type = 'proforma'") == "supplier-portal-private true 64")

s, j = as_user(OWNER, "GET", "/api/v2/purchase-orders/%s/portal" % PO1["uuid"])
panel = data(j)
check("staff panel: proforma matches the PO (no flags)", s == 200 and panel["invoices"][0]["flags"] == [], panel and panel["invoices"])
check("staff panel: balance due 6307.98 on the proforma", panel["balance"]["due"] == "6307.98" and panel["balance"]["basis"] == "proforma"
      and panel["balance"]["state"] == "unpaid", panel["balance"])
check("staff panel says supplier emails are off", panel["portal"]["emails_enabled"] is False and "nothing is emailed"
      in panel["portal"]["notice"])
PRF_ID = panel["invoices"][0]["id"]

# payment
s, j = as_user(OWNER, "POST", "/api/v2/purchase-orders/%s/portal/payments" % PO1["uuid"],
               form={"amount": "6307.98", "method": "faster_payment", "sent_on": "2026-11-17", "cleared_on": "2026-11-17",
                     "bank_transaction_id": "FP-E2E-0001", "payment_reference": "PRF-BUK012611-012",
                     "invoice_id": PRF_ID},
               files={"file": ("Payment confirmation.pdf", PAYMENT_PROOF, "application/pdf")})
panel = data(j)
check("staff record the Faster Payment with the bank's confirmation", s == 201 and panel["balance"]["state"] == "paid"
      and panel["balance"]["balance"] == "0.00" and panel["purchase_order"]["stage"] == "paid", j)
check("nothing emailed: the notification was suppressed", panel.get("notification", {}).get("suppressed") == "disabled",
      panel.get("notification"))
check("payment against the proforma, with the proof", panel["payments"][0]["against"]["number"] == "PRF-BUK012611-012"
      and panel["payments"][0]["proof_document_id"])
PROOF_ID = panel["payments"][0]["proof_document_id"]

s, j = sp(A, "GET", "/purchase-orders/%s" % PO1["uuid"])
d = data(j)
check("A sees the payment (amount, reference, dates) and the balance", d["payments"][0]["amount"] in ("6307.98", 6307.98)
      and d["payments"][0]["payment_reference"] == "PRF-BUK012611-012" and d["balance"]["state"] == "paid", d["payments"])
check("A doesn't see our bank transaction id or internal notes", "FP-E2E-0001" not in json.dumps(d["payments"])
      and "note" not in d["payments"][0])
check("A's history shows us as the company, not staff names",
      all(t["by"] in ("Workstation E2E", "Alex Supplier") for t in d["timeline"]) and "Owner" not in json.dumps(d["timeline"]),
      d["timeline"])

# downloads
s, j = sp(A, "POST", "/documents/%s/link" % PROOF_ID)
check("A gets a short-lived download link for the payment proof", s == 200 and data(j)["expires_in"] == 120
      and data(j)["path"].startswith("/api/v2/public/supplier-portal/files/"), j)
LINK = data(j)["path"]
s, body, hdrs = http("GET", API + LINK, raw=True)
check("the link downloads the exact file", s == 200 and body == PAYMENT_PROOF, (s, body[:80]))
check("as an attachment, not rendered, not cached", "attachment" in hdrs.get("Content-Disposition", "")
      and hdrs.get("X-Content-Type-Options") == "nosniff" and "no-store" in hdrs.get("Cache-Control", ""), hdrs)
tampered = LINK[:-3] + ("AAA" if not LINK.endswith("AAA") else "BBB")
s, j = http("GET", API + tampered)
check("a tampered link is refused", s == 403, j)


def mint(doc_uuid, user_uuid, exp):
    key = hmac.new(SECRET.encode(), b"opsapi:supplier-portal:download-links:v1", hashlib.sha256).digest()
    payload = ("v1|%s|%s|%d" % (doc_uuid, user_uuid, exp)).encode()
    return "/api/v2/public/supplier-portal/files/" + b64(payload) + "." + b64(hmac.new(key, payload, hashlib.sha256).digest())


s, j = http("GET", API + mint(PROOF_ID, A["uuid"], int(time.time()) - 5))
check("an expired link is refused (410)", s == 410 and j.get("code") == "LINK_EXPIRED", j)
s, j = http("GET", API + mint(PROOF_ID, B["uuid"], int(time.time()) + 60))
check("a valid signature for the wrong supplier still can't download", s == 403, j)
s, j = sp(B, "POST", "/documents/%s/link" % PROOF_ID)
check("B can't get a link for A's document (404)", s == 404, j)
s, j = http("GET", API + "/api/v2/public/supplier-portal/files/")
check("no token, no file", s in (403, 404), s)
s, j = sp(B, "GET", "/documents")
check("B's document list doesn't include A's", s == 200 and all(x["po_id"] == PO_B["uuid"] for x in data(j)), j)
s, j = sp(B, "GET", "/payments")
check("B's payment list doesn't include A's", s == 200 and data(j) == [], j)
s, j = sp(A, "GET", "/payments")
check("A's payment list", s == 200 and len(data(j)) == 1 and data(j)[0]["po_number"] == "PO-000001", j)
check("the download is logged", one("""SELECT count(*) FROM namespace_audit_logs WHERE entity_id = '%s'
      AND action = 'document.downloaded'""" % PO1["uuid"]) == "1")

# dispatch, delivery, invoice
s, j = sp(A, "POST", "/purchase-orders/%s/delivered" % PO1["uuid"], {"delivered_on": TODAY})
check("can't mark delivered before dispatch", s == 409 and j.get("code") == "WRONG_STAGE", j)
s, j = sp(A, "POST", "/purchase-orders/%s/dispatch" % PO1["uuid"],
          {"carrier": "DPD", "tracking_number": "15501234567890", "tracking_url": "https://track.dpd.co.uk/parcels/15501234567890",
           "dispatched_on": TODAY})
check("A enters dispatch and tracking", s == 200 and data(j)["stage"] == "dispatched", j)
s, j = sp(A, "POST", "/purchase-orders/%s/delivered" % PO1["uuid"], {"delivered_on": TODAY})
check("marking delivered needs a proof of delivery", s == 400 and j.get("code") == "POD_REQUIRED", j)
s, j = sp(A, "POST", "/purchase-orders/%s/delivered" % PO1["uuid"], form={"delivered_on": TODAY, "received_by": "Goods in"},
          files={"file": ("pod.png", POD, "image/png")})
check("A marks delivered with the POD (sample PNG)", s == 200 and data(j)["stage"] == "delivered", j)
s, j = sp(A, "POST", "/purchase-orders/%s/documents" % PO1["uuid"],
          form={"doc_type": "vat_invoice", "invoice": json.dumps({"number": "INV-E2E-0001", "invoice_date": "2026-11-19",
                                                                  "net": "5256.65", "vat": "1051.33", "total": "6307.98"})},
          files={"file": ("VAT invoice INV-E2E-0001.pdf", FINAL_INVOICE, "application/pdf")})
check("A uploads the final VAT invoice -> invoiced", s == 201 and data(j)["stage"] == "invoiced", j)

# messages
s, j = sp(A, "POST", "/purchase-orders/%s/messages" % PO1["uuid"], {"body": "Delivered today, invoice attached."})
check("A writes a message", s == 201, j)
s, j = as_user(OWNER, "POST", "/api/v2/purchase-orders/%s/portal/messages" % PO1["uuid"],
               {"body": "Thanks - received in good order."})
check("staff reply", s == 201 and len(data(j)["messages"]) == 2, j)
s, j = as_user(OWNER, "POST", "/api/v2/purchase-orders/%s/portal/messages" % PO1["uuid"],
               {"body": "FYI this is for Jane Buyer at Buyer Analytics Ltd"})
check("staff can't send the supplier our customer's details (422)", s == 422 and j.get("code") == "CUSTOMER_DETAILS_FOR_SUPPLIER", j)
s, j = sp(A, "GET", "/messages")
check("A's messages page: both messages, our side shown as the company",
      s == 200 and len(data(j)) == 2 and any(m["author"] == "Workstation E2E" for m in data(j)), j)

# stage rules and close
s, j = as_user(OWNER, "POST", "/api/v2/purchase-orders/%s/portal/stage" % PO_B["uuid"], {"to": "closed"})
check("can't close a PO that isn't delivered", s == 409, j)
s, j = as_user(OWNER, "POST", "/api/v2/purchase-orders/%s/portal/stage" % PO1["uuid"], {"to": "sent"})
check("staff can't set an arbitrary stage", s == 400, j)
s, j = as_user(OWNER, "POST", "/api/v2/purchase-orders/%s/portal/stage" % PO1["uuid"], {"to": "closed"})
check("staff close PO-000001 (delivered, invoiced, paid in full)", s == 200 and data(j)["purchase_order"]["stage"] == "closed"
      and data(j)["purchase_order"]["closed_at"], j)
s, j = sp(A, "POST", "/purchase-orders/%s/messages" % PO1["uuid"], {"body": "one more thing"})
check("after closing, the supplier can still write (history), but not upload", s == 201)
s, j = sp(A, "POST", "/purchase-orders/%s/documents" % PO1["uuid"], form={"doc_type": "other"},
          files={"file": ("late.pdf", PROFORMA, "application/pdf")})
check("no uploads on a closed PO", s == 409, j)

stages = [r[0] for r in sql("""SELECT new_values::json->>'to' FROM namespace_audit_logs WHERE entity_id = '%s'
                                AND action = 'po.stage_changed' ORDER BY id""" % PO1["uuid"])]
check("every stage is in the history, in order", stages == ["acknowledged", "proforma_received", "paid", "dispatched",
                                                            "delivered", "invoiced", "closed"], stages)
who = sql("""SELECT action, new_values::json->>'by', user_id IS NOT NULL, ip_address IS NOT NULL FROM namespace_audit_logs
             WHERE entity_id = '%s' AND action NOT LIKE 'notification.%%' ORDER BY id""" % PO1["uuid"])
check("each change says who (staff or supplier), with the user and IP", all(r[1] in ("staff", "supplier") and r[2] == "t"
      and r[3] == "t" for r in who), who)

# balance maths on B's PO: part payment, void
s, j = as_user(OWNER, "POST", "/api/v2/purchase-orders/%s/portal/payments" % PO_B["uuid"],
               {"amount": "100.00", "method": "bacs", "sent_on": "2026-11-17"})
check("part payment: 100 of 240 paid, 140 to pay", s == 201 and data(j)["balance"]["state"] == "part_paid"
      and data(j)["balance"]["balance"] == "140.00", data(j) and data(j)["balance"])
pay_id = data(j)["payments"][0]["id"]
s, j = as_user(OWNER, "POST", "/api/v2/purchase-orders/%s/portal/payments/%s/void" % (PO_B["uuid"], pay_id), {})
check("voiding needs a reason", s == 400, j)
s, j = as_user(OWNER, "POST", "/api/v2/purchase-orders/%s/portal/payments/%s/void" % (PO_B["uuid"], pay_id),
               {"reason": "Entered on the wrong PO"})
check("voided: back to unpaid, kept in the list", s == 200 and data(j)["balance"]["state"] == "unpaid"
      and data(j)["payments"][0]["voided"] is True, j)
s, j = as_user(OWNER, "POST", "/api/v2/purchase-orders/%s/portal/invoices" % PO_B["uuid"],
               {"kind": "proforma", "number": "PRF-B-1", "invoice_date": "2026-11-17", "net": "250.00", "vat": "50.00",
                "total": "300.00"})
flags = [f["code"] for f in data(j)["invoices"][0]["flags"]] if s == 201 else j
check("a proforma that doesn't match the PO is flagged for staff", s == 201 and "total_differs" in flags, flags)
s, j = sp(B, "GET", "/purchase-orders/%s" % PO_B["uuid"])
check("...but the supplier never sees our flags", s == 200 and "flags" not in json.dumps(data(j)["invoices"]), j)
s, j = as_user(OWNER, "POST", "/api/v2/purchase-orders/%s/portal/documents/%s/remove" % (PO1["uuid"], PROOF_ID), {"reason": "x"})
check("staff can soft-delete a document (kept, marked removed)", s == 200 and one(
    "SELECT deleted_at IS NOT NULL FROM purchase_order_documents WHERE uuid = '%s'" % PROOF_ID) == "t", j)
s, j = sp(A, "POST", "/documents/%s/link" % PROOF_ID)
check("a removed document can't be downloaded any more", s == 404, j)

# disable / enable
pu = data(as_user(OWNER, "GET", "/api/v2/shop/admin/suppliers/%s/portal-users" % SUP_A)[1])["users"][0]
check("supplier A's login is active after first use", pu["status"] == "active" and pu["last_seen_at"], pu)
s, j = as_user(OWNER, "POST", "/api/v2/shop/admin/suppliers/%s/portal-users/%s/disable" % (SUP_A, pu["id"]))
s2, j2 = sp(A, "GET", "/purchase-orders")
check("disabled login: refused", s == 200 and s2 == 403 and j2.get("code") == "ACCOUNT_DISABLED", (j, j2))
as_user(OWNER, "POST", "/api/v2/shop/admin/suppliers/%s/portal-users/%s/enable" % (SUP_A, pu["id"]))
check("enabled again", sp(A, "GET", "/purchase-orders")[0] == 200)

# ---------------------------------------------------------------------------
print("== the mail catcher")
time.sleep(2)
m = mails()
check("NOTHING was emailed during the whole flow (supplier emails off)", m == [], [(r, x["Subject"]) for r, x in m])
check("suppressed notifications are in the history", int(one("SELECT count(*) FROM namespace_audit_logs WHERE action = "
                                                            "'notification.suppressed'")) >= 2)

print("== hard guard when supplier emails are switched on: never a customer")
sql("""INSERT INTO users (uuid, first_name, last_name, email, username, password, active, created_at, updated_at)
       VALUES (gen_random_uuid()::text, 'Jane', 'Buyer', '%s', '%s', 'x', true, now(), now())""" % (CUSTOMER["email"], CUSTOMER["email"]))
sql("""INSERT INTO supplier_portal_users (uuid, namespace_id, supplier_id, user_id, email, status)
       SELECT gen_random_uuid()::text, %s, s.id, u.id, u.email, 'active' FROM shop_suppliers s, users u
        WHERE s.uuid = '%s' AND u.email = '%s'""" % (NS, SUP_B, CUSTOMER["email"]))
as_user(OWNER, "PUT", "/api/v2/shop/admin/settings", {"supplier_portal_emails_enabled": True})
s, j = as_user(OWNER, "POST", "/api/v2/purchase-orders/%s/portal/messages" % PO_B["uuid"], {"body": "Please confirm the rails."})
check("staff message with emails on", s == 201 and data(j)["notification"]["sent"] == 1, j)
time.sleep(3)
rcpts = [r for r, _ in mails()]
check("only supplier B's own portal user was emailed - the customer's address never", rcpts == ["b.contact@e2e-supplier-b.co.uk"], rcpts)
as_user(OWNER, "PUT", "/api/v2/shop/admin/settings", {"supplier_portal_emails_enabled": False})

print("== sign-in: a supplier login always needs the emailed code")
before = len(mails())
s, j = http("POST", API + "/auth/login", {}, form={"username": A["email"], "password": SUPPLIER_PW})
check("password alone gives no token: a sign-in code is required", s == 200 and j.get("requires_2fa") is True and "token" not in j, j)
check("a sign-in code was created for the supplier login", one("""SELECT count(*) FROM admin_otp_codes WHERE user_id =
      (SELECT id FROM users WHERE uuid = '%s')""" % A["uuid"]) == "1")
end = time.time() + 15
while time.time() < end and len(mails()) == before:
    time.sleep(0.5)
# The code goes through the platform's mail queue (it may not reach this sink); whatever arrived went to the
# supplier login itself and nobody else.
new = [r for r, _ in mails()[before:]]
check("the sign-in code went to nobody but the supplier login", all(r == A["email"] for r in new), new)

print("\n%s" % ("All checks passed." if failures == 0 else "%d check(s) FAILED." % failures))
sys.exit(0 if failures == 0 else 1)

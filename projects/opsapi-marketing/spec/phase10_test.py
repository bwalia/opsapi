#!/usr/bin/env python3
"""Phase 10: business-contact import (CSV / XLSX / PDF) → batched sending → unsubscribe means
never again. Builds real XLSX and PDF files (no external libs)."""
import base64
import io
import os
import re
import sys
import urllib.error
import urllib.request
import zipfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mktest import (  # noqa: E402
    API, P, USERS, call, check, code, data, enable, expect, finish, new_uuid, run_sender, sql, workspace,
)

PLUGINS = API + "/api/v2/namespace/plugins/opsapi_marketing"


def b64(raw):
    return base64.b64encode(raw).decode()


CSV = ("Company Name,Contact Person,E-mail Address,Telephone,Website\n"
       "Acme Plumbing Ltd,Jane Smith,jane@acme-plumbing.co.uk,+44 20 7946 0001,acme-plumbing.co.uk\n"
       "\"Bolt & Co, Builders\",Raj Patel,\"info@boltco.co.uk; raj@boltco.co.uk\",,boltco.co.uk\n"
       "Corner Cafe,Sam Lee,samlee1985@gmail.com,,\n"
       "Acme Plumbing Ltd,Jane Smith,JANE@acme-plumbing.co.uk,,\n"
       "Delta IT,Ola Nordmann,ola@delta-it.io,,\n").encode()


def xlsx(rows):
    strings, idx = [], {}

    def s(v):
        if v not in idx:
            idx[v] = len(strings)
            strings.append(v)
        return idx[v]
    body = "".join(f'<row r="{r}">' + "".join(f'<c r="{chr(65 + c)}{r}" t="s"><v>{s(v)}</v></c>'
                                               for c, v in enumerate(row) if v) + "</row>"
                   for r, row in enumerate(rows, 1))
    ns = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("xl/workbook.xml", f"<workbook {ns}/>")
        z.writestr("xl/sharedStrings.xml", f"<sst {ns}>" + "".join(
            "<si><t>" + v.replace("&", "&amp;").replace("<", "&lt;") + "</t></si>" for v in strings) + "</sst>")
        z.writestr("xl/worksheets/sheet1.xml", f"<worksheet {ns}><sheetData>{body}</sheetData></worksheet>")
    return buf.getvalue()


def pdf(lines):
    text = "BT /F1 10 Tf 40 800 Td 14 TL " + " ".join(
        "(" + ln.replace("(", "\\(").replace(")", "\\)") + ") '" for ln in lines) + " ET"
    objs = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R "
            "/Resources << /Font << /F1 5 0 R >> >> >>",
            f"<< /Length {len(text)} >>\nstream\n{text}\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    out, offs = "%PDF-1.4\n", []
    for i, o in enumerate(objs, 1):
        offs.append(len(out))
        out += f"{i} 0 obj\n{o}\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n" + "".join(f"{o:010d} 00000 n \n" for o in offs)
    out += f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n"
    return out.encode("latin-1")


XLSX = xlsx([["Business", "Email", "Name"], ["Echo Ltd", "hello@echo-ltd.com", "Eve Echo"],
             ["Fox LLP", "partners@foxllp.co.uk", ""]])
PDF = pdf(["Directory of firms", "Golf Gear - sales@golfgear.co.uk - 0161 000", "Hotel Inn  bookings@hotelinn.com",
           "logo@2x.png"])


def upload(ns, list_uuid, name, raw, **kw):
    body = {"file_name": name, "content_base64": b64(raw)}
    body.update(kw)
    return call("POST", P + f"/lists/{list_uuid}/prospects", "owner_a", ns, body)


def new_list(ns, name):
    return data(expect("list " + name, call("POST", P + "/lists", "owner_a", ns,
                                            {"name": name, "list_type": "static", "channel": "email"}), 201))["uuid"]


W = workspace("owner_a", "P10 prospects", "p10-" + new_uuid()[:8])
enable("owner_a", W)
expect("settings", call("PUT", PLUGINS, "owner_a", W, {"settings": {
    "dry_run": True, "quiet_hours_from": "00:00", "quiet_hours_to": "00:00", "marketing_frequency_cap_count": 50,
    "sender_address": "Sysops247 Ltd, 1 High Street, London", "email_rate_per_min": 500}}), 200)
L1 = new_list(W, "Bought companies")

# --- preview: every email, header-aware, personal + duplicates skipped (UK rules) ---
pv = data(expect("CSV preview", upload(W, L1, "companies.csv", CSV), 200))
check("CSV: 6 emails found (two in one cell)", pv.get("found") == 6, pv)
check("CSV: 4 importable", pv.get("importable") == 4, pv)
sk = pv.get("skipped") or {}
check("CSV: gmail skipped as personal", sk.get("personal") == 1, sk)
check("CSV: JANE@ duplicate skipped", sk.get("duplicates") == 1, sk)
first = (pv.get("sample") or [{}])[0]
check("CSV: company/name/phone mapped from headers",
      first.get("company") == "Acme Plumbing Ltd" and first.get("first_name") == "Jane"
      and first.get("phone") == "+442079460001", first)
check("CSV: preview imports nothing", sql(
    f"SELECT count(*) FROM mkt_list_members m JOIN mkt_lists l ON l.id = m.list_id WHERE l.uuid = '{L1}'") == ["0"])

r = upload(W, L1, "companies.csv", CSV, commit=True)
check("import needs the lawful-basis confirmation", r[0] == 400 and code(r) == "confirm_required", r)
im = data(expect("CSV import", upload(W, L1, "companies.csv", CSV, commit=True, confirm=True,
                                      source_note="Bought from ExampleData Ltd"), 200))
check("CSV: 4 imported, 4 new contacts", im.get("imported") == 4 and im.get("created_contacts") == 4, im)
row = sql(f"""SELECT c.metadata->>'company' || '|' || c.phone || '|' || s.legal_basis || '|' || s.status
              FROM crm_contacts c JOIN namespaces n ON n.id = c.namespace_id
              JOIN mkt_subscriptions s ON s.contact_uuid = c.uuid AND s.namespace_id = n.id
              WHERE n.uuid = '{W}' AND c.email = 'jane@acme-plumbing.co.uk'""")
check("contact: company, E.164 phone, legitimate-interest basis",
      row == ["Acme Plumbing Ltd|+442079460001|legitimate_interest|subscribed"], row)
rec = sql(f"SELECT file_name || '|' || imported || '|' || source_note FROM mkt_list_imports i "
          f"JOIN namespaces n ON n.id = i.namespace_id WHERE n.uuid = '{W}'")
check("import recorded as evidence", rec == ["companies.csv|4|Bought from ExampleData Ltd"], rec)

px = data(expect("XLSX preview", upload(W, L1, "firms.xlsx", XLSX), 200))
check("XLSX: 2 importable", px.get("file_type") == "xlsx" and px.get("importable") == 2, px)
pp = data(expect("PDF preview", upload(W, L1, "directory.pdf", PDF), 200))
check("PDF: 2 importable, image name ignored", pp.get("file_type") == "pdf" and pp.get("found") == 2, pp)
expect("XLSX import", upload(W, L1, "firms.xlsx", XLSX, commit=True, confirm=True), 200)
expect("PDF import", upload(W, L1, "directory.pdf", PDF, commit=True, confirm=True), 200)
check("list now has 8 members", sql(f"SELECT count(*) FROM mkt_list_members m JOIN mkt_lists l ON l.id = m.list_id "
                                     f"WHERE l.uuid = '{L1}' AND m.removed_at IS NULL") == ["8"])
pc = data(expect("consent basis", upload(W, L1, "companies.csv", CSV, legal_basis="consent"), 200))
check("opted-in list: personal addresses allowed", (pc.get("skipped") or {}).get("personal") == 0
      and pc.get("personal_rule") is False, pc)
check("old .xls refused clearly", upload(W, L1, "old.xls", b"\xd0\xcf\x11\xe0junk")[0] == 400)

# --- batched sending: 3 per batch, an hour apart ---
cid = data(expect("campaign", call("POST", P + "/campaigns", "owner_a", W, {
    "name": "Need a website?", "channel": "email", "message_type": "marketing",
    "subject": "{{contact.first_name}}, a new website for {{contact.company}}?",
    "body_html": "<p>Hi {{contact.first_name}},</p><p>We build websites. <a href=\"https://sysops247.example/contact\">"
                 "Contact us</a></p>",
    "body_text": "Hi {{contact.first_name}}, we build websites.",
    "batch_size": 3, "batch_interval_minutes": 60}), 201))["uuid"]
sd = data(expect("send now", call("POST", P + f"/campaigns/{cid}/schedule", "owner_a", W,
                                  {"list_uuid": L1, "send_now": True}), 200))
check("all 8 queued in one go", sd.get("queued") == 8, sd)
slots = sql(f"SELECT count(DISTINCT date_trunc('minute', send_after)) FROM mkt_deliveries d "
            f"JOIN mkt_campaigns c ON c.id = d.campaign_id WHERE c.uuid = '{cid}'")
check("3 batch slots (3 + 3 + 2)", slots == ["3"], slots)
run_sender(W)
st = sql(f"SELECT d.state, count(*) FROM mkt_deliveries d JOIN mkt_campaigns c ON c.id = d.campaign_id "
         f"WHERE c.uuid = '{cid}' GROUP BY 1 ORDER BY 1")
check("first batch only: 3 sent, 5 waiting", st == ["accepted|3", "queued|5"], st)
check("campaign still sending", sql(f"SELECT status FROM mkt_campaigns WHERE uuid = '{cid}'") == ["sending"])

# The later batches go out when due.
sql(f"UPDATE mkt_deliveries d SET send_after = NOW() FROM mkt_campaigns c "
    f"WHERE c.id = d.campaign_id AND c.uuid = '{cid}' AND d.state = 'queued'")
run_sender(W)
st = sql(f"SELECT d.state, count(*) FROM mkt_deliveries d JOIN mkt_campaigns c ON c.id = d.campaign_id "
         f"WHERE c.uuid = '{cid}' GROUP BY 1 ORDER BY 1")
check("remaining batches sent once due", st == ["accepted|8"], st)


body = sql(f"""SELECT d.subject || '|||' || replace(d.body_html, E'\\n', ' ') || '|||'
                      || replace(d.body_text, E'\\n', ' ') FROM mkt_deliveries d
               JOIN mkt_campaigns c ON c.id = d.campaign_id
               WHERE c.uuid = '{cid}' AND d.address = 'jane@acme-plumbing.co.uk'""")
subj, html, text = (body[0] if body else "||||||").split("|||")
check("merge: name and imported company", subj == "Jane, a new website for Acme Plumbing Ltd?", subj)
check("footer: sender address", "Sysops247 Ltd, 1 High Street, London" in html, html[-400:])
tok = re.search(r"public/unsubscribe\?token=([^\"'&<\s]+)", html)
check("footer: working unsubscribe link (absolute)", bool(tok) and "http" in html.split("public/unsubscribe")[0][-80:],
      html[-400:])
check("plain text: unsubscribe link", "Unsubscribe: http" in text, text[-200:])

# --- unsubscribe → never emailed again ---
try:
    with urllib.request.urlopen(API + "/api/v2/opsapi-marketing/public/unsubscribe?token=" + tok.group(1),
                                timeout=10) as u:
        unsub_status = u.status
except urllib.error.HTTPError as e:
    unsub_status = e.code
check("unsubscribe link works", unsub_status == 200, unsub_status)
check("address suppressed", sql(f"""SELECT count(*) FROM mkt_suppressions s JOIN namespaces n ON n.id = s.namespace_id
                                    WHERE n.uuid = '{W}' AND s.address = 'jane@acme-plumbing.co.uk'""") == ["1"])
L2 = new_list(W, "Another bought list")
p2 = data(expect("re-import preview", upload(W, L2, "companies.csv", CSV), 200))
check("re-import skips the unsubscribed address", (p2.get("skipped") or {}).get("unsubscribed") == 1
      and p2.get("importable") == 3, p2)
c2 = data(expect("campaign 2", call("POST", P + "/campaigns", "owner_a", W, {
    "name": "Second promo", "channel": "email", "message_type": "marketing", "subject": "Hello again",
    "body_html": "<p>Hi {{contact.first_name}}</p>"}), 201))["uuid"]
expect("send campaign 2 to the first list", call("POST", P + f"/campaigns/{c2}/schedule", "owner_a", W,
                                                 {"list_uuid": L1, "send_now": True}), 200)
run_sender(W)
jane = sql(f"""SELECT d.state || ':' || COALESCE(d.reason, '') FROM mkt_deliveries d JOIN mkt_campaigns c
               ON c.id = d.campaign_id WHERE c.uuid = '{c2}' AND d.address = 'jane@acme-plumbing.co.uk'""")
check("unsubscribed contact not emailed by a later campaign", jane and jane[0].startswith("skipped:suppressed"), jane)

# One email per address even when two CRM contacts share it.
sql(f"""INSERT INTO crm_contacts (uuid, namespace_id, first_name, email, owner_user_uuid, status, created_at, updated_at)
        SELECT gen_random_uuid()::text, id, 'Dup', 'ola@delta-it.io', '{USERS["owner_a"][0]}', 'active', now(), now()
        FROM namespaces WHERE uuid = '{W}';
        INSERT INTO mkt_list_members (namespace_id, list_id, contact_uuid, source)
        SELECT c.namespace_id, l.id, c.uuid, 'manual' FROM crm_contacts c JOIN mkt_lists l ON l.uuid = '{L1}'
        WHERE c.first_name = 'Dup' AND c.namespace_id = l.namespace_id""")
c3 = data(expect("campaign 3", call("POST", P + "/campaigns", "owner_a", W, {
    "name": "Third", "channel": "email", "message_type": "marketing", "subject": "Hi",
    "body_html": "<p>Hi</p>"}), 201))["uuid"]
expect("send campaign 3", call("POST", P + f"/campaigns/{c3}/schedule", "owner_a", W,
                               {"list_uuid": L1, "send_now": True}), 200)
dups = sql(f"SELECT count(*) FROM mkt_deliveries d JOIN mkt_campaigns c ON c.id = d.campaign_id "
           f"WHERE c.uuid = '{c3}' AND d.address = 'ola@delta-it.io'")
check("one delivery per address", dups == ["1"], dups)

sys.exit(finish())

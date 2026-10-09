"""Forms e2e checks (run by run.sh; stdlib only).

Talks to two API pods sharing one Postgres and Redis (A, B), plus a pod
without the forms feature (C); reads Postgres through `docker exec psql` and
the emails the SMTP sink wrote. Every check prints ok/FAIL; exit 1 on any FAIL.
"""
import base64, concurrent.futures as cf, email, email.policy, glob, hashlib, hmac, json, os, re, subprocess, sys, time, uuid
import urllib.error, urllib.request

A, B, C = os.environ["API_A"], os.environ["API_B"], os.environ["API_C"]
API_CONTAINER_B = os.environ.get("API_CONTAINER_B")
STUB_DIR = os.environ.get("STUB_DIR", "")
STUBS = os.environ.get("STUBS_CONTAINER", "")
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
        print("  FAIL " + name + ("  (" + str(detail)[:400] + ")" if detail is not None else ""))
    return ok


def sql(q):
    out = subprocess.run(["docker", "exec", "-i", PG, "psql", "-U", "postgres", "-d", "forms", "-At", "-F", "|",
                          "-v", "ON_ERROR_STOP=1", "-c", q], capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(out.stderr)
    return [line.split("|") for line in out.stdout.strip().split("\n") if line]


def one(q):
    rows = sql(q)
    return rows[0][0] if rows else None


def b64(d):
    return base64.urlsafe_b64encode(d).rstrip(b"=").decode()


def jwt(user):
    now = int(time.time())
    head = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    body = b64(json.dumps({"userinfo": {"uuid": user["uuid"], "email": user["email"]}, "iat": now,
                           "exp": now + 7200, "iss": "opsapi"}).encode())
    sig = b64(hmac.new(SECRET.encode(), (head + "." + body).encode(), hashlib.sha256).digest())
    return head + "." + body + "." + sig


def call(method, path, user=None, ns=None, body=None, base=A, headers=None, raw=False):
    h = {"Content-Type": "application/json"}
    if user:
        h["Authorization"] = "Bearer " + jwt(user)
    if ns:
        h["X-Namespace-Id"] = ns
    h.update(headers or {})
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            payload, status = r.read(), r.status
    except urllib.error.HTTPError as e:
        payload, status = e.read(), e.code
    if raw:
        return status, payload
    try:
        return status, json.loads(payload or b"{}")
    except ValueError:
        return status, {"_raw": payload[:300]}


def user(name):
    u = {"uuid": str(uuid.uuid4()), "email": name + "@forms.test", "name": name}
    sql("INSERT INTO users (uuid, first_name, last_name, email, username, password, active, created_at, updated_at) "
        "VALUES ('%s', '%s', 'Test', '%s', '%s', 'x', true, now(), now())" % (u["uuid"], name, u["email"], name))
    return u


def submit(public_id, answers, token, ip, key=None, hp=None, base=A, extra=None):
    body = {"answers": answers, "render_token": token, "context": {"page_url": "https://site.test/contact",
                                                                    "utm": {"campaign": "autumn"}}}
    body.update(extra or {})
    if hp is not None:
        body["_hp"] = hp
    return call("POST", "/api/v2/public/forms/%s/submissions" % public_id, body=body, base=base,
                headers={"Idempotency-Key": key or str(uuid.uuid4()), "X-Forwarded-For": ip})


def token_for(public_id):
    s, j = call("GET", "/api/v2/public/forms/" + public_id, headers={"X-Forwarded-For": "198.51.100.250"})
    return (j.get("data") or {}).get("render_token"), s, j


ip_counter = [0]


def ip():
    ip_counter[0] += 1
    n = ip_counter[0]
    return "203.0.%d.%d" % (n // 250, n % 250 + 1)


def upload(public_id, field, name, data, token, base=A):
    boundary = uuid.uuid4().hex
    body = ("--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"%s\"\r\n"
            "Content-Type: application/octet-stream\r\n\r\n" % (boundary, name)).encode() + data \
        + ("\r\n--%s--\r\n" % boundary).encode()
    h = {"Content-Type": "multipart/form-data; boundary=" + boundary, "X-Forwarded-For": ip()}
    if token:
        h["X-Render-Token"] = token
    req = urllib.request.Request("%s/api/v2/public/forms/%s/uploads?field=%s" % (base, public_id, field), data=body,
                                 method="POST", headers=h)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def lapis_exec(container, lua):
    return subprocess.run(["docker", "exec", "-w", "/app", container, "lapis", "exec", lua], capture_output=True,
                          text=True).stdout


def mails():
    out = []
    for p in sorted(glob.glob(os.path.join(MAIL, "*.eml"))):
        raw = open(p, errors="replace").read()
        rcpt, _, rest = raw.partition("\n")
        msg = email.message_from_string(rest, policy=email.policy.default)
        parts = [msg.get("Subject", "")]
        for part in msg.walk():  # bodies are base64 / quoted-printable encoded
            if part.get_content_maintype() == "text":
                parts.append(part.get_content())
        out.append({"rcpt": rcpt[len("X-Rcpt: "):], "text": "\n".join(parts)})
    return out


def wait_mail(pred, seconds=30):
    end = time.time() + seconds
    while time.time() < end:
        found = [m for m in mails() if pred(m)]
        if found:
            return found
        time.sleep(1)
    return []


def count(table, where):
    return int(one("SELECT COUNT(*) FROM %s WHERE %s" % (table, where)))


# ---------------------------------------------------------------------------
print("== seed")
owner_a, member_a, owner_b = user("ownera"), user("membera"), user("ownerb")
s, j = call("POST", "/api/v2/user/namespaces", owner_a, body={"name": "Forms A", "slug": "forms-a"})
check("owner A created workspace A", s in (200, 201), j)
s, j = call("POST", "/api/v2/user/namespaces", owner_b, body={"name": "Forms B", "slug": "forms-b"})
check("owner B created workspace B", s in (200, 201), j)
NS_A = one("SELECT uuid FROM namespaces WHERE slug = 'forms-a'")
NS_B = one("SELECT uuid FROM namespaces WHERE slug = 'forms-b'")
ID_A = one("SELECT id FROM namespaces WHERE slug = 'forms-a'")
sql("UPDATE namespaces SET max_users = 100 WHERE slug = 'forms-a'")
# member A: forms editor who may create users but holds no customer/CRM rights.
sql("""INSERT INTO namespace_roles (uuid, namespace_id, role_name, display_name, permissions, created_at, updated_at)
       VALUES (gen_random_uuid()::text, %s, 'forms_editor', 'Forms editor',
               '{"forms":["create","read","update","delete"],"users":["create","read"]}', now(), now())""" % ID_A)
sql("""INSERT INTO namespace_members (uuid, namespace_id, user_id, status, is_owner, joined_at, created_at, updated_at)
       SELECT gen_random_uuid()::text, %s, id, 'active', false, now(), now(), now() FROM users
       WHERE uuid = '%s'""" % (ID_A, member_a["uuid"]))
sql("""INSERT INTO namespace_user_roles (uuid, namespace_member_id, namespace_role_id, created_at, updated_at)
       SELECT gen_random_uuid()::text, m.id, r.id, now(), now() FROM namespace_members m, namespace_roles r
       WHERE m.namespace_id = %s AND r.namespace_id = %s AND r.role_name = 'forms_editor'
         AND m.user_id = (SELECT id FROM users WHERE uuid = '%s')""" % (ID_A, ID_A, member_a["uuid"]))
sql("""INSERT INTO namespace_mail_settings (namespace_id, enabled, host, port, security, from_email, updated_at)
       VALUES (%s, true, 'smtp', 2525, 'none', 'forms@a.test', now())""" % ID_A)

# ---------------------------------------------------------------------------
print("== permissions and targets")
s, j = call("GET", "/api/v2/forms/targets", owner_a, NS_A)
keys = {t["key"]: t for t in j.get("data", [])}
check("targets here: customer, lead, user (owner may use all)",
      s == 200 and set(keys) == {"customer", "lead", "user"} and all(t["allowed"] for t in keys.values()), j)
s, j = call("POST", "/api/v2/forms", member_a, NS_A, {"title": "No rights", "targets": ["customer"]})
check("editor without customers.create can't add the customer target (422)",
      s == 422 and "customers.create" in j.get("error", ""), (s, j))
s, j = call("POST", "/api/v2/forms", member_a, NS_A, {"title": "Escalate", "targets": [{"type": "user", "role": "admin"}]})
check("editor can't make a form that grants the admin role (422)", s == 422, (s, j))
s, j = call("POST", "/api/v2/forms", member_a, NS_A, {"title": "Invite members",
                                                      "targets": [{"type": "user", "role": "member"}]})
check("editor with users.create may invite as member", s == 201, (s, j))
s, j = call("GET", "/api/v2/forms", owner_b, NS_B)
check("workspace B lists none of A's forms", s == 200 and j.get("data") == [], j)

print("== build and publish")
s, j = call("POST", "/api/v2/forms", owner_a, NS_A, {
    "title": "Quote request",
    "fields": [
        {"type": "short_text", "label": "Company", "maps_to": "company"},
        {"type": "long_text", "label": "Message", "maps_to": "notes"},
        {"type": "single_select", "label": "Budget", "options": ["Low", "High"]},
    ],
    "targets": ["customer", "lead", {"type": "user", "role": "member"}],
    "settings": {"notify_emails": ["alerts@a.test"],
                 "auto_reply": {"enabled": True, "subject": "Thanks {{name}}", "body": "Hi {{name}},\nwe got it."}},
})
form = j.get("data") or {}
fields = (form.get("schema") or {}).get("fields", [])
check("form created as a draft", s == 201 and form.get("status") == "draft", (s, j))
check("name and email added first and locked",
      [(f["type"], f.get("system"), f.get("required")) for f in fields[:2]]
      == [("name", "contact.name", True), ("email", "contact.email", True)], fields)
FID = form.get("uuid")
if not FID:
    print("  FAIL can't create a form here, so the rest can't run")
    sys.exit(1)
without_email = [f for f in fields if f.get("system") != "contact.email"]
s, j = call("PUT", "/api/v2/forms/" + FID, owner_a, NS_A, {"fields": without_email,
                                                           "expected_updated_at": form.get("updated_at")})
check("removing the locked email field puts it back",
      s == 200 and any(f.get("system") == "contact.email" for f in j["data"]["schema"]["fields"]), (s, j))
s, j2 = call("PUT", "/api/v2/forms/" + FID, owner_a, NS_A, {"title": "Stale", "expected_updated_at": form["updated_at"]})
check("a stale expected_updated_at is refused (409)", s == 409, (s, j2))
PUB = form["public_id"]
_, s, _ = token_for(PUB)
check("a draft has no public page (404)", s == 404, s)
s, j = call("POST", "/api/v2/forms/%s/publish" % FID, owner_a, NS_A)
check("publish -> version 1, published", s == 200 and j["data"]["published_version"] == 1
      and j["data"]["status"] == "published", (s, j))
tok, s, j = token_for(PUB)
pf = (j.get("data") or {}).get("fields", [])
check("public GET returns the fields and a render token", s == 200 and tok and len(pf) == 5, (s, j))
check("public fields leak no internals (system, maps_to)",
      all("system" not in f and "maps_to" not in f for f in pf), pf)
s, j = call("GET", "/api/v2/forms/" + FID, owner_b, NS_B)
check("workspace B can't read A's form (404)", s == 404, (s, j))
for m, p in (("PUT", ""), ("DELETE", ""), ("GET", "/submissions"), ("GET", "/export"), ("POST", "/publish")):
    s, _ = call(m, "/api/v2/forms/%s%s" % (FID, p), owner_b, NS_B, {} if m in ("PUT", "POST") else None)
    check("workspace B %s /forms/<A's form>%s -> 404" % (m, p), s == 404, s)

ANS = {"name": {"first": "Ann", "last": "Lee"}, "email": "Ann@X.test", "company": "Acme",
       "message": "Need a quote", "budget": "high"}
print("== bots")
s, j = submit(PUB, ANS, tok, ip())
check("a submit within 2 s of loading the form is answered 201 ...", s == 201, (s, j))
time.sleep(2.2)
s, j = submit(PUB, ANS, tok, ip(), hp="http://spam.test")
check("... and so is a filled honeypot", s == 201, (s, j))
check("both were stored as spam, creating no records",
      count("form_submissions", "status = 'spam'") == 2 and count("customers", "lower(email) = 'ann@x.test'") == 0)
SPAM_HP = one("SELECT uuid FROM form_submissions WHERE meta->>'spam_reason' = 'honeypot'")

print("== a response creates and links the records")
s, j = submit(PUB, {"email": "nope", "budget": "huge"}, tok, ip())
check("invalid answers -> 400 with an error per field",
      s == 400 and set(j.get("errors", {})) == {"name", "email", "budget"}, (s, j))
s, j = submit(PUB, ANS, tok, ip())
check("valid response -> 201 with the thank-you message", s == 201 and j.get("message"), (s, j))
row = sql("SELECT id, status, respondent_email FROM form_submissions WHERE status <> 'spam' ORDER BY id DESC LIMIT 1")[0]
links = dict((r[0], (r[1], r[2])) for r in sql("SELECT target, outcome, entity_type FROM form_submission_links "
                                                 "WHERE submission_id = %s" % row[0]))
check("response complete, email stored lower-case", row[1] == "complete" and row[2] == "ann@x.test", row)
check("links: customer created, lead created, user invited",
      links == {"customer": ("created", "customer"), "lead": ("created", "lead"), "user": ("invited", "invitation")},
      links)
check("customer + lead are in workspace A, from the form",
      count("customers", "namespace_id = %s AND lower(email) = 'ann@x.test'" % ID_A) == 1
      and count("crm_leads", "namespace_id = %s AND lower(email) = 'ann@x.test' AND source = 'form' "
                             "AND company_name = 'Acme' AND campaign = 'autumn'" % ID_A) == 1)
check("one pending invitation for ann",
      count("namespace_invitations", "namespace_id = %s AND email = 'ann@x.test' AND status = 'pending'" % ID_A) == 1)

s, j = submit(PUB, dict(ANS, email="ann@x.test", company="Changed Ltd"), tok, ip())
row2 = one("SELECT id FROM form_submissions WHERE status <> 'spam' ORDER BY id DESC LIMIT 1")
outcomes = sorted(r[0] for r in sql("SELECT outcome FROM form_submission_links WHERE submission_id = %s" % row2))
check("same email again: all three matched", s == 201 and outcomes == ["matched"] * 3, outcomes)
check("... and nothing duplicated or overwritten",
      count("customers", "lower(email) = 'ann@x.test'") == 1 and count("crm_leads", "lower(email) = 'ann@x.test'") == 1
      and count("crm_leads", "company_name = 'Changed Ltd'") == 0
      and count("namespace_invitations", "email = 'ann@x.test'") == 1)

key = str(uuid.uuid4())
before = count("form_submissions", "status <> 'spam'")
r1 = submit(PUB, dict(ANS, email="idem@x.test"), tok, ip(), key=key)
r2 = submit(PUB, dict(ANS, email="idem@x.test"), tok, ip(), key=key, base=B)
check("the same Idempotency-Key twice (two pods): both 201, one response",
      r1[0] == 201 and r2[0] == 201 and count("form_submissions", "status <> 'spam'") == before + 1, (r1, r2))

print("== concurrency")
def race(i):
    return submit(PUB, dict(ANS, email="race@x.test", name={"first": "Race%d" % i, "last": ""}), tok, ip(),
                  base=A if i % 2 else B)[0]
with cf.ThreadPoolExecutor(20) as ex:
    codes = list(ex.map(race, range(20)))
check("20 concurrent responses with one email (two pods): all 201", codes == [201] * 20, codes)
check("... exactly one customer, one lead and one invitation",
      (count("customers", "lower(email) = 'race@x.test'"), count("crm_leads", "lower(email) = 'race@x.test'"),
       count("namespace_invitations", "email = 'race@x.test'")) == (1, 1, 1),
      (count("customers", "lower(email) = 'race@x.test'"), count("crm_leads", "lower(email) = 'race@x.test'"),
       count("namespace_invitations", "email = 'race@x.test'")))
check("... 20 responses, 1 created + 19 matched each",
      sql("SELECT outcome, COUNT(*) FROM form_submission_links l JOIN form_submissions s ON s.id = l.submission_id "
          "WHERE s.respondent_email = 'race@x.test' AND l.target = 'customer' GROUP BY outcome ORDER BY outcome")
      == [["created", "1"], ["matched", "19"]])

same_ip = ip()
codes = [submit(PUB, dict(ANS, email="rl%d@x.test" % i), tok, same_ip)[0] for i in range(6)]
check("6 responses from one IP in a minute: the 6th is 429", codes == [201] * 5 + [429], codes)

print("== emails (outbox)")
alert = wait_mail(lambda m: "alerts@a.test" in m["rcpt"] and "Quote request" in m["text"])
check("new-response alert sent to the notify address", bool(alert))
reply = wait_mail(lambda m: m["rcpt"] == "ann@x.test" and "Thanks Ann" in m["text"])
check("auto-reply sent to the respondent with {{name}} filled", bool(reply))
inv = wait_mail(lambda m: m["rcpt"] == "ann@x.test" and "/invite/" in m["text"])
check("invitation email sent with an /invite/<token> link", bool(inv))
time.sleep(3)
check("only one invitation email for ann (the repeat response matched)",
      len([m for m in mails() if m["rcpt"] == "ann@x.test" and "/invite/" in m["text"]]) == 1)
check("no email for spam responses",
      not [m for m in mails() if "spam.test" in m["text"]])
check("outbox deliveries to core.forms are done, none dead",
      count("plugin_event_deliveries", "subscriber = 'core.forms' AND status = 'dead'") == 0
      and count("plugin_event_deliveries", "subscriber = 'core.forms' AND status = 'done'") > 0)
check("responses are not copied into the audit trail", count("audit_events", "entity_type = 'form.submission'") == 0)

print("== accepting the invitation")
TOKEN = one("SELECT token FROM namespace_invitations WHERE email = 'ann@x.test'")
s, j = call("GET", "/api/v2/public/invitations/" + TOKEN)
check("invitation page data: workspace, role, no account yet",
      s == 200 and j["data"]["workspace"]["name"] == "Forms A" and j["data"]["account_exists"] is False, (s, j))
s, j = call("POST", "/api/v2/public/invitations/%s/accept" % TOKEN, body={"first_name": "Ann", "password": "short"})
check("weak password refused (400)", s == 400 and "password" in j.get("errors", {}), (s, j))
pw = "Zq" + uuid.uuid4().hex[:14] + "9X"
s, j = call("POST", "/api/v2/public/invitations/%s/accept" % TOKEN, body={"first_name": "Ann", "last_name": "Lee",
                                                                           "password": pw})
check("accepting creates the account (201)", s == 201, (s, j))
check("ann is now an active member of A with the member role",
      one("""SELECT r.role_name FROM users u JOIN namespace_members m ON m.user_id = u.id AND m.namespace_id = %s
             JOIN namespace_user_roles ur ON ur.namespace_member_id = m.id JOIN namespace_roles r ON r.id = ur.namespace_role_id
             WHERE u.email = 'ann@x.test' AND m.status = 'active'""" % ID_A) == "member")
s, _ = call("POST", "/api/v2/public/invitations/%s/accept" % TOKEN, body={"first_name": "Ann", "password": pw})
check("the link can't be used twice (404)", s == 404, s)

print("== responses API")
s, j = call("GET", "/api/v2/forms/%s/submissions?limit=2" % FID, owner_a, NS_A)
page1 = j.get("data") or []
cursor = (j.get("meta") or {}).get("next_cursor")
s2, j2 = call("GET", "/api/v2/forms/%s/submissions?limit=2&cursor=%s" % (FID, cursor), owner_a, NS_A)
page2 = j2.get("data") or []
check("keyset pages: 2 + 2, no overlap", s == 200 and len(page1) == 2 and len(page2) == 2
      and not {x["uuid"] for x in page1} & {x["uuid"] for x in page2}, (s, j, j2))
check("spam is hidden by default", all(x["status"] != "spam" for x in page1 + page2))
ann_sub = one("SELECT uuid FROM form_submissions WHERE respondent_email = 'ann@x.test' ORDER BY id LIMIT 1")
s, j = call("GET", "/api/v2/forms/%s/submissions/%s" % (FID, ann_sub), owner_a, NS_A)
recs = {l["target"]: l for l in (j.get("data") or {}).get("links", [])}
check("a response shows its linked records", s == 200 and recs.get("customer", {}).get("record", {}).get("email")
      and recs.get("lead", {}).get("record"), (s, j))

s, j = submit(PUB, dict(ANS, email="csv@x.test", message="=HYPERLINK(\"http://evil.test\")"), tok, ip())
s, raw = call("GET", "/api/v2/forms/%s/export" % FID, owner_a, NS_A, raw=True)
text = raw.decode("utf-8-sig", "replace")
check("CSV export: header + rows", s == 200 and text.startswith("Submitted at (UTC),Status,Name,Email")
      and "csv@x.test" in text, (s, text[:200]))
check("CSV export defuses formulas", "'=HYPERLINK" in text and ",=HYPERLINK" not in text)

print("== versions")
s, j = call("GET", "/api/v2/forms/" + FID, owner_a, NS_A)
fs = j["data"]["schema"]["fields"]
for f in fs:
    if f["key"] == "company":
        f["label"] = "Company name"
s, j = call("PUT", "/api/v2/forms/" + FID, owner_a, NS_A, {"fields": fs})
check("draft edit shows unpublished changes", s == 200 and j["data"]["has_unpublished_changes"] is True, (s, j))
s, j = call("POST", "/api/v2/forms/%s/publish" % FID, owner_a, NS_A)
check("republish -> version 2", s == 200 and j["data"]["published_version"] == 2, (s, j))
s, j = call("GET", "/api/v2/forms/%s/submissions/%s" % (FID, ann_sub), owner_a, NS_A)
check("an old response keeps the label it was answered under",
      any(f["key"] == "company" and f["label"] == "Company" for f in j["data"]["fields"]), j)
s, j = call("GET", "/api/v2/forms/%s/submissions?limit=1" % FID, owner_a, NS_A)
check("table columns use the latest label",
      any(c["key"] == "company" and c["label"] == "Company name" for c in j["meta"]["columns"]), j.get("meta"))

print("== limits, closing, deleting")
s, j = call("POST", "/api/v2/forms", owner_a, NS_A, {"title": "Five seats",
                                                     "fields": [{"type": "short_text", "label": "Name"}],
                                                     "settings": {"max_submissions": 5}})
F5 = j["data"]["uuid"]
P5 = j["data"]["public_id"]
call("POST", "/api/v2/forms/%s/publish" % F5, owner_a, NS_A)
t5, _, _ = token_for(P5)
time.sleep(2.2)
with cf.ThreadPoolExecutor(15) as ex:
    codes = list(ex.map(lambda i: submit(P5, {"name": "n%d" % i}, t5, ip(), base=A if i % 2 else B)[0], range(15)))
check("max_submissions=5 under 15 concurrent submits: exactly 5 accepted, the rest 409",
      sorted(codes) == [201] * 5 + [409] * 10
      and count("form_submissions", "form_id = (SELECT id FROM forms WHERE uuid = '%s')" % F5) == 5, codes)
s, j = call("POST", "/api/v2/forms/%s/close" % FID, owner_a, NS_A)
s1, _ = submit(PUB, ANS, tok, ip())
check("closed form refuses responses (410)", s == 200 and s1 == 410, (s, s1))
call("POST", "/api/v2/forms/%s/reopen" % FID, owner_a, NS_A)
s1, _ = submit(PUB, dict(ANS, email="reopen@x.test"), tok, ip())
check("reopened form takes responses again", s1 == 201, s1)

print("== failed targets and retry")
sql("UPDATE namespaces SET max_users = 1 WHERE id = %s" % ID_A)
s, j = submit(PUB, dict(ANS, email="full@x.test"), tok, ip())
sub = sql("SELECT s.uuid, s.status, l.outcome, l.error_code FROM form_submissions s JOIN form_submission_links l "
          "ON l.submission_id = s.id AND l.target = 'user' WHERE s.respondent_email = 'full@x.test'")[0]
check("a full workspace fails the invite but keeps the response (needs_attention)",
      s == 201 and sub[1:] == ["needs_attention", "failed", "workspace_full"], sub)
check("... the customer and lead were still created",
      count("customers", "lower(email) = 'full@x.test'") == 1 and count("crm_leads", "lower(email) = 'full@x.test'") == 1)
sql("UPDATE namespaces SET max_users = 100 WHERE id = %s" % ID_A)
s, j = call("POST", "/api/v2/forms/%s/submissions/%s/retry" % (FID, sub[0]), owner_a, NS_A)
check("retry after freeing seats: invited, response complete",
      s == 200 and j["data"]["status"] == "complete"
      and {l["target"]: l["outcome"] for l in j["data"]["links"]}.get("user") == "invited", (s, j))
check("... still one customer and one lead", count("customers", "lower(email) = 'full@x.test'") == 1
      and count("crm_leads", "lower(email) = 'full@x.test'") == 1)

s, j = call("PUT", "/api/v2/forms/%s/submissions/%s" % (FID, SPAM_HP), owner_a, NS_A, {"status": "complete"})
check("marking spam as not spam runs its targets", s == 200 and j["data"]["status"] == "complete"
      and len(j["data"]["links"]) == 3, (s, j))

n_before = int(one("SELECT submission_count FROM forms WHERE uuid = '%s'" % FID))
s, _ = call("DELETE", "/api/v2/forms/%s/submissions/%s" % (FID, ann_sub), owner_a, NS_A)
check("deleting a response removes it and its links",
      s == 200 and count("form_submissions", "uuid = '%s'" % ann_sub) == 0
      and int(one("SELECT submission_count FROM forms WHERE uuid = '%s'" % FID)) == n_before - 1)

sql("UPDATE namespaces SET status = 'suspended' WHERE id = %s" % ID_A)
s1, _ = submit(PUB, dict(ANS, email="susp@x.test"), tok, ip())
check("a suspended workspace's form refuses responses (404)", s1 == 404, s1)
sql("UPDATE namespaces SET status = 'active' WHERE id = %s" % ID_A)
s, _ = call("DELETE", "/api/v2/forms/" + F5, owner_a, NS_A)
s1, _ = submit(P5, {"name": "x"}, t5, ip())
check("a deleted form's link is gone (404)", s == 200 and s1 == 404, (s, s1))

print("== seats: an admin's invitation holds one, a form request doesn't")
active = int(one("SELECT COUNT(*) FROM namespace_members WHERE namespace_id = %s AND status = 'active'" % ID_A))
check("form invitations are recorded as requests, not admin invitations",
      count("namespace_invitations", "namespace_id = %s AND source = 'form'" % ID_A) >= 10
      and count("namespace_invitations", "namespace_id = %s AND source = 'admin'" % ID_A) == 0)
sql("UPDATE namespaces SET max_users = %d WHERE id = %s" % (active + 1, ID_A))
s, j = submit(PUB, dict(ANS, email="seat1@x.test"), tok, ip())
check("with one seat free, a form request is created",
      one("""SELECT l.outcome FROM form_submission_links l JOIN form_submissions s ON s.id = l.submission_id
             WHERE s.respondent_email = 'seat1@x.test' AND l.target = 'user'""") == "invited")
s, j = call("POST", "/api/v2/namespace/invitations", owner_a, NS_A, {"email": "admin1@x.test"})
check("a dozen pending form requests don't stop the admin inviting someone", s in (200, 201), (s, j))
s, j = call("POST", "/api/v2/namespace/invitations", owner_a, NS_A, {"email": "admin2@x.test"})
check("the admin's pending invitation holds the last seat", s == 400, (s, j))
TOKEN_SEAT = one("SELECT token FROM namespace_invitations WHERE email = 'seat1@x.test'")
pw2 = "Qz" + uuid.uuid4().hex[:14] + "7K"
s, j = call("POST", "/api/v2/public/invitations/%s/accept" % TOKEN_SEAT,
            body={"first_name": "Seat", "last_name": "One", "password": pw2})
check("a form request can't be accepted while no seat is free (409)",
      s == 409 and j.get("code") == "workspace_full", (s, j))
sql("UPDATE namespaces SET max_users = 100 WHERE id = %s" % ID_A)
s, j = call("POST", "/api/v2/public/invitations/%s/accept" % TOKEN_SEAT,
            body={"first_name": "Seat", "last_name": "One", "password": pw2})
check("... and is accepted once a seat is free", s == 201, (s, j))


print("== phase 2: conditional logic and steps")
s, j = call("POST", "/api/v2/forms", owner_a, NS_A, {"title": "Logic test", "fields": [
    {"type": "boolean", "label": "Do you have a company?", "required": True},
    {"type": "short_text", "label": "Company name", "required": True,
     "logic": {"match": "all", "rules": [{"field": "do_you_have_a_company", "op": "eq", "value": True}]}},
    {"type": "page_break", "label": "About the company"},
    {"type": "radio", "label": "Size", "options": ["Small", "Large"],
     "logic": {"rules": [{"field": "company_name", "op": "filled"}]}},
]})
LF = (j.get("data") or {})
check("a form with logic and a page break saves", s == 201 and [f["type"] for f in LF["schema"]["fields"]]
      == ["boolean", "short_text", "page_break", "radio"] and LF["schema"]["fields"][1]["logic"]["rules"][0]["op"] == "eq",
      (s, j))
s, j = call("POST", "/api/v2/forms", owner_a, NS_A, {"title": "Bad logic", "fields": [
    {"type": "short_text", "label": "First", "logic": {"rules": [{"field": "second", "op": "filled"}]}},
    {"type": "short_text", "label": "Second"}]})
check("logic that refers to a question below is refused (422)", s == 422 and "above" in j.get("error", ""), (s, j))
call("POST", "/api/v2/forms/%s/publish" % LF["uuid"], owner_a, NS_A)
ltok, _, lj = token_for(LF["public_id"])
check("the public form carries the logic", any(f.get("logic") for f in (lj.get("data") or {}).get("fields", [])))
time.sleep(2.2)
s, j = submit(LF["public_id"], {"do_you_have_a_company": False, "company_name": "Sneaky Ltd", "size": "large"}, ltok, ip())
row = one("SELECT data::text FROM form_submissions WHERE form_id = (SELECT id FROM forms WHERE uuid = '%s') "
          "ORDER BY id DESC LIMIT 1" % LF["uuid"])
check("answers to hidden questions are dropped by the server", s == 201 and "Sneaky" not in row and "large" not in row,
      (s, row))
s, j = submit(LF["public_id"], {"do_you_have_a_company": True}, ltok, ip())
check("a shown required question must be answered (400)", s == 400 and "company_name" in j.get("errors", {}), (s, j))
s, j = submit(LF["public_id"], {"do_you_have_a_company": True, "company_name": "Acme", "size": "large"}, ltok, ip())
check("shown questions are kept", s == 201, (s, j))

print("== phase 2: file uploads")
s, j = call("POST", "/api/v2/forms", owner_a, NS_A, {"title": "Uploads", "fields": [
    {"type": "short_text", "label": "Note"},
    {"type": "file_upload", "label": "Photo", "accept": "images", "max_size_mb": 1, "max_files": 2}]})
UF = j["data"]
call("POST", "/api/v2/forms/%s/publish" % UF["uuid"], owner_a, NS_A)
utok, _, _ = token_for(UF["public_id"])
PNG = b"\x89PNG\r\n\x1a\n" + b"\0" * 2048
s, j = upload(UF["public_id"], "photo", "holiday snap.png", PNG, utok)
check("an image uploads (201)", s == 201 and j["data"]["name"] == "holiday snap.png" and j["data"]["type"] == "image/png",
      (s, j))
FILE_ID = (j.get("data") or {}).get("id")
s, j = upload(UF["public_id"], "photo", "x.svg", b"<svg onload=alert(1)>", utok)
check("SVG is refused (415)", s == 415, (s, j))
s, j = upload(UF["public_id"], "photo", "doc.pdf", b"%PDF-1.4", utok)
check("a PDF is refused where only images are allowed (415)", s == 415, (s, j))
s, j = upload(UF["public_id"], "photo", "big.png", PNG + b"\0" * (1024 * 1024), utok)
check("a file over the field's limit is refused (413)", s == 413, (s, j))
s, j = upload(UF["public_id"], "photo", "a.png", PNG, None)
check("an upload without the page's token is refused (403)", s == 403, (s, j))
s, j = upload(UF["public_id"], "note", "a.png", PNG, utok)
check("an upload to a question that doesn't take files is refused (400)", s == 400, (s, j))
time.sleep(2.2)
s, j = submit(UF["public_id"], {"note": "hi", "photo": [FILE_ID]}, utok, ip())
data = json.loads(one("SELECT data::text FROM form_submissions WHERE form_id = (SELECT id FROM forms WHERE uuid = '%s') "
                      "ORDER BY id DESC LIMIT 1" % UF["uuid"]))
check("the response stores the file's name and size, not a storage URL",
      s == 201 and data["photo"][0]["name"] == "holiday snap.png" and "http" not in json.dumps(data), (s, data))
s, j = submit(UF["public_id"], {"note": "again", "photo": [FILE_ID]}, utok, ip())
check("a file can't be attached to a second response (400)", s == 400 and "photo" in j.get("errors", {}), (s, j))
usid = one("SELECT uuid FROM form_submissions WHERE form_id = (SELECT id FROM forms WHERE uuid = '%s') "
           "ORDER BY id LIMIT 1" % UF["uuid"])
s, j = call("GET", "/api/v2/forms/%s/submissions/%s/files/%s" % (UF["uuid"], usid, FILE_ID), owner_a, NS_A)
check("staff get a short-lived signed link", s == 200 and "X-Amz-Signature" in j["data"]["url"], (s, j))
s, _ = call("GET", "/api/v2/forms/%s/submissions/%s/files/%s" % (UF["uuid"], usid, FILE_ID), owner_b, NS_B)
check("another workspace can't get the link (404)", s == 404, s)
s, j = upload(UF["public_id"], "photo", "orphan.png", PNG, utok)
sql("UPDATE form_uploads SET created_at = NOW() - interval '2 days' WHERE uuid = '%s'" % j["data"]["id"])
lapis_exec(API_CONTAINER, 'print("purged " .. require("lib.forms.uploads").purge(100))')
check("a file never attached is purged after a day", count("form_uploads", "uuid = '%s'" % j["data"]["id"]) == 0)
check("an attached file is kept", count("form_uploads", "uuid = '%s' AND submission_id IS NOT NULL" % FILE_ID) == 1)

print("== phase 2: branding, analytics, captcha")
s, j = call("PUT", "/api/v2/forms/" + UF["uuid"], owner_a, NS_A, {"settings": {"theme": {
    "primary_color": "#123ABC", "logo_url": "https://cdn.test/logo.png", "submit_label": "Send it"}}})
check("branding saves", s == 200 and j["data"]["settings"]["theme"]["primary_color"] == "#123abc", (s, j))
_, _, pj = token_for(UF["public_id"])
check("the public form gets the branding at once", (pj.get("data") or {}).get("theme", {}).get("submit_label") == "Send it", pj)
s, j = call("PUT", "/api/v2/forms/" + UF["uuid"], owner_a, NS_A, {"settings": {"theme": {"primary_color": "red"}}})
check("a bad colour is refused (422)", s == 422, (s, j))
s, j = call("PUT", "/api/v2/forms/" + UF["uuid"], owner_a, NS_A, {"settings": {"theme": {"logo_url": "javascript:x"}}})
check("a non-https logo is refused (422)", s == 422, (s, j))
s, j = call("PUT", "/api/v2/forms/" + UF["uuid"], owner_a, NS_A, {"settings": {"theme": {"hide_branding": True}}})
check("no plan may hide \"Powered by OpsAPI\" (422, says why)", s == 422 and "plan" in json.dumps(j), (s, j))
s, j = call("GET", "/api/v2/forms/" + UF["uuid"], owner_a, NS_A)
check("the builder is told the toggle isn't available", s == 200 and j["data"].get("can_hide_branding") is False, j)
s, j = call("POST", "/api/v2/forms", owner_a, NS_A, {"title": "Old plan branding", "fields": [
    {"type": "short_text", "label": "Note"}]})
OLD = j["data"]
sql("""UPDATE forms SET settings = jsonb_build_object('theme', jsonb_build_object('hide_branding', true,
       'submit_label', 'Go')) WHERE uuid = '%s'""" % OLD["uuid"])
call("POST", "/api/v2/forms/%s/publish" % OLD["uuid"], owner_a, NS_A)
_, _, pj = token_for(OLD["public_id"])
theme = (pj.get("data") or {}).get("theme") or {}
check("a hide-branding saved under an earlier plan isn't honoured", theme.get("submit_label") == "Go"
      and "hide_branding" not in theme, pj)

for _ in range(3):
    token_for(LF["public_id"])
for t, st in (("start", None), ("start", None), ("step", 2)):
    call("POST", "/api/v2/public/forms/%s/events" % LF["public_id"], body={"type": t, "step": st})
lapis_exec(API_CONTAINER, 'require("lib.forms.stats").flush() print("flushed")')
s, j = call("GET", "/api/v2/forms/%s/analytics?days=7" % LF["uuid"], owner_a, NS_A)
an = j.get("data") or {}
check("analytics: views, starts, responses, conversion and the step funnel",
      s == 200 and an["totals"]["views"] >= 4 and an["totals"]["starts"] == 2 and an["totals"]["responses"] == 2
      and an["totals"]["conversion"] is not None and len(an["series"]) == 7
      and any(f["step"] == 2 and f["reached"] == 1 for f in an["funnel"]), (s, an.get("totals"), an.get("funnel")))
s, _ = call("GET", "/api/v2/forms/%s/analytics" % LF["uuid"], owner_b, NS_B)
check("another workspace can't read the analytics (404)", s == 404, s)

s, _ = call("PUT", "/api/v2/forms/workspace-settings", member_a, NS_A, {"turnstile": {"site_key": "k", "secret": "s"}})
check("only someone with forms.manage sets the CAPTCHA keys (403)", s == 403, s)
s, j = call("PUT", "/api/v2/forms/workspace-settings", owner_a, NS_A,
            {"turnstile": {"site_key": "site-key-1", "secret": "test-secret"}})
check("the owner saves the keys; the secret is never returned",
      s == 200 and j["data"]["turnstile"] == {"site_key": "site-key-1", "has_secret": True}
      and "test-secret" not in json.dumps(j), (s, j))
check("the secret is stored encrypted", "test-secret" not in (one("SELECT turnstile_secret_encrypted FROM "
      "form_workspace_settings WHERE namespace_id = %s" % ID_A) or "test-secret"))
s, j = call("PUT", "/api/v2/forms/" + LF["uuid"], owner_a, NS_A, {"settings": {"captcha": True}})
check("a form turns the check on", s == 200 and j["data"]["settings"]["captcha"] is True, (s, j))
ctok, _, cj = token_for(LF["public_id"])
check("the public form gets the site key only", (cj.get("data") or {}).get("captcha") ==
      {"provider": "turnstile", "site_key": "site-key-1"}, cj)
time.sleep(2.2)
ANS2 = {"do_you_have_a_company": False}
s1, j1 = submit(LF["public_id"], ANS2, ctok, ip())
s2, _ = submit(LF["public_id"], ANS2, ctok, ip(), extra={"captcha_token": "forged"})
s3, _ = submit(LF["public_id"], ANS2, ctok, ip(), extra={"captcha_token": "ok-token"})
check("no / a forged CAPTCHA token is refused; a good one goes through",
      (s1, j1.get("code"), s2, s3) == (400, "captcha", 400, 201), (s1, j1, s2, s3))
call("PUT", "/api/v2/forms/" + LF["uuid"], owner_a, NS_A, {"settings": {"captcha": False}})

print("== phase 2: records' form responses, in-app and chat alerts")
cust = one("SELECT uuid FROM customers WHERE lower(email) = 'race@x.test'")
s, j = call("GET", "/api/v2/forms/responses?entity_type=customer&entity_uuid=" + cust, owner_a, NS_A)
check("a customer's page can list the responses linked to them", s == 200 and len(j["data"]) == 20
      and j["data"][0]["form_title"] == "Quote request" and j["data"][0]["answers"], (s, len(j.get("data") or [])))
s, j = call("GET", "/api/v2/forms/responses?entity_type=customer&entity_uuid=" + cust, owner_b, NS_B)
check("... and another workspace sees none of them", s == 200 and j["data"] == [], (s, j))
owner_id = one("SELECT id FROM users WHERE uuid = '%s'" % owner_a["uuid"])
check("the form's creator got in-app notifications", count("notifications", "user_id = %s AND type = 'form_response'"
      % owner_id) > 0)
CH = str(uuid.uuid4())
sql("INSERT INTO chat_channels (uuid, name, type, created_by, namespace_id, created_at, updated_at) "
    "VALUES ('%s', 'leads', 'public', '%s', %s, now(), now())" % (CH, owner_a["uuid"], ID_A))
CHB = str(uuid.uuid4())
sql("INSERT INTO chat_channels (uuid, name, type, created_by, namespace_id, created_at, updated_at) "
    "VALUES ('%s', 'b', 'public', '%s', (SELECT id FROM namespaces WHERE slug = 'forms-b'), now(), now())"
    % (CHB, owner_b["uuid"]))
s, _ = call("PUT", "/api/v2/forms/" + FID, owner_a, NS_A, {"settings": {"chat_channel_uuid": CHB}})
check("another workspace's chat channel is refused (422)", s == 422, s)
s, _ = call("PUT", "/api/v2/forms/" + FID, owner_a, NS_A, {"settings": {"chat_channel_uuid": CH}})
submit(PUB, dict(ANS, email="chat@x.test"), tok, ip())
for _ in range(30):
    if count("chat_messages", "channel_uuid = '%s' AND content LIKE '%%chat@x.test%%'" % CH):
        break
    time.sleep(1)
check("a new response is posted to the chosen chat channel",
      s == 200 and count("chat_messages", "channel_uuid = '%s' AND content LIKE 'New response to%%'" % CH) == 1, s)

print("== phase 2: AI")
s, j = call("POST", "/api/v2/forms/generate", owner_a, NS_A, {"prompt": "Event sign-up; make each person a lead"})
d = j.get("data") or {}
check("generate: a draft with the model's valid questions, contact fields locked, the lead target",
      s == 200 and d["title"] == "Event sign-up" and [f["label"] for f in d["schema"]["fields"]]
      == ["Name", "Email", "Ticket", "Dietary needs"] and d["dropped"] == 1 and d["targets"] == [{"type": "lead"}],
      (s, j))
check("generate saves nothing", count("forms", "title = 'Event sign-up'") == 0)
s, j = call("POST", "/api/v2/forms/%s/summary" % FID, owner_a, NS_A)
d = j.get("data") or {}
budget = next((f for f in d.get("fields", []) if f["key"] == "budget"), {})
check("summary: exact counts plus the AI's text", s == 200 and d["responses"] > 10 and budget.get("counts")
      and "VIP" in (d.get("summary") or ""), (s, j))
prompts = sorted(glob.glob(os.path.join(STUB_DIR, "llm-*.json")))
last = open(prompts[-1]).read() if prompts else ""
check("no respondent's email was sent to the AI", prompts and "@x.test" not in last, last[:300])
check("AI calls are metered as feature 'forms'", count("ai_usage", "feature = 'forms'") >= 2)

print("== phase 2: plan limits")
lapis_exec(API_CONTAINER, 'require("lib.forms.limits").PLANS.free = { forms = 1 } print("set")')
s, j = call("POST", "/api/v2/forms", owner_a, NS_A, {"title": "Over the limit"})
lapis_exec(API_CONTAINER, 'require("lib.forms.limits").PLANS.free = {} print("reset")')
check("a plan's form limit is enforced (403, says why)", s == 403 and "plan includes 1 forms" in j.get("error", ""), (s, j))

print("== phase 2: custom domains")
def zone(records):
    # Written from inside the stubs container: a host-side write over a macOS bind mount can be read stale.
    subprocess.run(["docker", "exec", "-i", STUBS, "sh", "-c", "cat > /w/dns.json"], input=json.dumps(records),
                   text=True, check=True)


EDGE = {"edge.forms.test": {"A": ["10.9.9.9"]}}
zone(EDGE)
s, j = call("GET", "/api/v2/forms/domain", owner_a, NS_A)
check("domain settings: available, with the platform's target", s == 200 and j["data"]["available"]
      and j["data"]["target"] == "edge.forms.test" and not j["data"].get("domain"), j)
s, j = call("PUT", "/api/v2/forms/domain", member_a, NS_A, {"domain": "forms.acme.test"})
check("only forms.manage can connect a domain (403)", s == 403, (s, j))
bad = [call("PUT", "/api/v2/forms/domain", owner_a, NS_A, {"domain": d})[0]
       for d in ["not a domain", "203.0.113.9", "edge.forms.test", "-bad.acme.test", "a..b.test", "bücher.test"]]
check("bad, IP, the platform's own and non-ASCII domains are refused (400)", bad == [400] * 6, bad)
s, j = call("PUT", "/api/v2/forms/domain", owner_a, NS_A, {"domain": "https://Forms.Acme.TEST/path"})
d = j.get("data") or {}
recs = {r["type"]: r for r in d.get("records", [])}
TXT_A = recs.get("TXT", {}).get("value", "")
check("a domain is cleaned up and waits for DNS, with both records to add", s == 200
      and d.get("domain") == "forms.acme.test" and d.get("status") == "pending"
      and recs.get("CNAME", {}).get("value") == "edge.forms.test"
      and recs.get("TXT", {}).get("name") == "_opsapi-challenge.forms.acme.test" and TXT_A.startswith("opsapi-verify="), j)
check("it says what's missing", "doesn't point at edge.forms.test" in (d.get("last_error") or "")
      and "TXT record" in (d.get("last_error") or ""), d)
zone(dict(EDGE, **{"forms.acme.test": {"CNAME": "edge.forms.test"}}))
s, j = call("POST", "/api/v2/forms/domain/check", owner_a, NS_A)
check("pointing at the edge isn't enough: the TXT proof is required", s == 200 and j["data"]["status"] == "pending"
      and "TXT" in (j["data"].get("last_error") or "") and "point" not in (j["data"].get("last_error") or ""), j)
zone(dict(EDGE, **{"forms.acme.test": {"CNAME": "edge.forms.test"},
                   "_opsapi-challenge.forms.acme.test": {"TXT": [TXT_A]}}))
s, j = call("POST", "/api/v2/forms/domain/check", owner_a, NS_A)
check("with both records it's connected", s == 200 and j["data"]["status"] == "active"
      and not j["data"].get("last_error") and j["data"].get("verified_at"), j)
s, j = call("GET", "/api/v2/forms/" + UF["uuid"], owner_a, NS_A)
check("form links use the domain", j["data"]["share_url"] == "https://forms.acme.test/f/" + UF["public_id"]
      and j["data"]["share_domain"] == "forms.acme.test", j["data"].get("share_url"))
s1, _ = call("GET", "/api/v2/public/form-domains/check?domain=forms.acme.test")
s2, _ = call("GET", "/api/v2/public/form-domains/check?domain=other.acme.test")
check("the edge's check: 200 for a connected domain, 404 for others", (s1, s2) == (200, 404), (s1, s2))

s, j = call("POST", "/api/v2/forms", owner_b, NS_B, {"title": "B's form", "fields": [
    {"type": "short_text", "label": "Note"}]})
FB = j["data"]
call("POST", "/api/v2/forms/%s/publish" % FB["uuid"], owner_b, NS_B)
ACME = {"Origin": "https://forms.acme.test", "X-Forwarded-For": "198.51.100.251"}
s_foreign, _ = call("GET", "/api/v2/public/forms/" + FB["public_id"], headers=ACME)
s_own, own = call("GET", "/api/v2/public/forms/" + UF["public_id"], headers=ACME)
s_plain, _ = call("GET", "/api/v2/public/forms/" + FB["public_id"])
check("a custom domain serves only its own workspace's forms", (s_foreign, s_own, s_plain) == (404, 200, 200),
      (s_foreign, s_own, s_plain))
btok, _, _ = token_for(FB["public_id"])
time.sleep(2.1)
s, _ = call("POST", "/api/v2/public/forms/%s/submissions" % FB["public_id"], body={"answers": {"note": "x"},
            "render_token": btok}, headers=dict(ACME, **{"Idempotency-Key": str(uuid.uuid4())}))
check("... and takes responses only for them (404)", s == 404, s)

# Whoever proves control of the domain now wins.
s, j = call("PUT", "/api/v2/forms/domain", owner_b, NS_B, {"domain": "forms.acme.test"})
TXT_B = {r["type"]: r for r in j["data"]["records"]}["TXT"]["value"]
check("another workspace can't take a domain without its own proof", j["data"]["status"] == "pending", j)
zone(dict(EDGE, **{"forms.acme.test": {"CNAME": "edge.forms.test"},
                   "_opsapi-challenge.forms.acme.test": {"TXT": [TXT_B]}}))
s, j = call("POST", "/api/v2/forms/domain/check", owner_b, NS_B)
_, ja = call("GET", "/api/v2/forms/domain", owner_a, NS_A)
check("with it, the domain moves, and the first workspace is told why", j["data"]["status"] == "active"
      and ja["data"]["status"] == "pending" and "Another workspace" in (ja["data"].get("last_error") or ""), (j, ja))
check("a domain is active in one workspace at most",
      count("form_domains", "domain = 'forms.acme.test' AND status = 'active'") == 1)
s, j = call("DELETE", "/api/v2/forms/domain", owner_b, NS_B)
check("removing it", s == 200 and not j["data"].get("domain")
      and count("form_domains", "namespace_id = (SELECT id FROM namespaces WHERE uuid = '%s')" % NS_B) == 0, j)

# The hourly job connects a domain once its records appear.
call("PUT", "/api/v2/forms/domain", owner_a, NS_A, {"domain": "join.acme.test"})
_, j = call("GET", "/api/v2/forms/domain", owner_a, NS_A)
TXT_J = {r["type"]: r for r in j["data"]["records"]}["TXT"]["value"]
zone(dict(EDGE, **{"join.acme.test": {"A": ["10.9.9.9"]}, "_opsapi-challenge.join.acme.test": {"TXT": [TXT_J]}}))
sql("UPDATE form_domains SET checked_at = NOW() - INTERVAL '2 hours' WHERE domain = 'join.acme.test'")
out = lapis_exec(API_CONTAINER, 'print("CHECKED " .. require("lib.forms.domains").maintain())')
_, j = call("GET", "/api/v2/forms/domain", owner_a, NS_A)
check("the hourly check connects it (an A record to the edge's address works too)",
      j["data"]["status"] == "active", (out[-300:], j))
call("DELETE", "/api/v2/forms/domain", owner_a, NS_A)

print("== AI agent tools")
lua = r'''
local Tools = require("lib.agent.tools")
local J = require("lib.forms.json")
local db = require("lapis.db")
local ctx = { namespace_id = %s, user_uuid = "%s", origin = "http://localhost:8039",
  has_permission = function() return true end, can_assign_roles = function() return true end }
local res, err = Tools.execute(ctx, "create_form", { title = "Agent job form", fields = {
  { label = "Years of experience", type = "number" }, { label = "Role", type = "radio", options = "Dev, Ops" } },
  create_records = { "lead" } })
print("CREATE " .. J.encode({ res = res, err = err }))
local p = Tools.execute(ctx, "publish_form", { form = "Agent job form" })
print("CONFIRM " .. J.encode(p))
ctx.confirmed = true
local p2, perr = Tools.execute(ctx, "publish_form", { form = "Agent job form" })
print("PUBLISH " .. J.encode({ res = p2, err = perr }))
local bad, berr = Tools.execute(ctx, "create_form", { title = "Bad", fields = { { label = "X", type = "colour" } } })
print("BAD " .. J.encode({ err = berr }))
local up, uerr = Tools.execute(ctx, "update_form", { form = "Agent job form", add_fields = { { label = "Notice period",
  type = "short_text" } }, remove_fields = { "Role" }, require_fields = { "Years of experience" } })
print("UPDATE " .. J.encode({ res = up, err = uerr }))
local sm, serr = Tools.execute(ctx, "summarize_form_responses", { form = "Quote request" })
print("SUMMARY " .. J.encode({ res = sm, err = serr }))
''' % (ID_A, owner_a["uuid"])
out = subprocess.run(["docker", "exec", "-w", "/app", API_CONTAINER, "lapis", "exec", lua], capture_output=True,
                     text=True).stdout
got = {m.group(1): json.loads(m.group(2)) for m in re.finditer(r"^(CREATE|CONFIRM|PUBLISH|BAD|UPDATE|SUMMARY) (\{.*\})$",
                                                                    out, re.M)}
created = (got.get("CREATE") or {}).get("res") or {}
check("agent create_form: a draft with locked name/email first, then the questions",
      created.get("status") == "draft" and [f["type"] for f in created.get("fields", [])]
      == ["name", "email", "number", "radio"] and created["fields"][0].get("locked"), out[-600:])
check("agent publish_form asks for confirmation first", (got.get("CONFIRM") or {}).get("needs_confirmation") is True,
      got.get("CONFIRM"))
check("agent publish_form after confirming publishes", ((got.get("PUBLISH") or {}).get("res") or {}).get("status")
      == "published", got.get("PUBLISH"))
check("agent gets a usable error for an unknown field type", "unknown type 'colour'"
      in ((got.get("BAD") or {}).get("err") or ""), got.get("BAD"))
upd = (got.get("UPDATE") or {}).get("res") or {}
check("agent update_form: adds, removes, requires, in the draft",
      [f["label"] for f in upd.get("fields", [])] == ["Name", "Email", "Years of experience", "Notice period"]
      and upd["fields"][2].get("required") and upd.get("unpublished_changes"), got.get("UPDATE"))
smy = (got.get("SUMMARY") or {}).get("res") or {}
check("agent summarize_form_responses: counts and the summary", smy.get("responses", 0) > 10
      and "VIP" in (smy.get("summary") or "") and smy.get("highlights"), got.get("SUMMARY"))

print("== feature gate")
s, _ = call("GET", "/api/v2/forms", owner_a, NS_A, base=C)
s2, _ = call("GET", "/api/v2/public/forms/" + PUB, base=C)
check("a deployment without the forms feature has no forms routes (404)", s == 404 and s2 == 404, (s, s2))

print("")
print("%s" % ("ALL CHECKS PASSED" if failures == 0 else "%d CHECK(S) FAILED" % failures))
sys.exit(1 if failures else 0)

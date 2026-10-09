"""Forms e2e checks (run by run.sh; stdlib only).

Talks to two API pods sharing one Postgres and Redis (A, B), plus a pod
without the forms feature (C); reads Postgres through `docker exec psql` and
the emails the SMTP sink wrote. Every check prints ok/FAIL; exit 1 on any FAIL.
"""
import base64, concurrent.futures as cf, email, email.policy, glob, hashlib, hmac, json, os, re, subprocess, sys, time, uuid
import urllib.error, urllib.request

A, B, C = os.environ["API_A"], os.environ["API_B"], os.environ["API_C"]
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


def submit(public_id, answers, token, ip, key=None, hp=None, base=A):
    body = {"answers": answers, "render_token": token, "context": {"page_url": "https://site.test/contact",
                                                                    "utm": {"campaign": "autumn"}}}
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
''' % (ID_A, owner_a["uuid"])
out = subprocess.run(["docker", "exec", "-w", "/app", API_CONTAINER, "lapis", "exec", lua], capture_output=True,
                     text=True).stdout
got = {m.group(1): json.loads(m.group(2)) for m in re.finditer(r"^(CREATE|CONFIRM|PUBLISH|BAD) (\{.*\})$", out, re.M)}
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

print("== feature gate")
s, _ = call("GET", "/api/v2/forms", owner_a, NS_A, base=C)
s2, _ = call("GET", "/api/v2/public/forms/" + PUB, base=C)
check("a deployment without the forms feature has no forms routes (404)", s == 404 and s2 == 404, (s, s2))

print("")
print("%s" % ("ALL CHECKS PASSED" if failures == 0 else "%d CHECK(S) FAILED" % failures))
sys.exit(1 if failures else 0)

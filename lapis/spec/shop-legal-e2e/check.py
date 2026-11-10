"""Shop legal record + survey e2e checks (run by run.sh; stdlib only). Every check prints ok/FAIL; exit 1 on any FAIL."""
import base64, hashlib, hmac, json, os, subprocess, sys, time, urllib.error, urllib.request, uuid

API = os.environ["API"]
PG = os.environ["PG_CONTAINER"]
API_CONTAINER = os.environ["API_CONTAINER"]
SECRET = open(os.environ["JWT_SECRET_FILE"]).read().strip()
BFF = open(os.environ["BFF_KEY_FILE"]).read().strip()
failures = 0


def check(name, ok, detail=None):
    global failures
    if ok:
        print("  ok   " + name)
    else:
        failures += 1
        print("  FAIL " + name + ("  (" + str(detail)[:600] + ")" if detail is not None else ""))
    return ok


def sql(q):
    out = subprocess.run(["docker", "exec", "-i", PG, "psql", "-U", "postgres", "-d", "sl", "-At", "-F", "|",
                          "-v", "ON_ERROR_STOP=1", "-c", q], capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(out.stderr + "\n" + q)
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


def call(method, path, u=None, ns=None, body=None, bff=False, headers=None, raw=False):
    h = {"Content-Type": "application/json"}
    if u:
        h["Authorization"] = "Bearer " + jwt(u)
    if ns:
        h["X-Namespace-Id"] = ns
    if bff:
        h["X-Shop-Key"] = BFF
    h.update(headers or {})
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            payload, status, hdrs = r.read(), r.status, dict(r.headers)
    except urllib.error.HTTPError as e:
        payload, status, hdrs = e.read(), e.code, dict(e.headers)
    if raw:
        return status, payload.decode("utf-8", "replace"), hdrs
    try:
        j = json.loads(payload or b"{}")
    except ValueError:
        j = {"_raw": payload[:300]}
    return status, j


def user(name):
    u = {"uuid": str(uuid.uuid4()), "email": name + "@sl.test"}
    sql("INSERT INTO users (uuid, first_name, last_name, email, username, password, active, created_at, updated_at) "
        "VALUES ('%s', '%s', 'Test', '%s', '%s', 'x', true, now(), now())" % (u["uuid"], name, u["email"], name))
    return u


def member(ns_id, u, role_name, perms):
    sql("""INSERT INTO namespace_roles (uuid, namespace_id, role_name, display_name, permissions, created_at, updated_at)
           VALUES (gen_random_uuid()::text, %s, '%s', '%s', '%s', now(), now())""" % (ns_id, role_name, role_name, json.dumps(perms)))
    sql("""INSERT INTO namespace_members (uuid, namespace_id, user_id, status, is_owner, joined_at, created_at, updated_at)
           SELECT gen_random_uuid()::text, %s, id, 'active', false, now(), now(), now() FROM users WHERE uuid = '%s'"""
        % (ns_id, u["uuid"]))
    sql("""INSERT INTO namespace_user_roles (uuid, namespace_member_id, namespace_role_id, created_at, updated_at)
           SELECT gen_random_uuid()::text, m.id, r.id, now(), now() FROM namespace_members m, namespace_roles r
           WHERE m.namespace_id = %s AND r.namespace_id = %s AND r.role_name = '%s'
             AND m.user_id = (SELECT id FROM users WHERE uuid = '%s')""" % (ns_id, ns_id, role_name, u["uuid"]))


def docs(*keys, version="2026-11"):
    return [{"key": k, "version": version, "statement": "I agree to the " + k + "."} for k in keys]


# ---------------------------------------------------------------------------
print("== migrations")
check("zzs37 (legal) and zzs38 (survey) recorded",
      int(one("SELECT COUNT(*) FROM lapis_migrations WHERE name IN ('zzs37_shop_legal_acceptances', 'zzs38_shop_survey_events')")) == 2)

print("== seed")
owner, owner_b, clerk = user("owner"), user("ownerb"), user("clerk")
for u, name, slug in ((owner, "Shop L", "shop-l"), (owner_b, "Shop M", "shop-m")):
    s, j = call("POST", "/api/v2/user/namespaces", u, None, {"name": name, "slug": slug})
    check("workspace %s created" % slug, s in (200, 201), j)
NS, NS_ID = sql("SELECT uuid, id FROM namespaces WHERE slug = 'shop-l'")[0]
NS_B, NS_B_ID = sql("SELECT uuid, id FROM namespaces WHERE slug = 'shop-m'")[0]
member(NS_ID, clerk, "shop_clerk", {"shop": ["read", "update"]})
PUB = "/api/v2/public/shop/shop-l"
ADMIN = "/api/v2/shop/admin/legal/acceptances"

print("== recording (shop server only)")
s, j = call("POST", PUB + "/legal/acceptances", body={"email": "member@x.test", "checkpoint": "register", "documents": docs("terms-of-sale", "privacy-notice")})
check("anyone else: 403", s == 403, (s, j))
s, j = call("POST", PUB + "/legal/acceptances", bff=True,
            body={"email": "Member@X.test", "checkpoint": "register", "ip": "203.0.113.9", "documents": docs("terms-of-sale", "privacy-notice")})
check("signed-in member's register acceptance recorded", s == 201 and j.get("data", {}).get("recorded") == 2, (s, j))
# Someone types another person's email into a quote form and ticks the terms.
s, j = call("POST", PUB + "/legal/acceptances", bff=True,
            body={"email": "victim@x.test", "checkpoint": "quote", "subject_ref": "q-1", "documents": docs("terms-of-sale")})
check("quote acceptance (typed email) recorded as evidence", s == 201, (s, j))
s, j = call("POST", "/api/v2/public/shop/shop-m/legal/acceptances", bff=True,
            body={"email": "victim@x.test", "checkpoint": "register", "documents": docs("terms-of-sale")})
check("other workspace's own record", s == 201, (s, j))

print("== only a signed-in acceptance counts")
s, j = call("GET", PUB + "/legal/acceptances?email=member%40x.test", bff=True)
d = (j.get("data") or {}).get("documents") or {}
check("member: terms + privacy accepted", s == 200 and d.get("terms-of-sale", {}).get("checkpoint") == "register"
      and "privacy-notice" in d, (s, j))
s, j = call("GET", PUB + "/legal/acceptances?email=victim%40x.test", bff=True)
check("victim: a typed-in quote acceptance does not count", s == 200 and (j.get("data") or {}).get("documents") in ({}, []), (s, j))

print("== contact form can't accept for someone else")
s, j = call("POST", "/api/v2/public/leads/shop-l", body={
    "first_name": "Mallory", "email": "victim@x.test", "message": "hello",
    "consent": {"documents": docs("terms-of-sale", "trade-terms")}})
check("contact form accepted", s in (200, 201), (s, j))
check("its ticks are kept as evidence (checkpoint contact)",
      one("SELECT COUNT(*) FROM shop_legal_acceptances WHERE namespace_id = %s AND email = 'victim@x.test' AND checkpoint = 'contact'" % NS_ID) == "2")
s, j = call("GET", PUB + "/legal/acceptances?email=victim%40x.test", bff=True)
check("victim still has accepted nothing", s == 200 and (j.get("data") or {}).get("documents") in ({}, []), (s, j))
lead_consent = one("SELECT metadata->'consent'->'documents'->0->>'key' FROM crm_leads WHERE namespace_id = %s AND email = 'victim@x.test'" % NS_ID)
check("the ticks are on the lead too", lead_consent == "terms-of-sale", lead_consent)
before = one("SELECT COUNT(*) FROM shop_legal_acceptances")
s, j = call("POST", "/api/v2/public/leads/shop-l", body={
    "first_name": "Bad", "email": "bad@x.test", "consent": {"documents": [{"key": "Not A Key!", "version": "1", "statement": "x"}]}})
check("contact form with unusable ticks still saves the lead", s in (200, 201), (s, j))
check("…records nothing in the ledger", one("SELECT COUNT(*) FROM shop_legal_acceptances") == before)
time.sleep(0.5)
log = subprocess.run(["docker", "exec", API_CONTAINER, "sh", "-c", "grep -c 'legal acceptance not recorded' /var/log/nginx/error.log || true"],
                     capture_output=True, text=True).stdout.strip()
check("…and logs why instead of failing silently", log not in ("", "0"), log)

print("== back office list")
s, j = call("GET", ADMIN + "?limit=50", owner, NS)
rows = j.get("data") or []
by = {(r["email"], r["checkpoint"], r["document_key"]): r for r in rows}
check("owner sees this workspace's 5 rows only", s == 200 and len(rows) == 5 and j.get("meta", {}).get("total") == 5, (s, len(rows)))
check("register rows are email_confirmed", by.get(("member@x.test", "register", "terms-of-sale"), {}).get("email_confirmed") is True)
check("quote and contact rows are not", by.get(("victim@x.test", "quote", "terms-of-sale"), {}).get("email_confirmed") is False
      and by.get(("victim@x.test", "contact", "trade-terms"), {}).get("email_confirmed") is False)
s, j = call("GET", ADMIN + "?checkpoint=contact", owner, NS)
check("filter by checkpoint", s == 200 and len(j.get("data") or []) == 2, (s, j))
s, j = call("GET", ADMIN, clerk, NS)
check("shop clerk (read) can view", s == 200, s)
s, _ = call("GET", ADMIN)
check("nobody: 401", s == 401, s)

print("== erasure")
s, j = call("POST", ADMIN + "/erase", clerk, NS, {"email": "victim@x.test"})
check("clerk without shop.delete: 403", s == 403, (s, j))
s, j = call("POST", ADMIN + "/erase", owner_b, NS, {"email": "victim@x.test"})
check("another workspace's owner: 403", s == 403, (s, j))
s, _ = call("POST", ADMIN + "/erase", body={"email": "victim@x.test"})
check("nobody: 401", s == 401, s)
s, j = call("POST", ADMIN + "/erase", owner, NS, {"email": "not-an-email"})
check("bad email: 400", s == 400, (s, j))
s, j = call("POST", ADMIN + "/erase", owner, NS, {"email": " Victim@X.test "})
check("owner erases the 3 rows for that email", s == 200 and (j.get("data") or {}).get("erased") == 3, (s, j))
check("victim's rows gone here", one("SELECT COUNT(*) FROM shop_legal_acceptances WHERE namespace_id = %s AND email = 'victim@x.test'" % NS_ID) == "0")
check("other people's rows kept", one("SELECT COUNT(*) FROM shop_legal_acceptances WHERE namespace_id = %s" % NS_ID) == "2")
check("other workspace untouched", one("SELECT COUNT(*) FROM shop_legal_acceptances WHERE namespace_id = %s" % NS_B_ID) == "1")
audit = sql("SELECT action, new_values, user_id IS NOT NULL FROM namespace_audit_logs WHERE namespace_id = %s AND entity_type = 'shop_legal_acceptances'" % NS_ID)
check("erasure audited (who, how many)", len(audit) == 1 and audit[0][0] == "shop_legal_acceptances.erased"
      and json.loads(audit[0][1]) == {"erased": 3} and audit[0][2] == "t", audit)
check("…without the email", "victim" not in json.dumps(audit), audit)
s, j = call("POST", ADMIN + "/erase", owner, NS, {"email": "victim@x.test"})
check("erasing again: 0", s == 200 and (j.get("data") or {}).get("erased") == 0, (s, j))
try:
    sql("UPDATE shop_legal_acceptances SET statement = 'changed'")
    check("rows still can't be changed", False, "UPDATE succeeded")
except RuntimeError as e:
    check("rows still can't be changed", "append-only" in str(e), str(e)[:200])

print("== survey funnel (shop server, per-visitor rate limit)")
ev = lambda v, e, **k: dict({"visitor_id": v, "event": e}, **k)
batch = [ev("visitor-aaaa", "view"), ev("visitor-aaaa", "start"),
         ev("visitor-aaaa", "answer", question="job", answer="tune", step=1),
         ev("visitor-aaaa", "answer", question="job", answer="team", step=1),
         ev("visitor-aaaa", "answer", question="who", answer="pilot", step=2),
         ev("visitor-aaaa", "result", product="p96"), ev("visitor-aaaa", "lead"), ev("visitor-aaaa", "apply", plan="y"),
         ev("visitor-bbbb", "view"), ev("visitor-bbbb", "start"),
         ev("visitor-bbbb", "answer", question="job", answer="train", step=1),
         ev("visitor-cccc", "view")]
s, j = call("POST", PUB + "/survey-events", bff=True, headers={"X-Visitor-IP": "198.51.100.4"}, body={"events": batch})
check("batch of 12 accepted (202)", s == 202 and (j.get("data") or {}).get("accepted") == 12, (s, j))
s, j = call("POST", PUB + "/survey-events", body=ev("visitor-dddd", "view", answer="someone@x.test"))
check("an email address as an answer is refused", s == 400 and j.get("code") == "INVALID_ANSWER", (s, j))
check("no IP or email stored", one("SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'shop_survey_events' AND column_name ~ 'ip|email'") == "0")
s, j = call("GET", "/api/v2/shop/admin/analytics/survey?days=7", owner, NS)
r = j.get("data") or {}
v = r.get("visitors") or {}
check("report: 3 viewed, 2 started, 1 result, 1 lead, 1 apply", s == 200 and (v.get("view"), v.get("start"), v.get("result"), v.get("lead"), v.get("apply")) == (3, 2, 1, 1, 1), (s, v))
check("funnel stages in order", [f["stage"] for f in r.get("funnel", [])] == ["view", "start", "result", "lead", "apply"], r.get("funnel"))
job = next((q for q in r.get("answers", []) if q["question"] == "job"), {})
check("final answer per visitor (changed tune → team)", {a["answer"]: a["visitors"] for a in job.get("answers", [])} == {"team": 1, "train": 1}, job)
check("drop-off: step 2 lost half", any(d["step"] == 2 and d["visitors"] == 1 and abs((d.get("lost_from_previous") or 0) - 0.5) < 1e-9 for d in r.get("dropoff", [])), r.get("dropoff"))
check("recommended p96 once", r.get("results_by_product") == [{"product": "p96", "visitors": 1}], r.get("results_by_product"))
check("apply by plan", (r.get("apply_by_plan") or {}).get("y") == 1, r.get("apply_by_plan"))
s, j = call("GET", "/api/v2/shop/admin/analytics/survey?days=7", owner_b, NS_B)
rb = j.get("data") or {}
check("other workspace sees none of it", s == 200 and rb.get("visitors", {}).get("view") == 0, (s, j))
check("empty survey lists are [] not {}", all(rb.get(k) == [] for k in ("dropoff", "answers", "results_by_product")),
      {k: rb.get(k) for k in ("dropoff", "answers", "results_by_product")})
s, j = call("GET", "/api/v2/shop/admin/analytics?days=7", owner_b, NS_B)
ra = j.get("data") or {}
check("quiet period: analytics lists are [] not {} (the page called .slice on them)",
      s == 200 and all(ra.get(k) == [] for k in ("top_products", "basket_adds", "chat_tools", "chat_countries"))
      and isinstance(ra.get("series"), list), (s, {k: ra.get(k) for k in ("top_products", "chat_tools", "series")}))
s, j = call("GET", "/api/v2/shop/admin/analytics/survey?days=7", clerk, NS)
check("shop clerk without shop_analytics: 403", s == 403, s)
s, body, hdrs = call("GET", "/api/v2/shop/admin/analytics/export?report=survey&days=7", owner, NS, raw=True)
check("CSV export", s == 200 and "csv" in hdrs.get("Content-Type", "") and "funnel" in body and "team" in body, (s, body[:200]))

print("== survey → CRM lead")
s, j = call("POST", PUB + "/survey/lead-events", body={"event": "lead", "email": "buyer@x.test"})
check("anyone else: 403", s == 403, (s, j))
base = {"email": "Buyer@X.test", "name": "Bea Buyer", "ref": "WS-AB12C"}
s, j = call("POST", PUB + "/survey/lead-events", bff=True, body=dict(base, event="lead", answers={"job": "team", "who": "pilot", "bogus": "x"},
            product="p96", product_name="RTX PRO 6000", marketing=True))
lead_uuid = (j.get("data") or {}).get("lead_uuid")
check("build sent → lead", s == 201 and lead_uuid, (s, j))
s, j = call("POST", PUB + "/survey/lead-events", bff=True, body=dict(base, event="chat", question="Will it run 70B?", answer="Yes, at 8-bit."))
check("question to the AI engineer → same lead", s == 201 and (j.get("data") or {}).get("lead_uuid") == lead_uuid, (s, j))
s, j = call("POST", PUB + "/survey/lead-events", bff=True, body=dict(base, event="join", plan="year", tier="founding"))
check("Trade checkout → same lead", s == 201 and (j.get("data") or {}).get("lead_uuid") == lead_uuid, (s, j))
s, j = call("POST", PUB + "/survey/lead-events", bff=True, body=dict(base, event="join", plan="weekly"))
check("bad plan: 400", s == 400, (s, j))
s, j = call("GET", "/api/v2/crm/leads/" + str(lead_uuid), owner, NS)
lead = j.get("data") or {}
sv = ((lead.get("metadata") or {}).get("shop") or {}).get("survey") or {}
check("lead page gets metadata.shop.survey", s == 200 and sv.get("ref") == "WS-AB12C" and sv.get("product_name") == "RTX PRO 6000", (s, sv))
check("only known questions kept", sv.get("answers") == {"job": "team", "who": "pilot"}, sv.get("answers"))
check("chat and join kept", len(sv.get("chats") or []) == 1 and (sv.get("joins") or [{}])[0].get("plan") == "year", sv)
check("notes have a dated line per event", (lead.get("notes") or "").count("WS-AB12C") == 3, lead.get("notes"))

print("")
print("all %s" % ("passed" if failures == 0 else "%d FAILED" % failures))
sys.exit(1 if failures else 0)

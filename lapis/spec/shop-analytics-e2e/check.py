"""Shop Analytics e2e checks (run by run.sh; stdlib only).

Seeds workspace A with a known month of shop activity (and workspace B with an
order that must never show up in A), then checks every figure the analytics
API returns against numbers worked out by hand below. Every check prints
ok/FAIL; exit 1 on any FAIL.
"""
import base64, csv, hashlib, hmac, io, json, os, subprocess, sys, time, urllib.error, urllib.request, uuid

API = os.environ["API"]
PG = os.environ["PG_CONTAINER"]
API_CONTAINER = os.environ["API_CONTAINER"]
SECRET = open(os.environ["JWT_SECRET_FILE"]).read().strip()
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
    out = subprocess.run(["docker", "exec", "-i", PG, "psql", "-U", "postgres", "-d", "sa", "-At", "-F", "|",
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


def call(method, path, u=None, ns=None, body=None, raw=False):
    h = {"Content-Type": "application/json"}
    if u:
        h["Authorization"] = "Bearer " + jwt(u)
    if ns:
        h["X-Namespace-Id"] = ns
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            payload, status, headers = r.read(), r.status, dict(r.headers)
    except urllib.error.HTTPError as e:
        payload, status, headers = e.read(), e.code, dict(e.headers)
    if raw:
        return status, payload.decode("utf-8", "replace"), headers
    try:
        j = json.loads(payload or b"{}")
    except ValueError:
        j = {"_raw": payload[:300]}
    return status, j


def user(name):
    u = {"uuid": str(uuid.uuid4()), "email": name + "@sa.test"}
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


def ago(expr):
    return "NOW() - interval '%s'" % expr


# ---------------------------------------------------------------------------
print("== migrations")
check("zzs31-35 recorded", int(one("SELECT COUNT(*) FROM lapis_migrations WHERE name LIKE 'zzs3_\\_shop_analytics%'")) == 5,
      sql("SELECT name FROM lapis_migrations WHERE name LIKE 'zzs3%'"))
check("RBAC module registered with its category",
      one("SELECT category FROM modules WHERE machine_name = 'shop_analytics'") == "Commerce")
check("sidebar item in the Shop & Orders group",
      one("SELECT settings::text FROM menu_items WHERE key = 'shop_analytics'") in ('{"group":"commerce"}', '{"group": "commerce"}'))
idx = {r[0] for r in sql("SELECT indexname FROM pg_indexes WHERE indexname LIKE 'shop_%created_at_idx' OR indexname = 'shop_orders_ns_paid_at_idx'")}
check("window indexes created", {"shop_orders_ns_paid_at_idx", "shop_orders_ns_created_at_idx", "shop_carts_ns_created_at_idx",
                                 "shop_quotes_ns_created_at_idx", "shop_chat_sessions_ns_created_at_idx"} <= idx, idx)

print("== seed")
owner_a, owner_b, clerk, analyst = user("ownera"), user("ownerb"), user("clerk"), user("analyst")
for u, name, slug in ((owner_a, "Shop A", "shop-a"), (owner_b, "Shop B", "shop-b")):
    s, j = call("POST", "/api/v2/user/namespaces", u, None, {"name": name, "slug": slug})
    check("workspace %s created" % slug, s in (200, 201), j)
NS_A, ID_A = sql("SELECT uuid, id FROM namespaces WHERE slug = 'shop-a'")[0]
NS_B, ID_B = sql("SELECT uuid, id FROM namespaces WHERE slug = 'shop-b'")[0]
member(ID_A, clerk, "shop_clerk", {"shop": ["read", "update"]})
member(ID_A, analyst, "shop_analyst", {"shop_analytics": ["read"]})

sql("""INSERT INTO shop_products (uuid, namespace_id, sku, slug, name, product_type, base_price_minor, status)
       VALUES ('p1-uuid', %(a)s, 'GPU-1', 'gpu-1', 'RTX PRO 6000', 'gpu', 100000, 'active'),
              ('p2-uuid', %(a)s, 'MEM-1', 'mem-1', 'DDR5 64GB', 'memory', 25000, 'active'),
              ('pb-uuid', %(b)s, 'B-1', 'b-1', 'Other shop item', 'gpu', 1, 'active')""" % {"a": ID_A, "b": ID_B})
P1 = one("SELECT id FROM shop_products WHERE uuid = 'p1-uuid'")
P2 = one("SELECT id FROM shop_products WHERE uuid = 'p2-uuid'")


def cart(key, created, last_seen, status="active", ns=None):
    sql("""INSERT INTO shop_carts (uuid, namespace_id, token_hash, status, last_seen_at, created_at, updated_at)
           VALUES ('%s', %s, '%s', '%s', %s, %s, %s)""" % (key, ns or ID_A, key + "-hash", status, last_seen, created, created))
    return one("SELECT id FROM shop_carts WHERE uuid = '%s'" % key)


C1 = cart("c1", ago("2 days"), ago("2 days"), "converted")
C2 = cart("c2", ago("5 days"), ago("5 days"))            # paid order, status never flipped
C3 = cart("c3", ago("3 days"), ago("30 hours"))          # checkout tried twice, never paid -> abandoned
C4 = cart("c4", ago("2 hours"), ago("1 hour"))           # still open
C5 = cart("c5", ago("4 days"), ago("4 days"))            # empty
for c, p, q, unit in ((C1, P1, 1, 100000), (C3, P1, 1, 50000), (C4, P2, 2, 1000)):
    sql("INSERT INTO shop_cart_lines (uuid, cart_id, product_id, qty, unit_price_minor) VALUES (gen_random_uuid()::text, %s, %s, %s, %s)"
        % (c, p, q, unit))

sql("""INSERT INTO shop_quotes (uuid, namespace_id, quote_number, access_token, status, source, total_minor, viewed_at, created_at)
       VALUES ('q1', %(a)s, 'Q-1', 't', 'converted', 'cart', 24000, NULL, %(d3)s),
              ('q2', %(a)s, 'Q-2', 't', 'sent', 'chat', 100000, NOW(), %(d4)s),
              ('q3', %(a)s, 'Q-3', 't', 'sent', 'admin', 5000, NULL, %(d40)s)"""
    % {"a": ID_A, "d3": ago("3 days"), "d4": ago("4 days"), "d40": ago("40 days")})
Q1 = one("SELECT id FROM shop_quotes WHERE uuid = 'q1'")
Q2 = one("SELECT id FROM shop_quotes WHERE uuid = 'q2'")


def line(puuid, name, qty, sub, total):
    return {"uuid": str(uuid.uuid4()), "product_uuid": puuid, "product_name": name, "sku": name[:5], "qty": qty,
            "line_subtotal_minor": sub, "line_total_minor": total}


def order(key, status, total, vat, created, paid=None, email=None, cart_id=None, quote_id=None, lines=(), refunded=0, ns=None):
    sql("""INSERT INTO shop_orders (uuid, namespace_id, order_number, access_token, status, email, lines, subtotal_minor,
                                    vat_minor, total_minor, cart_id, quote_id, paid_at, refunded_minor, created_at, updated_at)
           VALUES ('%s', %s, '%s', 't', '%s', %s, '%s'::jsonb, %s, %s, %s, %s, %s, %s, %s, %s, %s)"""
        % (key, ns or ID_A, key.upper(), status, ("'%s'" % email) if email else "NULL", json.dumps(list(lines)),
           total - vat, vat, total, cart_id or "NULL", quote_id or "NULL", paid or "NULL", refunded, created, created))
    return one("SELECT id FROM shop_orders WHERE uuid = '%s'" % key)


O1 = order("o1", "paid", 120000, 20000, ago("2 days"), ago("2 days"), "a@x.test", C1,
           lines=[line("p1-uuid", "RTX PRO 6000", 1, 100000, 120000)])
order("o2", "delivered", 60000, 10000, ago("5 days"), ago("5 days"), "b@x.test", C2,
      lines=[line("p2-uuid", "DDR5 64GB", 2, 50000, 60000)])
order("o3", "refunded", 24000, 4000, ago("3 days"), ago("3 days"), "A@x.test", quote_id=Q1,     # full refund, status only
      lines=[line("p2-uuid", "DDR5 64GB", 1, 20000, 24000)])
order("o4", "paid", 36000, 6000, ago("1 day"), ago("1 day"), "c@x.test", refunded=6000,         # partial refund
      lines=[line("p1-uuid", "RTX PRO 6000", 1, 30000, 36000)])
order("o5", "paid", 10000, 0, ago("45 days"), ago("45 days"), "c@x.test")                        # previous period
order("o6", "pending_payment", 50000, 0, ago("1 day"), cart_id=C3)
order("o7", "payment_failed", 50000, 0, ago("1 day"), cart_id=C3)
order("ob", "paid", 9999999, 0, ago("1 day"), ago("1 day"), "z@b.test", ns=ID_B)                 # other tenant

S = lambda content, **kw: dict(role="assistant", content=content, at="2026-11-01T10:00:00Z", **kw)
U = {"role": "user", "content": "hi", "at": "2026-11-01T10:00:00Z"}
SYS = {"role": "system", "content": "Chat started by a@x.test", "at": "2026-11-01T10:00:00Z"}


def chat(key, msgs, created, quote_id=None, order_id=None, consent=False, country=None, member=False):
    sql("""INSERT INTO shop_chat_sessions (uuid, namespace_id, messages, message_count, quote_id, order_id, consent_at,
                                           country, is_member, created_at, updated_at)
           VALUES ('%s', %s, '%s'::jsonb, %s, %s, %s, %s, %s, %s, %s, %s)"""
        % (key, ID_A, json.dumps(msgs).replace("'", "''"), len(msgs), quote_id or "NULL", order_id or "NULL",
           "NOW()" if consent else "NULL", ("'%s'" % country) if country else "NULL", "true" if member else "false",
           created, created))


chat("s1", [SYS, U, S("Hello! What will you run on it?")], ago("1 day"), consent=True, country="GB")
chat("s2", [U, S("(no reply)")], ago("2 days"), quote_id=Q2, country="GB")
chat("s3", [U, S("Added it.\n\n[tools: search_catalog, add_to_cart]")], ago("3 days"), country="US")
# s4 is the shape the shop now writes: a structured tools list AND the text suffix (must count once)
chat("s4", [U, S("It has 96 GB.\n\n[tools: get_product]", tools=["get_product"]), U, S("Done")], ago("4 days"), order_id=O1, member=True)
chat("s5", [SYS], ago("1 day"))                                                                  # never typed
chat("s6", [U, S("Old chat")], ago("45 days"), consent=True)                                       # previous period

for c, p, n in ((C1, P1, 1), (C3, P1, 1), (C4, P1, 1), (C4, P2, 2)):
    sql("INSERT INTO shop_cart_events (namespace_id, product_id, cart_id, qty, created_at) VALUES (%s, %s, %s, %s, NOW() - interval '1 day')"
        % (ID_A, p, c, n))

# ---------------------------------------------------------------------------
print("== access control")
s, j = call("GET", "/api/v2/shop/admin/analytics", None, NS_A)
check("no token: 401", s == 401, s)
s, j = call("GET", "/api/v2/shop/admin/analytics", clerk, NS_A)
check("shop clerk without shop_analytics: 403", s == 403, (s, j))
s, _ = call("GET", "/api/v2/shop/admin/dashboard", clerk, NS_A)
check("...while the shop clerk still reads the shop dashboard", s == 200, s)
s, j = call("GET", "/api/v2/shop/admin/analytics", owner_b, NS_A)
check("another workspace's owner: 403", s == 403, (s, j))
s, j = call("GET", "/api/v2/shop/admin/analytics", analyst, NS_A)
check("analyst with only shop_analytics.read: 200", s == 200, (s, j))
s, _ = call("GET", "/api/v2/shop/admin/orders", analyst, NS_A)
check("...but the analyst cannot list orders (shop module)", s == 403, s)
s, j = call("GET", "/api/v2/shop/admin/analytics?from=2026-12-01&to=2026-11-01", owner_a, NS_A)
check("from after to: 400", s == 400 and j.get("code") == "VALIDATION_ERROR", (s, j))
s, j = call("GET", "/api/v2/shop/admin/analytics?from=2026-13-01", owner_a, NS_A)
check("not a date: 400", s == 400, (s, j))

print("== report (last 30 days)")
s, j = call("GET", "/api/v2/shop/admin/analytics?days=30", owner_a, NS_A)
check("owner: 200", s == 200 and j.get("success") is True, (s, j))
d = j.get("data") or {}
w = d.get("window") or {}
check("window is 30 UK days", w.get("days") == 30 and w.get("timezone") == "Europe/London" and w.get("bucket") == "day", w)


def expect(section, want):
    got = d.get(section) or {}
    bad = {k: (got.get(k), v) for k, v in want.items() if got.get(k) != v}
    check("%s: %s" % (section, ", ".join("%s=%s" % kv for kv in want.items())), not bad, bad)


expect("sales", {"orders": 4, "revenue_minor": 240000, "vat_minor": 40000, "revenue_ex_vat_minor": 200000,
                 "refunds_minor": 30000, "net_revenue_minor": 210000, "aov_minor": 60000, "refunded_orders": 1,
                 "customers": 3, "new_customers": 2, "returning_customers": 1})
expect("checkout", {"sessions": 6, "started": 5, "paid": 4, "payment_failed": 1, "pending": 1, "from_quote": 1, "paid_rate": 0.8})
expect("carts", {"created": 5, "with_items": 4, "reached_checkout": 3, "converted": 2, "abandoned": 1,
                 "abandoned_value_minor": 50000, "open": 1, "conversion_rate": 0.5, "abandonment_rate": 0.3333})
expect("quotes", {"created": 2, "value_minor": 124000, "converted": 1, "converted_value_minor": 24000, "viewed": 1,
                  "conversion_rate": 0.5})
check("quotes by source", (d.get("quotes") or {}).get("by_source") == {"cart": 1, "chat": 1, "admin": 0},
      (d.get("quotes") or {}).get("by_source"))
expect("chat", {"chats": 4, "ai_replied": 3, "no_reply": 1, "contact_saved": 1, "quotes": 1, "added_to_cart": 1,
                "orders": 1, "completed": 3, "member_chats": 1, "user_messages": 5, "revenue_minor": 120000,
                "completion_rate": 0.75, "reply_rate": 0.75})
tools = {t["name"]: (t["chats"], t["uses"]) for t in d.get("chat_tools") or []}
check("chat tools from structured arrays and the text suffix",
      tools == {"search_catalog": (1, 1), "add_to_cart": (1, 1), "get_product": (1, 1)}, tools)
countries = {(c.get("country") or "-"): c["chats"] for c in d.get("chat_countries") or []}
check("chats by country", countries == {"GB": 2, "US": 1, "-": 1}, countries)
top = d.get("top_products") or []
check("top products: paid orders only, by revenue ex VAT",
      [(p["product_uuid"], p["units"], p["revenue_ex_vat_minor"], p["orders"]) for p in top]
      == [("p1-uuid", 2, 130000, 2), ("p2-uuid", 2, 50000, 1)], top)
adds = d.get("basket_adds") or []
check("most added to basket", [(a["product_uuid"], a["adds"], a["units"]) for a in adds]
      == [("p1-uuid", 3, 3), ("p2-uuid", 1, 2)], adds)
check("basket adds complete for a 30-day window", d.get("basket_adds_complete") is True)
series = d.get("series") or []
check("series has one point per day", len(series) == 30, len(series))
tot = lambda k: sum(p[k] for p in series)
check("series totals match the headline figures",
      (tot("orders"), tot("revenue_minor"), tot("checkouts"), tot("carts"), tot("chats"), tot("quotes"))
      == (4, 240000, 5, 5, 4, 2),
      (tot("orders"), tot("revenue_minor"), tot("checkouts"), tot("carts"), tot("chats"), tot("quotes")))
prev = d.get("previous") or {}
check("previous period: the 45-day-old order, quote and chat",
      (prev.get("sales") or {}).get("orders") == 1 and (prev.get("sales") or {}).get("revenue_minor") == 10000
      and (prev.get("quotes") or {}).get("created") == 1 and (prev.get("chat") or {}).get("chats") == 1, prev)
ch = d.get("changes") or {}
check("change vs previous: revenue 240000 vs 10000 = +23x", ch.get("revenue_minor") == 23.0, ch)
check("no change figure when the previous period had none", ch.get("carts") is None, ch)
check("trade membership section present (no members seeded)", (d.get("trade") or {}).get("joins") == 0, d.get("trade"))
check("visitor tracking reported as off", d.get("visitor_tracking") == {"enabled": False, "status": "awaiting_privacy_signoff"})
check("other workspace's £99,999 order never counted", "9999999" not in json.dumps(d))

s, j = call("GET", "/api/v2/shop/admin/analytics?days=30&compare=false", owner_a, NS_A)
check("compare=false leaves out the previous period", s == 200 and "previous" not in j.get("data", {}), list(j.get("data", {})))
s, j = call("GET", "/api/v2/shop/admin/analytics?days=365", owner_a, NS_A)
dd = j.get("data") or {}
check("a year is weekly and still adds up", s == 200 and dd.get("window", {}).get("bucket") == "week"
      and sum(p["orders"] for p in dd.get("series", [])) == 5, (s, dd.get("window")))
check("a year flags basket adds as partial (30-day retention)", dd.get("basket_adds_complete") is False)
s, j = call("GET", "/api/v2/shop/admin/analytics?days=30", owner_b, NS_B)
check("workspace B sees only its own order", s == 200 and (j["data"]["sales"]["orders"], j["data"]["sales"]["revenue_minor"]) == (1, 9999999),
      j.get("data", {}).get("sales"))

print("== CSV export")
s, body, h = call("GET", "/api/v2/shop/admin/analytics/export?report=products&days=30", owner_a, NS_A, raw=True)
check("products CSV: 200 text/csv, attachment, no-store", s == 200 and h.get("Content-Type", "").startswith("text/csv")
      and "attachment" in h.get("Content-Disposition", "") and "no-store" in h.get("Cache-Control", ""), (s, h))
rows = list(csv.reader(io.StringIO(body)))
check("products CSV rows", rows[0][:3] == ["Product", "SKU", "Units sold"] and rows[1][0] == "RTX PRO 6000"
      and rows[1][4] == "1300.00", rows[:3])
s, body, _ = call("GET", "/api/v2/shop/admin/analytics/export?report=daily&days=30", owner_a, NS_A, raw=True)
rows = list(csv.reader(io.StringIO(body)))
check("daily CSV: header + 30 days, revenue sums to £2,400.00",
      s == 200 and len(rows) == 31 and abs(sum(float(r[2]) for r in rows[1:]) - 2400.0) < 0.001, (s, len(rows)))
s, body, _ = call("GET", "/api/v2/shop/admin/analytics/export?report=chat_tools&days=30", owner_a, NS_A, raw=True)
check("chat tools CSV", s == 200 and body.startswith("Tool,Chats,Replies using it"), body[:80])
s, _, _ = call("GET", "/api/v2/shop/admin/analytics/export?report=customers", owner_a, NS_A, raw=True)
check("unknown export: 404", s == 404, s)
s, _, _ = call("GET", "/api/v2/shop/admin/analytics/export?report=products", clerk, NS_A, raw=True)
check("export needs shop_analytics too: 403", s == 403, s)

print("== sidebar")
s, j = call("GET", "/api/v2/user/menu", owner_a, NS_A)
blob = json.dumps(j)
check("owner's sidebar has Shop Analytics", s == 200 and '"shop_analytics"' in blob and "/dashboard/shop/analytics" in blob, s)
s, j = call("GET", "/api/v2/user/menu", clerk, NS_A)
check("clerk's sidebar does not", s == 200 and '"shop_analytics"' not in json.dumps(j), s)

print("== zzs33 backfills roles that predate the module")
sql("UPDATE namespace_roles SET permissions = (permissions::jsonb - 'shop_analytics')::text WHERE namespace_id = %s AND role_name = 'owner'" % ID_A
    if one("SELECT data_type FROM information_schema.columns WHERE table_name='namespace_roles' AND column_name='permissions'") == "text"
    else "UPDATE namespace_roles SET permissions = permissions - 'shop_analytics' WHERE namespace_id = %s AND role_name = 'owner'" % ID_A)
roles = sql("SELECT role_name, permissions FROM namespace_roles WHERE namespace_id = %s" % ID_A)
check("owner role found", any(r[0] == "owner" for r in roles), roles)
out = subprocess.run(["docker", "exec", "-w", "/app", API_CONTAINER, "lapis", "exec",
                      "require('migrations.shop-analytics')[3]()"], capture_output=True, text=True)
check("grant re-runs cleanly", out.returncode == 0, out.stderr[-400:])
perms = json.loads(one("SELECT permissions FROM namespace_roles WHERE namespace_id = %s AND role_name = 'owner'" % ID_A))
check("owner role has shop_analytics again", "read" in (perms.get("shop_analytics") or []), perms)
analyst_role = json.loads(one("SELECT permissions FROM namespace_roles WHERE namespace_id = %s AND role_name = 'shop_clerk'" % ID_A))
check("custom roles are left alone", "shop_analytics" not in analyst_role, analyst_role)

print("\nAll checks passed." if failures == 0 else "\n%d check(s) FAILED." % failures)
sys.exit(1 if failures else 0)

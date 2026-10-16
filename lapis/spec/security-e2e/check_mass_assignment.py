"""Live checks: routes can't write fields they don't name (mass assignment), and admin-only routes check for an admin.
Run by run.sh after check.py, against fixtures it seeds (stores st-a in sec-a and st-b in sec-b, etc.).

Every check states the SAFE behaviour, so on code without the fixes they fail."""
import base64, hashlib, hmac, json, time, urllib.error, urllib.request

B = "http://sec-api"
SECRET = open("/sec/jwt_secret").read().strip()
U = json.load(open("/sec/users.json")); U.update(json.load(open("/sec/users2.json")))
F = json.load(open("/sec/fixtures.json"))
fails = []

def check(name, ok, detail=""):
    print(("  ok   " if ok else "  FAIL ") + name + ("" if ok else f"   {str(detail)[:300]}"))
    if not ok: fails.append(name)

def b64(d): return base64.urlsafe_b64encode(json.dumps(d, separators=(",", ":")).encode()).rstrip(b"=")
def token(who, roles=None):
    now = int(time.time())
    info = {"uuid": U[who]["uuid"], "email": U[who]["email"]}
    if roles: info["roles"] = roles
    h, body = b64({"typ": "JWT", "alg": "HS256"}), b64({"userinfo": info, "iat": now, "exp": now + 3600, "iss": "opsapi"})
    sig = base64.urlsafe_b64encode(hmac.new(SECRET.encode(), h + b"." + body, hashlib.sha256).digest()).rstrip(b"=")
    return (h + b"." + body + b"." + sig).decode()

def req(method, path, body=None, tok=None, headers=None, form=None):
    h = {"Accept": "application/json"}
    data = None
    if form is not None:
        # The legacy ecommerce routes read self.params (form/query), not a JSON body.
        data = "&".join(f"{k}={urllib.request.quote(str(v))}" for k, v in form.items()).encode()
        h["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = json.dumps(body).encode(); h["Content-Type"] = "application/json"
    if tok: h["Authorization"] = "Bearer " + tok
    h.update(headers or {})
    r = urllib.request.Request(B + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=30) as x:
            out = x.read(); return x.status, (json.loads(out) if out[:1] in (b"{", b"[") else out)
    except urllib.error.HTTPError as e:
        out = e.read()
        try: return e.code, json.loads(out)
        except Exception: return e.code, out[:200]

def row(r, *keys):  # the record in a response, whatever the envelope
    for c in (r, (r or {}).get("data") if isinstance(r, dict) else None,
              ((r or {}).get("data") or {}).get("product") if isinstance(r, dict) and isinstance(r.get("data"), dict) else None,
              (r or {}).get("product") if isinstance(r, dict) else None):
        if isinstance(c, dict) and all(k in c for k in keys): return c
    return {}

ALICE, BOB, EVE = token("alice"), token("bob"), token("eve")
SAM, PAT = token("sam"), token("pat")
TINA = token("tina", roles="tax_admin")  # what a real login puts in the token: the first platform role's name
A = {"X-Namespace-Slug": "sec-a"}

print("M1: platform secrets are for platform admins only")
for method, path in (("GET", "/api/v2/secrets"), ("GET", "/api/v2/secrets/se-1"), ("GET", "/api/v2/secrets/se-1/show"),
                     ("PUT", "/api/v2/secrets/se-1"), ("DELETE", "/api/v2/secrets/se-1")):
    st, r = req(method, path, {"name": "taken"} if method == "PUT" else None, TINA)
    check(f"a tax_admin {method} {path} -> 403", st == 403, (st, r))
st, r = req("GET", "/api/v2/secrets", tok=PAT)
check("a platform admin lists secrets", st == 200 and "stripe" in json.dumps(r), (st, r))
st, r = req("PUT", "/api/v2/secrets/does-not-exist", {"name": "x"}, PAT)
check("updating a secret that doesn't exist -> 404", st == 404, (st, r))

print("M2: order items (raw) are for platform admins only")
for method, path, body in (("GET", "/api/v2/orderitems", None), ("GET", "/api/v2/orderitems/oi-a", None),
                           ("PUT", "/api/v2/orderitems/oi-a", {"price": 0, "total": 0}),
                           ("DELETE", "/api/v2/orderitems/oi-a", None)):
    st, r = req(method, path, body, BOB)
    check(f"a signed-in user {method} {path} -> 403", st == 403, (st, r))
st, r = req("GET", "/api/v2/orderitems/oi-a", tok=PAT)
item = row(r, "price")
check("...and the item is untouched (price 100)", st == 200 and float(item.get("price") or 0) == 100, (st, r))
st, r = req("PUT", "/api/v2/orderitems/oi-a", tok=PAT, form={"price": 90, "order_id": F["order_b_like"], "uuid": "stolen"})
item = row(r, "price")
check("a platform admin changes the price but not the order or uuid", st == 200 and float(item.get("price") or 0) == 90
      and item.get("uuid") == "oi-a" and item.get("order_id") != F["order_b_like"], (st, r))

print("M3: a store owner's order update can't touch totals, payment, store or tenant")
st, r = req("PUT", "/api/v2/orders/or-a", tok=SAM, form={"total_amount": 0, "payment_status": "paid",
            "financial_status": "paid", "store_id": F["store_b"], "namespace_id": F["ns_b"], "internal_notes": "Packed"})
o = row(r, "total_amount")
check("sam's order: notes saved; total, payment, store and tenant unchanged",
      st == 200 and o.get("internal_notes") == "Packed" and float(o.get("total_amount") or 0) == 100
      and o.get("payment_status") == "pending" and o.get("store_id") != F["store_b"] and o.get("namespace_id") != F["ns_b"], (st, r))

print("M4: products can't move tenant or store, fake ratings, or take another tenant's category")
st, r = req("PUT", "/api/v2/products/pr-a", {"name": "Renamed A", "namespace_id": F["ns_b"], "store_id": F["store_b"],
            "rating_average": 5, "rating_count": 9999}, ALICE, A)
st2, r2 = req("GET", "/api/v2/products/pr-a", tok=ALICE, headers=A)
p = row(r2, "name")
check("the owner renames the product; tenant, store and rating unchanged",
      st == 200 and p.get("name") == "Renamed A" and p.get("namespace_id") != F["ns_b"] and p.get("store_id") != F["store_b"]
      and float(p.get("rating_count") or 0) != 9999, (st, r, p))
st, r = req("PUT", "/api/v2/storeproducts/pr-a", {"category_id": "ca-b"}, ALICE, A)
p = row(req("GET", "/api/v2/products/pr-a", tok=ALICE, headers=A)[1], "name")
check("another tenant's category isn't attached", p.get("category_id") != F["category_b"], (st, r, p))
st, r = req("PUT", "/api/v2/storeproducts/pr-a", {"name": "Eve's"}, EVE, A)
check("a member without the products permission edits a product -> 403", st == 403, (st, r))

print("M5: variants and categories stay with their product and store")
st, r = req("PUT", "/api/v2/variants/va-a", tok=SAM, form={"price": 400, "product_id": F["product_b"]})
v = row(r, "price")
check("sam changes a variant's price; it stays on its product", st == 200 and float(v.get("price") or 0) == 400
      and v.get("product_id") != F["product_b"], (st, r))
st, r = req("PUT", "/api/v2/categories/ca-a", tok=SAM, form={"name": "Renamed cat", "store_id": F["store_b"], "namespace_id": F["ns_b"]})
c = row(r, "name")
check("sam renames a category; store and tenant unchanged", st == 200 and c.get("name") == "Renamed cat"
      and c.get("store_id") != F["store_b"] and c.get("namespace_id") != F["ns_b"], (st, r))
st, r = req("PUT", "/api/v2/categories/ca-a", tok=SAM, form={"parent_id": F["category_b"]})
check("a parent category from another store -> 400", st == 400, (st, r))

print("M6: the cart prices a product with its own variants only")
st, r = req("POST", "/api/v2/cart/add", tok=BOB, form={"product_uuid": "pr-a", "variant_uuid": "va-b", "quantity": 1})
check("adding a product with another product's cheap variant -> 400", st == 400, (st, r))
st, r = req("POST", "/api/v2/cart/add", tok=BOB, form={"product_uuid": "pr-a", "variant_uuid": "va-a", "quantity": 1})
check("...its own variant is fine", st in (200, 201), (st, r))

print("M7: SCIM user provisioning is for platform admins; an admin can't take over the owner")
st, r = req("GET", "/scim/v2/Users", tok=BOB)
check("a signed-in user lists every account over SCIM -> 403", st == 403, (st, str(r)[:200]))
st, r = req("POST", "/scim/v2/Users", {"username": "mallory", "email": "mallory@sec.test", "password": "Mx" + "9" * 10 + "!",
            "first_name": "M", "last_name": "M", "role": "administrative"}, BOB)
check("a signed-in user creates a platform admin over SCIM -> 403", st == 403, (st, r))
st, r = req("DELETE", "/scim/v2/Users/" + U["sam"]["uuid"], tok=BOB)
check("a signed-in user deletes another account over SCIM -> 403", st == 403, (st, r))
st, r = req("GET", "/scim/v2/Users", tok=PAT)
check("a platform admin lists accounts over SCIM", st == 200, (st, str(r)[:200]))
st, r = req("PUT", "/api/v2/users/" + U["alice"]["uuid"], {"email": "alice-taken@evil.test"}, EVE, A)
check("an HR admin changes the workspace owner's email -> 403", st == 403, (st, r))
st, r = req("DELETE", "/api/v2/users/" + U["alice"]["uuid"], tok=EVE, headers=A)
check("an HR admin deletes the workspace owner -> 403", st == 403, (st, r))
mem = req("GET", "/api/v2/namespace/members", tok=ALICE, headers=A)[1]
mem = (mem.get("data") if isinstance(mem, dict) else mem) or []
mem = mem if isinstance(mem, list) else (mem.get("members") or mem.get("data") or [])
plain = [m for m in mem if isinstance(m, dict) and (m.get("email") or (m.get("user") or {}).get("email", "")).startswith("ok")]
target = plain and (plain[0].get("user_uuid") or (plain[0].get("user") or {}).get("uuid") or plain[0].get("uuid"))
if target:
    st, r = req("PUT", "/api/v2/users/" + target, {"first_name": "Renamed"}, EVE, A)
    check("...but can edit a plain member", st == 200, (st, r))

print("\nMASS-ASSIGNMENT FAILURES:", len(fails), fails)

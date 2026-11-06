#!/usr/bin/env python3
"""Media library end to end, against a running local stack (lib/media-library.lua).

    docker exec -i opsapi sh -c 'cat > /tmp/ml_setup.lua' < lapis/spec/media-library-e2e/setup.lua
    docker exec -w /app opsapi lapis exec "assert(loadfile('/tmp/ml_setup.lua'))()"
    python3 -I lapis/spec/media-library-e2e/check.py            # API at http://127.0.0.1:4020

setup.lua makes workspaces media-test-a (owner, editor = cms read/update, reader =
cms read) and media-test-b (owner), and writes their tokens to /tmp/ml_tokens.json
inside the container; this script reads them from there and never prints them.
"""
import base64, json, os, subprocess, sys, time, urllib.request, urllib.error, uuid

API = os.environ.get("API", "http://127.0.0.1:4020")
CONTAINER = os.environ.get("CONTAINER", "opsapi")
TOK = json.loads(subprocess.check_output(["docker", "exec", CONTAINER, "cat", "/tmp/ml_tokens.json"]))
failures = 0
RUN = str(int(time.time()))

# 1x1 PNG
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
SVG_OK = b'<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10" fill="red"/></svg>'
SVG_BAD = b'<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"><rect width="10" height="10"/></svg>'


def check(name, ok, detail=None):
    global failures
    if ok:
        print("  ok   - " + name)
    else:
        failures += 1
        print("  FAIL - " + name + ("  (" + str(detail)[:400] + ")" if detail is not None else ""))


def who(ws, role):
    t = TOK[ws][role]
    return {"Authorization": "Bearer " + t["token"], "X-Namespace-Slug": t["slug"]}


def send(method, url, headers=None, data=None):
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def call(ws, role, method, path, body=None):
    h = who(ws, role) if ws else {}
    data = None
    if body is not None:
        h["Content-Type"] = "application/json"
        data = json.dumps(body).encode()
    status, _, raw = send(method, API + path, h, data)
    try:
        return status, json.loads(raw or b"{}")
    except ValueError:
        return status, {"raw": raw[:200]}


def upload(ws, role, content, filename="pic.png", ctype="image/png", field="file", **fields):
    boundary = "----ml" + uuid.uuid4().hex
    parts = []
    for k, v in fields.items():
        parts.append(("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n" % (boundary, k, v)).encode())
    parts.append(("--%s\r\nContent-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\nContent-Type: %s\r\n\r\n"
                  % (boundary, field, filename, ctype)).encode() + content + b"\r\n")
    parts.append(("--%s--\r\n" % boundary).encode())
    h = who(ws, role)
    h["Content-Type"] = "multipart/form-data; boundary=" + boundary
    status, _, raw = send("POST", API + "/api/v2/cms/media", h, b"".join(parts))
    try:
        return status, json.loads(raw or b"{}")
    except ValueError:
        return status, {"raw": raw[:200]}


print("config + permissions")
s, r = call("a", "reader", "GET", "/api/v2/cms/media/config")
check("config says storage is ready", s == 200 and r["data"]["configured"] is True, r)
storage = r.get("data", {}).get("storage")
s, _ = call(None, None, "GET", "/api/v2/cms/media")
check("no token -> 401", s == 401, s)
s, r = upload("a", "reader", PNG)
check("reader (cms read only) cannot upload -> 403", s == 403, r)

print("upload")
s, r = upload("a", "editor", PNG, filename="hello-%s.png" % RUN, alt_text="A red dot", width="1", height="1")
check("editor uploads a PNG -> 201", s == 201, r)
img = r.get("data") or {}
check("row has url, type, size, size in pixels, alt text",
      img.get("url") and img.get("mime_type") == "image/png" and img.get("size_bytes") == len(PNG)
      and img.get("width") == 1 and img.get("height") == 1 and img.get("alt_text") == "A red dot", img)
if storage == "minio":
    check("MinIO image gets a public OpsAPI link", "/api/v2/public/media/" in (img.get("url") or ""), img.get("url"))
    s, h, body = send("GET", img["url"], {"Origin": "https://example.org"})
    hl = {k.lower(): v for k, v in h.items()}
    # The dashboard's own origin is on the CORS allow-list: still exactly one "*".
    _, h2, _ = send("GET", img["url"], {"Origin": "http://127.0.0.1:8039"})
    acao = [v for k, v in h2.items() if k.lower() == "access-control-allow-origin"]
    check("one CORS header (*) for the dashboard's origin too", acao == ["*"], acao)
    check("public link serves the same bytes", s == 200 and body == PNG, s)
    check("public link: image/png, cached for a year, nosniff, CORS *",
          hl.get("content-type", "").startswith("image/png") and "immutable" in hl.get("cache-control", "")
          and hl.get("x-content-type-options") == "nosniff" and hl.get("access-control-allow-origin") == "*"
          and "access-control-allow-credentials" not in hl, hl)
s, r = upload("a", "editor", PNG, field="image", filename="legacy.png")
check("old field name 'image' still works", s == 201, r)
legacy = (r.get("data") or {}).get("uuid")

s, r = upload("a", "editor", b"just some text, not a picture", filename="fake.png")
check("text dressed up as a PNG -> 400", s == 400, r)
s, r = upload("a", "editor", b"\x89PNG\r\n\x1a\n" + b"0" * (8 * 1024 * 1024), filename="big.png")
check("over 8 MB -> 413", s == 413, r)
s, r = upload("a", "editor", SVG_BAD, filename="bad.svg", ctype="image/svg+xml")
check("SVG with an onload script -> 400", s == 400, r)
s, r = upload("a", "editor", SVG_OK, filename="ok.svg", ctype="image/svg+xml")
check("plain SVG -> 201 as image/svg+xml", s == 201 and r["data"]["mime_type"] == "image/svg+xml", r)
if storage == "minio" and s == 201:
    _, h, _ = send("GET", r["data"]["url"])
    hl = {k.lower(): v for k, v in h.items()}
    check("SVG is served with a sandbox CSP", "sandbox" in hl.get("content-security-policy", ""), hl)

print("edited copy")
s, r = upload("a", "editor", PNG, filename="hello-crop.png", source_uuid=img.get("uuid"))
check("a cropped copy links to its original", s == 201 and r["data"]["source_uuid"] == img.get("uuid"), r)
s, r = upload("a", "editor", PNG, filename="x.png", source_uuid=str(uuid.uuid4()))
check("copy of an unknown original -> 404", s == 404, r)

print("list")
s, r = call("a", "reader", "GET", "/api/v2/cms/media?search=hello-%s&per_page=5" % RUN)
check("reader can search the library", s == 200 and [i["uuid"] for i in r["data"]] == [img.get("uuid")], r)
s, r = call("a", "reader", "GET", "/api/v2/cms/media?type=svg")
check("type=svg lists only SVGs", s == 200 and r["data"] and all(i["mime_type"] == "image/svg+xml" for i in r["data"]), r)
s, r = call("a", "reader", "GET", "/api/v2/cms/media?per_page=2&page=1&sort=oldest")
check("paging meta", s == 200 and r["meta"]["per_page"] == 2 and r["meta"]["total"] >= 5 and len(r["data"]) == 2, r.get("meta"))
s, r = call("a", "reader", "GET", "/api/v2/cms/media?per_page=0&page=-3&sort=drop%20table")
check("silly paging/sort values are clamped, not a 500", s == 200, s)
s, r = call("a", "reader", "GET", "/api/v2/cms/media?search=100%25_off")
check("search with % and _ is fine", s == 200, s)

print("backfill + used in")
s, r = call("a", "reader", "GET", "/api/v2/cms/media?search=old")
urls = {i["url"]: i for i in r.get("data", [])}
check("backfill added the post's images once each",
      "https://example.com/old.png" in urls and "/img/old-cover.jpg" in urls
      and sum(1 for i in r["data"] if i["url"] == "/img/old-cover.jpg") == 1, list(urls))
link = urls.get("https://example.com/old.png", {})
check("backfilled images are 'link' rows", link.get("storage") == "link", link)
s, r = call("a", "reader", "GET", "/api/v2/cms/media/" + link.get("uuid", "x"))
check("used_in names the post that shows it", s == 200 and any(u["title"] == "Media test post" for u in r["data"]["used_in"]), r)
s, r = call("a", "owner", "POST", "/api/v2/cms/posts",
            {"title": "Uses an upload " + RUN, "content_html": '<p><img src="%s"></p>' % img.get("url")})
check("owner makes a post that shows the upload", s in (200, 201), r)
s, r = call("a", "reader", "GET", "/api/v2/cms/media/" + img.get("uuid", "x"))
check("used_in finds it in the content", s == 200 and any(u["title"] == "Uses an upload " + RUN for u in r["data"]["used_in"]), r)

print("update")
s, r = call("a", "editor", "PUT", "/api/v2/cms/media/" + img.get("uuid", "x"), {"alt_text": "  A tiny red dot ", "title": "Dot"})
check("editor changes alt text + title (trimmed)", s == 200 and r["data"]["alt_text"] == "A tiny red dot" and r["data"]["title"] == "Dot", r)
s, r = call("a", "reader", "PUT", "/api/v2/cms/media/" + img.get("uuid", "x"), {"alt_text": "no"})
check("reader cannot change it -> 403", s == 403, r)

print("other workspace")
s, r = call("b", "owner", "GET", "/api/v2/cms/media?per_page=100")
check("B's library has none of A's images", s == 200 and all(i["uuid"] != img.get("uuid") for i in r["data"]), r)
for method in ("GET", "PUT", "DELETE"):
    s, _ = call("b", "owner", method, "/api/v2/cms/media/" + img.get("uuid", "x"), {"alt_text": "x"} if method == "PUT" else None)
    check("B %s on A's image -> 404" % method, s == 404, s)
s, r = upload("b", "owner", PNG, source_uuid=img.get("uuid"))
check("B cannot make a copy of A's image -> 404", s == 404, r)

print("delete")
s, r = call("a", "editor", "DELETE", "/api/v2/cms/media/" + (legacy or "x"))
check("editor without cms delete -> 403", s == 403, r)
s, r = call("a", "owner", "DELETE", "/api/v2/cms/media/" + (legacy or "x"))
check("owner deletes an image", s == 200, r)
s, _ = call("a", "owner", "GET", "/api/v2/cms/media/" + (legacy or "x"))
check("it is gone from the library", s == 404, s)
s, r = call("a", "owner", "DELETE", "/api/v2/cms/media/" + link.get("uuid", "x"))
check("removing a 'link' image only takes it out of the library", s == 200, r)
if storage == "minio":
    s, _, _ = send("GET", API + "/api/v2/public/media/" + (legacy or "x") + ".png")
    check("deleted image's public link -> 404", s == 404, s)
    s, _, _ = send("GET", API + "/api/v2/public/media/../../etc/passwd")
    check("odd public paths -> 404", s in (400, 404), s)

print("\n%s" % ("ALL PASSED" if failures == 0 else "%d FAILED" % failures))
sys.exit(1 if failures else 0)

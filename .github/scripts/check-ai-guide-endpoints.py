#!/usr/bin/env python3
"""Every endpoint the AI page guides document must be a real route.

The page assistant may only call the `METHOD /path` pairs written in
lapis/lib/agent/knowledge/*.md, so a renamed or removed route silently breaks it.
This probes each one against a running API as an authenticated user WITHOUT a
workspace header: real routes stop at their namespace / validation guard (no side
effects), a missing one answers NOT_FOUND_404 / METHOD_NOT_ALLOWED_405.

  check-ai-guide-endpoints.py <base_url> <jwt_secret> <user_uuid>
"""
import base64, glob, hashlib, hmac, json, os, re, sys, time, urllib.error, urllib.request

base, secret, user = sys.argv[1].rstrip("/"), sys.argv[2], sys.argv[3]
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")


def b64(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


now = int(time.time())
head = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
body = b64(json.dumps({"userinfo": {"uuid": user, "sub": user}, "iat": now, "exp": now + 3600, "iss": "opsapi"}).encode())
sig = b64(hmac.new(secret.encode(), f"{head}.{body}".encode(), hashlib.sha256).digest())
token = f"{head}.{body}.{sig}"
fake_id = "00000000-0000-0000-0000-000000000000"

missing, total = [], 0
for path in sorted(glob.glob(os.path.join(root, "lapis/lib/agent/knowledge/*.md"))):
    guide = open(path).read().split("\n---", 2)[-1]
    for method, route in sorted(set(re.findall(r"`(GET|POST|PUT|PATCH|DELETE)\s+(/[^\s`?]+)", guide))):
        total += 1
        url = base + re.sub(r"\{[^}/]*\}|:[A-Za-z_]\w*", fake_id, route)
        req = urllib.request.Request(url, method=method, headers={"Authorization": "Bearer " + token})
        try:
            code, text = urllib.request.urlopen(req, timeout=20).status, ""
        except urllib.error.HTTPError as e:
            code, text = e.code, e.read(400).decode("utf8", "replace")
        except Exception as e:  # connection problems are a failure of the check itself
            sys.exit(f"::error::cannot reach {base}: {e}")
        if code == 401:
            sys.exit("::error::the check's own token was rejected (401) — wrong JWT secret or user")
        if "NOT_FOUND_404" in text or "METHOD_NOT_ALLOWED_405" in text:
            missing.append(f"{os.path.basename(path)}: {method} {route}")

for m in missing:
    print(f"::error::AI page guide documents an endpoint that doesn't exist — {m}")
print(f"{total} documented endpoints checked, {len(missing)} missing")
sys.exit(1 if missing else 0)

"""Verify an OpsAPI webhook (Python). Copy `verify()` into your receiver.

The signature is the whole security of a webhook receiver: a valid one is the only proof the request came from
OpsAPI. Check it over the RAW body (before JSON parse) and reject stale timestamps (replay).

Run this file directly for a self-test:  python3 verify_webhook.py
"""
import hashlib
import hmac
import json
import time
from datetime import datetime, timezone


def verify(raw_body: bytes, signature_header: str, secret: str, max_age_seconds: int = 300):
    """Return the parsed payload if the request is genuine, else raise ValueError.

    raw_body:          the request body EXACTLY as received (bytes), before json.loads
    signature_header:  the X-Opsapi-Signature-256 header value ("sha256=...")
    secret:            the webhook secret (store it as an env var, e.g. OPSAPI_WEBHOOK_SECRET)
    """
    expected = "sha256=" + hmac.new(secret.encode(), raw_body, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, signature_header or ""):
        raise ValueError("bad signature")
    payload = json.loads(raw_body)
    sent = datetime.fromisoformat(str(payload.get("timestamp", "")).replace("Z", "+00:00"))
    if abs((datetime.now(timezone.utc) - sent).total_seconds()) > max_age_seconds:
        raise ValueError("timestamp too old (possible replay)")
    return payload


# ---- Flask example (delete if you don't use Flask) -----------------------------------------------------------
# import os
# from flask import request
# @app.post("/opsapi-update")
# def opsapi_update():
#     try:
#         payload = verify(request.get_data(), request.headers.get("X-Opsapi-Signature-256", ""),
#                          os.environ["OPSAPI_WEBHOOK_SECRET"])
#     except ValueError as e:
#         return str(e), 401
#     # rebuild / revalidate the pages for payload["data"]["slug"]
#     return {"ok": True}


if __name__ == "__main__":
    secret = "test-secret"
    body = json.dumps({
        "event": "post.published", "namespace_id": 12,
        "data": {"slug": "hello"}, "timestamp": datetime.now(timezone.utc).isoformat(),
    }).encode()
    good = "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()

    assert verify(body, good, secret)["data"]["slug"] == "hello", "a correctly signed request must pass"

    for name, call in {
        "wrong secret":   lambda: verify(body, good, "other-secret"),
        "tampered body":  lambda: verify(body + b" ", good, secret),
        "no signature":   lambda: verify(body, "", secret),
        "stale timestamp": lambda: verify(
            json.dumps({"timestamp": datetime(2000, 1, 1, tzinfo=timezone.utc).isoformat(),
                        "data": {}}).encode(),
            "sha256=" + hmac.new(secret.encode(),
                                 json.dumps({"timestamp": datetime(2000, 1, 1, tzinfo=timezone.utc).isoformat(),
                                             "data": {}}).encode(), hashlib.sha256).hexdigest(),
            secret),
    }.items():
        try:
            call()
            raise SystemExit(f"FAIL: {name} should have been rejected")
        except ValueError:
            pass
    print("ok: genuine request accepted; wrong secret, tampered body, missing signature and replay all rejected")

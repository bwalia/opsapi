"""Verify an OpsAPI webhook in Python (stdlib only).

Two signing schemes exist (see ../reference.md):
  CMS "Website update" webhooks:  HMAC_SHA256(secret, raw_body)
  Workspace event webhooks:       HMAC_SHA256(secret, X-Opsapi-Timestamp + "." + raw_body)
verify_opsapi_webhook picks the scheme by whether X-Opsapi-Timestamp is present.

ALWAYS pass the raw request body bytes, never re-serialised JSON.

Flask:
    from flask import Flask, request
    app = Flask(__name__)

    @app.post("/api/opsapi-update")
    def opsapi_update():
        ok, result = verify_opsapi_webhook(request.get_data(), request.headers.get,
                                           os.environ["OPSAPI_WEBHOOK_SECRET"])
        if not ok:
            return result, 401
        # result["event"], result["data"]["slug"] -> rebuild / purge here
        return {"ok": True}

FastAPI:
    from fastapi import FastAPI, Request, HTTPException
    app = FastAPI()

    @app.post("/api/opsapi-update")
    async def opsapi_update(request: Request):
        ok, result = verify_opsapi_webhook(await request.body(), request.headers.get,
                                           os.environ["OPSAPI_WEBHOOK_SECRET"])
        if not ok:
            raise HTTPException(status_code=401, detail=result)
        return {"ok": True}
"""

import hashlib
import hmac
import json
import os  # noqa: F401  (used in the examples above)
import time
from datetime import datetime, timezone

MAX_AGE_S = 5 * 60


def _parse_time(value):
    if value is None:
        return None
    value = str(value)
    if value.isdigit():
        return float(value)
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc).timestamp()
    except ValueError:
        return None


def verify_opsapi_webhook(raw_body, get_header, secret):
    """Return (True, payload_dict) or (False, reason_str).

    get_header: callable(name) -> str | None, case-insensitive (Flask/Starlette headers.get are).
    """
    if not secret:
        return False, "no secret configured"
    raw = raw_body if isinstance(raw_body, bytes) else str(raw_body).encode("utf-8")
    given = get_header("X-Opsapi-Signature-256") or ""
    ts = get_header("X-Opsapi-Timestamp")

    signed = (ts.encode("utf-8") + b"." + raw) if ts else raw
    expected = "sha256=" + hmac.new(secret.encode("utf-8"), signed, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(given, expected):
        return False, "bad signature"

    try:
        payload = json.loads(raw)
    except ValueError:
        return False, "invalid JSON"

    when = _parse_time(ts) if ts else _parse_time(payload.get("timestamp"))
    if when is None or abs(time.time() - when) > MAX_AGE_S:
        return False, "stale or missing timestamp"
    return True, payload


if __name__ == "__main__":
    secret = "test-secret"
    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    body = json.dumps({"event": "post.updated", "namespace_id": 1,
                       "data": {"slug": "hi"}, "timestamp": now_iso}).encode()

    cms_sig = "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    cms_h = {"X-Opsapi-Signature-256": cms_sig}
    assert verify_opsapi_webhook(body, cms_h.get, secret)[0], "CMS scheme"
    assert not verify_opsapi_webhook(body + b" ", cms_h.get, secret)[0], "tampered body"

    ts = str(int(time.time()))
    ev_sig = "sha256=" + hmac.new(secret.encode(), ts.encode() + b"." + body, hashlib.sha256).hexdigest()
    ev_h = {"X-Opsapi-Signature-256": ev_sig, "X-Opsapi-Timestamp": ts}
    assert verify_opsapi_webhook(body, ev_h.get, secret)[0], "event scheme"
    assert not verify_opsapi_webhook(body, ev_h.get, "wrong")[0], "wrong secret"
    print("ok")

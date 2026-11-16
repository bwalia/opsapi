"""HMRC sandbox test-user generator.

A small side app deployed next to OpsAPI (its own pod and Service, see the
diytaxreturn-lapis chart, templates/hmrc-test-users.yaml). Testers press one
button and get a fresh HMRC sandbox individual (Government Gateway user ID +
password, NINO, SA UTR, MTD IT ID) to sign in with on "Connect to HMRC" when
testing File My Tax.

How it works (same flow as diy-tax-return-uk's hmrc-mtd-sample-app-sandbox):
  1. client-credentials grant with the OpsAPI HMRC sandbox app -> server token
  2. POST /create-test-user/individuals (Create Test User API 1.0)

Sandbox only: it refuses to start against production HMRC. Optional HTTP Basic
access (ACCESS_PASSWORD) and a per-IP rate limit, because every user it makes is
created with OpsAPI's HMRC application.
"""

from __future__ import annotations

import base64
import hmac
import logging
import os
import threading
import time
from collections import defaultdict, deque
from pathlib import Path

import httpx
from fastapi import APIRouter, FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel

log = logging.getLogger("hmrc-test-users")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")

SANDBOX_BASE = "https://test-api.service.hmrc.gov.uk"

# The enrolments a test user can be given. MTD Income Tax filing needs all three
# (the default). Anything else is refused rather than passed through to HMRC.
SERVICES = {
    "national-insurance": "National Insurance (NINO)",
    "self-assessment": "Self Assessment (SA UTR)",
    "mtd-income-tax": "Making Tax Digital for Income Tax (MTD IT ID)",
}
DEFAULT_SERVICES = list(SERVICES)

# A VAT-registered business (organisation test user) for testing VAT (MTD).
ORG_SERVICES = {
    "mtd-vat": "VAT (MTD) — gives a VAT registration number (VRN)",
    "corporation-tax": "Corporation Tax (CT UTR)",
}
DEFAULT_ORG_SERVICES = ["mtd-vat"]
# An accountant (agent) — gets an Agent Reference Number (ARN) for acting for clients.
AGENT_SERVICES = {"agent-services": "Agent services (gives an Agent Reference Number)"}
KINDS = {"individual": ("individuals", SERVICES, DEFAULT_SERVICES),
         "organisation": ("organisations", ORG_SERVICES, DEFAULT_ORG_SERVICES),
         "agent": ("agents", AGENT_SERVICES, ["agent-services"])}


class CreateRequest(BaseModel):
    # "individual" (a taxpayer for File My Tax) or "organisation" (a VAT-registered business)
    kind: str | None = None
    service_names: list[str] | None = None


class Settings:
    def __init__(self) -> None:
        self.environment = os.getenv("HMRC_ENVIRONMENT", "sandbox").strip().lower()
        self.client_id = os.getenv("HMRC_CLIENT_ID", "").strip()
        self.client_secret = os.getenv("HMRC_CLIENT_SECRET", "").strip()
        self.base_url = os.getenv("HMRC_SANDBOX_BASE_URL", SANDBOX_BASE).rstrip("/")
        # Served under this path (the chart routes /hmrc-test-users on the OpsAPI host here).
        root = os.getenv("ROOT_PATH", "").strip("/")
        self.prefix = "/" + root if root else ""
        self.access_password = os.getenv("ACCESS_PASSWORD", "")
        # Only for running it on your own machine: without a password anyone who can reach
        # the page could mint sandbox taxpayers with this release's HMRC application.
        self.allow_no_password = os.getenv("ALLOW_NO_PASSWORD", "").strip().lower() == "true"
        self.rate_limit = int(os.getenv("RATE_LIMIT_PER_HOUR", "20"))
        # Proxies in front of the app that append to X-Forwarded-For (the chart's ingress);
        # the client address is the entry they added, never one the caller sent.
        self.trusted_proxy_hops = max(0, int(os.getenv("TRUSTED_PROXY_HOPS", "1")))
        self.opsapi_ui_url = os.getenv("OPSAPI_UI_URL", "").rstrip("/")


def create_app(settings: Settings | None = None, transport: httpx.BaseTransport | None = None) -> FastAPI:
    settings = settings or Settings()
    if settings.environment != "sandbox":
        # Test users only exist in HMRC's sandbox; never point this at live HMRC.
        raise RuntimeError("HMRC_ENVIRONMENT must be 'sandbox' for the test-user generator")
    if not settings.access_password and not settings.allow_no_password:
        raise RuntimeError("ACCESS_PASSWORD is required (set ALLOW_NO_PASSWORD=true only on your own machine)")

    app = FastAPI(title="HMRC sandbox test users", docs_url=None, redoc_url=None, openapi_url=None)
    router = APIRouter(prefix=settings.prefix)
    page = (Path(__file__).parent / "index.html").read_text(encoding="utf-8")

    token_lock = threading.Lock()
    token_cache: dict[str, float | str] = {"token": "", "expires": 0.0}
    hits: dict[str, deque] = defaultdict(deque)

    def http() -> httpx.Client:
        return httpx.Client(timeout=30, transport=transport)

    def server_token() -> str:
        """Application-restricted token (client credentials), cached until shortly before expiry."""
        with token_lock:
            if token_cache["token"] and time.time() < float(token_cache["expires"]):
                return str(token_cache["token"])
            with http() as c:
                r = c.post(f"{settings.base_url}/oauth/token", data={
                    "grant_type": "client_credentials",
                    "client_id": settings.client_id,
                    "client_secret": settings.client_secret,
                }, headers={"Content-Type": "application/x-www-form-urlencoded"})
            if r.status_code != 200:
                log.warning("server token refused: HTTP %s", r.status_code)
                raise HTTPException(502, "HMRC refused the application credentials "
                                         f"(HTTP {r.status_code}). Check HMRC_CLIENT_ID / HMRC_CLIENT_SECRET.")
            d = r.json()
            token_cache["token"] = d["access_token"]
            token_cache["expires"] = time.time() + max(60, int(d.get("expires_in", 3600)) - 60)
            return str(token_cache["token"])

    def check_access(request: Request) -> None:
        if not settings.access_password:
            return
        auth = request.headers.get("authorization", "")
        if auth.lower().startswith("basic "):
            try:
                _, _, pw = base64.b64decode(auth[6:]).decode("utf-8").partition(":")
            except Exception:  # noqa: BLE001 - malformed header is just "no access"
                pw = ""
            if hmac.compare_digest(pw.encode(), settings.access_password.encode()):
                return
        raise HTTPException(401, "Sign in to use the test-user generator",
                            headers={"WWW-Authenticate": 'Basic realm="HMRC test users"'})

    def client_ip(request: Request) -> str:
        # The LEFT of X-Forwarded-For is whatever the caller sent; only the entries our own
        # proxies appended (the right-most trusted_proxy_hops) can be believed.
        peer = request.client.host if request.client else "?"
        hops = settings.trusted_proxy_hops
        chain = [p.strip() for p in request.headers.get("x-forwarded-for", "").split(",") if p.strip()]
        if hops == 0 or len(chain) < hops:
            return peer
        return chain[-hops]

    def check_rate(request: Request) -> None:
        ip = client_ip(request)
        now = time.time()
        if len(hits) > 10000:  # bounded memory: drop addresses with no recent requests
            for k in [k for k, v in hits.items() if not v or now - v[-1] > 3600]:
                del hits[k]
        q = hits[ip]
        while q and now - q[0] > 3600:
            q.popleft()
        if len(q) >= settings.rate_limit:
            raise HTTPException(429, f"At most {settings.rate_limit} test users an hour. Try again later.")
        q.append(now)

    @app.get("/healthz")
    def healthz() -> dict:
        return {"ok": True, "configured": bool(settings.client_id and settings.client_secret)}

    @router.get("/", response_class=HTMLResponse)
    def index(request: Request) -> HTMLResponse:
        check_access(request)
        html = (page.replace("__PREFIX__", settings.prefix)
                .replace("__OPSAPI_UI__", settings.opsapi_ui_url or ""))
        return HTMLResponse(html)

    @router.get("/api/services")
    def services(request: Request) -> dict:
        check_access(request)
        out = {}
        for kind, (_, services_, defaults) in KINDS.items():
            out[kind] = [{"key": k, "label": v, "default": k in defaults} for k, v in services_.items()]
        # "services" kept for older pages: the individual list.
        return {"services": out["individual"], "kinds": out}

    @router.post("/api/test-users")
    def create_test_user(request: Request, body: CreateRequest | None = None) -> JSONResponse:
        check_access(request)
        if not (settings.client_id and settings.client_secret):
            raise HTTPException(503, "HMRC_CLIENT_ID / HMRC_CLIENT_SECRET are not set for this app.")
        kind = (body.kind if body and body.kind else "individual")
        if kind not in KINDS:
            raise HTTPException(400, "kind must be individual or organisation")
        path, allowed, defaults = KINDS[kind]
        names = (body.service_names if body and body.service_names else defaults)
        unknown = [n for n in names if n not in allowed]
        if unknown:
            raise HTTPException(400, f"Unknown service(s): {', '.join(unknown)}")
        check_rate(request)

        token = server_token()
        with http() as c:
            r = c.post(f"{settings.base_url}/create-test-user/{path}",
                       json={"serviceNames": names},
                       headers={"Authorization": f"Bearer {token}",
                                "Accept": "application/vnd.hmrc.1.0+json",
                                "Content-Type": "application/json"})
        if r.status_code == 401:
            token_cache["token"] = ""  # token expired early: next request gets a fresh one
        if r.status_code != 201:
            log.warning("create test user failed: HTTP %s", r.status_code)
            try:
                detail = r.json().get("message") or r.text[:300]
            except ValueError:
                detail = r.text[:300]
            raise HTTPException(502, f"HMRC could not create a test user (HTTP {r.status_code}): {detail}")

        d = r.json()
        if kind == "agent":
            log.info("created HMRC sandbox test agent (ARN ending %s)",
                     str(d.get("agentServicesAccountNumber", ""))[-4:])
            return JSONResponse({
                "kind": "agent",
                "user_id": d.get("userId"),
                "password": d.get("password"),
                "arn": d.get("agentServicesAccountNumber"),
                "name": d.get("userFullName"),
                "email": d.get("emailAddress"),
                "service_names": names,
                "sandbox": True,
            }, status_code=201, headers={"Cache-Control": "no-store"})
        if kind == "organisation":
            org = d.get("organisationDetails") or {}
            # Never log the password: only that a business was made, and its VRN tail.
            log.info("created HMRC sandbox test organisation (VRN ending %s)", str(d.get("vrn", ""))[-4:])
            return JSONResponse({
                "kind": "organisation",
                "user_id": d.get("userId"),
                "password": d.get("password"),
                "vrn": d.get("vrn"),
                "ct_utr": d.get("ctUtr"),
                "company_registration_number": d.get("crn"),
                "name": org.get("name") or d.get("userFullName"),
                "email": d.get("emailAddress"),
                "address": org.get("address"),
                "service_names": names,
                "sandbox": True,
            }, status_code=201, headers={"Cache-Control": "no-store"})
        person = d.get("individualDetails") or {}
        # Never log the password: only that a user was made, and its NINO tail.
        log.info("created HMRC sandbox test user (NINO ending %s)", str(d.get("nino", ""))[-4:])
        return JSONResponse({
            "kind": "individual",
            "user_id": d.get("userId"),
            "password": d.get("password"),
            "nino": d.get("nino"),
            "sa_utr": d.get("saUtr"),
            "mtd_it_id": d.get("mtdItId"),
            "name": d.get("userFullName"),
            "email": d.get("emailAddress"),
            "date_of_birth": person.get("dateOfBirth"),
            "address": person.get("address"),
            "service_names": names,
            "sandbox": True,
        }, status_code=201, headers={"Cache-Control": "no-store"})

    app.include_router(router)
    if settings.prefix:
        # Visiting the bare prefix without the trailing slash.
        @app.get(settings.prefix, include_in_schema=False)
        def bare(request: Request) -> HTMLResponse:
            return index(request)
    return app


app = create_app() if os.getenv("HMRC_TEST_USERS_NO_AUTOAPP") != "1" else None

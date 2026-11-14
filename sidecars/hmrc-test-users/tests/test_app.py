"""Tests for the HMRC test-user generator, with HMRC replaced by a mock transport."""

import base64
import os
import secrets
import sys
from pathlib import Path

import httpx
import pytest

os.environ["HMRC_TEST_USERS_NO_AUTOAPP"] = "1"
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from fastapi.testclient import TestClient  # noqa: E402

from app.main import Settings, create_app  # noqa: E402

# Fake values made per run (no credential-shaped literals in the repo).
FAKE_HMRC_PW = secrets.token_hex(6)
FAKE_ACCESS_PW = secrets.token_hex(6)

CREATED = {
    "userId": "945350439195", "password": FAKE_HMRC_PW, "userFullName": "Ida Newton",
    "emailAddress": "ida.newton@example.com", "nino": "NJ070957A", "saUtr": "1097172564",
    "mtdItId": "XJIT00000328268",
    "individualDetails": {"firstName": "Ida", "lastName": "Newton", "dateOfBirth": "1960-06-01",
                          "address": {"line1": "45 Springfield Rise", "line2": "Glasgow", "postcode": "TS1 1PA"}},
}


def settings(**over):
    s = Settings()
    s.environment, s.client_id, s.client_secret = "sandbox", "cid", "csecret"
    s.base_url, s.prefix, s.access_password, s.rate_limit = "https://hmrc.test", "/hmrc-test-users", "", 20
    for k, v in over.items():
        setattr(s, k, v)
    return s


class Hmrc:
    """Mock HMRC: records calls and answers token + create-test-user."""

    def __init__(self, create_status=201):
        self.calls = []
        self.create_status = create_status

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.calls.append(request)
        if request.url.path == "/oauth/token":
            body = request.content.decode()
            assert "grant_type=client_credentials" in body and "client_id=cid" in body
            return httpx.Response(200, json={"access_token": "srv-token", "expires_in": 14400})
        if request.url.path == "/create-test-user/individuals":
            assert request.headers["authorization"] == "Bearer srv-token"
            assert request.headers["accept"] == "application/vnd.hmrc.1.0+json"
            if self.create_status != 201:
                return httpx.Response(self.create_status, json={"message": "nope"})
            return httpx.Response(201, json=CREATED)
        return httpx.Response(404)


def client(hmrc, **over):
    return TestClient(create_app(settings(**over), transport=httpx.MockTransport(hmrc)))


def test_refuses_production():
    with pytest.raises(RuntimeError):
        create_app(settings(environment="production"))


def test_creates_a_test_user_with_mtd_enrolments():
    hmrc = Hmrc()
    r = client(hmrc).post("/hmrc-test-users/api/test-users", json={})
    assert r.status_code == 201
    d = r.json()
    assert (d["user_id"], d["password"], d["nino"], d["sa_utr"], d["mtd_it_id"]) == (
        "945350439195", FAKE_HMRC_PW, "NJ070957A", "1097172564", "XJIT00000328268")
    assert d["date_of_birth"] == "1960-06-01"
    assert r.headers["cache-control"] == "no-store"
    import json
    sent = json.loads(hmrc.calls[-1].content)
    assert sent == {"serviceNames": ["national-insurance", "self-assessment", "mtd-income-tax"]}


def test_server_token_is_cached():
    hmrc = Hmrc()
    c = client(hmrc)
    c.post("/hmrc-test-users/api/test-users", json={})
    c.post("/hmrc-test-users/api/test-users", json={})
    assert [r.url.path for r in hmrc.calls].count("/oauth/token") == 1


def test_unknown_service_is_refused_before_calling_hmrc():
    hmrc = Hmrc()
    r = client(hmrc).post("/hmrc-test-users/api/test-users", json={"service_names": ["mtd-vat", "x"]})
    assert r.status_code == 400 and hmrc.calls == []


def test_hmrc_error_is_reported():
    r = client(Hmrc(create_status=403)).post("/hmrc-test-users/api/test-users", json={})
    assert r.status_code == 502 and "HTTP 403" in r.json()["detail"]


def test_basic_auth_when_password_set():
    c = client(Hmrc(), access_password=FAKE_ACCESS_PW)
    assert c.get("/hmrc-test-users/").status_code == 401
    assert c.post("/hmrc-test-users/api/test-users", json={}).status_code == 401
    good = {"Authorization": "Basic " + base64.b64encode(("tester:" + FAKE_ACCESS_PW).encode()).decode()}
    bad = {"Authorization": "Basic " + base64.b64encode(b"tester:nope").decode()}
    assert c.get("/hmrc-test-users/", headers=bad).status_code == 401
    assert c.get("/hmrc-test-users/", headers=good).status_code == 200
    assert c.post("/hmrc-test-users/api/test-users", json={}, headers=good).status_code == 201


def test_rate_limit():
    c = client(Hmrc(), rate_limit=2)
    codes = [c.post("/hmrc-test-users/api/test-users", json={}).status_code for _ in range(3)]
    assert codes == [201, 201, 429]


def test_page_and_health():
    c = client(Hmrc())
    page = c.get("/hmrc-test-users/")
    assert page.status_code == 200 and 'const PREFIX = "/hmrc-test-users"' in page.text
    assert c.get("/hmrc-test-users").status_code == 200
    assert c.get("/healthz").json() == {"ok": True, "configured": True}


def test_missing_credentials():
    r = client(Hmrc(), client_id="").post("/hmrc-test-users/api/test-users", json={})
    assert r.status_code == 503

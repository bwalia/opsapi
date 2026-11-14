# HMRC sandbox test-user generator

A small side app deployed next to OpsAPI in its own pod. Testers press one
button and get a fresh HMRC **sandbox** taxpayer to test File My Tax end to end:

- Government Gateway **user ID + password**, used on HMRC's sign-in page when connecting;
- **NINO**, which goes in File My Tax;
- SA UTR, MTD IT ID, name, date of birth and address.

It ports the test-user flow from diy-tax-return-uk's `hmrc-mtd-sample-app-sandbox`:

1. a client-credentials grant with the OpsAPI HMRC sandbox application gets a server token;
2. `POST /create-test-user/individuals` (Create Test User API 1.0) is called with
   `national-insurance`, `self-assessment` and `mtd-income-tax`.

The app refuses to start unless `HMRC_ENVIRONMENT=sandbox`. The password is shown once and never stored or logged.

## Where it runs

- **int:** https://int-opsapi.workstation.co.uk/hmrc-test-users
  - Sign in with any user name and the `ACCESS_PASSWORD` in Secret
    `workstation-opsapi-hmrc-test-users`, namespace `int`.
- **Chart:** `devops/helm-charts/diytaxreturn-lapis/templates/hmrc-test-users.yaml`.
  - Turn it on per environment with `hmrcTestUsers.enabled`.
  - It reuses `hmrcCredentialsSecret`; the HMRC app it points at must be a sandbox app.
- **Image:** `bwalia/opsapi-hmrc-test-users`.
  - Built by `.github/workflows/hmrc-test-users.yml` on changes to this folder.
  - That workflow also restarts the int pod.

## API

| Method | Path | |
|---|---|---|
| GET | `/hmrc-test-users/` | the page |
| GET | `/hmrc-test-users/api/services` | enrolments that can be chosen |
| POST | `/hmrc-test-users/api/test-users` | `{"service_names": [...]}` (optional) → 201 with the credentials |
| GET | `/healthz` | liveness/readiness |

The POST is limited per IP (`RATE_LIMIT_PER_HOUR`, default 20) because every test
user is created with OpsAPI's HMRC application.

## Environment

| Variable | |
|---|---|
| `HMRC_CLIENT_ID`, `HMRC_CLIENT_SECRET` | HMRC sandbox application |
| `HMRC_ENVIRONMENT` | must be `sandbox` |
| `ROOT_PATH` | path prefix it is served under (chart: `/hmrc-test-users`) |
| `ACCESS_PASSWORD` | optional HTTP Basic password for the page and API |
| `RATE_LIMIT_PER_HOUR` | default 20 |
| `OPSAPI_UI_URL` | optional link back to File My Tax |

## Local run and tests

```bash
cd sidecars/hmrc-test-users
pip install -r requirements-dev.txt && python -m pytest -q tests
HMRC_CLIENT_ID=... HMRC_CLIENT_SECRET=... ROOT_PATH=/hmrc-test-users \
  uvicorn app.main:app --port 8080     # http://localhost:8080/hmrc-test-users/
```

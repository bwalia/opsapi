# OpsAPI

Multi-tenant API platform built on OpenResty Nginx/Lua/PostgreSQL (OLP Stack). Lua runs directly inside Nginx workers — no CGI overhead, Unix-socket-grade performance.

## Components

- **OpsAPI (Backend)** — Lapis/Lua API server with JWT auth, RBAC, multi-tenancy
- **OpsAPI Dashboard** — Next.js admin dashboard (port 8039)
- **OpsAPI Node** — Node.js service for file uploads (optional)

---

## Quick Start (Local Development)

### Prerequisites

1. **Docker Desktop** — Download and install from https://www.docker.com/products/docker-desktop/
   - After installing, **open Docker Desktop** and wait until it shows "Docker Desktop is running" (green icon in the system tray/menu bar)
   - Docker Compose is included with Docker Desktop
2. **Git** — Download from https://git-scm.com/downloads

### Step 1: Clone the repository

```bash
git clone https://github.com/bwalia/opsapi.git
cd opsapi
```

### Step 2: Create the environment file

```bash
cp lapis/.sample.env lapis/.env
```

This copies a pre-configured environment file with working defaults. **No editing needed** — it works out of the box for local development.

### Step 3: Make the start script executable

```bash
chmod +x start.sh
```

### Step 4: Start everything

```bash
./start.sh -e local -n -j all
```

**What this does:**
- `-e local` — sets up for local development (http://127.0.0.1:4010)
- `-n` — skips git operations (stash/pull) since you just cloned
- `-j all` — creates all database tables

**The first run takes 3-5 minutes** as Docker downloads images and builds containers. Subsequent runs are much faster.

**Note:** Near the end, the script updates your `/etc/hosts` file and will ask for your **computer password** (sudo). This is safe — it just adds `127.0.0.1 opsapi-dev.local` so you can access the API at http://opsapi-dev.local:4010.

### Step 5: Verify it's working

Once the script finishes, open these URLs in your browser:

| Service | URL |
|---------|-----|
| **Backend API** | http://127.0.0.1:4010/health |
| **Dashboard** | http://127.0.0.1:8039 |
| **API Docs (Swagger)** | http://127.0.0.1:4010/swagger |

You should see the health check return `{"status":"ok"}` and the dashboard load a login page.

### Step 6: Log in

Use these credentials on the Dashboard (http://127.0.0.1:8039) or for API calls:

```
Email:    admin@opsapi.com
Password: Admin@123
```

These are the defaults created by `start.sh`. You can customise them — see [Custom Admin Credentials](#custom-admin-credentials) below.

### All Service URLs and Logins

| Service | URL | Login |
|---------|-----|-------|
| **Backend API** | http://127.0.0.1:4010 | See above |
| **Dashboard** | http://127.0.0.1:8039 | See above |
| **Swagger Docs** | http://127.0.0.1:4010/swagger | No login needed |
| **Adminer (DB browser)** | http://127.0.0.1:7779 | System: `PostgreSQL`, Server: `postgres`, User: `pguser`, Password: `pgpassword`, Database: `opsapi` |
| **MinIO Console (files)** | http://127.0.0.1:9001 | User: `minioadmin`, Password: `minioadmin123` |
| **Grafana (monitoring)** | http://127.0.0.1:3011 | User: `admin`, Password: `admin` |
| **Prometheus (metrics)** | http://127.0.0.1:9090 | No login needed |
| **Gatus (health status)** | http://127.0.0.1:8888 | No login needed |

### Common Issues

**"Permission denied" when running start.sh:**
```bash
chmod +x start.sh
```

**"Cannot connect to the Docker daemon":**
Open Docker Desktop and wait for it to fully start (green icon).

**Port already in use (e.g. port 4010, 5439, 9000):**
Another application is using that port. Stop it, or change the port in `lapis/docker-compose.yml`.

**Script asks for password:**
This is your computer password (sudo) — it's adding a hostname entry to `/etc/hosts`. This is normal and safe.

### Custom Admin Credentials

```bash
./start.sh -e local -n -j all \
  -A admin@mycompany.com -W MySecurePassword123
```

### Project-Specific Setup

If you're working on a specific project, use its project code to only create the tables you need:

```bash
# UK Tax Return project
./start.sh -e local -n -j tax_copilot

# E-commerce project
./start.sh -e local -n -j ecommerce
```

### Stopping and Restarting

```bash
# Stop all containers
cd lapis && docker compose down

# Restart (fast — no rebuild)
cd lapis && docker compose up -d

# Restart with rebuild (after code changes)
./start.sh -e local -n -j all

# Full reset — wipes database and starts fresh
./start.sh -e local -n -j all -r
```

---

## start.sh Reference

The `start.sh` script handles the full setup: environment config, Docker build, migrations, namespace seeding, and /etc/hosts entry.

### All Options

| Flag | Description | Default |
|------|-------------|---------|
| `-e, --env ENV` | Target environment (`local`/`dev`/`test`/`acc`/`prod`/`remote` or any custom name) | Interactive prompt |
| `-d, --domain DOMAIN` | Apex domain | `wslcrm.com` |
| `-P, --protocol PROTO` | API protocol (`http`/`https`) | `http` for local, `https` for others |
| `-j, --project CODE` | Project code for conditional migrations | `all` |
| `-A, --admin-email EMAIL` | Super admin email for namespace setup | `admin@opsapi.com` |
| `-W, --admin-password PWD` | Super admin password | `Admin@123` |
| `-N, --namespace-name NAME` | Custom namespace name | Derived from project code |
| `-S, --namespace-slug SLUG` | Custom namespace slug | Derived from project code |
| `-s, --stash y/n` | Git stash option | Interactive prompt |
| `-p, --pull y/n` | Git pull option | Interactive prompt |
| `-a, --auto` | Auto mode: stash=y, pull=y (no prompts) | — |
| `-n, --no-git` | Skip all git operations | — |
| `-r, --reset-db` | Reset database (removes Docker volumes — **destructive**) | `false` |
| `-c, --check-env` | Only check/update `.env`, don't start containers | — |
| `-C, --ci` | CI/CD mode: uses `docker-compose.ci.yml` (no dev volume mounts) | — |
| `-h, --help` | Show help | — |

### Project Codes

| Code | Description |
|------|-------------|
| `all` | All features (default, backward compatible) |
| `tax_copilot` | UK Tax Return AI Agent (core + tax tables) |
| `ecommerce` | E-commerce platform (core + stores, products, orders) |
| `collaboration` | Chat + Kanban + Services |
| `hospital` | Hospital CRM |
| `core_only` | Just authentication tables |

### Environments

**Preset:**

| Environment | API URL |
|-------------|---------|
| `local` | `http://127.0.0.1:4010` |
| `dev` | `https://dev-api.{domain}` |
| `test` | `https://test-api.{domain}` |
| `acc` | `https://acc-api.{domain}` |
| `prod` | `https://api.{domain}` |
| `remote` | `https://remote-api.{domain}` |

**Custom:** Any name generates `https://{name}-api.{domain}` (e.g. `-e staging` → `https://staging-api.wslcrm.com`).

### Examples

```bash
# Local dev, no git ops, all features
./start.sh -e local -n

# Local dev, tax project, fresh database
./start.sh -e local -n -j tax_copilot -r

# Local dev, custom admin + namespace
./start.sh -e local -n -j tax_copilot \
  -A admin@mycompany.com -W SecurePass123 \
  -N "My Company" -S my-company

# Dev environment, auto git (stash + pull)
./start.sh -e dev -a -j all

# Custom domain
./start.sh -e dev -d myapp.com -a

# Just check .env URLs (don't start containers)
./start.sh -c -e dev

# CI/CD deployment
./start.sh -e remote -n -C -j all

# Full reset — wipes database
./start.sh -e local -n -r
```

### What start.sh Does

1. Selects environment and configures API URLs in `lapis/.env`
2. Optionally stashes/pulls git changes
3. Creates required directories (`lapis/logs`, `lapis/pgdata`, `lapis/keycloak_data`)
4. Builds and starts Docker containers (`docker compose up --build -d`)
5. Waits for PostgreSQL and OpsAPI to be healthy
6. Runs database migrations (`lapis migrate`) with project code
7. Runs namespace setup script (creates admin user, namespace, default roles, modules)
8. Adds `opsapi-dev.local` to `/etc/hosts` (requires sudo)

---

## Environment Variables

All environment variables are in `lapis/.env`. The `.sample.env` file has working defaults for local dev.

### Required

| Variable | Description | Local Default |
|----------|-------------|---------------|
| `POSTGRES_HOST` | PostgreSQL host | `172.71.0.10` |
| `POSTGRES_PORT` | PostgreSQL port | `5432` |
| `POSTGRES_USER` | Database user | `pguser` |
| `POSTGRES_PASSWORD` | Database password | `pgpassword` |
| `POSTGRES_DB` | Database name | `opsapi` |
| `JWT_SECRET_KEY` | JWT signing secret | Set in `.sample.env` |
| `OPENSSL_SECRET_KEY` | AES-128 encryption key (32 hex chars) | Set in `.sample.env` |
| `OPENSSL_SECRET_IV` | AES-128 encryption IV (32 hex chars) | Set in `.sample.env` |
| `MINIO_ENDPOINT` | MinIO S3 endpoint | `http://172.71.0.17:9000` |
| `MINIO_ACCESS_KEY` | MinIO access key | `minioadmin` |
| `MINIO_SECRET_KEY` | MinIO secret key | `minioadmin123` |
| `MINIO_BUCKET` | Default bucket | `opsapi` |
| `NEXT_PUBLIC_API_URL` | API URL (auto-set by `start.sh`) | `http://127.0.0.1:4010` |

### Optional

| Variable | Description |
|----------|-------------|
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | Google OAuth credentials |
| `GOOGLE_REDIRECT_URI` | Google OAuth callback (auto-set by `start.sh`) |
| `KEYCLOAK_*` | Keycloak SSO configuration |
| `STRIPE_SECRET_KEY` / `STRIPE_PUBLISHABLE_KEY` / `STRIPE_WEBHOOK_SECRET` | Stripe payments |
| `CORS_ALLOWED_DOMAINS` | Comma-separated domains (allows subdomains + any port) |
| `CORS_ALLOWED_ORIGINS` | Comma-separated explicit origin URLs |
| `NODE_API_URL` | Node.js service URL |
| `OPSAPI_SSL_VERIFY` | SSL verification for external calls (`true`/`false`) |

**Note:** `NEXT_PUBLIC_API_URL` is a build-time variable for the Next.js dashboard. If changed after initial build, rebuild with:

```bash
cd lapis && docker compose build --no-cache dashboard && docker compose up -d dashboard
```

---

## Troubleshooting

### Check container logs

```bash
# API error logs
docker exec -i opsapi tail -50 /var/log/nginx/error.log

# Container logs
docker logs opsapi
docker logs opsapi-postgres-dev-db
```

### Restart the API

```bash
cd lapis && docker compose restart lapis
```

### Re-run migrations

```bash
docker exec -e "PROJECT_CODE=all" -it opsapi lapis migrate
```

### Test login from inside the container

```bash
docker exec -i opsapi curl -s -X POST 'http://127.0.0.1/auth/login' \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin@opsapi.com","password":"Admin@123"}'
```

### Test API with token

```bash
TOKEN=$(docker exec -i opsapi curl -s -X POST 'http://127.0.0.1/auth/login' \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin@opsapi.com","password":"Admin@123"}' | jq -r '.token')

docker exec -i opsapi curl -s "http://127.0.0.1/api/v2/users" -H "Authorization: Bearer $TOKEN"
```

### Check database

```bash
docker exec -i opsapi-postgres-dev-db psql -U pguser -d opsapi -c "\dt"
```

### Dashboard not updating after API URL change

```bash
cd lapis && docker compose build --no-cache dashboard && docker compose up -d dashboard
```

### Full reset (wipes all data)

```bash
./start.sh -e local -n -r
```

Or manually:

```bash
cd lapis && docker compose down --volumes && docker compose up --build -d
sleep 15
docker exec -e "PROJECT_CODE=all" -it opsapi lapis migrate
```

---

## API Documentation

- **Swagger UI:** http://127.0.0.1:4010/swagger
- **OpenAPI JSON:** http://127.0.0.1:4010/openapi.json

### Public Endpoints (No Auth)

| Endpoint | Description |
|----------|-------------|
| `GET /health` | Health check |
| `GET /swagger` | API documentation |
| `GET /metrics` | Prometheus metrics |
| `POST /auth/login` | Login (returns JWT) |
| `POST /api/v2/register` | User registration |

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                    Docker Network (172.71.0.0/16)             │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │   OpsAPI    │    │  Dashboard  │    │  PostgreSQL │     │
│  │   (Lapis)   │    │  (Next.js)  │    │  (pgvector) │     │
│  │ 172.71.0.12 │    │ 172.71.0.19 │    │ 172.71.0.10 │     │
│  │   :4010     │    │   :8039     │    │   :5439     │     │
│  └─────────────┘    └─────────────┘    └─────────────┘     │
│                                                              │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │    Redis    │    │    MinIO    │    │   Grafana   │     │
│  │ 172.71.0.13 │    │ 172.71.0.17 │    │ 172.71.0.16 │     │
│  │   :6373     │    │ :9000/:9001 │    │   :3011     │     │
│  └─────────────┘    └─────────────┘    └─────────────┘     │
│                                                              │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │ Prometheus  │    │   Adminer   │    │   Gatus     │     │
│  │ 172.71.0.15 │    │             │    │ 172.71.0.18 │     │
│  │   :9090     │    │   :7779     │    │   :8888     │     │
│  └─────────────┘    └─────────────┘    └─────────────┘     │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## Deployment

### GitHub Actions (Self-Hosted Runner)

Deploy using Docker Compose on a self-hosted runner.

**Trigger:** Actions → Deploy OpsAPI via Docker Compose (Self-Hosted) → Run workflow

| Option | Description | Default |
|--------|-------------|---------|
| `TARGET_ENV` | Preset environment | `remote` |
| `CUSTOM_ENV` | Custom environment name (overrides TARGET_ENV) | — |
| `PROTOCOL` | API protocol | `https` |
| `RESET_DB` | Reset database | `false` |
| `RUN_MIGRATIONS` | Run migrations after deploy | `true` |
| `PULL_LATEST` | Pull latest code | `true` |
| `RUNNER_LABEL` | Self-hosted runner label | `self-hosted` |
| `ENV_FILE_CONTENT` | Base64-encoded `.env` content | — |
| `SLACK_WEBHOOK_URL` | Slack webhook for notifications | — |

### Kubernetes

#### OpsAPI

```bash
# 1. Create sealed secret from env vars
kubeseal --format=yaml < secret.yaml > sealed-secret.yaml

# 2. Deploy with Helm
helm upgrade --install opsapi ./devops/helm-charts/opsapi \
  -f ./devops/helm-charts/opsapi/values-<namespace>.yaml \
  --set image.repository=bwalia/opsapi \
  --set image.tag=latest \
  --namespace <namespace> --create-namespace
```

#### OpsAPI Node

```bash
# 1. Create sealed secret
cat node/opsapi-node/.env | kubectl create secret generic node-app-env \
  --dry-run=client --from-file=.env=/dev/stdin -o json \
  | kubeseal --format yaml --namespace <namespace>

# 2. Deploy with Helm
helm upgrade --install opsapi-node ./devops/helm-charts/opsapi-node \
  -f ./devops/helm-charts/opsapi-node/values-<namespace>.yaml \
  --set image.repository=bwalia/opsapi-node \
  --set image.tag=latest \
  --namespace <namespace> --create-namespace
```

---

## Google OAuth Setup

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create/select a project → Enable Google+ API
3. Create OAuth 2.0 credentials
4. Add authorized redirect URI: `http://127.0.0.1:4010/auth/google/callback`
5. Update `lapis/.env`:

```bash
GOOGLE_CLIENT_ID=your-client-id
GOOGLE_CLIENT_SECRET=your-client-secret
GOOGLE_REDIRECT_URI=http://127.0.0.1:4010/auth/google/callback
```

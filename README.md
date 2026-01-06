# OPSAPI

Opsapi API is built on the top of Opneresty Nginx / Lua for increased performance and reliability

## Opneresty Nginx / Lua / Postgres - or you may refer it as `OLP Stack`

## Avoids Nginx to CGI resource consumption as lua is compiled to work directly with Nginx Workers

## OpsAPI is Simple and allows Developers to create Database API right from the begining (Batteries included)

## Nginx is highly scalable and reliable and idea of OPSAPI is to make OLP stack nginx/lua/postgres to work together think Unix sockets to have very high performance

## Native applications can just run on a single instance linux OS recommended using Unix sockets (highly recommended for production and securing database api)

## If run as containerised stack the Dockerfile is highly optimised for performance

## Status by Gatus

### Check `http://localhost:8888/`

## Components

- **OPSAPI (Backend)**: Lua-based API server with authentication and ecommerce functionality
- **OPSAPI Dashboard**: Next.js admin dashboard for managing the platform
- **OPSAPI Node**: Node.js service for file uploads and additional features

---

## Run OPSAPI Locally (Quick Start)

### Requirements

- Docker
- Docker Compose

### Installation

1. **Clone the repository and navigate to the project root:**

   ```bash
   cd opsapi
   ```

2. **Configure environment variables:**

   Copy the sample environment file and update with your values:

   ```bash
   cp lapis/.sample.env lapis/.env
   ```

   Edit `lapis/.env` with your configuration. See [Environment Variables](#environment-variables) section for details.

3. **Run the development script:**

   ```bash
   ./run-development.sh
   ```

   This script will:

   - Prompt for target environment (or use `-e` flag)
   - Validate and update environment-specific URLs in `.env`
   - Optionally stash uncommitted changes
   - Optionally pull latest changes from git
   - Create necessary directories (logs, pgdata, keycloak_data)
   - Start all Docker services with fresh volumes
   - Wait for services to be ready
   - Run database migrations
   - Configure local hostname (opsapi-dev.local)

   **Environment Selection:**

   The script supports multiple deployment environments with automatic URL configuration:

   **Preset Environments:**

   | Environment | API URL |
   |-------------|---------|
   | `local` | `http://localhost:4010` |
   | `dev` | `https://dev-api.wslcrm.com` |
   | `test` | `https://test-api.wslcrm.com` |
   | `acc` | `https://acc-api.wslcrm.com` |
   | `prod` | `https://api.wslcrm.com` |
   | `remote` | `https://remote-api.wslcrm.com` |

   **Dynamic Environments:**

   You can also use any custom environment name. The script will automatically generate the API URL using the pattern `https://<name>-api.wslcrm.com`:

   | Custom Environment | Generated API URL |
   |-------------------|-------------------|
   | `staging` | `https://staging-api.wslcrm.com` |
   | `demo` | `https://demo-api.wslcrm.com` |
   | `feature-x` | `https://feature-x-api.wslcrm.com` |
   | `my_custom_env` | `https://my_custom_env-api.wslcrm.com` |

   Environment names must start with a letter and can contain letters, numbers, hyphens, or underscores.

   The script automatically validates and updates these environment variables in `lapis/.env`:
   - `NEXT_PUBLIC_API_URL` - API base URL
   - `GOOGLE_REDIRECT_URI` - Google OAuth callback URL
   - `KEYCLOAK_REDIRECT_URI` - Keycloak SSO callback URL

   **Command-line options:**

   ```bash
   # Interactive mode (default - prompts for environment, protocol, and git options)
   ./run-development.sh

   # Specify preset environment directly
   ./run-development.sh -e local           # Local development (http://localhost:4010)
   ./run-development.sh -e dev             # Dev environment (https://dev-api.wslcrm.com)
   ./run-development.sh -e test            # Test environment
   ./run-development.sh -e acc             # Acceptance environment
   ./run-development.sh -e prod            # Production environment
   ./run-development.sh -e remote          # Remote environment
   ./run-development.sh --env=dev          # Alternative syntax

   # Use custom/dynamic environments
   ./run-development.sh -e staging         # https://staging-api.wslcrm.com
   ./run-development.sh -e demo            # https://demo-api.wslcrm.com
   ./run-development.sh -e feature-x       # https://feature-x-api.wslcrm.com

   # Specify protocol (http or https)
   ./run-development.sh -e dev -P http     # Dev env with HTTP: http://dev-api.wslcrm.com
   ./run-development.sh -e dev -P https    # Dev env with HTTPS (default)
   ./run-development.sh -e local -P https  # Local with HTTPS: https://localhost:4010
   ./run-development.sh --protocol=http    # Alternative syntax

   # Combined with git options
   ./run-development.sh -e dev -a          # Dev env, auto git (stash + pull)
   ./run-development.sh -e remote -n       # Remote env, no git operations
   ./run-development.sh -e staging -a      # Custom staging env, auto git
   ./run-development.sh -e dev -P http -a  # Dev with HTTP, auto git

   # Check/update .env only (don't start containers)
   ./run-development.sh -c -e dev          # Just validate .env for dev
   ./run-development.sh -c -e dev -P http  # Validate with HTTP protocol

   # Reset database (removes volumes)
   ./run-development.sh -e local -r        # Local with fresh database

   # Auto mode - stash and pull without prompts
   ./run-development.sh -a
   ./run-development.sh --auto

   # Skip all git operations
   ./run-development.sh -n
   ./run-development.sh --no-git

   # Specify git options individually
   ./run-development.sh -s y -p y          # Stash: yes, Pull: yes
   ./run-development.sh -s n -p y          # No stash, Pull: yes
   ./run-development.sh --stash=y --pull=n

   # Show help
   ./run-development.sh -h
   ```

   | Option | Description |
   |--------|-------------|
   | `-e ENV` / `--env ENV` | Target environment (local/dev/test/acc/prod/remote or any custom name) |
   | `-P PROTO` / `--protocol PROTO` | API protocol (http or https). Default: http for local, https for others |
   | `-c` / `--check-env` | Only check/update .env, don't start containers |
   | `-s y` / `--stash y` | Stash uncommitted changes |
   | `-s n` / `--stash n` | Skip stashing |
   | `-p y` / `--pull y` | Pull latest from git |
   | `-p n` / `--pull n` | Skip pull |
   | `-a` / `--auto` | Auto mode (stash=y, pull=y) |
   | `-n` / `--no-git` | No git operations |
   | `-r` / `--reset-db` | Reset database (removes volumes) |
   | `-h` / `--help` | Show help |

4. **Access the application:**
   - **Backend API**: http://localhost:4010
   - **Dashboard**: http://localhost:8039
   - **Adminer (DB UI)**: http://localhost:7779
   - **Grafana**: http://localhost:3011
   - **Prometheus**: http://localhost:9090
   - **MinIO Console**: http://localhost:9001
   - **Gatus (Status)**: http://localhost:8888

### Default Login Credentials

```
Email: administrative@admin.com
Password: Admin@123
```

---

## Environment Variables

All environment variables are configured in `lapis/.env`. Here are the key variables:

### Database

```bash
DB_HOST=172.71.0.10           # Docker network IP for postgres
DB_PORT=5432
DB_USER=pguser
DB_PASSWORD=pgpassword
DATABASE=opsapi
```

### JWT & Encryption

```bash
JWT_SECRET_KEY=your-jwt-secret-key
OPENSSL_SECRET_KEY=your-16-char-key
OPENSSL_SECRET_IV=your-16-char-iv
```

### MinIO (S3-compatible Storage)

```bash
MINIO_ENDPOINT=your-minio-endpoint
MINIO_ACCESS_KEY=your-access-key
MINIO_SECRET_KEY=your-secret-key
MINIO_BUCKET=your-bucket
MINIO_REGION=your-region
```

### Dashboard & Authentication URLs

These URLs are environment-specific and are automatically configured by `run-development.sh`:

```bash
# For local development
NEXT_PUBLIC_API_URL=http://localhost:4010
GOOGLE_REDIRECT_URI=http://localhost:4010/auth/google/callback
KEYCLOAK_REDIRECT_URI=http://localhost:4010/auth/callback

# For dev environment
NEXT_PUBLIC_API_URL=https://dev-api.wslcrm.com
GOOGLE_REDIRECT_URI=https://dev-api.wslcrm.com/auth/google/callback
KEYCLOAK_REDIRECT_URI=https://dev-api.wslcrm.com/auth/callback

# For test environment
NEXT_PUBLIC_API_URL=https://test-api.wslcrm.com
GOOGLE_REDIRECT_URI=https://test-api.wslcrm.com/auth/google/callback
KEYCLOAK_REDIRECT_URI=https://test-api.wslcrm.com/auth/callback

# For production
NEXT_PUBLIC_API_URL=https://api.wslcrm.com
GOOGLE_REDIRECT_URI=https://api.wslcrm.com/auth/google/callback
KEYCLOAK_REDIRECT_URI=https://api.wslcrm.com/auth/callback

# For remote environment
NEXT_PUBLIC_API_URL=https://remote-api.wslcrm.com
GOOGLE_REDIRECT_URI=https://remote-api.wslcrm.com/auth/google/callback
KEYCLOAK_REDIRECT_URI=https://remote-api.wslcrm.com/auth/callback

# For custom environments (e.g., staging)
NEXT_PUBLIC_API_URL=https://staging-api.wslcrm.com
GOOGLE_REDIRECT_URI=https://staging-api.wslcrm.com/auth/google/callback
KEYCLOAK_REDIRECT_URI=https://staging-api.wslcrm.com/auth/callback
```

**Tip:** Use `./run-development.sh -c -e <env>` to check and update these URLs without starting containers. Works with both preset environments (local, dev, test, acc, prod, remote) and custom environment names (staging, demo, etc.).

**Protocol Customization:** By default, `local` uses `http://` and all other environments use `https://`. You can override this with the `-P` option:
```bash
./run-development.sh -e dev -P http    # Use HTTP for dev: http://dev-api.wslcrm.com
./run-development.sh -e local -P https # Use HTTPS for local: https://localhost:4010
```

**Important:** `NEXT_PUBLIC_API_URL` is a build-time variable for the Next.js dashboard. If you change this value, you must rebuild the dashboard with:

```bash
docker compose build --no-cache dashboard
docker compose up -d dashboard
```

### Stripe (Optional)

```bash
STRIPE_SECRET_KEY=sk_test_...
STRIPE_PUBLISHABLE_KEY=pk_test_...
STRIPE_WEBHOOK_SECRET=whsec_...
```

### Google OAuth (Optional)

```bash
GOOGLE_CLIENT_ID=your-google-client-id
GOOGLE_CLIENT_SECRET=your-google-client-secret
GOOGLE_REDIRECT_URI=http://localhost:4010/auth/google/callback
```

### Keycloak SSO (Optional)

```bash
KEYCLOAK_AUTH_URL=https://your-keycloak/realms/opsapi/protocol/openid-connect/auth
KEYCLOAK_TOKEN_URL=https://your-keycloak/realms/opsapi/protocol/openid-connect/token
KEYCLOAK_USERINFO_URL=https://your-keycloak/realms/opsapi/protocol/openid-connect/userinfo
KEYCLOAK_CLIENT_ID=opsapi
KEYCLOAK_CLIENT_SECRET=your-client-secret
KEYCLOAK_REDIRECT_URI=http://localhost:4010/auth/callback
```

### Node API

```bash
NODE_API_URL=http://172.71.0.14/api
```

---

## Troubleshooting

### Restart the API container

```bash
cd lapis
docker compose restart lapis
```

### Check logs

```bash
docker exec -i opsapi tail -50 /var/log/nginx/error.log
```

### Test login

```bash
docker exec -i opsapi curl -s -X POST 'http://localhost/auth/login' \
  -H 'Content-Type: application/json' \
  -d '{"username":"administrative@admin.com","password":"Admin@123"}'
```

### Test API with token

```bash
TOKEN=$(docker exec -i opsapi curl -s -X POST 'http://localhost/auth/login' \
  -H 'Content-Type: application/json' \
  -d '{"username":"administrative@admin.com","password":"Admin@123"}' | jq -r '.token')

# Test endpoints
docker exec -i opsapi curl -s "http://localhost/api/v2/users" -H "Authorization: Bearer $TOKEN"
docker exec -i opsapi curl -s "http://localhost/api/v2/roles" -H "Authorization: Bearer $TOKEN"
```

### Check database connectivity

```bash
docker exec -i opsapi psql -h 172.71.0.10 -U pguser -d opsapi -c "\dt"
# Password: pgpassword
```

### Dashboard not reflecting API URL changes

If you changed `NEXT_PUBLIC_API_URL` in `.env` but the dashboard still uses the old value:

```bash
cd lapis
docker compose build --no-cache dashboard
docker compose up -d dashboard
```

### Re-run migrations

```bash
docker exec -it opsapi lapis migrate
```

### Full reset (fresh start)

```bash
cd lapis
docker compose down --volumes
docker compose up --build -d
sleep 15
docker exec -it opsapi lapis migrate
```

---

## Deploy via GitHub Actions (Self-Hosted Runner)

Deploy OPSAPI to a self-hosted runner using Docker Compose. This mirrors the `run-development.sh` script functionality for automated CI/CD deployments.

### Prerequisites

1. Self-hosted GitHub Actions runner configured
2. Docker and Docker Compose installed on the runner
3. `.env` file pre-configured on the runner (or pass via workflow input)

### Triggering the Workflow

Go to **Actions** → **Deploy OPSAPI via Docker Compose (Self-Hosted)** → **Run workflow**

### Workflow Options

| Option | Description | Default |
|--------|-------------|---------|
| `TARGET_ENV` | Preset environment (local/dev/test/acc/prod/remote) | `remote` |
| `CUSTOM_ENV` | Custom environment name (overrides TARGET_ENV) | - |
| `PROTOCOL` | API protocol (http/https) | `https` |
| `RESET_DB` | Reset database (removes volumes) | `false` |
| `RUN_MIGRATIONS` | Run database migrations after deployment | `true` |
| `PULL_LATEST` | Pull latest code before deploying | `true` |
| `RUNNER_LABEL` | Self-hosted runner label | `self-hosted` |
| `ENV_FILE_CONTENT` | Base64 encoded .env file content (optional) | - |
| `SLACK_WEBHOOK_URL` | Slack webhook for notifications (optional) | - |

### Example Usage

**Deploy to remote environment (default):**
```
TARGET_ENV: remote
PROTOCOL: https
```

**Deploy to custom staging environment:**
```
CUSTOM_ENV: staging
PROTOCOL: https
```
This generates API URL: `https://staging-api.wslcrm.com`

**Deploy with database reset (use with caution):**
```
TARGET_ENV: dev
RESET_DB: true
RUN_MIGRATIONS: true
```

**Deploy with custom .env file:**
```bash
# Encode your .env file
cat lapis/.env | base64 -w0

# Paste the output in ENV_FILE_CONTENT input
```

### What the Workflow Does

1. Checks out the repository code
2. Optionally pulls latest changes
3. Updates `.env` file with environment-specific URLs
4. Creates required directories (logs, pgdata, keycloak_data)
5. Stops existing Docker containers
6. Builds and starts containers with `docker compose up --build -d`
7. Runs database migrations (if enabled)
8. Verifies deployment health
9. Sends Slack notification (if configured)

### Setting Up a Self-Hosted Runner

1. Go to **Settings** → **Actions** → **Runners** → **New self-hosted runner**
2. Follow the instructions to install the runner on your server
3. Add labels to your runner (e.g., `remote`, `production`, `staging`)
4. Use the `RUNNER_LABEL` input to target specific runners

---

## Deploy on Kubernetes

To deploy OPSAPI on Kubernetes, please follow the instructions.

### Requirements

1. kubectl
2. kubeseal
3. helm

### Installation

1. Encode the env variables to base64. Sample variables:

   ```
   DATABASE:
   DB_HOST:
   DB_PASSWORD:
   DB_PORT:
   DB_USER:
   JWT_SECRET_KEY:
   OPENSSL_SECRET_IV:
   OPENSSL_SECRET_KEY:
   MINIO_ENDPOINT:
   MINIO_ACCESS_KEY:
   MINIO_SECRET_KEY:
   MINIO_BUCKET:
   MINIO_REGION:
   NODE_API_URL:
   GOOGLE_CLIENT_ID:
   GOOGLE_CLIENT_SECRET:
   GOOGLE_REDIRECT_URI:
   FRONTEND_URL:
   ```

2. Create a secret.yaml file with encoded env variables:

   ```yaml
   apiVersion: v1
   data:
     DATABASE:
     DB_HOST:
     DB_PASSWORD:
     # ... other variables
   kind: Secret
   metadata:
     creationTimestamp: null
     name: opsapi-secrets
     namespace: <namespace>
   ```

3. Generate the sealed secret:

   ```bash
   kubeseal --format=yaml < secret.yaml > sealed-secret.yaml
   ```

4. Copy the content from `encryptedData` in sealed-secret.yaml to your values file under `app_secrets`

5. Deploy OPSAPI using helm:
   ```bash
   helm upgrade --install opsapi ./devops/helm-charts/opsapi \
     -f ./devops/helm-charts/opsapi/values-<namespace>.yaml \
     --set image.repository=bwalia/opsapi \
     --set image.tag=latest \
     --namespace <namespace> --create-namespace
   ```

---

## Deploy OPSAPI Node on Kubernetes

### Requirements

1. kubectl
2. kubeseal
3. helm

### Installation

1. Encode the .env file to base64. Sample .env:

   ```
   PORT=3000
   MINIO_ENDPOINT=
   MINIO_PORT=
   MINIO_ACCESS_KEY=
   MINIO_SECRET_KEY=
   MINIO_BUCKET=
   MINIO_REGION=
   JWT_SECRET=
   ```

   **Note:** `JWT_SECRET` must match the OPSAPI `JWT_SECRET_KEY`

2. Generate sealed secrets:

   ```bash
   cat node/opsapi-node/.env | kubectl create secret generic node-app-env \
     --dry-run=client --from-file=.env=/dev/stdin -o json \
     | kubeseal --format yaml --namespace <namespace>
   ```

3. Copy the content from `encryptedData -> .env` to your values file under `secrets -> env_file`

4. Deploy OPSAPI Node:
   ```bash
   helm upgrade --install opsapi-node ./devops/helm-charts/opsapi-node \
     -f ./devops/helm-charts/opsapi-node/values-<namespace>.yaml \
     --set image.repository=bwalia/opsapi-node \
     --set image.tag=latest \
     --namespace <namespace> --create-namespace
   ```

---

## Google OAuth Setup

To enable Google OAuth authentication:

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project or select existing
3. Enable Google+ API
4. Create OAuth 2.0 credentials
5. Add authorized redirect URI: `http://localhost:4010/auth/google/callback`
6. Update environment variables in `lapis/.env`:
   ```bash
   GOOGLE_CLIENT_ID=your-client-id
   GOOGLE_CLIENT_SECRET=your-client-secret
   GOOGLE_REDIRECT_URI=http://localhost:4010/auth/google/callback
   ```

---

## API Documentation

Access the OpenAPI specification at:

- Swagger UI: http://localhost:4010/swagger
- OpenAPI JSON: http://localhost:4010/openapi.json

### Public Endpoints (No Auth Required)

- `/` - Health check
- `/health` - Health status
- `/swagger` - API documentation
- `/openapi.json` - OpenAPI spec
- `/metrics` - Prometheus metrics
- `/auth/login` - Login
- `/auth/register` - Registration

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Docker Network                        │
│                      (172.71.0.0/16)                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    │
│  │   OPSAPI    │    │  Dashboard  │    │  PostgreSQL │    │
│  │  (Lapis)    │    │  (Next.js)  │    │             │    │
│  │ 172.71.0.12 │    │ 172.71.0.19 │    │ 172.71.0.10 │    │
│  │   :4010     │    │   :8039     │    │   :5439     │    │
│  └─────────────┘    └─────────────┘    └─────────────┘    │
│                                                             │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    │
│  │    Redis    │    │    MinIO    │    │   Grafana   │    │
│  │ 172.71.0.13 │    │ 172.71.0.17 │    │ 172.71.0.16 │    │
│  │   :6373     │    │ :9000/:9001 │    │   :3011     │    │
│  └─────────────┘    └─────────────┘    └─────────────┘    │
│                                                             │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    │
│  │ Prometheus  │    │   Adminer   │    │   Gatus     │    │
│  │ 172.71.0.15 │    │             │    │ 172.71.0.18 │    │
│  │   :9090     │    │   :7779     │    │   :8888     │    │
│  └─────────────┘    └─────────────┘    └─────────────┘    │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

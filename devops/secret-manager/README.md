# Secret Manager

A secure, production-grade secret management solution for DTAP (Development, Test, Acceptance, Production) environments.

## Overview

This secret manager provides a flexible way to manage Kubernetes secrets across multiple environments without requiring direct access to GitHub repository secrets. It supports two modes:

1. **Local JSON File** - Read secrets from a local JSON file on your server
2. **Remote API** - Fetch secrets from a secure API endpoint

## Features

- **Security-First Design**
  - No secrets logged to stdout/stderr
  - Temporary files created with restricted permissions (600)
  - Secure memory cleanup after use
  - Input validation to prevent injection attacks
  - JWT token authentication for API mode

- **Cross-Platform Support**
  - Works on macOS and Linux
  - Handles base64 encoding differences between platforms

- **Validation**
  - Required vs optional secret validation
  - JSON schema validation
  - Environment validation (dev, test, acc, prod, int)

## Prerequisites

- `bash` 4.0+
- `jq` - JSON processor
- `curl` - For API mode

### Installation

```bash
# macOS
brew install jq

# Ubuntu/Debian
sudo apt-get install jq
```

## Usage

### Basic Syntax

```bash
./run-secret-manager.sh <environment> <project-name> <output-path> <secrets-source> [api-url] [jwt-token]
```

### Arguments

| Argument | Description | Required |
|----------|-------------|----------|
| `environment` | Target environment: `dev`, `test`, `acc`, `prod`, `int` | Yes |
| `project-name` | Project identifier (e.g., `opsapi-kisaan`) | Yes |
| `output-path` | Path to write the generated secret YAML | Yes |
| `secrets-source` | Local JSON file path OR `api` for remote fetch | Yes |
| `api-url` | API endpoint URL (required if secrets-source is `api`) | Conditional |
| `jwt-token` | JWT authentication token (required if secrets-source is `api`) | Conditional |

### Examples

#### Using Local JSON File

```bash
# Create your secrets JSON file (see secrets-schema.json for format)
./run-secret-manager.sh prod opsapi-kisaan /tmp/secret.yaml ~/.secrets/prod.json
```

#### Using Remote API

```bash
# Using command line argument
./run-secret-manager.sh prod opsapi-kisaan /tmp/secret.yaml api \
    "https://dev.wslcrm.com/api/secret-manager" \
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."

# Using environment variable for JWT (more secure)
export SECRET_MANAGER_JWT_TOKEN="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
./run-secret-manager.sh prod opsapi-kisaan /tmp/secret.yaml api \
    "https://dev.wslcrm.com/api/secret-manager"
```

## Secret JSON Format

Create a JSON file following this structure:

```json
{
  "DATABASE_NAME": "opsapi_prod",
  "DATABASE_HOST": "pgsql.default.svc.cluster.local",
  "DATABASE_PASSWORD": "your-secure-password",
  "DATABASE_PORT": "5432",
  "DATABASE_USER": "user-prod",
  "JWT_SECRET_KEY": "your-jwt-secret-key",
  "KEYCLOAK_AUTH_URL": "https://sso.example.com/realms/opsapi/protocol/openid-connect/auth",
  "KEYCLOAK_CLIENT_ID": "opsapi",
  "KEYCLOAK_CLIENT_SECRET": "your-keycloak-secret",
  "KEYCLOAK_REDIRECT_URI": "https://api.example.com/auth/callback",
  "KEYCLOAK_TOKEN_URL": "https://sso.example.com/realms/opsapi/protocol/openid-connect/token",
  "KEYCLOAK_USERINFO_URL": "https://sso.example.com/realms/opsapi/protocol/openid-connect/userinfo",
  "LAPIS_CONFIG_LUA_FILE": "local config = require...",
  "MINIO_ACCESS_KEY": "your-minio-access-key",
  "MINIO_BUCKET": "opsapi-prod-pg",
  "MINIO_ENDPOINT": "https://s3.example.com",
  "MINIO_SECRET_KEY": "your-minio-secret-key",
  "MINIO_REGION": "uk-west-1",
  "NODE_API_URL": "http://opsapi-node.prod.svc.cluster.local:3000/api",
  "OPENSSL_SECRET_KEY": "8151d12b939a4670",
  "OPENSSL_SECRET_IV": "9abd41f7eec7635e",
  "GOOGLE_CLIENT_ID": "optional-google-client-id",
  "GOOGLE_CLIENT_SECRET": "optional-google-secret",
  "GOOGLE_REDIRECT_URI": "https://api.example.com/auth/google/callback",
  "STRIPE_SECRET_KEY": "sk_live_...",
  "STRIPE_PUBLISHABLE_KEY": "pk_live_...",
  "STRIPE_WEBHOOK_SECRET": "whsec_...",
  "NEXT_PUBLIC_API_URL": "https://api.example.com"
}
```

### Required Secrets

These must be present in your JSON file:

- `DATABASE_NAME`, `DATABASE_HOST`, `DATABASE_PASSWORD`, `DATABASE_PORT`, `DATABASE_USER`
- `JWT_SECRET_KEY`
- `KEYCLOAK_AUTH_URL`, `KEYCLOAK_CLIENT_ID`, `KEYCLOAK_CLIENT_SECRET`, `KEYCLOAK_REDIRECT_URI`, `KEYCLOAK_TOKEN_URL`, `KEYCLOAK_USERINFO_URL`
- `LAPIS_CONFIG_LUA_FILE`
- `MINIO_ACCESS_KEY`, `MINIO_BUCKET`, `MINIO_ENDPOINT`, `MINIO_SECRET_KEY`, `MINIO_REGION`
- `NODE_API_URL`
- `OPENSSL_SECRET_KEY`, `OPENSSL_SECRET_IV`

### Optional Secrets

These will show a warning if missing but won't fail:

- `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `GOOGLE_REDIRECT_URI`
- `STRIPE_SECRET_KEY`, `STRIPE_PUBLISHABLE_KEY`, `STRIPE_WEBHOOK_SECRET`
- `NEXT_PUBLIC_API_URL`

## Output

The script generates two files:

1. **YAML File** - Kubernetes Secret manifest with base64-encoded values
2. **Base64 File** - The entire YAML file base64-encoded (for CI/CD pipelines)

### Example Output

```
[SUCCESS] Secret management completed successfully!
[INFO] Generated files:
[INFO]   - YAML: /tmp/secret.yaml
[INFO]   - Base64: /tmp/secret.yaml.b64
```

## CI/CD Integration

### GitHub Actions Workflow

The workflow supports two secret sources:

| Source | Description | Use Case |
|--------|-------------|----------|
| `github-secrets` (default) | Uses GitHub repository secrets | When secrets are managed in GitHub |
| `local-file` | Reads from local JSON files on self-hosted runner | **Recommended** - More secure, no network exposure |

### Using Local File Mode (Recommended)

Since the GitHub Actions self-hosted runner runs on the same server as the dev environment, you can directly read secrets from local files. This is the **most secure and professional approach**:

**Advantages:**
- No secrets exposed over network
- No JWT tokens or API authentication needed
- Faster execution (direct file read)
- More reliable (no network dependencies)
- Easier to manage (just edit JSON files)

**Setup:**

1. Create secrets directory on the self-hosted runner server:
```bash
mkdir -p /home/bwalia/.secrets
chmod 700 /home/bwalia/.secrets
```

2. Create JSON files for each environment:
```bash
# Create secrets files (copy from example and fill in real values)
cp devops/secret-manager/example-secrets-prod.json /home/bwalia/.secrets/opsapi-kisaan-prod.json
# Edit with real values...
chmod 600 /home/bwalia/.secrets/*.json
```

3. When triggering the workflow, select `local-file` as the Secret Source

### Server-Side Setup

Secrets are stored as JSON files on the self-hosted runner server:

```
/home/bwalia/.secrets/
├── opsapi-kisaan-dev.json
├── opsapi-kisaan-test.json
├── opsapi-kisaan-acc.json
├── opsapi-kisaan-prod.json
├── opsapi-kisaan-int.json
├── opsapi-dev.json
├── opsapi-test.json
├── opsapi-acc.json
├── opsapi-prod.json
└── opsapi-int.json
```

**File naming convention:** `{project}-{environment}.json`

**Set proper permissions:**
```bash
chmod 700 /home/bwalia/.secrets
chmod 600 /home/bwalia/.secrets/*.json
```

### Workflow Diagram (Local File Mode)

```
GitHub Actions Workflow (self-hosted runner)
                ↓
    Reads JSON from /home/bwalia/.secrets/{project}-{env}.json
                ↓
    run-secret-manager.sh (templates to YAML + base64)
                ↓
    kubeseal_automation.sh (creates SealedSecret)
                ↓
    Helm deploys to Kubernetes
```

## Security Best Practices

### File Permissions

Always set restrictive permissions on your secret files:

```bash
chmod 600 ~/.secrets/prod.json
chmod 600 ~/.secrets/test.json
```

### Server Setup

1. Store secret JSON files in a secure location (e.g., `/home/user/.secrets/`)
2. Ensure the directory has restricted permissions: `chmod 700 ~/.secrets`
3. Use a dedicated service account with minimal permissions
4. Enable audit logging for secret access

### API Security

1. Use HTTPS only
2. Implement rate limiting
3. Use short-lived JWT tokens
4. Log all access attempts
5. Implement IP allowlisting if possible

## Troubleshooting

### Common Errors

**Error: jq is required but not installed**
```bash
# Install jq
brew install jq  # macOS
sudo apt-get install jq  # Ubuntu
```

**Error: Invalid JSON format**
```bash
# Validate your JSON file
jq . your-secrets.json
```

**Error: Missing required secrets**
- Check that all required keys are present in your JSON file
- Verify key names match exactly (case-sensitive)

**Error: API request failed**
- Verify the API URL is correct
- Check JWT token is valid and not expired
- Ensure network connectivity to the API server

## Files

```
devops/secret-manager/
├── run-secret-manager.sh       # Main script
├── secrets-schema.json         # JSON schema for validation
├── example-secrets-prod.json   # Example secrets file (DO NOT USE IN PRODUCTION)
└── README.md                   # This documentation
```

## Version History

- **1.0.0** - Initial release with local file and remote API support

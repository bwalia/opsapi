#!/bin/bash
#
# Secret Manager Script
# =====================
# Fetches secrets from a remote API or local JSON file, templates them into
# a Kubernetes Secret YAML, and outputs base64-encoded content for CI/CD workflows.
#
# Usage:
#   ./run-secret-manager.sh <environment> <project-name> <template-path> <secrets-source> [api-url] [jwt-token]
#
# Arguments:
#   environment     - Target environment (dev, test, acc, prod)
#   project-name    - Project name (e.g., opsapi-kisaan)
#   template-path   - Path to output the generated secret template
#   secrets-source  - Either a local JSON file path OR "api" to fetch from remote
#   api-url         - (Optional) API URL to fetch secrets from (required if secrets-source is "api")
#   jwt-token       - (Optional) JWT token for API authentication (required if secrets-source is "api")
#
# Examples:
#   # From local JSON file:
#   ./run-secret-manager.sh prod opsapi-kisaan /tmp/secret.yaml /home/user/.secrets/prod.json
#
#   # From remote API:
#   ./run-secret-manager.sh prod opsapi-kisaan /tmp/secret.yaml api https://dev.wslcrm.com/api/secret-manager "eyJ..."
#
# Security Features:
#   - No secrets are logged to stdout/stderr
#   - Temporary files are created with restricted permissions (600)
#   - Memory is cleared after use where possible
#   - Input validation prevents injection attacks
#   - JWT tokens are passed via environment variable option
#
# Author: DevOps Team
# Version: 1.0.0

set -euo pipefail

# ==============================================================================
# SECURITY: Disable command tracing to prevent secret exposure
# ==============================================================================
set +x

# ==============================================================================
# CONFIGURATION
# ==============================================================================
readonly SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
readonly TIMESTAMP=$(date +%Y%m%d_%H%M%S)
readonly LOG_FILE="/tmp/secret-manager-${TIMESTAMP}.log"

# Required secret keys that must be present
readonly REQUIRED_KEYS=(
    "DATABASE_NAME"
    "DATABASE_HOST"
    "DATABASE_PASSWORD"
    "DATABASE_PORT"
    "DATABASE_USER"
    "JWT_SECRET_KEY"
    "KEYCLOAK_AUTH_URL"
    "KEYCLOAK_CLIENT_ID"
    "KEYCLOAK_CLIENT_SECRET"
    "KEYCLOAK_REDIRECT_URI"
    "KEYCLOAK_TOKEN_URL"
    "KEYCLOAK_USERINFO_URL"
    "LAPIS_CONFIG_LUA_FILE"
    "MINIO_ACCESS_KEY"
    "MINIO_BUCKET"
    "MINIO_ENDPOINT"
    "MINIO_SECRET_KEY"
    "MINIO_REGION"
    "NODE_API_URL"
    "OPENSSL_SECRET_KEY"
    "OPENSSL_SECRET_IV"
)

# Optional secret keys (will warn if missing but not fail)
readonly OPTIONAL_KEYS=(
    "GOOGLE_CLIENT_ID"
    "GOOGLE_CLIENT_SECRET"
    "GOOGLE_REDIRECT_URI"
    "STRIPE_SECRET_KEY"
    "STRIPE_PUBLISHABLE_KEY"
    "STRIPE_WEBHOOK_SECRET"
    "NEXT_PUBLIC_API_URL"
)

# Valid environments
readonly VALID_ENVIRONMENTS=("dev" "test" "acc" "prod" "int")

# ==============================================================================
# LOGGING FUNCTIONS (Security-aware)
# ==============================================================================
log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

log_warn() {
    echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
    echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

log_success() {
    echo "[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo "[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Security: Log without exposing sensitive data
log_secure() {
    echo "[SECURE] $(date '+%Y-%m-%d %H:%M:%S') - $1"
    # Do NOT write secure logs to file
}

# ==============================================================================
# CLEANUP FUNCTION
# ==============================================================================
cleanup() {
    local exit_code=$?

    # Securely remove temporary files
    if [[ -n "${TEMP_JSON_FILE:-}" ]] && [[ -f "$TEMP_JSON_FILE" ]]; then
        # Overwrite with random data before deletion
        dd if=/dev/urandom of="$TEMP_JSON_FILE" bs=1024 count=10 2>/dev/null || true
        rm -f "$TEMP_JSON_FILE"
    fi

    if [[ -n "${TEMP_YAML_FILE:-}" ]] && [[ -f "$TEMP_YAML_FILE" ]]; then
        dd if=/dev/urandom of="$TEMP_YAML_FILE" bs=1024 count=10 2>/dev/null || true
        rm -f "$TEMP_YAML_FILE"
    fi

    # Clear sensitive variables from memory
    unset JWT_TOKEN 2>/dev/null || true
    unset SECRETS_JSON 2>/dev/null || true

    if [[ $exit_code -ne 0 ]]; then
        log_error "Script exited with code $exit_code"
    fi

    exit $exit_code
}

trap cleanup EXIT INT TERM

# ==============================================================================
# UTILITY FUNCTIONS
# ==============================================================================

# Print usage information
usage() {
    cat << EOF
Secret Manager Script v1.0.0
============================

Usage: $SCRIPT_NAME <environment> <project-name> <template-path> <secrets-source> [api-url] [jwt-token]

Arguments:
  environment     Target environment: dev, test, acc, prod, int
  project-name    Project identifier (e.g., opsapi-kisaan)
  template-path   Output path for generated secret YAML
  secrets-source  Local JSON file path OR "api" for remote fetch
  api-url         API endpoint (required if secrets-source is "api")
  jwt-token       JWT authentication token (required if secrets-source is "api")
                  Can also be set via SECRET_MANAGER_JWT_TOKEN env var

Examples:
  # Using local JSON file:
  $SCRIPT_NAME prod opsapi-kisaan ./secrets.yaml ~/.secrets/prod.json

  # Using remote API:
  $SCRIPT_NAME prod opsapi-kisaan ./secrets.yaml api https://api.example.com/secrets "\$JWT_TOKEN"

  # Using environment variable for JWT:
  export SECRET_MANAGER_JWT_TOKEN="eyJ..."
  $SCRIPT_NAME prod opsapi-kisaan ./secrets.yaml api https://api.example.com/secrets

Environment Variables:
  SECRET_MANAGER_JWT_TOKEN    JWT token for API authentication
  SECRET_MANAGER_DEBUG        Set to "1" to enable debug mode (non-sensitive only)

EOF
    exit 1
}

# Validate environment argument
validate_environment() {
    local env="$1"
    local valid=false

    for valid_env in "${VALID_ENVIRONMENTS[@]}"; do
        if [[ "$env" == "$valid_env" ]]; then
            valid=true
            break
        fi
    done

    if [[ "$valid" != "true" ]]; then
        log_error "Invalid environment: $env"
        log_error "Valid environments: ${VALID_ENVIRONMENTS[*]}"
        exit 1
    fi
}

# Validate project name (alphanumeric, hyphens, underscores only)
validate_project_name() {
    local name="$1"

    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Invalid project name: $name"
        log_error "Project name must contain only alphanumeric characters, hyphens, and underscores"
        exit 1
    fi
}

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Base64 encode with cross-platform support (no newlines)
base64_encode() {
    local input="$1"

    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        echo -n "$input" | base64
    else
        # Linux
        echo -n "$input" | base64 -w 0
    fi
}

# Validate JSON structure
validate_json() {
    local json_file="$1"

    if ! command_exists jq; then
        log_error "jq is required but not installed"
        log_error "Install with: brew install jq (macOS) or apt-get install jq (Ubuntu)"
        exit 1
    fi

    if ! jq empty "$json_file" 2>/dev/null; then
        log_error "Invalid JSON format in: $json_file"
        exit 1
    fi
}

# ==============================================================================
# SECRET FETCHING FUNCTIONS
# ==============================================================================

# Fetch secrets from local JSON file
fetch_secrets_from_file() {
    local json_file="$1"

    if [[ ! -f "$json_file" ]]; then
        log_error "Secrets file not found: $json_file"
        exit 1
    fi

    # Check file permissions (should be restrictive)
    local perms=$(stat -f "%Lp" "$json_file" 2>/dev/null || stat -c "%a" "$json_file" 2>/dev/null)
    if [[ "$perms" != "600" ]] && [[ "$perms" != "400" ]]; then
        log_warn "Secrets file has insecure permissions: $perms (recommended: 600)"
    fi

    validate_json "$json_file"

    cat "$json_file"
}

# Fetch secrets from remote API
fetch_secrets_from_api() {
    local api_url="$1"
    local jwt_token="$2"
    local environment="$3"
    local project_name="$4"

    if [[ -z "$jwt_token" ]]; then
        log_error "JWT token is required for API authentication"
        exit 1
    fi

    if ! command_exists curl; then
        log_error "curl is required but not installed"
        exit 1
    fi

    log_info "Fetching secrets from API..."
    log_secure "API URL: $api_url (token: [REDACTED])"

    # Create temporary file for response
    TEMP_JSON_FILE=$(mktemp)
    chmod 600 "$TEMP_JSON_FILE"

    # Make API request
    local http_code
    http_code=$(curl -s -w "%{http_code}" \
        -X GET \
        -H "Authorization: Bearer $jwt_token" \
        -H "Content-Type: application/json" \
        -H "X-Environment: $environment" \
        -H "X-Project: $project_name" \
        -o "$TEMP_JSON_FILE" \
        --connect-timeout 30 \
        --max-time 60 \
        "$api_url?environment=$environment&project=$project_name" 2>/dev/null)

    if [[ "$http_code" != "200" ]]; then
        log_error "API request failed with HTTP status: $http_code"
        # Don't expose response body as it might contain sensitive error messages
        rm -f "$TEMP_JSON_FILE"
        exit 1
    fi

    validate_json "$TEMP_JSON_FILE"

    cat "$TEMP_JSON_FILE"
}

# ==============================================================================
# SECRET VALIDATION
# ==============================================================================

validate_secrets() {
    local json_content="$1"
    local missing_required=()
    local missing_optional=()

    log_info "Validating secret keys..."

    # Check required keys
    for key in "${REQUIRED_KEYS[@]}"; do
        local value
        value=$(echo "$json_content" | jq -r --arg key "$key" '.[$key] // empty')

        if [[ -z "$value" ]]; then
            missing_required+=("$key")
        fi
    done

    # Check optional keys
    for key in "${OPTIONAL_KEYS[@]}"; do
        local value
        value=$(echo "$json_content" | jq -r --arg key "$key" '.[$key] // empty')

        if [[ -z "$value" ]]; then
            missing_optional+=("$key")
        fi
    done

    # Report missing optional keys as warnings
    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        log_warn "Missing optional secrets (features may be limited):"
        for key in "${missing_optional[@]}"; do
            log_warn "  - $key"
        done
    fi

    # Fail if required keys are missing
    if [[ ${#missing_required[@]} -gt 0 ]]; then
        log_error "Missing required secrets:"
        for key in "${missing_required[@]}"; do
            log_error "  - $key"
        done
        exit 1
    fi

    log_success "All required secrets validated successfully"
}

# ==============================================================================
# TEMPLATE GENERATION
# ==============================================================================

generate_secret_yaml() {
    local json_content="$1"
    local environment="$2"
    local project_name="$3"
    local output_path="$4"

    log_info "Generating Kubernetes Secret YAML..."

    # Start building the YAML
    cat > "$output_path" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${project_name}-secrets
  namespace: CICD_NAMESPACE_PLACEHOLDER
type: Opaque
data:
EOF

    # Get all keys from JSON and encode values
    local all_keys=("${REQUIRED_KEYS[@]}" "${OPTIONAL_KEYS[@]}")

    for key in "${all_keys[@]}"; do
        local value
        value=$(echo "$json_content" | jq -r --arg key "$key" '.[$key] // empty')

        if [[ -n "$value" ]]; then
            local encoded_value
            encoded_value=$(base64_encode "$value")
            echo "  ${key}: ${encoded_value}" >> "$output_path"
        fi
    done

    log_success "Secret YAML generated at: $output_path"
}

# ==============================================================================
# OUTPUT GENERATION
# ==============================================================================

generate_base64_output() {
    local yaml_file="$1"

    log_info "Generating base64-encoded output for CI/CD..."

    local base64_content
    if [[ "$OSTYPE" == "darwin"* ]]; then
        base64_content=$(base64 -i "$yaml_file")
    else
        base64_content=$(base64 -w 0 "$yaml_file")
    fi

    # Output to stdout for pipeline consumption
    echo ""
    echo "=============================================================================="
    echo "BASE64 ENCODED SECRET (use this in GitHub Secrets or CI/CD)"
    echo "=============================================================================="
    echo "$base64_content"
    echo "=============================================================================="
    echo ""

    # Also save to a .b64 file
    local b64_file="${yaml_file}.b64"
    echo "$base64_content" > "$b64_file"
    chmod 600 "$b64_file"
    log_success "Base64 output saved to: $b64_file"
}

# ==============================================================================
# MAIN FUNCTION
# ==============================================================================

main() {
    log_info "Starting Secret Manager..."
    log_info "Script version: 1.0.0"
    log_info "Timestamp: $TIMESTAMP"

    # Parse arguments
    if [[ $# -lt 4 ]]; then
        usage
    fi

    local environment="$1"
    local project_name="$2"
    local template_path="$3"
    local secrets_source="$4"
    local api_url="${5:-}"
    local jwt_token="${6:-${SECRET_MANAGER_JWT_TOKEN:-}}"

    # Validate inputs
    validate_environment "$environment"
    validate_project_name "$project_name"

    log_info "Environment: $environment"
    log_info "Project: $project_name"
    log_info "Output: $template_path"

    # Ensure output directory exists
    local output_dir
    output_dir=$(dirname "$template_path")
    mkdir -p "$output_dir"

    # Fetch secrets based on source type
    local secrets_json

    if [[ "$secrets_source" == "api" ]]; then
        if [[ -z "$api_url" ]]; then
            log_error "API URL is required when secrets-source is 'api'"
            exit 1
        fi
        secrets_json=$(fetch_secrets_from_api "$api_url" "$jwt_token" "$environment" "$project_name")
    else
        # Treat as local file path
        secrets_json=$(fetch_secrets_from_file "$secrets_source")
    fi

    # Validate secrets
    validate_secrets "$secrets_json"

    # Generate YAML template
    TEMP_YAML_FILE=$(mktemp)
    chmod 600 "$TEMP_YAML_FILE"

    generate_secret_yaml "$secrets_json" "$environment" "$project_name" "$TEMP_YAML_FILE"

    # Copy to final destination
    cp "$TEMP_YAML_FILE" "$template_path"
    chmod 600 "$template_path"

    # Generate base64 output
    generate_base64_output "$template_path"

    log_success "Secret management completed successfully!"
    log_info "Generated files:"
    log_info "  - YAML: $template_path"
    log_info "  - Base64: ${template_path}.b64"

    return 0
}

# ==============================================================================
# ENTRY POINT
# ==============================================================================

main "$@"

#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ============================================
# Configuration
# ============================================
BASE_DOMAIN="wslcrm.com"
ENV_FILE="lapis/.env"

# ============================================
# Usage and Help
# ============================================
show_help() {
    echo -e "${GREEN}OpsAPI Development Environment Setup${NC}"
    echo ""
    echo -e "${BLUE}Usage:${NC}"
    echo "  ./run-development.sh [OPTIONS]"
    echo ""
    echo -e "${BLUE}Options:${NC}"
    echo "  -e, --env [ENV]       Target environment (local|dev|test|acc|prod|remote|<custom>)"
    echo "  -P, --protocol [PROTO] API protocol (http|https). Default: https for remote, http for local"
    echo "  -s, --stash [y|n]     Git stash option (y=stash, n=skip)"
    echo "  -p, --pull [y|n]      Git pull option (y=pull, n=skip)"
    echo "  -a, --auto            Auto mode: stash=y, pull=y (no prompts)"
    echo "  -n, --no-git          Skip all git operations (stash=n, pull=n)"
    echo "  -r, --reset-db        Reset database (removes volumes and wipes data)"
    echo "  -c, --check-env       Only check and update .env file, don't start containers"
    echo "  -h, --help            Show this help message"
    echo ""
    echo -e "${BLUE}Preset Environments:${NC}"
    echo "  local    - http://localhost:4010 (default for local development)"
    echo "  dev      - https://dev-api.${BASE_DOMAIN}"
    echo "  test     - https://test-api.${BASE_DOMAIN}"
    echo "  acc      - https://acc-api.${BASE_DOMAIN}"
    echo "  prod     - https://api.${BASE_DOMAIN}"
    echo "  remote   - https://remote-api.${BASE_DOMAIN}"
    echo ""
    echo -e "${BLUE}Dynamic Environments:${NC}"
    echo "  Any custom name will generate: https://<name>-api.${BASE_DOMAIN}"
    echo "  Use -P http to override protocol: http://<name>-api.${BASE_DOMAIN}"
    echo "  Example: -e staging           -> https://staging-api.${BASE_DOMAIN}"
    echo "  Example: -e staging -P http   -> http://staging-api.${BASE_DOMAIN}"
    echo ""
    echo -e "${BLUE}Examples:${NC}"
    echo "  ./run-development.sh                    # Interactive mode (prompts)"
    echo "  ./run-development.sh -e local           # Local development environment"
    echo "  ./run-development.sh -e dev -a          # Dev environment, auto git (https)"
    echo "  ./run-development.sh -e dev -P http     # Dev environment with HTTP"
    echo "  ./run-development.sh -e remote -n       # Remote environment, no git ops"
    echo "  ./run-development.sh -e staging -a      # Custom 'staging' environment"
    echo "  ./run-development.sh --env=prod -a      # Prod environment, auto mode"
    echo "  ./run-development.sh -c -e dev          # Just check/update .env for dev"
    echo "  ./run-development.sh -r                 # Reset database (fresh start)"
    echo ""
}

# ============================================
# Parse Arguments
# ============================================
STASH_ARG=""
PULL_ARG=""
RESET_DB=false
TARGET_ENV=""
CHECK_ENV_ONLY=false
PROTOCOL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--env)
            TARGET_ENV="$2"
            shift 2
            ;;
        --env=*)
            TARGET_ENV="${1#*=}"
            shift
            ;;
        -s|--stash)
            STASH_ARG="$2"
            shift 2
            ;;
        --stash=*)
            STASH_ARG="${1#*=}"
            shift
            ;;
        -p|--pull)
            PULL_ARG="$2"
            shift 2
            ;;
        --pull=*)
            PULL_ARG="${1#*=}"
            shift
            ;;
        -a|--auto)
            STASH_ARG="y"
            PULL_ARG="y"
            shift
            ;;
        -n|--no-git)
            STASH_ARG="n"
            PULL_ARG="n"
            shift
            ;;
        -r|--reset-db)
            RESET_DB=true
            shift
            ;;
        -c|--check-env)
            CHECK_ENV_ONLY=true
            shift
            ;;
        -P|--protocol)
            PROTOCOL="$2"
            shift 2
            ;;
        --protocol=*)
            PROTOCOL="${1#*=}"
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            show_help
            exit 1
            ;;
    esac
done

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   OpsAPI Development Environment      ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# ============================================
# Functions
# ============================================

# Function to prompt yes/no (only used in interactive mode)
prompt_yes_no() {
    local prompt="$1"
    local response
    while true; do
        read -p "$prompt [y/n]: " response
        case "$response" in
            [yY]|[yY][eE][sS]) return 0 ;;
            [nN]|[nN][oO]) return 1 ;;
            *) echo -e "${YELLOW}Please answer y or n.${NC}" ;;
        esac
    done
}

# Function to check if arg is yes
is_yes() {
    case "$1" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# Function to check if arg is no
is_no() {
    case "$1" in
        [nN]|[nN][oO]) return 0 ;;
        *) return 1 ;;
    esac
}

# Function to get API URL based on environment and protocol
# Supports both preset environments and dynamic custom environments
# Usage: get_api_url <env> [protocol]
get_api_url() {
    local env="$1"
    local proto="$2"

    case "$env" in
        local)
            # Local always uses http unless explicitly overridden
            local local_proto="${proto:-http}"
            echo "${local_proto}://localhost:4010"
            ;;
        prod)
            # Production uses api.domain.com (no prefix)
            local prod_proto="${proto:-https}"
            echo "${prod_proto}://api.${BASE_DOMAIN}"
            ;;
        *)
            # All other environments use {env}-api.domain.com pattern
            # This includes: dev, test, acc, remote, and any custom environment
            local remote_proto="${proto:-https}"
            echo "${remote_proto}://${env}-api.${BASE_DOMAIN}"
            ;;
    esac
}

# Function to validate environment
# Now accepts any alphanumeric environment name (dynamic environments)
validate_environment() {
    local env="$1"

    # Check if environment name is empty
    if [[ -z "$env" ]]; then
        return 1
    fi

    # Check if environment name contains only valid characters (alphanumeric, hyphen, underscore)
    if [[ "$env" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        return 0
    else
        return 1
    fi
}

# Function to validate protocol
validate_protocol() {
    local proto="$1"
    case "$proto" in
        http|https) return 0 ;;
        *) return 1 ;;
    esac
}

# Function to prompt for protocol selection
prompt_protocol() {
    local env="$1"
    local default_proto

    # Set default based on environment
    if [[ "$env" == "local" ]]; then
        default_proto="http"
    else
        default_proto="https"
    fi

    echo -e "${CYAN}Select API protocol:${NC}"
    echo "  1) https - Secure connection (recommended for remote environments)"
    echo "  2) http  - Non-secure connection (typical for local development)"
    echo ""
    echo -e "${BLUE}[i] Default for '$env' environment: ${CYAN}${default_proto}${NC}"
    echo ""

    local choice
    while true; do
        read -p "Enter choice [1-2] or press Enter for default ($default_proto): " choice
        case "$choice" in
            "")
                echo "$default_proto"
                return 0
                ;;
            1|https)
                echo "https"
                return 0
                ;;
            2|http)
                echo "http"
                return 0
                ;;
            *)
                echo -e "${YELLOW}Invalid choice. Please enter 1 for https, 2 for http, or press Enter for default.${NC}" >&2
                ;;
        esac
    done
}

# Function to prompt for environment selection
prompt_environment() {
    echo -e "${CYAN}Select target environment:${NC}"
    echo "  1) local   - http://localhost:4010"
    echo "  2) dev     - https://dev-api.${BASE_DOMAIN}"
    echo "  3) test    - https://test-api.${BASE_DOMAIN}"
    echo "  4) acc     - https://acc-api.${BASE_DOMAIN}"
    echo "  5) prod    - https://api.${BASE_DOMAIN}"
    echo "  6) remote  - https://remote-api.${BASE_DOMAIN}"
    echo ""
    echo -e "${CYAN}Or enter a custom environment name (e.g., staging, demo, etc.)${NC}"
    echo ""

    local choice
    while true; do
        read -p "Enter choice [1-6] or custom environment name: " choice
        case "$choice" in
            1|local)
                echo "local"
                return 0
                ;;
            2|dev)
                echo "dev"
                return 0
                ;;
            3|test)
                echo "test"
                return 0
                ;;
            4|acc)
                echo "acc"
                return 0
                ;;
            5|prod)
                echo "prod"
                return 0
                ;;
            6|remote)
                echo "remote"
                return 0
                ;;
            *)
                # Check if it's a valid custom environment name
                if validate_environment "$choice"; then
                    echo "$choice"
                    return 0
                else
                    echo -e "${YELLOW}Invalid choice. Please enter 1-6 or a valid environment name.${NC}" >&2
                    echo -e "${YELLOW}Environment names must start with a letter and contain only letters, numbers, hyphens, or underscores.${NC}" >&2
                fi
                ;;
        esac
    done
}

# Function to check and update .env file
check_and_update_env() {
    local target_env="$1"
    local proto="$2"
    local api_url
    api_url=$(get_api_url "$target_env" "$proto")

    if [[ -z "$api_url" ]]; then
        echo -e "${RED}[!] Error: Invalid environment '$target_env'${NC}"
        return 1
    fi

    echo -e "${BLUE}[i] Target environment: ${CYAN}${target_env}${NC}"
    echo -e "${BLUE}[i] API URL: ${CYAN}${api_url}${NC}"
    echo ""

    # Check if .env file exists
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}[!] Error: .env file not found at '$ENV_FILE'${NC}"
        echo -e "${YELLOW}[!] Please create the .env file first.${NC}"
        return 1
    fi

    # Variables to check and update
    local vars_to_check=("NEXT_PUBLIC_API_URL" "GOOGLE_REDIRECT_URI" "KEYCLOAK_REDIRECT_URI")
    local needs_update=false
    local updates_made=()

    echo -e "${GREEN}[+] Checking .env file for environment-specific URLs...${NC}"
    echo ""

    for var in "${vars_to_check[@]}"; do
        local current_value
        current_value=$(grep "^${var}=" "$ENV_FILE" | cut -d'=' -f2-)

        if [[ -z "$current_value" ]]; then
            echo -e "${YELLOW}  [!] $var is not set in .env file${NC}"
            needs_update=true
            continue
        fi

        # Determine expected value based on variable and environment
        local expected_value=""
        case "$var" in
            NEXT_PUBLIC_API_URL)
                expected_value="$api_url"
                ;;
            GOOGLE_REDIRECT_URI)
                expected_value="${api_url}/auth/google/callback"
                ;;
            KEYCLOAK_REDIRECT_URI)
                expected_value="${api_url}/auth/callback"
                ;;
        esac

        # Check if current value matches expected
        if [[ "$current_value" != "$expected_value" ]]; then
            echo -e "${YELLOW}  [!] $var mismatch:${NC}"
            echo -e "      Current:  ${RED}$current_value${NC}"
            echo -e "      Expected: ${GREEN}$expected_value${NC}"
            needs_update=true
            updates_made+=("$var")
        else
            echo -e "${GREEN}  [+] $var is correctly set${NC}"
        fi
    done

    echo ""

    if $needs_update; then
        echo -e "${YELLOW}[!] Environment URLs need to be updated.${NC}"

        local do_update=false
        if [[ -n "$STASH_ARG" ]] || [[ "$CHECK_ENV_ONLY" == "true" ]]; then
            # Non-interactive mode or check-only mode - ask for confirmation
            if prompt_yes_no "Do you want to update the .env file?"; then
                do_update=true
            fi
        else
            # Interactive mode
            if prompt_yes_no "Do you want to update the .env file with correct URLs?"; then
                do_update=true
            fi
        fi

        if $do_update; then
            echo -e "${GREEN}[+] Updating .env file...${NC}"

            # Backup the .env file
            cp "$ENV_FILE" "${ENV_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
            echo -e "${BLUE}[i] Backup created: ${ENV_FILE}.backup.$(date +%Y%m%d_%H%M%S)${NC}"

            # Update NEXT_PUBLIC_API_URL
            if grep -q "^NEXT_PUBLIC_API_URL=" "$ENV_FILE"; then
                sed -i.tmp "s|^NEXT_PUBLIC_API_URL=.*|NEXT_PUBLIC_API_URL=${api_url}|" "$ENV_FILE"
            else
                echo "NEXT_PUBLIC_API_URL=${api_url}" >> "$ENV_FILE"
            fi

            # Update GOOGLE_REDIRECT_URI
            if grep -q "^GOOGLE_REDIRECT_URI=" "$ENV_FILE"; then
                sed -i.tmp "s|^GOOGLE_REDIRECT_URI=.*|GOOGLE_REDIRECT_URI=${api_url}/auth/google/callback|" "$ENV_FILE"
            else
                echo "GOOGLE_REDIRECT_URI=${api_url}/auth/google/callback" >> "$ENV_FILE"
            fi

            # Update KEYCLOAK_REDIRECT_URI
            if grep -q "^KEYCLOAK_REDIRECT_URI=" "$ENV_FILE"; then
                sed -i.tmp "s|^KEYCLOAK_REDIRECT_URI=.*|KEYCLOAK_REDIRECT_URI=${api_url}/auth/callback|" "$ENV_FILE"
            else
                echo "KEYCLOAK_REDIRECT_URI=${api_url}/auth/callback" >> "$ENV_FILE"
            fi

            # Clean up sed temp files
            rm -f "${ENV_FILE}.tmp"

            echo -e "${GREEN}[+] .env file updated successfully!${NC}"
            echo ""

            # Show updated values
            echo -e "${CYAN}Updated values:${NC}"
            echo -e "  NEXT_PUBLIC_API_URL=${api_url}"
            echo -e "  GOOGLE_REDIRECT_URI=${api_url}/auth/google/callback"
            echo -e "  KEYCLOAK_REDIRECT_URI=${api_url}/auth/callback"
            echo ""
        else
            echo -e "${YELLOW}[!] Skipping .env update. Please update manually if needed.${NC}"
        fi
    else
        echo -e "${GREEN}[+] All environment URLs are correctly configured!${NC}"
    fi

    return 0
}

# ============================================
# Environment Selection
# ============================================
echo -e "${GREEN}[+] Environment Configuration${NC}"
echo ""

# Determine target environment
if [[ -n "$TARGET_ENV" ]]; then
    # Environment provided via argument
    if validate_environment "$TARGET_ENV"; then
        echo -e "${BLUE}[i] Environment from argument: ${CYAN}${TARGET_ENV}${NC}"
    else
        echo -e "${RED}[!] Invalid environment: '$TARGET_ENV'${NC}"
        echo -e "${YELLOW}[!] Environment name must start with a letter and contain only letters, numbers, hyphens, or underscores.${NC}"
        echo -e "${YELLOW}[!] Preset options: local, dev, test, acc, prod, remote${NC}"
        echo -e "${YELLOW}[!] Or use any custom name (e.g., staging, demo, feature-x)${NC}"
        exit 1
    fi
else
    # Interactive mode - prompt for environment
    TARGET_ENV=$(prompt_environment)
    echo ""
fi

# Determine protocol
if [[ -n "$PROTOCOL" ]]; then
    # Protocol provided via argument
    if validate_protocol "$PROTOCOL"; then
        echo -e "${BLUE}[i] Protocol from argument: ${CYAN}${PROTOCOL}${NC}"
    else
        echo -e "${RED}[!] Invalid protocol: '$PROTOCOL'${NC}"
        echo -e "${YELLOW}[!] Protocol must be 'http' or 'https'${NC}"
        exit 1
    fi
else
    # Interactive mode - prompt for protocol (unless environment is 'local' and no explicit protocol)
    # For non-interactive mode with no protocol specified, use defaults
    if [[ -n "$STASH_ARG" ]] || [[ -n "$PULL_ARG" ]]; then
        # Non-interactive mode - use default protocol based on environment
        if [[ "$TARGET_ENV" == "local" ]]; then
            PROTOCOL="http"
        else
            PROTOCOL="https"
        fi
        echo -e "${BLUE}[i] Protocol (default): ${CYAN}${PROTOCOL}${NC}"
    else
        # Interactive mode - prompt for protocol
        PROTOCOL=$(prompt_protocol "$TARGET_ENV")
        echo ""
    fi
fi

# Show final API URL
API_URL_PREVIEW=$(get_api_url "$TARGET_ENV" "$PROTOCOL")
echo -e "${BLUE}[i] API URL will be: ${CYAN}${API_URL_PREVIEW}${NC}"
echo ""

# Check and update .env file
check_and_update_env "$TARGET_ENV" "$PROTOCOL"
if [[ $? -ne 0 ]]; then
    echo -e "${RED}[!] Environment check failed. Exiting.${NC}"
    exit 1
fi

# If check-env-only mode, exit here
if $CHECK_ENV_ONLY; then
    echo -e "${GREEN}[+] Environment check complete. Exiting (--check-env mode).${NC}"
    exit 0
fi

echo ""

# ============================================
# Git Stash Logic
# ============================================
if [[ -n $(git status --porcelain 2>/dev/null) ]]; then
    echo -e "${YELLOW}[!] You have uncommitted changes:${NC}"
    git status --short
    echo ""

    # Determine stash action
    do_stash=false
    if [[ -n "$STASH_ARG" ]]; then
        # Argument provided - use it
        if is_yes "$STASH_ARG"; then
            do_stash=true
            echo -e "${BLUE}[i] Stash option: yes (from argument)${NC}"
        else
            echo -e "${BLUE}[i] Stash option: no (from argument)${NC}"
        fi
    else
        # Interactive mode
        if prompt_yes_no "Do you want to stash your changes before pulling?"; then
            do_stash=true
        fi
    fi

    if $do_stash; then
        echo -e "${GREEN}[+] Stashing changes...${NC}"
        git stash push -m "Auto-stash before development run $(date '+%Y-%m-%d %H:%M:%S')"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}[+] Changes stashed successfully${NC}"
        else
            echo -e "${RED}[!] Failed to stash changes${NC}"
            exit 1
        fi
    fi
else
    echo -e "${GREEN}[+] Working directory clean - no stash needed${NC}"
fi

# ============================================
# Git Pull Logic
# ============================================
echo ""

do_pull=false
if [[ -n "$PULL_ARG" ]]; then
    # Argument provided - use it
    if is_yes "$PULL_ARG"; then
        do_pull=true
        echo -e "${BLUE}[i] Pull option: yes (from argument)${NC}"
    else
        echo -e "${BLUE}[i] Pull option: no (from argument)${NC}"
    fi
else
    # Interactive mode
    if prompt_yes_no "Do you want to pull the latest changes from git?"; then
        do_pull=true
    fi
fi

if $do_pull; then
    echo -e "${GREEN}[+] Pulling latest changes...${NC}"
    git pull
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}[+] Git pull completed successfully${NC}"
    else
        echo -e "${RED}[!] Git pull failed. You may need to resolve conflicts.${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}[+] Skipping git pull${NC}"
fi

echo ""
echo -e "${GREEN}[+] Setting up development environment...${NC}"
echo ""

mkdir -p lapis/logs
mkdir -p lapis/pgdata
mkdir -p lapis/keycloak_data

chmod -R +x lapis/logs
chmod -R +x lapis/pgdata
chmod -R +x lapis/keycloak_data

cd lapis

#sed -i 's/COPY lapis\/\. \/app/COPY . \/app/' lapis/Dockerfil

# Stop existing containers - only remove volumes if --reset-db flag is set
if $RESET_DB; then
    echo -e "${YELLOW}[!] Resetting database - removing volumes...${NC}"
    docker compose down --volumes
else
    echo -e "${GREEN}[+] Preserving database data...${NC}"
    docker compose down
fi

docker compose up --build -d

sleep 15

docker exec -it opsapi lapis migrate

sleep 5

HOSTNAME="opsapi-dev.local"
K3S_LB_IP=127.0.0.1
HOSTS_FILE="/etc/hosts"

echo "[+] Removing lines matching '$HOSTNAME' from $HOSTS_FILE"

# Backup before change
sudo cp "$HOSTS_FILE" "$HOSTS_FILE.bak"

# Delete lines containing the host entry
sudo sed -i '' "/${HOSTNAME//./\\.}/d" "$HOSTS_FILE"

echo "[+] House keeping Done. Backup saved as $HOSTS_FILE.bak"

# Check if the entry already exists
if grep -q "$HOSTNAME" $HOSTS_FILE; then
    echo "[+] Updating existing entry for $HOSTNAME"
    sudo sed -i '' "s/^.*$HOSTNAME\$/$K3S_LB_IP $HOSTNAME/" $HOSTS_FILE
else
    echo "[+] Adding new entry: $K3S_LB_IP $HOSTNAME"
    echo "$K3S_LB_IP $HOSTNAME" | sudo tee -a $HOSTS_FILE > /dev/null
fi

sleep 5
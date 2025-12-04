#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
    echo "  -s, --stash [y|n]     Git stash option (y=stash, n=skip)"
    echo "  -p, --pull [y|n]      Git pull option (y=pull, n=skip)"
    echo "  -a, --auto            Auto mode: stash=y, pull=y (no prompts)"
    echo "  -n, --no-git          Skip all git operations (stash=n, pull=n)"
    echo "  -h, --help            Show this help message"
    echo ""
    echo -e "${BLUE}Examples:${NC}"
    echo "  ./run-development.sh                    # Interactive mode (prompts)"
    echo "  ./run-development.sh -a                 # Auto mode: stash and pull"
    echo "  ./run-development.sh -n                 # No git operations"
    echo "  ./run-development.sh -s y -p y          # Stash yes, pull yes"
    echo "  ./run-development.sh -s n -p y          # No stash, pull yes"
    echo "  ./run-development.sh --stash=y --pull=n # Stash yes, no pull"
    echo ""
}

# ============================================
# Parse Arguments
# ============================================
STASH_ARG=""
PULL_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
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

docker compose down --volumes
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
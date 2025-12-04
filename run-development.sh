#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   OpsAPI Development Environment      ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Function to prompt yes/no
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

# Check for uncommitted changes
if [[ -n $(git status --porcelain 2>/dev/null) ]]; then
    echo -e "${YELLOW}[!] You have uncommitted changes:${NC}"
    git status --short
    echo ""

    if prompt_yes_no "Do you want to stash your changes before pulling?"; then
        echo -e "${GREEN}[+] Stashing changes...${NC}"
        git stash push -m "Auto-stash before development run $(date '+%Y-%m-%d %H:%M:%S')"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}[+] Changes stashed successfully${NC}"
        else
            echo -e "${RED}[!] Failed to stash changes${NC}"
            exit 1
        fi
    fi
fi

# Ask about git pull
echo ""
if prompt_yes_no "Do you want to pull the latest changes from git?"; then
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
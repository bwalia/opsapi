#!/bin/bash

set -e

mkdir -p logs
mkdir -p pgdata
mkdir -p keycloak_data

chmod -R +x logs
chmod -R +x pgdata
chmod -R +x keycloak_data

# cd lapis

#sed -i 's/COPY lapis\/\. \/app/COPY . \/app/' Dockerfil

docker compose down --volumes
docker compose up --build -d --remove-orphans

sleep 15

docker exec -it opsapi lapis migrate

sleep 5

HOSTNAME="dev-opsapi.local"
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

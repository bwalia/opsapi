#!/bin/bash

# Path to the Ansible inventory file
INVENTORY_FILE=$1

# Create the known_hosts file if it doesn't exist
mkdir -p ~/.ssh

# Extract IP addresses from the inventory file and add them to known_hosts
while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^#.*$ ]] || [[ -z "$line" ]] && continue

    # Fetch the host key and add it to known_hosts
    ssh-keyscan -H "$line" >> ~/.ssh/known_hosts
done < "$INVENTORY_FILE"


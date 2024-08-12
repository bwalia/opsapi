#!/bin/bash

get_email() {
    while true; do
        echo "Please enter super admin email:"
        read email
        if [ -n "$email" ]; then
            break
        else
            echo "Email cannot be empty. Please try again."
        fi
    done
}

get_password() {
    while true; do
        echo "Please enter your password (minimum 8 characters, 1 capital letter, 1 number):"
        read -s password
        if [[ ${#password} -ge 8 && "$password" =~ [A-Z] && "$password" =~ [0-9] ]]; then
            break
        else
            echo "Password does not meet the requirements. Please try again."
        fi
    done
}

hash_password() {
    echo -n "$password" | base64 | awk '{print $1}'
}

get_email
get_password
hashed_password=$(hash_password)

json_data=$(cat <<EOF
{
    "email": "$email",
    "password": "$hashed_password"
}
EOF
)
mkdir data
json_file="data/settings.json"
echo "$json_data" > "$json_file"

echo "Data has been saved to $json_file"

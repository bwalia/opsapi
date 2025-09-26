#!/bin/bash

# This bash script automates the process of sealing Kubernetes secrets using kubeseal.

# set -x

# Validate input parameter
if [ -z "$1" ]; then
    echo "Error: Missing base64 encoded environment file content as first parameter"
    echo "Usage: $0 <base64_encoded_env_file_content>"
    exit 1
else
    ENV_FILE_CONTENT_BASE64="$1"
    # Validate base64 content
    if ! echo "$ENV_FILE_CONTENT_BASE64" | base64 -d > /dev/null 2>&1; then
        echo "Error: Invalid base64 content provided"
        exit 1
    else
        echo "✓ Valid base64 content provided"
    fi
fi

if [ -z "$2" ]; then
    echo "Error: Environment reference (like prod, dev) as second parameter is required"
    exit 1
else
    ENV_REF="$2"
fi

if [ -z "$3" ]; then
    echo "Notice: CICD Namespace referenced from 2nd parameter"
    CICD_NAMESPACE=$ENV_REF
else
    CICD_NAMESPACE="$3"
fi

echo "Environment reference: $ENV_REF"
echo "CICD Namespace: $CICD_NAMESPACE"
echo "OSTYPE variable: $OSTYPE"

# Method 3: Check for specific OS
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "✓ Running on macOS"
    OS_TYPE="macos"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo "✓ Running on Linux"
    OS_TYPE="linux"

    # Check if it's Ubuntu specifically
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "Distribution: $NAME"
        if [[ "$NAME" == *"Ubuntu"* ]]; then
            echo "✓ Detected Ubuntu Linux"
            OS_TYPE="ubuntu"
        fi
    fi
else
    echo "❌ Unsupported or unknown operating system: $OSTYPE"
    exit 1
fi
echo "Final OS detection: $OS_TYPE"

# Function to install kubeseal
install_kubeseal() {
    echo "Installing kubeseal..."
    if [[ "$OS_TYPE" == "macos" ]]; then
        if command -v brew &> /dev/null; then
            brew install kubeseal
        else
            echo "Homebrew not found. Installing kubeseal manually..."
            KUBESEAL_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest | grep tag_name | cut -d '"' -f 4 | cut -d 'v' -f 2)
            curl -L "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-darwin-amd64.tar.gz" -o kubeseal.tar.gz
            tar -xzf kubeseal.tar.gz kubeseal
            sudo mv kubeseal /usr/local/bin/
            rm kubeseal.tar.gz
        fi
    elif [[ "$OS_TYPE" == "ubuntu" || "$OS_TYPE" == "linux" ]]; then
        KUBESEAL_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest | grep tag_name | cut -d '"' -f 4 | cut -d 'v' -f 2)
        wget "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
        tar -xzf "kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" kubeseal
        sudo install -m 755 kubeseal /usr/local/bin/kubeseal
        rm kubeseal "kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
    fi
}

# Check if kubeseal binary is installed
if ! command -v kubeseal &> /dev/null; then
    echo "kubeseal binary is not installed!"
        install_kubeseal
        if ! command -v kubeseal &> /dev/null; then
            echo "Error: Failed to install kubeseal!"
            exit 1
        fi
fi
# Add more OS checks if needed

echo "kubeseal binary found: $(which kubeseal)"
echo "kubeseal version: $(kubeseal --version)"

# Install yq if not present
if ! command -v yq &> /dev/null; then
    echo "yq not found, installing..."
    if [[ "$OS_TYPE" == "macos" ]]; then
        brew install yq
    elif [[ "$OS_TYPE" == "ubuntu" ]]; then
        sudo apt-get install -y yq
    fi
fi

if ! command -v yq &> /dev/null; then
    echo "Error: yq is not installed!"
    exit 1
fi

echo $ENV_FILE_CONTENT_BASE64 | base64 -d > temp.txt
ENV_FILE_CONTENT_BASE64_DECODED_FILE="temp.txt"
#"/Users/balinderwalia/Documents/Work/aws_keys/.env_opsapi_prod"

SECRET_INPUT_PATH="devops/kubeseal/secret_opsapi_per_env_input_template.yaml"
SECRET_OUTPUT_PATH="/tmp/secret_opsapi_${ENV_REF}.yaml"
SEALED_SECRET_OUTPUT_PATH="/tmp/sealed_secret_opsapi_${ENV_REF}.yaml"

if [ ! -f "$ENV_FILE_CONTENT_BASE64_DECODED_FILE" ]; then
    echo "Error: Environment file '$ENV_FILE_CONTENT_BASE64_DECODED_FILE' not found!"
    exit 1
fi

if [ ! -f "$SECRET_INPUT_PATH" ]; then
    echo "Error: Sealed secret template file '$SECRET_INPUT_PATH' not found!"
    exit 1
fi

if base64 --help 2>&1 | grep -q -- '--wrap'; then
    # GNU base64 (Linux)
    echo "Using GNU base64 (Linux)"
    BASE64_WRAP_OPTION="--wrap=0"
else
    # BSD base64 (macOS)
    echo "Using BSD base64 (macOS)"
    BASE64_WRAP_OPTION="-b 0"
fi

# cat temp.txt
# rm temp.txt

rm -Rf $SECRET_OUTPUT_PATH
cp $SECRET_INPUT_PATH $SECRET_OUTPUT_PATH
if [ ! -f "$SECRET_OUTPUT_PATH" ]; then
    echo "Error: Sealed secret output file '$SECRET_OUTPUT_PATH' not found!"
    exit 1
fi

# Use cross-platform sed replacement
if [[ "$OS_TYPE" == "macos" ]]; then
    sed -i '' "s/CICD_NAMESPACE_PLACEHOLDER/$CICD_NAMESPACE/g" $SECRET_OUTPUT_PATH
    sed -i '' "s/CICD_ENV_REF_PLACEHOLDER/$ENV_REF/g" $SECRET_OUTPUT_PATH
    sed -i '' "s/CICD_ENV_FILE_PLACEHOLDER_BASE64/$CICD_ENV_FILE_PLACEHOLDER_BASE64/g" $SECRET_OUTPUT_PATH
elif [[ "$OS_TYPE" == "linux" || "$OS_TYPE" == "ubuntu" ]]; then
    sed -i "s/CICD_NAMESPACE_PLACEHOLDER/$CICD_NAMESPACE/g" $SECRET_OUTPUT_PATH
    sed -i "s/CICD_ENV_REF_PLACEHOLDER/$ENV_REF/g" $SECRET_OUTPUT_PATH
    sed -i "s/CICD_ENV_FILE_PLACEHOLDER_BASE64/$ENV_FILE_CONTENT_BASE64/g" $SECRET_OUTPUT_PATH
else
    sed -i "s/CICD_NAMESPACE_PLACEHOLDER/$CICD_NAMESPACE/g" $SECRET_OUTPUT_PATH
    sed -i "s/CICD_ENV_REF_PLACEHOLDER/$ENV_REF/g" $SECRET_OUTPUT_PATH
    sed -i "s/CICD_ENV_FILE_PLACEHOLDER_BASE64/$ENV_FILE_CONTENT_BASE64/g" $SECRET_OUTPUT_PATH
fi

if [ ! -f "$SECRET_OUTPUT_PATH" ]; then
    echo "Error: Sealed secret output file '$SECRET_OUTPUT_PATH' not found!"
    exit 1
fi

cat $SECRET_OUTPUT_PATH
exit 0

echo "Sealing the secret using kubeseal..."
kubeseal --format yaml < $SECRET_OUTPUT_PATH > $SEALED_SECRET_OUTPUT_PATH

# rm -Rf $SECRET_OUTPUT_PATH
# cat sealed_secret_opsapi_prod.yaml
echo "Sealed secret created at '$SEALED_SECRET_OUTPUT_PATH'"

# extract the sealed secret env_file
echo "Extracting sealed secret env_file encrypted value..."

if ! command -v yq &> /dev/null; then
    echo "Error: yq is not installed!"
    exit 1
fi

HELM_VALUES_INPUT_PATH=devops/helm-charts/opsapi/values-env-template.yaml
HELM_VALUES_OUTPUT_PATH=devops/helm-charts/opsapi/values-${ENV_REF}.yaml

if [ ! -f "$HELM_VALUES_INPUT_PATH" ]; then
    echo "Error: Helm values template file '$HELM_VALUES_INPUT_PATH' not found!"
    exit 1
fi

cp $HELM_VALUES_INPUT_PATH $HELM_VALUES_OUTPUT_PATH

JWT_SECRET_KEY=$(yq .spec.encryptedData.JWT_SECRET_KEY $SEALED_SECRET_OUTPUT_PATH)
KEYCLOAK_AUTH_URL=$(yq .spec.encryptedData.KEYCLOAK_AUTH_URL $SEALED_SECRET_OUTPUT_PATH)
KEYCLOAK_CLIENT_ID=$(yq .spec.encryptedData.KEYCLOAK_CLIENT_ID $SEALED_SECRET_OUTPUT_PATH)
KEYCLOAK_CLIENT_SECRET=$(yq .spec.encryptedData.KEYCLOAK_CLIENT_SECRET $SEALED_SECRET_OUTPUT_PATH)
KEYCLOAK_REDIRECT_URI=$(yq .spec.encryptedData.KEYCLOAK_REDIRECT_URI $SEALED_SECRET_OUTPUT_PATH)
KEYCLOAK_TOKEN_URL=$(yq .spec.encryptedData.KEYCLOAK_TOKEN_URL $SEALED_SECRET_OUTPUT_PATH)
KEYCLOAK_USERINFO_URL=$(yq .spec.encryptedData.KEYCLOAK_USERINFO_URL $SEALED_SECRET_OUTPUT_PATH)
LAPIS_CONFIG_LUA_FILE=$(yq .spec.encryptedData.LAPIS_CONFIG_LUA_FILE $SEALED_SECRET_OUTPUT_PATH)
MINIO_ACCESS_KEY=$(yq .spec.encryptedData.MINIO_ACCESS_KEY $SEALED_SECRET_OUTPUT_PATH)
MINIO_BUCKET=$(yq .spec.encryptedData.MINIO_BUCKET $SEALED_SECRET_OUTPUT_PATH)
MINIO_ENDPOINT=$(yq .spec.encryptedData.MINIO_ENDPOINT $SEALED_SECRET_OUTPUT_PATH)
MINIO_REGION=$(yq .spec.encryptedData.MINIO_REGION $SEALED_SECRET_OUTPUT_PATH)
MINIO_SECRET_KEY=$(yq .spec.encryptedData.MINIO_SECRET_KEY $SEALED_SECRET_OUTPUT_PATH)
OPENSSL_SECRET_KEY=$(yq .spec.encryptedData.OPENSSL_SECRET_KEY $SEALED_SECRET_OUTPUT_PATH)
OPENSSL_SECRET_IV=$(yq .spec.encryptedData.OPENSSL_SECRET_IV $SEALED_SECRET_OUTPUT_PATH)
NODE_API_URL=$(yq .spec.encryptedData.NODE_API_URL $SEALED_SECRET_OUTPUT_PATH)

echo "Extracted encrypted values from sealed secret."

# echo "LAPIS_CONFIG_LUA_FILE: "
# echo $LAPIS_CONFIG_LUA_FILE

if [ -z "$JWT_SECRET_KEY" ] || [ -z "$KEYCLOAK_AUTH_URL" ] || [ -z "$KEYCLOAK_CLIENT_ID" ] || [ -z "$KEYCLOAK_CLIENT_SECRET" ] || [ -z "$KEYCLOAK_REDIRECT_URI" ] || [ -z "$KEYCLOAK_TOKEN_URL" ] || [ -z "$KEYCLOAK_USERINFO_URL" ] || [ -z "$LAPIS_CONFIG_LUA_FILE" ] || [ -z "$MINIO_ACCESS_KEY" ] || [ -z "$MINIO_BUCKET" ] || [ -z "$MINIO_ENDPOINT" ] || [ -z "$MINIO_REGION" ] || [ -z "$MINIO_SECRET_KEY" ] || [ -z "$OPENSSL_SECRET_KEY" ] || [ -z "$OPENSSL_SECRET_IV" ] || [ -z "$NODE_API_URL" ]; then
    echo "Error: One or more extracted encrypted values are empty!"
    exit 1
fi

echo "Replacing placeholders in Helm values file..."

if python3 --version &> /dev/null; then
    echo "Python3 is installed"
else
    echo "Error: Python3 is not installed!"
    exit 1
fi

# Example: Set service port number based on environment
if [ "$ENV_REF" == "prod" ]; then
OPSAPI_SVC_PORT_NUM=32136
    elif [ "$ENV_REF" == "test" ]; then
    OPSAPI_SVC_PORT_NUM=32134
        elif [ "$ENV_REF" == "acc" ]; then
        OPSAPI_SVC_PORT_NUM=32135
            elif [ "$ENV_REF" == "int" ]; then
            OPSAPI_SVC_PORT_NUM=32133
                elif [ "$ENV_REF" == "dev" ]; then
                OPSAPI_SVC_PORT_NUM=32132
                    else
                    OPSAPI_SVC_PORT_NUM=32136
fi

# for root postgres password run : export PGPASSWORD=$(kubectl get secret postgres.pgsql.credentials.postgresql.acid.zalan.do -o 'jsonpath={.data.password}' | base64 -d)
# for user-prd password run : export PGPASSWORD=$(kubectl get secret user-prd.pgsql.credentials.postgresql.acid.zalan.do -o 'jsonpath={.data.password}' | base64 -d)

# Use Python for reliable string replacement
python3 << EOF
import sys

# Read the file
with open('$HELM_VALUES_OUTPUT_PATH', 'r') as f:
    content = f.read()

# Replace the placeholder with the encrypted secret
content = content.replace('JWT_SECRET_KEY', '$JWT_SECRET_KEY')
content = content.replace('KEYCLOAK_AUTH_URL', '$KEYCLOAK_AUTH_URL')
content = content.replace('KEYCLOAK_CLIENT_ID', '$KEYCLOAK_CLIENT_ID')
content = content.replace('KEYCLOAK_CLIENT_SECRET', '$KEYCLOAK_CLIENT_SECRET')
content = content.replace('KEYCLOAK_REDIRECT_URI', '$KEYCLOAK_REDIRECT_URI')
content = content.replace('KEYCLOAK_TOKEN_URL', '$KEYCLOAK_TOKEN_URL')
content = content.replace('KEYCLOAK_USERINFO_URL', '$KEYCLOAK_USERINFO_URL')
content = content.replace('KEYCLOAK_TOKEN_URL', '$KEYCLOAK_TOKEN_URL')
content = content.replace('LAPIS_CONFIG_LUA_FILE', '$LAPIS_CONFIG_LUA_FILE')
content = content.replace('MINIO_ACCESS_KEY', '$MINIO_ACCESS_KEY')
content = content.replace('MINIO_BUCKET', '$MINIO_BUCKET')
content = content.replace('MINIO_ENDPOINT', '$MINIO_ENDPOINT')
content = content.replace('MINIO_REGION', '$MINIO_REGION')
content = content.replace('MINIO_SECRET_KEY', '$MINIO_SECRET_KEY')
content = content.replace('OPENSSL_SECRET_KEY', '$OPENSSL_SECRET_KEY')
content = content.replace('OPENSSL_SECRET_IV', '$OPENSSL_SECRET_IV')
content = content.replace('NODE_API_URL', '$NODE_API_URL')
content = content.replace('CICD_NAMESPACE_PLACEHOLDER', '$ENV_REF')
content = content.replace('prod-opsapi.', 'opsapi.')
content = content.replace('CICD_SVC_PORT_PLACEHOLDER', '$OPSAPI_SVC_PORT_NUM')
# Write back to file
with open('$HELM_VALUES_OUTPUT_PATH', 'w') as f:
    f.write(content)

print("Successfully replaced placeholder with encrypted secret")
EOF

cat $HELM_VALUES_OUTPUT_PATH

echo "Helm values file created at '$HELM_VALUES_OUTPUT_PATH'"
# Clean up temporary files
rm -Rf $SECRET_OUTPUT_PATH
#rm -Rf $SEALED_SECRET_OUTPUT_PATH
#rm -Rf temp.txt



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
#"/Users/balinderwalia/Documents/Work/aws_keys/.env_wsl_prod"

SECRET_INPUT_PATH="devops/kubeseal/secret_opsapi_node_per_env_input_template.yaml"
SECRET_OUTPUT_PATH="devops/kubeseal/secret_opsapi_node_${ENV_REF}.yaml"

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

#   cat temp.txt 

# rm temp.txt

rm -Rf $SECRET_OUTPUT_PATH
cp $SECRET_INPUT_PATH $SECRET_OUTPUT_PATH

# Use cross-platform sed replacement using python below

if [ ! -f "$SECRET_OUTPUT_PATH" ]; then
    echo "Error: Sealed secret output file '$SECRET_OUTPUT_PATH' not found!"
    exit 1
fi

# cat $SECRET_OUTPUT_PATH

echo "Sealing the secret using kubeseal..."
kubeseal --format yaml < $SECRET_OUTPUT_PATH > sealed_secret_opsapi_node_${ENV_REF}.yaml

# rm -Rf $SECRET_OUTPUT_PATH
# cat sealed_secret_opsapi_node_prod.yaml
echo "Sealed secret created at 'sealed_secret_opsapi_node_${ENV_REF}.yaml'"

# extract the sealed secret env_file
echo "Extracting sealed secret env_file encrypted value..."

if ! command -v yq &> /dev/null; then
    echo "Error: yq is not installed!"
    exit 1
fi

yq .spec.encryptedData.env_file sealed_secret_opsapi_node_${ENV_REF}.yaml > sealed_secret_opsapi_node_${ENV_REF}.txt
echo "Sealed env_file base64 content saved to 'sealed_secret_opsapi_node_${ENV_REF}.txt'"
# cat sealed_secret_opsapi_node_prod.txt

HELM_VALUES_INPUT_PATH=devops/helm-charts/opsapi-node/values-env-template.yaml
HELM_VALUES_OUTPUT_PATH=devops/helm-charts/opsapi-node/values-${ENV_REF}.yaml

if [ ! -f "$HELM_VALUES_INPUT_PATH" ]; then
    echo "Error: Helm values template file '$HELM_VALUES_INPUT_PATH' not found!"
    exit 1
fi

cp $HELM_VALUES_INPUT_PATH $HELM_VALUES_OUTPUT_PATH

SAFE_SEALEDSECRET_ENCRYPTED=$(<sealed_secret_opsapi_node_${ENV_REF}.txt)

# echo $SAFE_SEALEDSECRET_ENCRYPTED

if python3 --version &> /dev/null; then
    echo "Python3 is installed"
else
    echo "Error: Python3 is not installed!"
    exit 1
fi

# Use Python for reliable string replacement
python3 << EOF
import sys

# Read the file
with open('$HELM_VALUES_OUTPUT_PATH', 'r') as f:
    content = f.read()

# Replace the placeholder with the encrypted secret
content = content.replace('helmfilesecretsplaceholder', '$SAFE_SEALEDSECRET_ENCRYPTED')
content = content.replace('CICD_NAMESPACE_PLACEHOLDER', '$CICD_NAMESPACE')
content = content.replace('CICD_ENV_FILE_PLACEHOLDER_BASE64', '$ENV_FILE_CONTENT_BASE64')
content = content.replace('CICD_ENV_REF_PLACEHOLDER', '$ENV_REF')
# Write back to file
with open('$HELM_VALUES_OUTPUT_PATH', 'w') as f:
    f.write(content)

print("Successfully replaced placeholder with encrypted secret")
EOF

cat $HELM_VALUES_OUTPUT_PATH

echo "Helm values file created at '$HELM_VALUES_OUTPUT_PATH'"
# Clean up temporary files
rm -Rf $SECRET_OUTPUT_PATH
rm -Rf sealed_secret_opsapi_node_${ENV_REF}.yaml
rm -Rf temp.txt
rm -Rf sealed_secret_opsapi_node_${ENV_REF}.txt



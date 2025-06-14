# OPSAPI

Opsapi built on the top of Lua.

## Deploy on Kubernates

To deploy OPSAPI on kubernates, please follow the instructions.

#### Requirements:

    1. kubectl
    2. kubeseal
    3. helm

#### Installation:

    1. encode the env variables to base64
        Here is the sample of env variables
        DATABASE:
        DB_HOST:
        DB_PASSWORD:
        DB_PORT:
        DB_USER:
        JWT_SECRET_KEY:
        KEYCLOAK_AUTH_URL:
        KEYCLOAK_CLIENT_ID:
        KEYCLOAK_CLIENT_SECRET:
        KEYCLOAK_REDIRECT_URI:
        KEYCLOAK_TOKEN_URL:
        KEYCLOAK_USERINFO_URL:
        OPENSSL_SECRET_IV:
        OPENSSL_SECRET_KEY:
        LAPIS_CONFIG_LUA_FILE:
        MINIO_ENDPOINT:
        MINIO_ACCESS_KEY:
        MINIO_SECRET_KEY:
        MINIO_BUCKET:
        NODE_API_URL:

        NOTE: For LAPIS_CONFIG_LUA_FILE please add your variables to existing config.lua and encode the file base64, and For NODE_API_URL please add the Opsapi-Node Url.

    2. Create a secret.yaml file and add the encoded env variables in it.
        Here is the example of secret.yaml

        apiVersion: v1
        data:
            DATABASE:
            DB_HOST:
            DB_PASSWORD:
            DB_PORT:
            DB_USER:
            JWT_SECRET_KEY:
            KEYCLOAK_AUTH_URL:
            KEYCLOAK_CLIENT_ID:
            KEYCLOAK_CLIENT_SECRET:
            KEYCLOAK_REDIRECT_URI:
            KEYCLOAK_TOKEN_URL:
            KEYCLOAK_USERINFO_URL:
            LAPIS_CONFIG:
            MINIO_ACCESS_KEY:
            MINIO_BUCKET:
            MINIO_ENDPOINT:
            MINIO_SECRET_KEY:
            NODE_API_URL:
            OPENSSL_SECRET_IV:
            OPENSSL_SECRET_KEY:
        kind: Secret
        metadata:
            creationTimestamp: null
            name: opsapi-secrets
            namespace: <namespace>


    3. Run this command to generate the kubeseal:
        kubeseal --format=yaml < secret.yaml > sealed-secret.yaml

    4. You will get the sealed-secret.yaml file open the file and copy the content from key encryptedData.

    5. Put the copied secret to values file under the app_secrets

    6. Deploy OPSAPI using helm:
        helm upgrade --install opsapi ./devops/helm-charts/opsapi \
        -f ./devops/helm-charts/opsapi/values-<namespace>.yaml \
        --set image.repository=bwalia/opsapi \
        --set image.tag=latest \
        --namespace <namespace> --create-namespace

## Deploy Opsapi Node

Ospapi Node App is built in Node js to support some feature of Opsapi

## Deploy on Kubernates

To deploy OPSAPI UI on kubernates, please follow the instructions.

#### Requirements:

    1. kubectl
    2. kubeseal
    3. helm

#### Installation:

    1. encode the .env file to base64
        Here is the sample of .env

        PORT=3000

        # MinIO settings
        MINIO_ENDPOINT=
        MINIO_PORT=
        MINIO_ACCESS_KEY=
        MINIO_SECRET_KEY=
        MINIO_BUCKET=
        MINIO_REGION=

        # JWT
        JWT_SECRET=

        NOTE: Make sure JWT_SECRET Must match with the OPSAPI JWT_SECRET_KEY, only then Opsapi Node work with Opsapi.


    2. Run the kubeseal to generate sealed secrets.
        Here is the kubeseal command:
        cat node/opsapi-node/.env | kubectl create secret generic node-app-env --dry-run=client --from-file=.env=/dev/stdin -o json \ | kubeseal --format yaml --namespace <namespace>

    (MAKE SURE YOU ARE ON ROOT DIRECTORY WHILE RUN THIS COMMAND)

    4. You will get the sealed-secret.yaml file, copy the content from key encryptedData -> .env.

    5. Put the copied secret to values file under the secrets -> env_file

    6. Deploy OPSAPI Node using helm:
        helm upgrade --install opsapi-node ./devops/helm-charts/opsapi-node \
        -f ./devops/helm-charts/opsapi-node/values-<namespace>.yaml \
        --set image.repository=bwalia/opsapi-node \
        --set image.tag=latest \
        --namespace <namespace> --create-namespace



## Run Opsapi On Local

#### Requirments:

    docker

#### Installation

    1. Update the opsapi/Dockerfile:
        from this

        COPY lapis/. /app

        to this

        COPY . /app

    2. Update the node/opsapi-node/Dockerfile:
        from this

        COPY node/opsapi-node/package*.json /app/
        COPY node/opsapi-node/. /app/

        to this

        COPY ./package*.json /app/
        COPY . /app/

    3. Run the command:
        bash ./run-development.sh

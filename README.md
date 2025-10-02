# OPSAPI

Opsapi built on the top of Lua with ecommerce frontend built in Next.js.

## Components

- **OPSAPI (Backend)**: Lua-based API server with authentication and ecommerce functionality
- **OPSAPI Node**: Node.js service for additional features
- **OPSAPI Ecommerce**: Next.js frontend for multi-tenant ecommerce platform

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
        MINIO_REGION:
        NODE_API_URL:
        GOOGLE_CLIENT_ID:
        GOOGLE_CLIENT_SECRET:
        GOOGLE_REDIRECT_URI:
        FRONTEND_URL:

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
            MINIO_REGION:
            NODE_API_URL:
            OPENSSL_SECRET_IV:
            OPENSSL_SECRET_KEY:
            GOOGLE_CLIENT_ID:
            GOOGLE_CLIENT_SECRET:
            GOOGLE_REDIRECT_URI:
            FRONTEND_URL:
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

#### Requirements:

    1. docker
    2. docker-compose

#### Installation

    1. Update the lapis/Dockerfile:
        Open file: lapis/Dockerfile
        Find line: COPY lapis/. /app
        Replace with: COPY . /app

    2. Update the node/opsapi-node/Dockerfile:
        Open file: node/opsapi-node/Dockerfile
        Find lines:
            COPY node/opsapi-node/package*.json /app/
            COPY node/opsapi-node/. /app/
        Replace with:
            COPY ./package*.json /app/
            COPY . /app/

    3. Setup environment variables:

        a) Backend Environment (OPSAPI):
        Copy lapis/.sample.env to lapis/.env and update with your values:

        # Database
        DB_HOST=localhost
        DB_PORT=5432
        DB_USER=pguser
        DB_PASSWORD=pgpassword
        DATABASE=opsapi

        # JWT
        JWT_SECRET_KEY=your-jwt-secret-key

        # OpenSSL
        OPENSSL_SECRET_KEY=your-openssl-key
        OPENSSL_SECRET_IV=your-openssl-iv

        # MinIO
        MINIO_ENDPOINT=your-minio-endpoint
        MINIO_ACCESS_KEY=your-access-key
        MINIO_SECRET_KEY=your-secret-key
        MINIO_BUCKET=your-bucket
        MINIO_REGION=your-region

        # Google OAuth (Optional)
        GOOGLE_CLIENT_ID=your-google-client-id
        GOOGLE_CLIENT_SECRET=your-google-client-secret
        GOOGLE_REDIRECT_URI=http://localhost:4010/auth/google/callback

        # Frontend URL
        FRONTEND_URL=http://localhost:3000

        # Node API
        NODE_API_URL=http://localhost:3001/api

        b) Frontend Environment (OPSAPI Ecommerce):
        Create opsapi-ecommerce/opsapi-ecommerce/.env.local with:

        NEXT_PUBLIC_API_URL=http://localhost:4010
        NEXT_PUBLIC_APP_NAME=Multi-Tenant Ecommerce
        NEXT_PUBLIC_APP_VERSION=1.0.0

        c) Node Service Environment (OPSAPI Node):
        Create node/opsapi-node/.env with:

        PORT=3000

        # MinIO settings
        MINIO_ENDPOINT=your-minio-endpoint
        MINIO_PORT=9000
        MINIO_ACCESS_KEY=your-access-key
        MINIO_SECRET_KEY=your-secret-key
        MINIO_BUCKET=your-bucket
        MINIO_REGION=your-region

        # JWT (must match OPSAPI JWT_SECRET_KEY)
        JWT_SECRET=your-jwt-secret-key

    5. Run all services with Docker:
        bash ./run-dev.sh

    6. Access the application:
        - Frontend (Ecommerce): http://localhost:3000
        - Backend API (OPSAPI): http://localhost:4010
        - Node Service (OPSAPI Node): http://localhost:3001

## Google OAuth Setup

To enable Google OAuth authentication:

    1. Go to Google Cloud Console
    2. Create a new project or select existing
    3. Enable Google+ API
    4. Create OAuth 2.0 credentials
    5. Add authorized redirect URI: http://localhost:4010/auth/google/callback
    6. Update environment variables in lapis/.env:
        GOOGLE_CLIENT_ID=your-client-id
        GOOGLE_CLIENT_SECRET=your-client-secret
        GOOGLE_REDIRECT_URI=http://localhost:4010/auth/google/callback
        FRONTEND_URL=http://localhost:3000

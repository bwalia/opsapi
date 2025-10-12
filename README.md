# OPSAPI

Opsapi API is built on the top of Opneresty Nginx / Lua for increased performance and reliability

## Opneresty Nginx / Lua / Postgres - or you may refer it as `OLP Stack`
## Avoids Nginx to CGI resource consumption as lua is compiled to work directly with Nginx Workers
## OpsAPI is Simple and allows Developers to create Database API right from the begining (Batteries included)
## Nginx is highly scalable and reliable and idea of OPSAPI is to make OLP stack nginx/lua/postgres to work together think Unix sockets to have very high performance
## Native applications can just run on a single instance linux OS recommended using Unix sockets (highly recommended for production and securing database api)
## If run as containerised stack the Dockerfile is highly optimised for performance

## Status by Gatus

### Check `http://localhost:8888/`

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
       cd lapis && bash ./lapis-run-dev.sh

    6. Access the application:
        - Frontend (Ecommerce): http://localhost:3000
        - Backend API (OPSAPI): http://localhost:4010
        - Node Service (OPSAPI Node): http://localhost:3001

## Troubleshooting dev env


# Restart
docker-compose restart lapis

# Wait for startup
sleep 5

# Check if routes are loaded
docker exec -i opsapi tail -50 /var/log/nginx/error.log | grep "routes"

# Test each endpoint
TOKEN=$(docker exec -i opsapi curl -s -X POST 'http://localhost/auth/login' \
  -H 'Content-Type: application/json' \
  -d '{"username":"administrative@admin.com","password":"Admin@123"}' | jq -r '.token')

# Test roles
docker exec -i opsapi curl -s "http://localhost/api/v2/roles" -H "Authorization: Bearer $TOKEN"

# Test groups  
docker exec -i opsapi curl -s "http://localhost/api/v2/groups" -H "Authorization: Bearer $TOKEN"

# Test users
docker exec -i opsapi curl -s "http://localhost/api/v2/users" -H "Authorization: Bearer $TOKEN"



# Test database connectivity
docker exec -i opsapi psql -h 172.71.0.10 -U pguser -d opsapi -c "\dt"

Enter pgsql database password - default dev env password for pgsql is `pgpassword`

# Check if user exists
docker exec -i opsapi psql -h 172.71.0.10 -U pguser -d opsapi -c "SELECT email, uuid FROM users WHERE email = 'administrative@admin.com';"

Enter pgsql database password - default dev env password for pgsql is `pgpassword`

# Test the endpoint (note run this on host computer but it will run inside the opsapi dev container)
docker exec -i opsapi curl -s 'http://localhost/auth/login' \
  -H 'Content-Type: application/json' \
  -d '{"username":"administrative@admin.com","password":"Admin@123"}'



# Restart the container
docker-compose restart lapis

# Test 1: JSON body
docker exec -i opsapi curl -X POST 'http://localhost/auth/login' \
  -H 'Content-Type: application/json' \
  -d '{"username":"administrative@admin.com","password":"Admin@123"}'

# Test 2: Form-encoded
docker exec -i opsapi curl -X POST 'http://localhost/auth/login' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'username=administrative@admin.com&password=Admin@123'

# Test 3: Using 'email' instead of 'username'
docker exec -i opsapi curl -X POST 'http://localhost/auth/login' \
  -H 'Content-Type: application/json' \
  -d '{"email":"administrative@admin.com","password":"Admin@123"}'

# Check logs
docker exec -i opsapi tail -30 /var/log/nginx/error.log



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


# Add public route 

## 1. Update app.lua to add the route:

// Add after the /openapi.json route

-- Alternative OpenAPI spec path (PUBLIC)
app:get("/swagger/swagger.json", function(self)
    ngx.log(ngx.NOTICE, "=== Serving /swagger/swagger.json - NO AUTH REQUIRED ===")
    ngx.header["Access-Control-Allow-Origin"] = "*"
    ngx.header["Access-Control-Allow-Methods"] = "GET, OPTIONS"
    ngx.header["Access-Control-Allow-Headers"] = "Content-Type, Authorization"
    
    local ok, openapi_gen = pcall(require, "helper.openapi_generator")
    if not ok then
        ngx.log(ngx.ERR, "Failed to load openapi_generator: ", tostring(openapi_gen))
        return { status = 500, json = { error = "Generator not found" } }
    end
    
    local spec = openapi_gen.generate()
    return { status = 200, json = spec }
end)

2. Update the before_filter to include the new route:

// Update the before_filter section

app:before_filter(function(self)
    local uri = ngx.var.uri
    
    -- Double-check: Skip auth for public routes
    if uri == "/" or uri == "/health" or uri == "/swagger" or 
       uri == "/api-docs" or uri == "/openapi.json" or uri == "/metrics" or
       uri == "/swagger/swagger.json" or
       uri:match("^/auth/") then
        ngx.log(ngx.DEBUG, "Skipping auth for: ", uri)
        return
    end
    
    ngx.log(ngx.NOTICE, "Applying auth to: ", uri)
    local ok, auth = pcall(require, "helper.auth")
    if ok then
        auth.authenticate()
    end
end)

3. Update auth.lua to include the new pattern:

// Update the PUBLIC_ROUTES table in helper/auth.lua

local PUBLIC_ROUTES = {
    ["^/$"] = true,
    ["^/health$"] = true,
    ["^/swagger$"] = true,
    ["^/api%-docs$"] = true,
    ["^/openapi%.json$"] = true,
    ["^/swagger/swagger%.json$"] = true,
    ["^/metrics$"] = true,
    ["^/auth/login$"] = true,
    ["^/auth/register$"] = true,
}

4. Add it to the OpenAPI spec:

// Add to the paths section in openapi_generator.lua

["/swagger/swagger.json"] = {
    get = {
        summary = "OpenAPI Specification (Alternative Path)",
        description = "Alternative endpoint for OpenAPI 3.0 specification in JSON format",
        tags = { "Public" },
        security = {},
        responses = {
            ["200"] = {
                description = "OpenAPI 3.0 specification",
                content = {
                    ["application/json"] = {
                        schema = {
                            type = "object",
                            description = "Complete OpenAPI 3.0 specification"
                        }
                    }
                }
            }
        }
    }
},


5. Apply the changes:

# Apply all the changes using the terminal commands
docker exec -i opsapi sh -c 'cat > /tmp/update_auth.lua << '\''EOF'\''
-- Update auth.lua with new public route
local content = io.open("/app/helper/auth.lua", "r"):read("*all")
content = string.gsub(content, 
    '\''%["^/openapi%%%.json$"%] = true,'\'', 
    '\''["^/openapi%%%.json$"] = true,\n    ["^/swagger/swagger%%%.json$"] = true,'\'')
io.open("/app/helper/auth.lua", "w"):write(content)
EOF'

docker exec -i opsapi /usr/local/openresty/bin/resty /tmp/update_auth.lua

# Restart
docker-compose restart lapis
sleep 3

# Test the new endpoint
echo "Testing /swagger/swagger.json..."
curl -s http://localhost:4010/swagger/swagger.json | jq '.info.title'

# Test that it returns the same as /openapi.json
echo -e "\nComparing both endpoints..."
curl -s http://localhost:4010/openapi.json | jq '.info' > /tmp/openapi1.json
curl -s http://localhost:4010/swagger/swagger.json | jq '.info' > /tmp/openapi2.json
diff /tmp/openapi1.json /tmp/openapi2.json && echo "✅ Both endpoints return identical content"

# Test all public endpoints
echo -e "\nTesting all public endpoints..."
curl -s -o /dev/null -w "/ -> %{http_code}\n" http://localhost:4010/
curl -s -o /dev/null -w "/health -> %{http_code}\n" http://localhost:4010/health
curl -s -o /dev/null -w "/swagger -> %{http_code}\n" http://localhost:4010/swagger
curl -s -o /dev/null -w "/openapi.json -> %{http_code}\n" http://localhost:4010/openapi.json
curl -s -o /dev/null -w "/swagger/swagger.json -> %{http_code}\n" http://localhost:4010/swagger/swagger.json
curl -s -o /dev/null -w "/metrics -> %{http_code}\n" http://localhost:4010/metrics

echo -e "\n✅ All public routes working!"
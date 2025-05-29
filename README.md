

```
# Deployment onto to the Kubernates
NOTE: MAKE SURE YOU HAVE KUBESEAL IN YOUR SYSTEM

```
1. Update config.lua file for postgres DB details
2. Encode the config.lua file and put under the key LAPIS_CONFIG to create the secret.
3. Create a new file with name api-secrets.yaml with following details:
```
apiVersion: v1
kind: Secret
metadata:
  name: opsapi-secret
  namespace: <NAMESPACE>
data:
    DATABASE: {{ .Values.app_secrets.database }}
    DB_HOST: {{ .Values.app_secrets.db_host }}
    DB_PASSWORD: {{ .Values.app_secrets.db_password }}
    DB_PORT: {{ .Values.app_secrets.db_port }}
    DB_USER: {{ .Values.app_secrets.db_user }}
    JWT_SECRET_KEY: {{ .Values.app_secrets.jwt_secret_key }}
    KEYCLOAK_AUTH_URL: {{ .Values.app_secrets.keycloak_auth_url }}
    KEYCLOAK_CLIENT_ID: {{ .Values.app_secrets.keycloak_client_id }}
    KEYCLOAK_CLIENT_SECRET: {{ .Values.app_secrets.keycloak_client_secret }}
    KEYCLOAK_REDIRECT_URI: {{ .Values.app_secrets.keycloak_redirect_uri }}
    KEYCLOAK_TOKEN_URL: {{ .Values.app_secrets.keycloak_token_url }}
    KEYCLOAK_USERINFO_URL: {{ .Values.app_secrets.keycloak_userinfo_url }}
    OPENSSL_SECRET_IV: {{ .Values.app_secrets.openssl_secret_iv }}
    OPENSSL_SECRET_KEY: {{ .Values.app_secrets.openssl_secret_key }}
    LAPIS_CONFIG_LUA_FILE: {{ .Values.app_secrets.lapis_config }}
    MINIO_ENDPOINT: {{ .Values.app_secrets.minio_endpoint }}
    MINIO_ACCESS_KEY: {{ .Values.app_secrets.minio_access_key }}
    MINIO_SECRET_KEY: {{ .Values.app_secrets.minio_secret_key }}
    MINIO_BUCKET: {{ .Values.app_secrets.minio_bucket }}
```

```
5. Now, Run this command to generate the sealed-secrets
```
kubeseal --format=yaml < api-secrets.yaml > api-sealed-secret.yaml
kubeseal --format=yaml < front-secrets.yaml > front-sealed-secret.yaml
```

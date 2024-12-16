#!/bin/bash

mkdir -p lapis/logs
mkdir -p lapis/pgdata
mkdir -p lapis/keycloak_data

chmod -R +x lapis/logs
chmod -R +x lapis/pgdata
chmod -R +x lapis/keycloak_data

cd lapis
sed -i 's|COPY lapis/\. /app/|COPY . /app|' Dockerfile
docker compose down
docker compose up --build -d
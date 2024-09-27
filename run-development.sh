#!/bin/bash

mkdir -p lapis/logs
mkdir -p lapis/pgdata

chmod -R +x lapis/logs
chmod -R +x lapis/pgdata

cd lapis
docker compose up --build -d
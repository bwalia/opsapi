#!/bin/bash

set -e

# Use Python for reliable string replacement
# Input lapis/nginx-values-template.conf
# Output lapis/nginx-values-output.conf

if [ -z "$1" ]; then
ENV_REF="test"
else
ENV_REF=$1
fi

if [ -z "$2" ]; then
RENDER_NGINX_MAKE_LIVE="false"
else
RENDER_NGINX_MAKE_LIVE=$2
fi

export NGINX_RESOLVER="10.96.0.10"  # Default Kubernetes DNS resolver
export NUM_WORKERS=1
export PORT=80
export CODE_CACHE=on

NGINX_VALUES_INPUT_PATH="lapis/nginx-values.conf"

cp $NGINX_VALUES_INPUT_PATH "lapis/nginx-values-template.conf"

NGINX_VALUES_OUTPUT_PATH="lapis/nginx-values-output.conf"

python3 devops/nginx/render_config.py "lapis/nginx-values-template.conf" $NGINX_VALUES_OUTPUT_PATH

if [ "$RENDER_NGINX_MAKE_LIVE" = "true" ]; then
  mv "lapis/nginx.conf" "lapis/nginx.conf.bak"
  mv $NGINX_VALUES_OUTPUT_PATH "lapis/nginx.conf"
  echo "Rendered nginx.conf and made it live."
else
  echo "Rendered nginx-values-output.conf. To make it live, run the script with the second argument as 'true'."
fi
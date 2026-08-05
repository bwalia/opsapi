FROM openresty/openresty:1.31-alpine-fat

ARG TARGET_NGINX_CONF=nginx.conf
ARG TAG=latest

# Build metadata — injected by CI (build-push-docker-image.yml) from
# `git describe --tags --always` + GITHUB_RUN_NUMBER + `date -u`. Baked
# in as container ENVs so app.lua's os.getenv() calls resolve at request
# time (nginx.conf `env APP_VERSION;` etc. also required — declared there).
#
# Every environment (int/test/acc/prod) pulls the same
# docker.io/bwalia/opsapi:latest tag, so once a new build has propagated
# they all report the same version — which is what the "constant across
# environments" requirement in the diytaxreturn-uk platform expects.
ARG APP_VERSION=dev
ARG BUILD_NUMBER=local
ARG BUILD_TIME=""
ENV APP_VERSION=${APP_VERSION} \
    BUILD_NUMBER=${BUILD_NUMBER} \
    BUILD_TIME=${BUILD_TIME}
LABEL org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${APP_VERSION}" \
      org.opencontainers.image.created="${BUILD_TIME}" \
      opsapi.build.number="${BUILD_NUMBER}"

RUN apk add --no-cache wget make gcc libc-dev \
    && wget https://luarocks.github.io/luarocks/releases/luarocks-3.12.0.tar.gz \
    && tar zxpf luarocks-3.12.0.tar.gz \
    && cd luarocks-3.12.0 \
    && ./configure \
    && make \
    && make install \
    && cd .. \
    && rm -rf luarocks-3.12.0 luarocks.tar.gz

RUN apk add --no-cache openssl-dev
RUN luarocks install luaossl
RUN luarocks install luasec
RUN luarocks install lapis
RUN luarocks install bcrypt
RUN luarocks install tableshape
RUN luarocks install lua-resty-http
RUN luarocks install lua-resty-openidc
RUN luarocks install lua-resty-string
RUN luarocks install base64
RUN luarocks install lua-resty-jwt
RUN luarocks install payments
RUN luarocks install lua-resty-mail

RUN apk add mysql-client
RUN apk add postgresql-client
RUN apk add curl
# poppler-utils provides pdftotext + pdftoppm, used by lib/tax-extraction.lua to
# pull transactions out of uploaded PDF bank statements (and rasterise scanned
# PDFs for the Vision fallback). Without it, the "Extract" action fails on PDFs.
RUN apk add --no-cache poppler-utils
RUN wget https://dl.min.io/client/mc/release/linux-amd64/mc -O /usr/local/bin/mc \
    --tries=3 --timeout=30 && \
    chmod +x /usr/local/bin/mc

WORKDIR /app

# ────────────────────────────────────────────────────────────────────────
# Source COPY — split into semantic layers so Lua-only changes only
# rebuild the tail layer, not the whole image. Combined with .dockerignore
# (which cuts the build context from 773MB to ~10MB by excluding logs/,
# pgdata/, keycloak_data/, session-data/), this makes local iteration
# and Docker Hub push cycles dramatically faster.
#
# Layer order = least-to-most volatile. A change to routes/foo.lua only
# invalidates the routes/ layer + anything below it. Everything above
# stays cached — including all luarocks (~600MB), which is where the
# real time savings live.
# ────────────────────────────────────────────────────────────────────────

# 1. api-docs — swagger.json is used at runtime (`/tmp/swagger.json`),
#    but the docs themselves rarely change with code work.
COPY api-docs /app/api-docs

# 2. Static assets + top-level config that rarely churn.
COPY nginx.conf mime.types config.lua /app/

# 3. Lapis views (etlua templates) — rarely change but part of the app.
COPY views /app/views

# 4. Core scripts — one-shot bootstrap / migration helpers.
COPY scripts /app/scripts

# 4. Helpers + libs — reusable modules. Change less than routes/queries.
COPY helper /app/helper
COPY lib /app/lib

# 5. Models — plain Model:extend() declarations, changes rarely.
COPY models /app/models
COPY models.lua /app/models.lua

# 6. Middleware + queries — moderate churn.
COPY middleware /app/middleware
COPY queries /app/queries

# 7. Migrations — changes with every schema evolution, but doesn't
#    invalidate route/query layers below.
COPY migrations /app/migrations
COPY migrations.lua /app/migrations.lua
COPY schema-updates.lua production-schema-upgrade.lua ecommerce-migrations.lua /app/

# 8. Plugin projects (`projects/hospital-patient-manager`, etc.) are
#    NOT COPY'd here — they live at the opsapi repo root, outside this
#    Dockerfile's build context (lapis/). Consumer products
#    (diy-tax-return-uk) supply /app/projects/<code>/ at deploy time
#    via bind-mount or a wrapping image layer. Same behaviour as the
#    original `COPY . /app` (which built from lapis/, so projects/ was
#    also excluded there).

# 9. Routes — the MOST volatile. Every feature change touches these.
#    Isolated as the last content layer so day-to-day route edits
#    only invalidate this layer.
COPY routes /app/routes

# 10. app.lua wires everything together and is edited when adding new
#     route registrations. Kept separate so pure route-file additions
#     that DON'T require an app.lua edit skip this layer.
COPY app.lua /app/app.lua

# Anything else at the repo root that snuck past .dockerignore. Kept
# last as a catch-all so the volatile layers above stay stable.
# (nginx-values-*.conf etc. — used by ops tooling, harmless in image.)
COPY *.lua /app/

RUN mkdir -p /tmp/ && chown nobody /tmp/ && touch /tmp/swagger.json \
 && chown nobody /tmp/swagger.json && chmod 755 /tmp/swagger.json \
 && cp /app/api-docs/swagger.json /tmp/swagger.json

RUN mkdir -p /opt/

COPY opt /opt/
RUN chown -R nobody /opt/

RUN mkdir -p /var/log/nginx/ && chown -R nobody:root /var/log/nginx/
RUN touch /var/log/nginx/json_access.log && chown nobody:root /var/log/nginx/json_access.log
RUN touch /var/log/nginx/access.log && chown nobody:root /var/log/nginx/access.log
RUN touch /var/log/nginx/error.log && chown nobody:root /var/log/nginx/error.log

RUN chmod 755 /usr/local/openresty/nginx/logs && chown -R nobody:root /usr/local/openresty/nginx/logs
RUN touch /usr/local/openresty/nginx/logs/nginx.pid && chown nobody:root /usr/local/openresty/nginx/logs/nginx.pid
RUN chmod 775 /usr/local/openresty/nginx/logs/nginx.pid && echo "000" > /usr/local/openresty/nginx/logs/nginx.pid

EXPOSE 80

CMD ["lapis", "server"]

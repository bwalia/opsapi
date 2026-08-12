# syntax=docker/dockerfile:1.7
# ===========================================================================
# OpsAPI APP image — thin layer on top of the prebuilt dependency base.
# ===========================================================================
# The heavy, rarely-changing dependencies (OpenResty + luarocks + all rocks +
# system packages) live in bwalia/opsapi-base, built separately by the
# "Build OpsAPI Base Image" workflow. This image just COPYs the Lua source on
# top, so a normal deploy is a handful of tiny COPY layers + push (~1 min)
# instead of a ~12 min luarocks recompile every time.
#
# OPSAPI_BASE is overridable (e.g. pin a digest for reproducibility); it
# defaults to the :latest base. Declared before FROM so it can parameterise it.
# ===========================================================================
ARG OPSAPI_BASE=bwalia/opsapi-base:latest
FROM ${OPSAPI_BASE}

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

# NOTE: OpenResty, luarocks + all Lua rocks (luaossl, luasec, lapis, bcrypt,
# tableshape, lua-resty-*, base64, payments, lua-resty-mail) and the runtime
# system tools (mysql-client, postgresql-client, curl, poppler-utils, MinIO mc)
# are all provided by the bwalia/opsapi-base image this builds FROM. To change
# a dependency, edit lapis/Dockerfile.base (which rebuilds the base image).

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

# 4b. Config-as-Code (CMI) library — the registry that declares which
#     tables are portable and the JSON pretty-printer. Only the two .lua
#     modules ship in the image; the baseline .json files live in
#     opsapi/config/ (repo root, outside this build context) and are
#     mounted or docker-cp'd in at import time — same pattern the
#     cmi-import CI workflow uses via `kubectl cp`.
COPY config /app/config

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

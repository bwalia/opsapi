# Synthetic OpsAPI target for the SRE demo.
# Emits the EXACT metric schema OpsAPI produces (nginx_http_requests_total with
# status/method/endpoint labels + nginx_http_request_duration_seconds histogram),
# so the golden-signal, SLO and burn-rate dashboards/alerts are driven by real,
# production-shaped metrics even when the full app stack is not running.
# k6 drives traffic across /, /slow and /error to make the signals move.
FROM openresty/openresty:alpine

# `opm` is a Perl script and `curl` is used by the container healthcheck; the
# base alpine image ships neither (CLAUDE.md notes the missing perl).
RUN apk add --no-cache perl curl \
    && opm get knyar/nginx-lua-prometheus \
    && mkdir -p /var/log/nginx     # access/error logs (compose mounts ./logs here)

COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf

EXPOSE 80

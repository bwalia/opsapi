FROM openresty/openresty:alpine

ARG TARGET_NGINX_CONF=nginx.conf
ARG TAG=latest

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

RUN apk add mysql-client
RUN apk add postgresql-client
RUN apk add curl
RUN wget https://dl.min.io/client/mc/release/linux-amd64/mc -O /usr/local/bin/mc \
    --tries=3 --timeout=30 && \
    chmod +x /usr/local/bin/mc

WORKDIR /app

COPY . /app

RUN mkdir -p /tmp/ && chown nobody /tmp/ && touch /tmp/swagger.json
RUN chown nobody /tmp/swagger.json && chmod 755 /tmp/swagger.json
RUN cp /app/api-docs/swagger.json /tmp/swagger.json

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

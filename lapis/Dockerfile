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

EXPOSE 8080

CMD ["lapis", "server"]

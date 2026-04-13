FROM openresty/openresty:alpine

ENV LUA_PATH "/usr/local/openresty/nginx/lua/?.lua;;"
ENV LUA_CPATH "/usr/local/openresty/lualib/?.so;;"

RUN apk add --no-cache wget make gcc libc-dev \
    && wget https://luarocks.org/releases/luarocks-3.11.0.tar.gz \
    && tar zxpf luarocks-3.11.0.tar.gz \
    && cd luarocks-3.11.0 \
    && ./configure \
    && make \
    && make install \
    && cd .. \
    && rm -rf luarocks-3.11.0 luarocks.tar.gz

RUN apk add --no-cache openssl-dev
RUN luarocks install luaossl
RUN luarocks install luasec

RUN luarocks install pgmoon
RUN luarocks install luafilesystem

COPY ./lua /usr/local/openresty/nginx/lua

COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY lua.conf /usr/local/openresty/nginx/conf/lua.conf
COPY database/migrations/ /opt/nginx/data/migrations/

EXPOSE 80

CMD ["openresty", "-g", "daemon off;"]

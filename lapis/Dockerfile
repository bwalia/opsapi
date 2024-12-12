FROM openresty/openresty:alpine

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
RUN luarocks install lapis
RUN luarocks install bcrypt
RUN luarocks install tableshape
RUN luarocks install lua-resty-http
RUN luarocks install lua-resty-openidc

WORKDIR /app

COPY . /app
COPY logs/ /usr/local/openresty/nginx/logs/

COPY .env /app/.env
RUN echo "export $(cat /app/.env | xargs)" >> /etc/profile.d/lapis_env.sh
RUN chmod +x /etc/profile.d/lapis_env.sh

EXPOSE 8080

CMD ["sh", "-c", "source /etc/profile.d/lapis_env.sh && lapis server"]

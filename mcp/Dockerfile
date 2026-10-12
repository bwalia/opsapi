# OpsAPI MCP server — Streamable HTTP (POST /mcp, GET /healthz).
# Holds no OpsAPI key: every client sends its own "Authorization: Bearer opsk_…".
#   docker build -t opsapi-mcp ./mcp
#   docker run -p 8787:8787 -e OPSAPI_URL=https://int-opsapi.workstation.co.uk opsapi-mcp

FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json tsconfig.json ./
RUN npm ci
COPY src ./src
RUN npm run build

FROM node:22-alpine
ENV NODE_ENV=production HOST=0.0.0.0 PORT=8787
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force
COPY --from=build /app/dist ./dist
USER node
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://127.0.0.1:8787/healthz >/dev/null || exit 1
CMD ["node", "dist/http.js"]

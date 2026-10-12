#!/usr/bin/env node
/**
 * OpsAPI MCP server — Streamable HTTP transport.
 *
 * Stateless: every POST /mcp builds a fresh MCP server bound to the caller's
 * own key. This process holds no OpsAPI key; it forwards the client's
 * `Authorization: Bearer opsk_…` (and optional `X-Namespace-Id`) to OpsAPI.
 *
 * Env: OPSAPI_URL (required), PORT (8787), HOST (127.0.0.1), OPSAPI_DASHBOARD_URL,
 * MCP_HOST (host names clients use; default: localhost and the listen address),
 * MCP_ALLOWED_ORIGINS (browser origins allowed; default none).
 */

import http from "node:http";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { OpsApi } from "./opsapi.js";
import { createServer, VERSION } from "./tools.js";

const MAX_BODY_BYTES = 1024 * 1024;
const KEY_RE = /^Bearer\s+(opsk_[A-Za-z0-9]{16,256})$/i;

export interface HttpConfig {
  opsapiUrl: string;
  dashboardUrl?: string;
  /** Structured log sink; defaults to one JSON line per entry on stdout. */
  log?: (entry: Record<string, unknown>) => void;
  /** Host header names /mcp answers (ports ignored). Default: localhost, 127.0.0.1, [::1]. */
  allowedHosts?: string[];
  /** Origins /mcp accepts when a request sends one. Default: none, so any request with an Origin is refused. */
  allowedOrigins?: string[];
}

export const LOOPBACK_HOSTS = ["localhost", "127.0.0.1", "[::1]"];

/** "MCP.example.com:8787" → "mcp.example.com", "[::1]:80" → "[::1]"; undefined when it isn't a plain host. */
export function hostName(h?: string): string | undefined {
  return /^(\[[0-9a-f:.]+\]|[a-z0-9.-]+)(:\d{1,5})?$/i.exec(h?.trim() ?? "")?.[1].toLowerCase();
}
const origin = (o: string) => o.trim().toLowerCase().replace(/\/+$/, "");

/** "a, b" → ["a", "b"]. */
const list = (v?: string) => (v ?? "").split(",").map((s) => s.trim()).filter(Boolean);

const rpcError = (code: number, message: string) => ({ jsonrpc: "2.0", error: { code, message }, id: null });

function send(res: http.ServerResponse, status: number, body: unknown, headers: Record<string, string> = {}) {
  res.writeHead(status, { "Content-Type": "application/json", ...headers }).end(JSON.stringify(body));
}

function readBody(req: http.IncomingMessage): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    req.on("data", (c: Buffer) => {
      size += c.length;
      if (size > MAX_BODY_BYTES) {
        req.removeAllListeners("data");
        req.resume(); // drain and drop the rest so the 413 can still be sent
        reject(Object.assign(new Error("Request body too large"), { status: 413 }));
      } else chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

export function createHttpServer(cfg: HttpConfig): http.Server {
  const log = cfg.log ?? ((e) => console.log(JSON.stringify({ time: new Date().toISOString(), ...e })));
  const hosts = new Set((cfg.allowedHosts ?? LOOPBACK_HOSTS).map(hostName).filter(Boolean));
  const origins = new Set((cfg.allowedOrigins ?? []).map(origin));

  // DNS rebinding / cross-site guard: a web page can make a browser send requests here under its own host name
  // or with its own Origin. Only our host names and the listed origins get through.
  function refused(req: http.IncomingMessage): string | undefined {
    if (!hosts.has(hostName(req.headers.host))) return "Forbidden: unknown Host (set MCP_HOST to the host name clients use).";
    const o = req.headers.origin;
    if (o !== undefined && !origins.has(origin(o))) return "Forbidden: Origin not allowed (see MCP_ALLOWED_ORIGINS).";
    return undefined;
  }

  async function handleMcp(req: http.IncomingMessage, res: http.ServerResponse) {
    // Auth first: no key, no work, and nothing sent upstream.
    const key = KEY_RE.exec(req.headers.authorization ?? "")?.[1];
    if (!key) {
      return send(res, 401, rpcError(-32001, "Unauthorized: send 'Authorization: Bearer opsk_…' (your personal OpsAPI key)."), {
        "WWW-Authenticate": 'Bearer realm="opsapi-mcp"',
      });
    }
    // Stateless server: no session to resume (GET) or end (DELETE).
    if (req.method !== "POST") {
      return send(res, 405, rpcError(-32000, "Method not allowed: this server is stateless, use POST."), { Allow: "POST" });
    }
    if (Number(req.headers["content-length"] ?? 0) > MAX_BODY_BYTES) {
      return send(res, 413, rpcError(-32600, "Request body too large"));
    }

    let body: unknown;
    try {
      body = JSON.parse((await readBody(req)).toString("utf8"));
    } catch (e) {
      const status = (e as { status?: number }).status ?? 400;
      return send(res, status, rpcError(status === 413 ? -32600 : -32700, status === 413 ? "Request body too large" : "Parse error"));
    }

    const ns = req.headers["x-namespace-id"];
    const api = new OpsApi({
      baseUrl: cfg.opsapiUrl,
      apiKey: key,
      namespace: typeof ns === "string" && ns ? ns : undefined,
      dashboardUrl: cfg.dashboardUrl,
    });
    const server = createServer(api);
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
    res.on("close", () => {
      void transport.close();
      void server.close();
    });
    await server.connect(transport);
    await transport.handleRequest(req, res, body);
  }

  const httpServer = http.createServer((req, res) => {
    const started = Date.now();
    const path = (req.url ?? "/").split("?")[0];
    // Never log headers: Authorization carries the caller's key.
    res.on("finish", () => log({ level: "info", msg: "request", method: req.method, path, status: res.statusCode, ms: Date.now() - started }));

    if (path === "/healthz") return send(res, 200, { status: "ok", version: VERSION });
    if (path !== "/mcp") return send(res, 404, { error: "Not found" });
    const why = refused(req);
    if (why) return send(res, 403, rpcError(-32000, why));
    handleMcp(req, res).catch((e) => {
      log({ level: "error", msg: "mcp request failed", error: e instanceof Error ? e.message : String(e) });
      if (!res.headersSent) send(res, 500, rpcError(-32603, "Internal server error"));
      else res.end();
    });
  });
  httpServer.requestTimeout = 30_000; // whole request must arrive within 30 s
  httpServer.headersTimeout = 10_000;
  return httpServer;
}

// Run when executed directly (also through the npm bin symlink).
if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const opsapiUrl = process.env.OPSAPI_URL || "";
  if (!opsapiUrl) {
    console.error("[opsapi-mcp-http] Missing config: set OPSAPI_URL.");
    process.exit(1);
  }
  const port = Number(process.env.PORT || 8787);
  const host = process.env.HOST || "127.0.0.1";
  // Behind a domain (or listening on 0.0.0.0), MCP_HOST names it; otherwise only localhost and the listen address.
  const wildcard = ["0.0.0.0", "::"].includes(host);
  const configured = list(process.env.MCP_HOST);
  const allowedHosts = configured.length
    ? configured
    : [...LOOPBACK_HOSTS, ...(wildcard ? [] : [host.includes(":") ? `[${host}]` : host])];
  const allowedOrigins = list(process.env.MCP_ALLOWED_ORIGINS);
  const server = createHttpServer({ opsapiUrl, dashboardUrl: process.env.OPSAPI_DASHBOARD_URL, allowedHosts, allowedOrigins });
  server.listen(port, host, () =>
    console.log(JSON.stringify({
      time: new Date().toISOString(), level: "info", msg: "listening", host, port, version: VERSION, allowedHosts, allowedOrigins,
      ...(wildcard && !configured.length && { warning: "listening on all interfaces: set MCP_HOST, or only localhost is answered" }),
    }))
  );

  const shutdown = (signal: string) => {
    console.log(JSON.stringify({ time: new Date().toISOString(), level: "info", msg: "shutting down", signal }));
    server.close(() => process.exit(0));
    server.closeIdleConnections();
    setTimeout(() => process.exit(1), 10_000).unref(); // in-flight requests get 10 s
  };
  process.once("SIGTERM", () => shutdown("SIGTERM"));
  process.once("SIGINT", () => shutdown("SIGINT"));
}

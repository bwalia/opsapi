#!/usr/bin/env node
/**
 * OpsAPI MCP server — stdio transport (the default `bin`).
 *
 * The agent acts as the employee who owns the personal API key. Env:
 *   OPSAPI_URL            e.g. https://int-opsapi.workstation.co.uk   (required)
 *   OPSAPI_API_KEY        the opsk_... personal key                   (required)
 *   OPSAPI_NAMESPACE      numeric workspace id or uuid — NOT the slug (optional)
 *   OPSAPI_DASHBOARD_URL  dashboard origin for full task links         (optional)
 *
 * Tools are defined once in tools.ts; http.ts serves the same tools over HTTP.
 */

import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { OpsApi } from "./opsapi.js";
import { createServer } from "./tools.js";

const baseUrl = process.env.OPSAPI_URL || "";
const apiKey = process.env.OPSAPI_API_KEY || "";

if (!baseUrl || !apiKey) {
  // Fail loudly on stderr — stdout is the MCP transport and must stay clean.
  console.error("[opsapi-mcp] Missing config: set OPSAPI_URL and OPSAPI_API_KEY environment variables.");
  process.exit(1);
}

const server = createServer(
  new OpsApi({
    baseUrl,
    apiKey,
    namespace: process.env.OPSAPI_NAMESPACE,
    dashboardUrl: process.env.OPSAPI_DASHBOARD_URL,
  })
);

try {
  await server.connect(new StdioServerTransport());
  console.error("[opsapi-mcp] ready");
} catch (err) {
  console.error("[opsapi-mcp] fatal:", err);
  process.exit(1);
}

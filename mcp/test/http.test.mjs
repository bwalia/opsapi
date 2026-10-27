// HTTP transport: auth gate + one end-to-end run through a real MCP client
// (StreamableHTTPClientTransport) against a mocked OpsAPI HTTP server.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { createHttpServer, hostName } from "../dist/http.js";

const KEY = "opsk_" + "a1".repeat(24);
const P1 = "11111111-1111-4111-8111-111111111111";
const T1 = "dddddddd-0000-4000-8000-00000000000d";

const upstreamCalls = [];
const upstream = http.createServer((req, res) => {
  upstreamCalls.push({ url: req.url, auth: req.headers.authorization, ns: req.headers["x-namespace-id"] });
  const body = req.url.startsWith("/api/v2/kanban/my-tasks")
    ? { success: true, data: [{ uuid: T1, task_number: 1, title: "Write the MCP", status: "open", priority: "high", project_uuid: P1, overdue: false }], meta: { total: 1 } }
    : { success: false, error: "not found" };
  res.writeHead(body.success ? 200 : 404, { "Content-Type": "application/json" }).end(JSON.stringify(body));
});
let mcp;
let mcpUrl;

const listen = (s) => new Promise((r) => s.listen(0, "127.0.0.1", () => r(`http://127.0.0.1:${s.address().port}`)));

before(async () => {
  const upstreamUrl = await listen(upstream);
  mcp = createHttpServer({ opsapiUrl: upstreamUrl, dashboardUrl: "https://app.test", log: () => {} });
  mcpUrl = (await listen(mcp)) + "/mcp";
});

after(() => {
  for (const s of [mcp, upstream]) {
    s.close();
    s.closeAllConnections();
  }
});

const rpc = { jsonrpc: "2.0", id: 1, method: "tools/list" };
const post = (headers, body = JSON.stringify(rpc)) =>
  fetch(mcpUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json, text/event-stream", ...headers },
    body,
  });

test("requests without a valid Bearer opsk_ key get 401 and never reach OpsAPI", async () => {
  for (const headers of [{}, { Authorization: "Bearer not-a-key" }, { Authorization: `Basic ${KEY}` }, { Authorization: "Bearer opsk_" }]) {
    const res = await post(headers);
    assert.equal(res.status, 401, JSON.stringify(headers));
    assert.match(res.headers.get("www-authenticate") ?? "", /^Bearer/);
    const body = await res.json();
    assert.equal(body.error.code, -32001);
  }
  const get = await fetch(mcpUrl, { headers: { Accept: "text/event-stream" } });
  assert.equal(get.status, 401);
  assert.equal(upstreamCalls.length, 0);
});

test("limits and non-POST methods", async () => {
  assert.equal((await fetch(mcpUrl, { headers: { Authorization: `Bearer ${KEY}` } })).status, 405);
  assert.equal((await fetch(mcpUrl, { method: "DELETE", headers: { Authorization: `Bearer ${KEY}` } })).status, 405);
  assert.equal((await post({ Authorization: `Bearer ${KEY}` }, "x".repeat(12 * 1024 * 1024 + 1))).status, 413);
  assert.equal((await post({ Authorization: `Bearer ${KEY}` }, "{not json")).status, 400);
  const health = await fetch(mcpUrl.replace("/mcp", "/healthz"));
  assert.equal(health.status, 200);
  assert.equal(upstreamCalls.length, 0);
});

/** POST /mcp with any Host / Origin (fetch can't set Host). */
const raw = (url, headers) =>
  new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = http.request(
      { host: u.hostname, port: u.port, path: u.pathname, method: "POST", headers: { "Content-Type": "application/json", ...headers } },
      (res) => {
        let b = "";
        res.on("data", (c) => (b += c));
        res.on("end", () => resolve({ status: res.statusCode, body: b ? JSON.parse(b) : null }));
      }
    );
    req.on("error", reject);
    req.end(JSON.stringify(rpc));
  });

test("hostName keeps only a plain host name", () => {
  assert.equal(hostName("MCP.Example.com:8787"), "mcp.example.com");
  assert.equal(hostName("[::1]:80"), "[::1]");
  assert.equal(hostName("127.0.0.1"), "127.0.0.1");
  for (const bad of [undefined, "", "evil.com@127.0.0.1", "a/b", "a b", "x:y:z"]) assert.equal(hostName(bad), undefined, bad);
});

test("another Host, or any Origin by default, gets 403 before auth and never reaches OpsAPI", async () => {
  const auth = { Authorization: `Bearer ${KEY}` };
  for (const headers of [
    { ...auth, Host: "evil.example" },
    { ...auth, Host: "evil.example:" + new URL(mcpUrl).port },
    { Host: "rebind.attacker.test" },
    { ...auth, Origin: "https://evil.example" },
    { ...auth, Origin: "null" },
  ]) {
    const res = await raw(mcpUrl, headers);
    assert.equal(res.status, 403, JSON.stringify(headers));
    assert.equal(res.body.error.code, -32000);
  }
  // localhost is the same machine: allowed by default, so this one reaches the auth check.
  assert.equal((await raw(mcpUrl, { Host: `localhost:${new URL(mcpUrl).port}` })).status, 401);
  assert.equal(upstreamCalls.length, 0);
});

test("MCP_HOST and MCP_ALLOWED_ORIGINS: only the configured host and origins get through", async () => {
  const s = createHttpServer({
    opsapiUrl: "http://127.0.0.1:9", log: () => {}, allowedHosts: ["mcp.example.com:443"], allowedOrigins: ["https://app.example/"],
  });
  const url = (await listen(s)) + "/mcp";
  try {
    assert.equal((await raw(url, {})).status, 403, "the listen address is not a configured host");
    assert.equal((await raw(url, { Host: "mcp.example.com" })).status, 401);
    assert.equal((await raw(url, { Host: "MCP.example.com:8443", Origin: "https://APP.example" })).status, 401);
    assert.equal((await raw(url, { Host: "mcp.example.com", Origin: "https://other.example" })).status, 403);
  } finally {
    s.close();
    s.closeAllConnections();
  }
});

test("an MCP client lists tools and calls one; the caller's key and namespace are forwarded", async () => {
  const client = new Client({ name: "it", version: "1" });
  const transport = new StreamableHTTPClientTransport(new URL(mcpUrl), {
    requestInit: { headers: { Authorization: `Bearer ${KEY}`, "X-Namespace-Id": "7" } },
  });
  await client.connect(transport);
  try {
    const { tools } = await client.listTools();
    const names = tools.map((t) => t.name).sort();
    assert.deepEqual(names, [
      "add_comment", "complete_task", "create_category", "create_page", "create_post", "create_task", "get_page",
      "get_post", "get_task", "list_boards", "list_categories_and_tags", "list_my_tasks", "list_pages", "list_posts",
      "list_projects", "log_time", "move_task", "notify_website", "search_tasks", "set_task_pr", "update_page",
      "update_post", "update_task", "upload_image",
    ]);

    const r = await client.callTool({ name: "list_my_tasks", arguments: { due: "today" } });
    assert.ok(!r.isError);
    assert.match(r.content[0].text, /#1 Write the MCP \[open\/high\]/);
    assert.match(r.content[0].text, new RegExp(`https://app.test/dashboard/projects/${P1}/tasks/${T1}`));

    assert.equal(upstreamCalls.length, 1);
    assert.equal(upstreamCalls[0].auth, `Bearer ${KEY}`);
    assert.equal(upstreamCalls[0].ns, "7");
    assert.match(upstreamCalls[0].url, /^\/api\/v2\/kanban\/my-tasks\?due=today&date=\d{4}-\d{2}-\d{2}/);
  } finally {
    await client.close();
  }
});

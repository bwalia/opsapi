// Unit tests for the tool layer: a real MCP client talks to createServer()
// over an in-memory transport; OpsAPI is a mocked global fetch.
import { test } from "node:test";
import assert from "node:assert/strict";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { OpsApi, encodeForm } from "../dist/opsapi.js";
import { createServer, localDate } from "../dist/tools.js";

const P1 = "11111111-1111-4111-8111-111111111111";
const P2 = "22222222-2222-4222-8222-222222222222";
const P3 = "33333333-3333-4333-8333-333333333333";
const B1 = "b1b1b1b1-0000-4000-8000-000000000001";
const B2 = "b2b2b2b2-0000-4000-8000-000000000002";
const U1 = "aaaaaaaa-0000-4000-8000-00000000000a";
const U2 = "bbbbbbbb-0000-4000-8000-00000000000b";
const U3 = "cccccccc-0000-4000-8000-00000000000c";
const T1 = "dddddddd-0000-4000-8000-00000000000d";

const projects = [
  { uuid: P1, name: "Website Redesign", slug: "website-redesign", member_role: "owner", task_count: 4 },
  { uuid: P2, name: "Website API", slug: "website-api", member_role: "member", task_count: 2 },
  { uuid: P3, name: "Mobile App", slug: "mobile-app", member_role: "member", task_count: 0 },
];
const boards = [
  { uuid: B1, name: "Sprint board", is_default: false },
  { uuid: B2, name: "Main", is_default: true },
];
const columns = [
  { id: 11, name: "To Do" },
  { id: 12, name: "In Progress" },
  { id: 13, name: "Done", is_done_column: true },
];
const members = [
  { user_uuid: U1, email: "alice@acme.test", first_name: "Alice", last_name: "Smith" },
  { user_uuid: U2, email: "bob@acme.test", first_name: "Bob", last_name: "Jones" },
  { user_uuid: U3, email: "bob.j@acme.test", first_name: "Bob", last_name: "Jones" },
];

// Fake OpsAPI: routes are "METHOD /path" → data or (call) => data.
function fakeOpsApi(t, routes) {
  const calls = [];
  t.mock.method(globalThis, "fetch", async (url, init = {}) => {
    const u = new URL(url);
    const call = {
      method: init.method ?? "GET",
      path: u.pathname,
      query: Object.fromEntries(u.searchParams),
      headers: init.headers ?? {},
      body: init.body ? Object.fromEntries(new URLSearchParams(init.body)) : undefined,
    };
    calls.push(call);
    const h = routes[`${call.method} ${call.path}`];
    if (h === undefined) return Response.json({ success: false, error: "no such route" }, { status: 404 });
    return Response.json({ success: true, data: typeof h === "function" ? h(call) : h });
  });
  return calls;
}

const kanbanRoutes = {
  "GET /api/v2/kanban/projects": projects,
  [`GET /api/v2/kanban/projects/${P1}/boards`]: boards,
  [`GET /api/v2/kanban/projects/${P1}/members`]: members,
  [`GET /api/v2/kanban/boards/${B1}`]: { ...boards[0], columns },
  [`GET /api/v2/kanban/boards/${B2}`]: { ...boards[1], columns },
};

async function connect() {
  const api = new OpsApi({ baseUrl: "http://opsapi.test/", apiKey: "opsk_test", dashboardUrl: "https://app.test" });
  const server = createServer(api);
  const client = new Client({ name: "test", version: "1" });
  const [a, b] = InMemoryTransport.createLinkedPair();
  await Promise.all([server.connect(a), client.connect(b)]);
  return client;
}
const text = (r) => r.content.map((c) => c.text).join("\n");
const writes = (calls) => calls.filter((c) => c.method !== "GET");

test("encodeForm: nested values become JSON strings, empty values are dropped", () => {
  const body = encodeForm({ a: 1, m: { x: 1 }, list: ["u1"], skip: undefined, nil: null });
  assert.equal(body, "a=1&m=%7B%22x%22%3A1%7D&list=%5B%22u1%22%5D");
});

test("create_task resolves project, default board, column and assignees, and form-encodes the write", async (t) => {
  const calls = fakeOpsApi(t, {
    ...kanbanRoutes,
    [`POST /api/v2/kanban/boards/${B2}/tasks`]: (c) => ({ uuid: T1, task_number: 7, title: c.body.title, assignees: [{}, {}] }),
  });
  const client = await connect();
  const r = await client.callTool({
    name: "create_task",
    arguments: {
      project: "redesign", // unique partial name
      title: "Fix login",
      column: "in progress",
      priority: "high",
      due_date: "2026-10-20",
      assignees: ["ALICE@acme.test", U2],
    },
  });
  assert.ok(!r.isError, text(r));
  const [post] = writes(calls);
  assert.equal(post.path, `/api/v2/kanban/boards/${B2}/tasks`); // the is_default board
  assert.equal(post.headers["Content-Type"], "application/x-www-form-urlencoded");
  assert.equal(post.headers.Authorization, "Bearer opsk_test");
  assert.deepEqual(
    { ...post.body, assignee_uuids: JSON.parse(post.body.assignee_uuids) },
    { title: "Fix login", priority: "high", due_date: "2026-10-20", column_id: "12", assignee_uuids: [U1, U2] }
  );
  assert.match(text(r), /Created #7 "Fix login" in Website Redesign \/ Main/);
  assert.match(text(r), new RegExp(`url: https://app.test/dashboard/projects/${P1}/tasks/${T1}`));
  assert.equal(r.structuredContent.task.task_number, 7);
});

test("create_task: board and column by name or id", async (t) => {
  const calls = fakeOpsApi(t, { ...kanbanRoutes, [`POST /api/v2/kanban/boards/${B1}/tasks`]: { uuid: T1, task_number: 1 } });
  const client = await connect();
  const r = await client.callTool({ name: "create_task", arguments: { project: P1, board: "sprint", column: 13, title: "x" } });
  assert.ok(!r.isError, text(r));
  const [post] = writes(calls);
  assert.equal(post.path, `/api/v2/kanban/boards/${B1}/tasks`);
  assert.equal(post.body.column_id, "13");
  assert.equal(post.body.assignee_uuids, undefined);
});

test("create_task: ambiguous or unknown references fail and create nothing", async (t) => {
  const calls = fakeOpsApi(t, kanbanRoutes);
  const client = await connect();
  const cases = [
    [{ project: "website" }, /"website" matches 2 projects: Website Redesign .*Website API/],
    [{ project: "Payroll" }, /No project matches "Payroll". Available: Website Redesign/],
    [{ project: P1, board: "Kanban" }, /No board matches "Kanban"/],
    [{ project: P1, column: "Review" }, /No column matches "Review". Available: To Do \(11\)/],
    [{ project: P1, assignees: ["carol@acme.test"] }, /No project member matches "carol@acme.test"/],
    [{ project: P1, assignees: ["Bob Jones"] }, /"Bob Jones" matches 2 project members/],
    [{ project: P1, assignees: ["ali"] }, /No project member matches "ali"/], // people: exact only
  ];
  for (const [args, expected] of cases) {
    const r = await client.callTool({ name: "create_task", arguments: { title: "x", ...args } });
    assert.ok(r.isError, JSON.stringify(args));
    assert.match(text(r), expected);
  }
  assert.equal(writes(calls).length, 0);
});

test("update_task merges metadata into what the task has; set_task_pr too", async (t) => {
  const stored = JSON.stringify({ pr_url: "https://gh/pr/1", branch: "old", keep: 1, drop: true });
  const calls = fakeOpsApi(t, {
    [`GET /api/v2/kanban/tasks/${T1}`]: { uuid: T1, task_number: 3, metadata: stored }, // jsonb may arrive as a string
    [`PUT /api/v2/kanban/tasks/${T1}`]: (c) => ({ uuid: T1, task_number: 3, status: c.body.status, metadata: c.body.metadata }),
  });
  const client = await connect();
  const r = await client.callTool({
    name: "update_task",
    arguments: { task_uuid: T1, status: "review", metadata: { branch: "feat/x", drop: null } },
  });
  assert.ok(!r.isError, text(r));
  const [put] = writes(calls);
  assert.equal(put.headers["Content-Type"], "application/x-www-form-urlencoded");
  assert.equal(put.body.status, "review");
  assert.deepEqual(JSON.parse(put.body.metadata), { pr_url: "https://gh/pr/1", branch: "feat/x", keep: 1 });

  await client.callTool({ name: "set_task_pr", arguments: { task_uuid: T1, pr_url: "https://gh/pr/2" } });
  assert.deepEqual(JSON.parse(writes(calls)[1].body.metadata), { pr_url: "https://gh/pr/2", branch: "old", keep: 1, drop: true });

  const none = await client.callTool({ name: "update_task", arguments: { task_uuid: T1 } });
  assert.ok(none.isError);
  assert.equal(writes(calls).length, 2);
});

test("list_my_tasks sends the my-tasks filter contract and shows overdue + links", async (t) => {
  const calls = fakeOpsApi(t, {
    "GET /api/v2/kanban/projects": projects,
    "GET /api/v2/kanban/my-tasks": [
      { uuid: T1, task_number: 4, title: "Ship it", status: "open", priority: "critical", due_date: "2026-10-01T00:00:00Z",
        overdue: true, project_name: "Mobile App", project_uuid: P3, url: `/dashboard/projects/${P3}/tasks/${T1}` },
    ],
  });
  const client = await connect();
  const r = await client.callTool({
    name: "list_my_tasks",
    arguments: { due: "today_and_overdue", priority: ["critical", "high"], status: ["open", "in_progress"], project: "Mobile", search: "login", limit: 10 },
  });
  assert.ok(!r.isError, text(r));
  const q = calls.find((c) => c.path === "/api/v2/kanban/my-tasks").query;
  assert.deepEqual(q, {
    due: "today_and_overdue",
    date: localDate(),
    priority: "critical,high",
    status: "open,in_progress",
    project_uuid: P3,
    search: "login",
    per_page: "10",
    perPage: "10",
  });
  assert.match(text(r), /#4 Ship it \[open\/critical\] · Mobile App · due 2026-10-01 \(OVERDUE\)/);
  assert.match(text(r), new RegExp(`url: https://app.test/dashboard/projects/${P3}/tasks/${T1}`));
  assert.doesNotMatch(text(r), /unfiltered/);
  assert.equal(r.structuredContent.tasks[0].overdue, true);

  await client.callTool({ name: "list_my_tasks", arguments: { date: "2026-12-31" } });
  assert.deepEqual(calls.at(-1).query, { date: "2026-12-31", per_page: "25", perPage: "25" });
});

test("list_my_tasks still works against a server without the filters", async (t) => {
  fakeOpsApi(t, {
    "GET /api/v2/kanban/my-tasks": [{ uuid: T1, task_number: 2, title: "Old", status: "open", priority: "low", project_uuid: P1 }],
  });
  const client = await connect();
  const r = await client.callTool({ name: "list_my_tasks", arguments: { due: "today" } });
  assert.ok(!r.isError);
  assert.match(text(r), /does not support my-tasks filters/);
  assert.match(text(r), new RegExp(`url: https://app.test/dashboard/projects/${P1}/tasks/${T1}`)); // built locally
});

test("move_task resolves the column on the task's own board", async (t) => {
  const calls = fakeOpsApi(t, {
    ...kanbanRoutes,
    [`GET /api/v2/kanban/tasks/${T1}`]: { uuid: T1, task_number: 5, title: "Move me", status: "open", board_uuid: B2 },
    [`PUT /api/v2/kanban/tasks/${T1}/move`]: { uuid: T1, status: "completed" },
  });
  const client = await connect();
  const r = await client.callTool({ name: "move_task", arguments: { task_uuid: T1, column: "done" } });
  assert.ok(!r.isError, text(r));
  const [put] = writes(calls);
  assert.deepEqual(put.body, { column_id: "13" });
  assert.match(text(r), /Moved #5 "Move me" to Done \(status is now completed\)/);
});

test("search_tasks fans out over the user's projects and boards", async (t) => {
  const calls = fakeOpsApi(t, {
    "GET /api/v2/kanban/projects": projects.slice(0, 1),
    [`GET /api/v2/kanban/projects/${P1}/boards`]: boards,
    [`GET /api/v2/kanban/boards/${B1}/tasks`]: [{ uuid: T1, task_number: 9, title: "Login bug", status: "review", priority: "high" }],
    [`GET /api/v2/kanban/boards/${B2}/tasks`]: [],
  });
  const client = await connect();
  const r = await client.callTool({ name: "search_tasks", arguments: { query: "login" } });
  assert.ok(!r.isError, text(r));
  assert.ok(calls.filter((c) => c.path.endsWith("/tasks")).every((c) => c.query.search === "login"));
  assert.match(text(r), /#9 Login bug \[review\/high\] · Website Redesign \/ Sprint board/);
  assert.equal(r.structuredContent.tasks[0].url, `https://app.test/dashboard/projects/${P1}/tasks/${T1}`);
});

test("OpsAPI errors surface as tool errors with the status", async (t) => {
  fakeOpsApi(t, {});
  const client = await connect();
  const r = await client.callTool({ name: "get_task", arguments: { task_uuid: T1 } });
  assert.ok(r.isError);
  assert.match(text(r), /OpsAPI 404 on GET \/api\/v2\/kanban\/tasks\/.*: no such route/);
});

test("ids must be uuids and PR links https: anything else is refused before OpsAPI is called", async (t) => {
  const calls = fakeOpsApi(t, {});
  const client = await connect();
  const refused = async (name, args) => {
    const r = await client.callTool({ name, arguments: args }).catch((e) => ({ isError: true, content: [{ text: e.message }] }));
    assert.ok(r.isError, `${name} ${JSON.stringify(args)}`);
  };
  for (const id of ["../users", `${T1}/../../users`, `${T1}?x=1`, "1", ""]) {
    await refused("get_task", { task_uuid: id });
    await refused("add_comment", { task_uuid: id, content: "hi" });
    await refused("log_time", { task_uuid: id, minutes: 5 });
  }
  for (const pr_url of ["http://github.com/o/r/pull/1", "javascript:alert(1)", "ftp://x/y", "github.com/o/r/pull/1"]) {
    await refused("set_task_pr", { task_uuid: T1, pr_url });
    await refused("complete_task", { task_uuid: T1, pr_url });
  }
  assert.equal(calls.length, 0);
});

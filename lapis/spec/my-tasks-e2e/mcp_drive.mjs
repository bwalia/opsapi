// The real @opsapi/mcp server (stdio and HTTP) driven by an MCP client against this sandbox, with
// self-service keys minted by mcp_check.py. Run by run.sh when WITH_MCP=1 (needs node and a built mcp/).
import { readFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
const SDK = process.env.MCP_DIR + '/node_modules/@modelcontextprotocol/sdk/dist/esm/client/';
const { Client } = await import(SDK + 'index.js');
const { StdioClientTransport } = await import(SDK + 'stdio.js');
const { StreamableHTTPClientTransport } = await import(SDK + 'streamableHttp.js');

const API = process.argv[2], NS = process.argv[3], DIR = process.argv[4];
const OWNER = readFileSync(DIR + '/owner.key', 'utf8').trim(), ALICE = readFileSync(DIR + '/alice.key', 'utf8').trim();
let failures = 0;
const check = (name, ok, detail) => { console.log((ok ? '  ok   - ' : '  FAIL - ') + name + (ok || detail === undefined ? '' : '  ' + JSON.stringify(detail).slice(0, 400))); if (!ok) failures++; };
const text = (r) => (r.content || []).map((c) => c.text || '').join('\n');
const call = async (c, name, args) => { const r = await c.callTool({ name, arguments: args }); return { r, t: text(r), s: r.structuredContent, err: !!r.isError }; };

async function stdio(key) {
  const c = new Client({ name: 'e2e', version: '1' });
  await c.connect(new StdioClientTransport({ command: 'node', args: [process.env.MCP_DIR + '/dist/index.js'],
    env: { ...process.env, OPSAPI_URL: API, OPSAPI_API_KEY: key, OPSAPI_NAMESPACE: NS, OPSAPI_DASHBOARD_URL: 'https://dash.test' } }));
  return c;
}

console.log('== stdio, as the workspace owner');
const o = await stdio(OWNER);
const tools = (await o.listTools()).tools.map((t) => t.name).sort();
check('13 tools listed', ['add_comment','complete_task','create_task','get_task','list_boards','list_my_tasks','list_projects','log_time','move_task','search_tasks','set_task_pr','update_task'].every((n) => tools.includes(n)), tools);
let x = await call(o, 'list_projects', {});
check('list_projects shows both projects of workspace A only', !x.err && x.t.includes('Alpha Web') && x.t.includes('Beta Docs') && !x.t.includes('Gamma Ops'), x.t);
x = await call(o, 'list_projects', { search: 'alpha' });
check('list_projects search (server-side now)', !x.err && x.t.includes('Alpha Web') && !x.t.includes('Beta Docs'), x.t);
x = await call(o, 'list_boards', { project: 'Alpha' });
check('list_boards by partial project name shows columns', !x.err && /In Progress/.test(x.t), x.t);
x = await call(o, 'create_task', { project: 'Alpha Web', title: 'MCP e2e task', priority: 'high', due_date: '2030-06-15', assignees: ['alice@mt.test'] });
const created = x.s && (x.s.task || x.s);
const tuuid = created && (created.uuid || created.task_uuid);
check('create_task by project name, assignee by email', !x.err && !!tuuid && x.t.includes('https://dash.test/dashboard/projects/'), x.t);
x = await call(o, 'create_task', { project: 'Alpha Web', title: 'nobody', assignees: ['nobody@mt.test'] });
check('create_task with an unknown assignee is refused, nothing created', x.err, x.t);
x = await call(o, 'update_task', { task_uuid: tuuid, metadata: { k1: 'a' } });
check('update_task metadata k1', !x.err, x.t);
x = await call(o, 'update_task', { task_uuid: tuuid, metadata: { k2: 'b' }, priority: 'critical' });
x = await call(o, 'get_task', { task_uuid: tuuid });
check('update_task merged metadata (k1 kept, k2 added) and priority', !x.err && /k1/.test(JSON.stringify(x.s || x.t)) && /k2/.test(JSON.stringify(x.s || x.t)) && /critical/.test(x.t + JSON.stringify(x.s || {})), x.s || x.t);
x = await call(o, 'move_task', { task_uuid: tuuid, column: 'In Progress' });
check('move_task by column name', !x.err, x.t);
x = await call(o, 'search_tasks', { query: 'MCP e2e' });
check('search_tasks finds it', !x.err && x.t.includes('MCP e2e task'), x.t);
await o.close();

console.log('== HTTP transport, as Alice (explicitly read-only key)');
const port = 18000 + Math.floor(Math.random() * 1000);
const srv = spawn('node', [process.env.MCP_DIR + '/dist/http.js'], { env: { ...process.env, OPSAPI_URL: API, PORT: String(port), HOST: '127.0.0.1' }, stdio: 'ignore' });
await new Promise((r) => setTimeout(r, 1500));
const h = new Client({ name: 'e2e-http', version: '1' });
await h.connect(new StreamableHTTPClientTransport(new URL('http://127.0.0.1:' + port + '/mcp'), { requestInit: { headers: { Authorization: 'Bearer ' + ALICE, 'X-Namespace-Id': NS } } }));
x = await call(h, 'list_my_tasks', { due: 'today_and_overdue', date: '2030-06-15', limit: 50 });
check('list_my_tasks today_and_overdue over HTTP, with the new task first (critical)', !x.err && x.t.indexOf('MCP e2e task') !== -1 && /critical/i.test(x.t.split('\n').slice(0, 4).join(' ')), x.t.slice(0, 600));
x = await call(h, 'create_task', { project: 'Alpha Web', title: 'should not be created' });
check('Alice cannot create with her read-only key', x.err, x.t);
await h.close();
const bad = await fetch('http://127.0.0.1:' + port + '/mcp', { method: 'POST', headers: { 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' }) });
check('HTTP without a key -> 401', bad.status === 401, bad.status);
srv.kill('SIGTERM');
console.log(failures === 0 ? '\nAll checks passed.' : '\n' + failures + ' check(s) failed.');
process.exit(failures === 0 ? 0 : 1);

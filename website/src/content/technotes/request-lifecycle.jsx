import Figure, { Markers, Box, Table } from '@/components/Figure';

export const meta = {
    slug: 'request-lifecycle',
    title: 'One request through OpsAPI: from nginx worker to PostgreSQL',
    summary:
        'What happens between a request arriving and the JSON going back: the global before_filter, the public allow-list, JWT and API-key checks, feature-gated routes, the middleware chain, the routes → queries → models layering and the two response envelopes.',
    date: '2026-10-28',
    tags: ['architecture', 'lua', 'openresty', 'lapis', 'middleware'],
    audience: 'developers and SRE',
    readMinutes: 10,
};

function PipelineDiagram() {
    const x = 40;
    const w = 380;
    return (
        <svg viewBox="0 0 920 760" role="img" aria-labelledby="rl-pipe-t">
            <title id="rl-pipe-t">The stages a request passes through inside an OpsAPI nginx worker</title>
            <Markers />
            <Box x={x} y={16} w={w} h={56} title="Client" lines={['Authorization: Bearer <JWT or opsk_ key>']} />
            <line x1={x + w / 2} y1="72" x2={x + w / 2} y2="96" className="dg-line" markerEnd="url(#ah)" />

            <rect x="20" y="100" width="880" height="636" rx="10" className="dg-zone" />
            <text x="36" y="122" className="dg-mono">ONE NGINX WORKER (OPENRESTY + LUAJIT + LAPIS)</text>

            <Box x={x} y={136} w={w} h={56} title="CORS + global rate limit" lines={['CorsMiddleware.enable, GlobalRateLimit']} />
            <line x1={x + w / 2} y1="192" x2={x + w / 2} y2="214" className="dg-line" markerEnd="url(#ah)" />

            <Box x={x} y={216} w={w} h={56} title="before_filter (app.lua)" lines={['public allow-list or authenticate']} variant="accent" />
            <line x1={x + w / 2} y1="272" x2={x + w / 2} y2="294" className="dg-line" markerEnd="url(#ah)" />

            <Box x={x} y={296} w={w} h={56} title="Router" lines={['only routes whose feature is on']} />
            <line x1={x + w / 2} y1="352" x2={x + w / 2} y2="374" className="dg-line" markerEnd="url(#ah)" />

            <Box x={x} y={376} w={w} h={56} title="requireAuth" lines={['sets self.current_user']} variant="violet" />
            <line x1={x + w / 2} y1="432" x2={x + w / 2} y2="454" className="dg-line" markerEnd="url(#ah)" />
            <Box x={x} y={456} w={w} h={56} title="requireNamespace" lines={['self.namespace + permissions']} variant="violet" />
            <line x1={x + w / 2} y1="512" x2={x + w / 2} y2="534" className="dg-line" markerEnd="url(#ah)" />
            <Box x={x} y={536} w={w} h={56} title="requirePermission(module, action)" lines={['optional; 403 if missing']} variant="violet" />
            <line x1={x + w / 2} y1="592" x2={x + w / 2} y2="614" className="dg-line" markerEnd="url(#ah)" />

            <Box x={x} y={616} w={w} h={100} title="Handler → Queries → Models" lines={['scoped by namespace_id', 'returns { status, json }']} variant="amber" />

            <line x1={x + w} y1="666" x2="598" y2="666" className="dg-line" markerEnd="url(#ah)" />
            <Box x={600} y={636} w={280} h={60} title="PostgreSQL" lines={['pgmoon over cosocket']} />

            <text x="470" y="236" className="dg-text dg-strong">Public paths skip auth</text>
            <text x="470" y="256" className="dg-small">/, /health, /ready, /live, /swagger, /openapi.json,</text>
            <text x="470" y="274" className="dg-small">/metrics, /auth/login, /auth/signin, …, /api/v2/public/*</text>
            <line x1={x + w} y1="244" x2="462" y2="244" className="dg-line--dash" />

            <text x="470" y="316" className="dg-text dg-strong">Feature off: no route registered</text>
            <text x="470" y="336" className="dg-small">load_if(feature, "routes.x") skipped the require,</text>
            <text x="470" y="354" className="dg-small">so the router answers 404 for everyone</text>
            <line x1={x + w} y1="324" x2="462" y2="324" className="dg-line--dash" />

            <text x="470" y="396" className="dg-text dg-strong">Early exits</text>
            <text x="470" y="416" className="dg-small">401 no or bad token · 400 no workspace header</text>
            <text x="470" y="434" className="dg-small">404 workspace not found · 403 not a member,</text>
            <text x="470" y="452" className="dg-small">inactive member or suspended workspace</text>
            <line x1={x + w} y1="404" x2="462" y2="404" className="dg-line--red" />
        </svg>
    );
}

function LayeringDiagram() {
    const cols = [
        { x: 20, t: 'routes/x.lua', l: ['parse body (cjson)', 'wrap in middleware', 'check ownership', 'shape the response'], v: 'violet' },
        { x: 250, t: 'queries/XQueries.lua', l: ['business rules', 'validation', 'pagination', 'raw SQL via lapis.db'], v: 'amber' },
        { x: 480, t: 'models/XModel.lua', l: ['Model:extend(table)', 'timestamps', 'thin, no logic', 'autoloaded'], v: '' },
        { x: 710, t: 'PostgreSQL', l: ['namespace_id on', 'every business table', 'indexes start with it', ''], v: 'accent' },
    ];
    return (
        <svg viewBox="0 0 920 220" role="img" aria-labelledby="rl-layer-t">
            <title id="rl-layer-t">The four layers a module is built from, left to right</title>
            <Markers />
            {cols.map((c, i) => (
                <g key={c.t}>
                    <rect x={c.x} y="20" width="190" height="180" rx="8" className={`dg-box${c.v ? ` dg-box--${c.v}` : ''}`} />
                    <text x={c.x + 95} y="50" textAnchor="middle" className="dg-title">{c.t}</text>
                    {c.l.map((line, j) => (
                        <text key={j} x={c.x + 95} y={86 + j * 24} textAnchor="middle" className="dg-small">{line}</text>
                    ))}
                    {i < cols.length - 1 ? (
                        <line x1={c.x + 190} y1="110" x2={c.x + 228} y2="110" className="dg-line" markerEnd="url(#ah)" />
                    ) : null}
                </g>
            ))}
        </svg>
    );
}

function ErrorDiagram() {
    return (
        <svg viewBox="0 0 920 250" role="img" aria-labelledby="rl-err-t">
            <title id="rl-err-t">How an error becomes a catalogue-backed JSON envelope</title>
            <Markers />
            <Box x={20} y={30} w={200} h={64} title="Errors.raise(code)" lines={['or Errors.response']} variant="violet" />
            <Box x={20} y={140} w={200} h={64} title="Uncaught Lua error" lines={['maps to SYSTEM_500']} variant="red" />
            <line x1="220" y1="62" x2="318" y2="112" className="dg-line" markerEnd="url(#ah)" />
            <line x1="220" y1="172" x2="318" y2="128" className="dg-line" markerEnd="url(#ah)" />
            <Box x={320} y={86} w={220} h={66} title="install_handler (app.lua)" lines={['locale + catalogue lookup']} variant="accent" />
            <line x1="540" y1="104" x2="638" y2="66" className="dg-line" markerEnd="url(#ah)" />
            <line x1="540" y1="134" x2="638" y2="172" className="dg-line" markerEnd="url(#ah)" />
            <Box x={640} y={30} w={260} h={66} title="error_occurrences row" lines={['admin audit, sanitised']} />
            <Box x={640} y={140} w={260} h={66} title="{ error: { … } } + X-Request-ID" lines={['code, message, correlation_id']} variant="amber" />
        </svg>
    );
}

export default function Body() {
    return (
        <>
            <p>
                OpsAPI has no separate application server. Lua runs inside the nginx workers of OpenResty, Lapis routes the
                request, and pgmoon talks to PostgreSQL over nginx's non-blocking sockets. This note follows one
                authenticated request from the moment it reaches a worker to the JSON that goes back, and names the file
                that owns each step so you can read along in the repository.
            </p>

            <h2>The whole path</h2>
            <Figure caption="Each stage can end the request early. The coloured stages are the ones you touch when writing a module: the middleware wrappers and the handler." minWidth={760}>
                <PipelineDiagram />
            </Figure>

            <h2>1. Process-wide setup</h2>
            <p>
                When a worker loads <code>app.lua</code> it installs three things that run for every request: CORS
                handling, the global rate limiter (<code>OPSAPI_RATE_LIMIT_DEFAULT</code>, which also logs the edge's
                PoP code) and the catalogue-backed error handler. Route files are required once, at load time, so the
                set of routes a worker serves is fixed for its lifetime.
            </p>

            <h2>2. The before_filter</h2>
            <p>
                <code>app:before_filter</code> in <code>app.lua</code> runs before any route. It works on the raw
                request path (<code>ngx.var.request_uri</code>), not nginx's decoded <code>ngx.var.uri</code>. The
                comment there explains why: an encoded path like <code>..%2Fpublic%2Fx</code> could otherwise look
                public while the router ran a protected route.
            </p>
            <p>It then decides whether the request needs a login at all:</p>
            <ul>
                <li>An exact allow-list: <code>/</code>, <code>/health</code>, <code>/ready</code>, <code>/live</code>, <code>/swagger</code>, <code>/api-docs</code>, <code>/openapi.json</code>, <code>/metrics</code>, <code>/api/v2/system/info</code> and the public auth routes (<code>/auth/login</code>, <code>/auth/2fa/verify</code>, <code>/auth/google</code>, <code>/auth/signin</code> and friends).</li>
                <li>Patterns: anything under <code>/api/v2/public/</code>, the active theme's CSS, plugin UI files under <code>/plugin-ui/</code>, and <code>/api/v2/&lt;code&gt;/public/</code> only when <code>&lt;code&gt;</code> is a registered plugin whose prefix that is.</li>
            </ul>
            <p>
                Everything else goes to <code>helper/auth.lua</code>'s <code>authenticate()</code>. It reads the{' '}
                <code>Authorization: Bearer</code> header. A token starting <code>opsk_</code> is an API key and is
                checked against the <code>api_keys</code> table; anything else is verified as a JWT with{' '}
                <code>JWT_SECRET_KEY</code>. A missing or bad token ends the request with 401. On success the user
                info lands in <code>ngx.ctx.user</code> and <code>self.current_user</code>.
            </p>
            <pre><code>{`-- app.lua: fail closed if the auth helper can't load
local ok, auth = pcall(require, "helper.auth")
if not ok then
    ngx.log(ngx.ERR, "[auth] helper.auth failed to load: ", tostring(auth))
    return self:write({ status = 500, json = { error = "Authentication unavailable" } })
end`}</code></pre>
            <p>
                Two more checks run here for signed-in users. A user with no workspace yet is given their default one
                lazily (<code>helper/namespace-resolver.lua</code>, skipped for API keys), and a request made in the
                context of a suspended or archived workspace is refused on every route by{' '}
                <code>helper/namespace-status.lua</code>.
            </p>

            <h2>3. Only enabled modules have routes</h2>
            <p>
                Core routes (auth, users, roles, namespaces, API keys, webhooks, plugins and more) are always loaded.
                Every business module is loaded through <code>load_if</code>, which only requires the route file when
                the deployment's <code>PROJECT_CODE</code> enables that feature:
            </p>
            <pre><code>{`local function load_if(feature, route_name)
    local enabled
    if type(feature) == "table" then
        enabled = ProjectConfig.isAnyFeatureEnabled(feature)
    else
        enabled = ProjectConfig.isFeatureEnabled(feature)
    end
    if enabled then
        return safe_load_routes(route_name)
    ...

load_if("kanban", "routes.kanban-tasks")
load_if({ "ecommerce", "billing" }, "routes.customers")`}</code></pre>
            <p>
                A module that isn't enabled has no route registered, so the router answers 404 to everyone, platform
                admins included, and nothing ever queries its tables (which don't exist in that database). The{' '}
                <a href="/technotes/project-code-feature-gating/">feature gating technote</a> covers this in depth.
            </p>

            <h2>4. The middleware chain</h2>
            <p>Routes compose small wrappers from <code>middleware/</code>. Each returns a function that either answers early or calls the next one:</p>
            <Table
                head={['Wrapper', 'Sets', 'Ends the request with']}
                rows={[
                    [<code key="a">AuthMiddleware.requireAuth</code>, 'self.current_user, self.api_key_auth', '401 when there is no valid principal'],
                    [<code key="b">NamespaceMiddleware.requireNamespace</code>, 'self.namespace, namespace_permissions, is_namespace_owner, is_platform_admin', '400 no workspace given, 404 workspace not found, 403 not a member / inactive / suspended'],
                    [<code key="c">NamespaceMiddleware.requirePermission(m, a)</code>, 'nothing new (wraps requireNamespace)', '403 "Permission denied" with the required module and action'],
                    [<code key="d">NamespaceMiddleware.requireOwner</code>, '—', '403 unless owner or platform admin'],
                ]}
            />
            <p>A typical protected route reads, outside in:</p>
            <pre><code>{`app:get("/api/v2/academy/creator/account", AuthMiddleware.requireAuth(
    NamespaceMiddleware.requirePermission("courses", "read", function(self)
        local ns = self.namespace
        ...`}</code></pre>
            <p>
                <code>requirePermission</code> calls <code>requireNamespace</code> itself, so you don't nest both. The
                workspace comes from the <code>X-Namespace-Id</code> or <code>X-Namespace-Slug</code> header, then
                the JWT, then the subdomain. The{' '}
                <a href="/technotes/multi-tenancy-and-rbac/">multi-tenancy technote</a> walks through resolution and
                permissions.
            </p>

            <h2>5. Routes, queries, models</h2>
            <Figure caption="Every module follows the same split. The route file never holds SQL; the model never holds rules.">
                <LayeringDiagram />
            </Figure>
            <p>
                <code>routes/crm-accounts.lua</code> is the reference CRUD module. The list handler passes the
                workspace id down and returns the house shape:
            </p>
            <pre><code>{`app:get("/api/v2/crm/accounts", AuthMiddleware.requireAuth(
    NamespaceMiddleware.requireNamespace(function(self)
        local result = CrmQueries.getAccounts(self.namespace.id, {
            page = self.params.page,
            per_page = self.params.per_page,
            status = self.params.status,
            search = self.params.search
        })
        return {
            status = 200,
            json = { success = true, data = result.items, meta = result.meta }
        }
    end)
))`}</code></pre>
            <p>
                The query builds its <code>WHERE</code> clause starting from{' '}
                <code>namespace_id = ? AND deleted_at IS NULL</code>. The middleware sets the workspace but does not
                filter your SQL for you, so every query takes the namespace id as its first argument. Read, update and
                delete handlers also re-check that the loaded row's <code>namespace_id</code> matches before acting.
                The model is one line:
            </p>
            <pre><code>{`local Model = require("lapis.db.model").Model
local CrmAccounts = Model:extend("crm_accounts", { timestamp = true })
return CrmAccounts`}</code></pre>
            <p>
                Routes parse JSON bodies themselves (<code>ngx.req.read_body()</code> then <code>cjson.decode</code>);
                there is no automatic binding. JSON columns such as <code>metadata</code> are encoded with{' '}
                <code>cjson.encode</code> before they're stored.
            </p>

            <h2>6. What comes back</h2>
            <p>Successful responses use one envelope:</p>
            <pre><code>{`{ "success": true, "data": [ ... ], "meta": { "page": 1, "per_page": 20, "total": 42 } }`}</code></pre>
            <p>
                Errors raised through <code>lib/errors.lua</code> use the catalogue envelope instead. The message comes
                from the <code>message_catalog</code> table in the caller's locale, a sanitised row is written to{' '}
                <code>error_occurrences</code> for the admin view, and the correlation id is returned both in the body
                and as <code>X-Request-ID</code>. If the client sent an <code>X-Request-ID</code>, that value is reused.
            </p>
            <Figure caption="Any uncaught Lua error is mapped to SYSTEM_500 and logged in full on the server, so internals never reach the client." minWidth={760}>
                <ErrorDiagram />
            </Figure>
            <pre><code>{`{
  "error": {
    "code": "AUTH_INVALID_CREDENTIALS",
    "message": "The email or password you entered is incorrect.",
    "category": "error",
    "title": "Invalid credentials",
    "occurrence_uuid": "43555f92-2f0c-45d1-a342-c5c1d8219212",
    "correlation_id": "627512de-3867-4a88-9606-bc75ad743d1d"
  }
}`}</code></pre>
            <div className="callout callout--amber">
                <p>
                    The catalogue tables must exist in every deployment. Before PR #821 they were only created with the
                    tax module, so a minimal build turned every error, even a wrong password, into a bare 500.
                </p>
            </div>

            <h2>Checklist for a new route</h2>
            <ol>
                <li>Put the route file behind <code>load_if</code> with its feature, and gate its migration on the same feature.</li>
                <li>Wrap the handler in <code>requireAuth</code> and <code>requirePermission(module, action)</code>.</li>
                <li>Pass <code>self.namespace.id</code> into every query, and check row ownership before update or delete.</li>
                <li>Return <code>{'{ success, data, meta }'}</code>, and raise catalogue codes for errors.</li>
                <li>If the route must be public, add it to the before_filter allow-list on purpose, never by accident.</li>
            </ol>
        </>
    );
}

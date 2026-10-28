import Figure, { Markers, Box, Table } from '@/components/Figure';

export const meta = {
    slug: 'plugins-and-consumer-projects',
    title: 'Extending OpsAPI: plugins and consumer products',
    summary:
        'How a folder of Lua files becomes a first-class OpsAPI module with routes, RBAC, dashboard pages, events, jobs and its own migrations, and how an external product ships its schema in its own image built FROM bwalia/opsapi.',
    date: '2026-10-28',
    tags: ['plugins', 'extensibility', 'migrations', 'devops'],
    audience: 'developers and DevOps',
    readMinutes: 11,
};

function BootDiagram() {
    return (
        <svg viewBox="0 0 940 420" role="img" aria-labelledby="pl-boot-t">
            <title id="pl-boot-t">How plugins are discovered and mounted when a worker starts</title>
            <Markers />
            <rect x="20" y="20" width="250" height="250" rx="8" className="dg-box dg-box--muted" />
            <text x="36" y="46" className="dg-mono">/app/projects/helpdesk/</text>
            <text x="48" y="78" className="dg-text">project.lua</text>
            <text x="48" y="104" className="dg-text">api/tickets.lua</text>
            <text x="48" y="130" className="dg-text">events/billing.lua</text>
            <text x="48" y="156" className="dg-text">jobs/close_stale.lua</text>
            <text x="48" y="182" className="dg-text">migrations/2026…_create.lua</text>
            <text x="48" y="208" className="dg-text">ui/overview.html</text>
            <text x="36" y="250" className="dg-small">OPSAPI_PROJECTS_DIR</text>

            <line x1="270" y1="80" x2="328" y2="80" className="dg-line" markerEnd="url(#ah)" />
            <Box x={330} y={50} w={260} h={60} title="ProjectLoader.discover" lines={['folders with a project.lua']} variant="accent" />
            <line x1="460" y1="110" x2="460" y2="138" className="dg-line" markerEnd="url(#ah)" />
            <Box x={330} y={140} w={260} h={70} title="loadManifest" lines={['code not reserved, prefix free,', 'sdk_version supported']} variant="accent" />
            <line x1="460" y1="210" x2="460" y2="238" className="dg-line" markerEnd="url(#ah)" />
            <Box x={330} y={240} w={260} h={60} title="register" lines={['ProjectConfig.registerFeature']} variant="accent" />
            <line x1="460" y1="300" x2="460" y2="328" className="dg-line" markerEnd="url(#ah)" />
            <Box x={330} y={330} w={260} h={60} title="loadRoutes" lines={['under /api/v2/helpdesk']} variant="violet" />

            <line x1="590" y1="175" x2="658" y2="175" className="dg-line--red" markerEnd="url(#ah-red)" />
            <Box x={660} y={130} w={260} h={90} title="Load failure" lines={['recorded in failures()', '/ready answers 503', 'rollout stops']} variant="red" />
            <line x1="590" y1="360" x2="658" y2="360" className="dg-line" markerEnd="url(#ah)" />
            <Box x={660} y={320} w={260} h={80} title="Same treatment as core" lines={['auth, workspace, RBAC,', 'Swagger, dashboard menu']} />
        </svg>
    );
}

function MigrateDiagram() {
    return (
        <svg viewBox="0 0 940 300" role="img" aria-labelledby="pl-mig-t">
            <title id="pl-mig-t">How plugin migrations run as part of lapis migrate</title>
            <Markers />
            <Box x={20} y={40} w={170} h={60} title="lapis migrate" lines={['Helm pre-upgrade Job']} variant="amber" />
            <line x1="190" y1="70" x2="238" y2="70" className="dg-line" markerEnd="url(#ah)" />
            <Box x={240} y={40} w={190} h={60} title="core migrations" lines={['lapis_migrations']} />
            <line x1="430" y1="70" x2="478" y2="70" className="dg-line" markerEnd="url(#ah)" />
            <Box x={480} y={40} w={220} h={60} title="zzx_run_project_migrations" lines={['re-runs on every migrate']} variant="accent" />
            <line x1="700" y1="70" x2="748" y2="70" className="dg-line" markerEnd="url(#ah)" />
            <Box x={750} y={40} w={170} h={60} title="migrateAll" lines={['every plugin']} variant="accent" />

            <line x1="835" y1="100" x2="835" y2="148" className="dg-line" markerEnd="url(#ah)" />
            <rect x="240" y="150" width="680" height="126" rx="8" className="dg-zone" />
            <text x="256" y="174" className="dg-mono">PER PLUGIN, UNDER A POSTGRES ADVISORY LOCK</text>
            <Box x={256} y={186} w={200} h={72} title="pending files" lines={['filename order']} />
            <line x1="456" y1="222" x2="484" y2="222" className="dg-line" markerEnd="url(#ah)" />
            <Box x={486} y={186} w={210} h={72} title="migration + row" lines={['one transaction', 'in project_migrations']} variant="violet" />
            <line x1="696" y1="222" x2="724" y2="222" className="dg-line" markerEnd="url(#ah)" />
            <Box x={726} y={186} w={180} h={72} title="sync manifest" lines={['RBAC, menu, jobs,', 'events']} />
        </svg>
    );
}

function ConsumerDiagram() {
    return (
        <svg viewBox="0 0 940 280" role="img" aria-labelledby="pl-cons-t">
            <title id="pl-cons-t">How an external product ships its schema in its own image</title>
            <Markers />
            <rect x="20" y="20" width="250" height="150" rx="8" className="dg-box dg-box--muted" />
            <text x="36" y="46" className="dg-mono">consumer repo</text>
            <text x="48" y="78" className="dg-text">project.lua</text>
            <text x="48" y="104" className="dg-text">migrations/*.lua</text>
            <text x="48" y="130" className="dg-text">Dockerfile</text>
            <line x1="270" y1="95" x2="328" y2="95" className="dg-line" markerEnd="url(#ah)" />
            <Box x={330} y={52} w={290} h={86} title="Image FROM bwalia/opsapi:<tag>" lines={['COPY into', '/app/projects/<code>/']} variant="amber" />
            <line x1="620" y1="95" x2="678" y2="95" className="dg-line" markerEnd="url(#ah)" />
            <Box x={680} y={52} w={240} h={86} title="k8s pre-upgrade hook" lines={['lapis exec project-migrator', '.migrate(code, path)']} variant="violet" />
            <line x1="800" y1="138" x2="800" y2="188" className="dg-line" markerEnd="url(#ah)" />
            <Box x={560} y={190} w={360} h={64} title="Same database, same runner" lines={['project_migrations(project_code, name)']} variant="accent" />
            <text x="20" y="222" className="dg-small">No change to OpsAPI's repo or its</text>
            <text x="20" y="240" className="dg-small">lapis/migrations folder.</text>
        </svg>
    );
}

export default function Body() {
    return (
        <>
            <p>
                When you need an API OpsAPI doesn't have, you don't fork it. A <strong>plugin</strong> is a folder of
                Lua files that OpsAPI loads at startup. It gets the same login, workspace scoping, RBAC, migrations and
                Swagger docs as the built-in modules, plus generated dashboard pages, event handlers, scheduled jobs
                and per-workspace settings. The same mechanism lets an external product keep its schema in its own
                repository and ship it in an image built on top of OpsAPI.
            </p>

            <h2>From folder to routes</h2>
            <Figure caption="A broken plugin never fails silently: the pod reports not ready and a rolling update stops with the old pods still serving." minWidth={760}>
                <BootDiagram />
            </Figure>
            <p>
                At the bottom of <code>app.lua</code>, after the core and feature routes are mounted, the loader scans
                the projects folder and mounts each plugin it accepts:
            </p>
            <pre><code>{`local ProjectLoader = require("helper.project-loader")
for _, manifest in ipairs(ProjectLoader.init(os.getenv("OPSAPI_PROJECTS_DIR") or "/app/projects")) do
    ProjectLoader.loadRoutes(app, manifest)
end`}</code></pre>
            <p>The manifest is validated before anything is registered:</p>
            <ul>
                <li><code>code</code> is lowercase letters, digits and underscores, and can't be a built-in module's code such as <code>crm</code>.</li>
                <li><code>api_prefix</code> (default <code>/api/v2/&lt;code&gt;</code>) must be under <code>/api/</code> and not already used.</li>
                <li>A plugin that needs a newer <code>sdk_version</code> than the running OpsAPI is refused.</li>
                <li>A plugin can't replace a built-in route, and its <code>before_filter</code> only runs for its own routes.</li>
            </ul>

            <h2>Scaffolding with the CLI</h2>
            <p>The <code>opsapi</code> CLI in the image generates the pieces:</p>
            <pre><code>{`docker exec opsapi opsapi plugin:new helpdesk
docker exec opsapi opsapi make:resource helpdesk ticket title:string:required status:string
docker exec opsapi opsapi migrate
docker exec opsapi opsapi make:page helpdesk overview "Support overview"
docker exec opsapi opsapi make:listener helpdesk invoice.paid
docker exec opsapi opsapi make:job helpdesk close_stale 1h`}</code></pre>
            <Table
                head={['Command', 'What you get']}
                rows={[
                    [<code key="a">plugin:new</code>, 'The folder and a project.lua manifest'],
                    [<code key="b">make:resource</code>, 'A migration (id, uuid, namespace_id with cascade, your fields, timestamps, tenant index), an api/ file using sdk.crud, and the RBAC module, sidebar entry and events added to the manifest'],
                    [<code key="c">make:page</code>, 'A custom dashboard page under ui/, run in a sandboxed frame'],
                    [<code key="d">make:listener</code>, 'A handler that runs when another module publishes an event, such as invoice.paid'],
                    [<code key="e">make:job</code>, 'A scheduled job that runs on an interval, once per workspace'],
                ]}
            />
            <p>
                <code>sdk.crud</code> registers list, show, create, update and delete, each behind its own permission
                (<code>helpdesk_tickets.read</code>, <code>.create</code> and so on), scoped to the caller's workspace,
                with whitelisted, type-checked input. List responses use the same{' '}
                <code>{'{ success, data, meta }'}</code> envelope as core. Routes under{' '}
                <code>/api/v2/&lt;code&gt;/public/</code> skip login; everything else needs a JWT or API key.
            </p>

            <h2>Events and jobs</h2>
            <p>
                Plugins can publish changes to their tables as events (<code>helpdesk.ticket.created</code>,{' '}
                <code>.updated</code>, <code>.deleted</code>, plus business verbs like <code>.closed</code>) and
                subscribe to events from other modules. Events are recorded in the same transaction as the change, then
                delivered by background workers: at least once, retried with backoff, and claimed by exactly one worker
                with <code>FOR UPDATE SKIP LOCKED</code>. Handlers should be idempotent and key on{' '}
                <code>event.id</code>. Workspace webhooks use the same outbox.
            </p>

            <h2>Per-workspace switch and settings</h2>
            <p>
                A plugin is installed for the whole deployment, but each workspace can turn it off under{' '}
                <strong>Workspace → Plugins</strong> (<code>PUT /api/v2/namespace/plugins/:code</code>, which needs{' '}
                <code>namespace.update</code>). When it's off there, its routes answer 404 with{' '}
                <code>"code": "PLUGIN_DISABLED"</code>, its pages leave the sidebar, and no events or jobs run for that
                workspace. In the current code platform admins bypass the switch so they can operate a plugin before
                enabling it. <code>default_enabled = false</code> makes a plugin opt-in.
            </p>
            <p>
                Settings a workspace fills in are declared in the manifest and rendered as a form without dashboard
                code. Handlers read them with <code>sdk.settings(self)</code>, <code>event.settings</code> or{' '}
                <code>job.settings</code>. URL settings are called with <code>sdk.http</code>, which refuses private and
                internal addresses. Deployment-wide secrets come from environment variables named{' '}
                <code>PLUGIN_&lt;CODE&gt;_&lt;SETTING&gt;</code>.
            </p>

            <h2>Migrations</h2>
            <Figure caption="Plugin migrations are tracked apart from core in project_migrations, keyed by plugin code and file name." minWidth={760}>
                <MigrateDiagram />
            </Figure>
            <p>
                <code>lapis migrate</code> runs the core registry, including an entry named to sort last,{' '}
                <code>zzx_run_project_migrations</code>, which calls <code>ProjectMigrator.migrateAll</code>. A database
                trigger deletes that entry's row from <code>lapis_migrations</code> as soon as it's recorded, so it runs
                again on every deploy. For each plugin the migrator:
            </p>
            <ul>
                <li>takes a Postgres advisory lock, so several pods or a Helm hook plus a manual run can't race;</li>
                <li>runs pending files in filename order, each in a transaction with its tracking row, so a failure leaves nothing half-applied and stops the deploy;</li>
                <li>stores a checksum and reports <em>drift</em> if an applied file is later edited;</li>
                <li>syncs the manifest: RBAC modules, menu entries, jobs and event subscriptions.</li>
            </ul>
            <pre><code>{`CREATE TABLE IF NOT EXISTS project_migrations (
    ...
    checksum VARCHAR(64),
    UNIQUE(project_code, migration_name)
)`}</code></pre>
            <p>
                A migration file returns <code>function(schema, db) … end</code>, or{' '}
                <code>{'{ transaction = false, up = function(schema, db) … end }'}</code> for statements such as{' '}
                <code>CREATE INDEX CONCURRENTLY</code>. Prefix tables with the plugin code and give every tenant table
                a <code>namespace_id</code> foreign key with an index that starts with it.
            </p>

            <h2>Consumer products: your schema, your repo</h2>
            <p>
                Some products use OpsAPI as their backend without living in its repository. diy-tax-return-uk is one.
                They don't add migrations to <code>lapis/migrations/</code>. Instead they ship a small image that
                adds their manifest and migrations to the projects folder, and run the same migrator from their own
                deploy hook:
            </p>
            <Figure caption="From OpsAPI's side this is invisible: the runner doesn't care whether a project was baked into the image or added at deploy time." minWidth={760}>
                <ConsumerDiagram />
            </Figure>
            <pre><code>{`FROM bwalia/opsapi:<tag>          # pin the version you tested against
COPY migrations/ /app/projects/<code>/migrations/
COPY project.lua /app/projects/<code>/project.lua

# Kubernetes pre-upgrade hook:
lapis exec "require('helper.project-migrator').migrate('<code>', '/app/projects/<code>')"`}</code></pre>
            <p>
                The product's history lives in <code>project_migrations</code> under its own code, so it never collides
                with OpsAPI's <code>lapis_migrations</code>, and OpsAPI upgrades don't need to know about it.
            </p>

            <h2>Security model</h2>
            <div className="callout callout--amber">
                <p>
                    <strong>Plugins are trusted code.</strong> They run inside the OpsAPI process with full database
                    access. Only the operator of a deployment installs them, by baking them into an image. Never let
                    tenants upload plugins: in a shared deployment one tenant's code could read every other tenant's
                    data. Tenant-level customisation belongs in configuration stored in the database.
                </p>
            </div>

            <h2>Deploying</h2>
            <ol>
                <li>Bake plugins into an image <code>FROM bwalia/opsapi:&lt;version&gt;</code> and run <code>opsapi plugin:check</code> in the build.</li>
                <li>Run <code>lapis migrate</code> before new pods take traffic, for example in a Helm pre-upgrade Job; it runs core then plugin migrations.</li>
                <li>Keep the readiness probe on <code>/ready</code>, so a plugin that fails to load stops the rollout.</li>
                <li>Don't mount plugins from a writable shared volume. Rebuild the image instead.</li>
            </ol>
            <p>
                The full guide is <a href="https://github.com/bwalia/opsapi/blob/main/PLUGINS.md">PLUGINS.md</a>, and{' '}
                <a href="https://github.com/bwalia/opsapi/tree/main/projects/helpdesk">projects/helpdesk</a> is a
                complete example.
            </p>
        </>
    );
}

import Figure, { Markers, Box, Table } from '@/components/Figure';

export const meta = {
    slug: 'project-code-feature-gating',
    title: 'PROJECT_CODE: one codebase, many products',
    summary:
        'How one environment variable decides which modules a deployment has: the presets, combining codes, why core is always on, and why every module must be gated in both app.lua and migrations.lua.',
    date: '2026-10-28',
    tags: ['architecture', 'deployment', 'migrations', 'devops'],
    audience: 'developers and DevOps',
    readMinutes: 9,
};

function FlowDiagram() {
    return (
        <svg viewBox="0 0 940 400" role="img" aria-labelledby="pc-flow-t">
            <title id="pc-flow-t">From the PROJECT_CODE variable to loaded routes and created tables</title>
            <Markers />
            <Box x={20} y={150} w={190} h={70} title="PROJECT_CODE" lines={['e.g. tax_copilot,services', 'unset = all']} variant="amber" />
            <line x1="210" y1="185" x2="258" y2="185" className="dg-line" markerEnd="url(#ah)" />
            <Box x={260} y={140} w={220} h={90} title="ProjectConfig" lines={['split on commas, lowercase', 'union of preset features', 'core always added']} variant="accent" />

            <line x1="480" y1="160" x2="578" y2="72" className="dg-line" markerEnd="url(#ah)" />
            <line x1="480" y1="185" x2="578" y2="185" className="dg-line" markerEnd="url(#ah)" />
            <line x1="480" y1="210" x2="578" y2="300" className="dg-line" markerEnd="url(#ah)" />

            <Box x={580} y={30} w={340} h={84} title="app.lua: load_if(feature, route)" lines={['require the route file only when on', 'off: no route, router answers 404']} variant="violet" />
            <Box x={580} y={150} w={340} h={70} title="migrations.lua: load_if_enabled" lines={['+ conditional / conditional_array']} variant="violet" />
            <Box x={580} y={258} w={340} h={84} title="Menu + default roles" lines={['sidebar items and RBAC modules', 'filtered to the enabled set']} />

            <text x="20" y="372" className="dg-small">Plugins add their own feature at boot with ProjectConfig.registerFeature(code, features, modules).</text>
        </svg>
    );
}

function BothPlacesDiagram() {
    const cells = [
        { x: 200, y: 60, t: 'Works', l: ['routes and tables'], v: 'accent' },
        { x: 540, y: 60, t: '500s', l: ['relation … does not exist'], v: 'red' },
        { x: 200, y: 160, t: 'Unused tables', l: ['harmless, but untidy'], v: 'muted' },
        { x: 540, y: 160, t: '404, no tables', l: ['module simply absent'], v: '' },
    ];
    return (
        <svg viewBox="0 0 900 260" role="img" aria-labelledby="pc-both-t">
            <title id="pc-both-t">What happens when route gating and migration gating disagree</title>
            <text x="370" y="34" textAnchor="middle" className="dg-mono">TABLES CREATED</text>
            <text x="710" y="34" textAnchor="middle" className="dg-mono">TABLES NOT CREATED</text>
            <text x="20" y="96" className="dg-mono">ROUTES LOADED</text>
            <text x="20" y="196" className="dg-mono">ROUTES NOT LOADED</text>
            {cells.map((c) => (
                <Box key={c.t} x={c.x} y={c.y} w={320} h={70} title={c.t} lines={c.l} variant={c.v} />
            ))}
        </svg>
    );
}

export default function Body() {
    return (
        <>
            <p>
                OpsAPI ships many modules in one image: CRM, invoicing, accounting, UK tax filing, hospital and care,
                e-commerce, delivery, chat, kanban, an LMS, a CMS and more. Few deployments want all of them. The{' '}
                <code>PROJECT_CODE</code> environment variable picks which ones a deployment has, at boot, for the whole
                process. Modules it leaves out have no routes and no tables.
            </p>

            <h2>How it flows</h2>
            <Figure caption="One variable feeds three consumers. The route loader and the migration loader must agree, which is the rule this note is about." minWidth={760}>
                <FlowDiagram />
            </Figure>
            <p>
                <code>helper/project-config.lua</code> reads the variable, splits it on commas, lowercases and trims
                each code, and takes the union of each preset's features. If the variable is unset it means{' '}
                <code>all</code>. An unknown code is logged as a warning and skipped. <code>core</code> is added even
                if no preset names it:
            </p>
            <pre><code>{`-- Always ensure CORE is included
if not feature_set[ProjectConfig.FEATURES.CORE] then
    table.insert(features, 1, ProjectConfig.FEATURES.CORE)
    feature_set[ProjectConfig.FEATURES.CORE] = true
end`}</code></pre>
            <p>
                The result is cached per worker, so changing the variable means restarting the pods. That's
                deliberate: the set of routes and the database schema must not drift during a process's life.
            </p>

            <h2>The presets</h2>
            <p>These are the codes defined in <code>ProjectConfig.PROJECT_FEATURES</code> today:</p>
            <Table
                head={['Code', 'Features it enables (core always included)']}
                rows={[
                    [<code key="1">all</code>, 'Every feature: the default when PROJECT_CODE is unset'],
                    [<code key="2">core_only</code>, 'menu, themes'],
                    [<code key="3">tax_copilot</code>, 'tax_copilot, notifications, menu, themes'],
                    [<code key="4">business</code>, 'crm, timesheets, invoicing, accounting, kanban, notifications, menu, forms, themes'],
                    [<code key="5">ecommerce</code>, 'ecommerce, delivery, notifications, reviews, menu, shop, forms, themes'],
                    [<code key="6">ecommerce_chat</code>, 'ecommerce, delivery, chat, notifications, reviews, menu, forms, themes'],
                    [<code key="7">collaboration</code>, 'chat, kanban, notifications, menu, vault, services, forms, themes'],
                    [<code key="8">hospital</code>, 'hospital, notifications, menu, forms, themes'],
                    [<code key="9">field_service</code>, 'field_service, ecommerce, timesheets, invoicing, notifications, menu, forms, themes'],
                    [<code key="10">property</code>, 'crm, kanban, invoicing, notifications, menu, forms, themes'],
                    [<code key="11">cms</code>, 'cms, menu, forms, themes'],
                    [<code key="12">academy</code>, 'academy, menu, forms, themes'],
                    [<code key="13">billing</code>, 'billing, notifications, menu, forms, themes'],
                    [<code key="14">services</code>, 'services (feature-only)'],
                    [<code key="15">forms</code>, 'forms (feature-only)'],
                    [<code key="16">ats</code>, 'ats (feature-only)'],
                ]}
            />
            <h3>Combining codes</h3>
            <p>
                Codes combine with commas: <code>PROJECT_CODE=ecommerce,chat</code> or{' '}
                <code>tax_copilot,services</code>. Three codes, <code>services</code>, <code>forms</code> and{' '}
                <code>ats</code>, are <em>feature-only</em>: they add their module and migrations but don't seed a
                tenant of their own when combined with a real product code. So{' '}
                <code>PROJECT_CODE=tax_copilot,ats</code> still yields exactly one primary workspace, now with hiring
                enabled.
            </p>

            <h2>Gating routes</h2>
            <p>
                In <code>app.lua</code>, core route files go through <code>safe_load_routes</code> unconditionally.
                Every module route goes through <code>load_if</code>, which only <code>require</code>s the file when
                its feature is enabled. A list means any of them:
            </p>
            <pre><code>{`load_if("kanban", "routes.kanban-boards")
load_if({ "ecommerce", "billing" }, "routes.customers")`}</code></pre>
            <p>
                Because the route is never registered, a request for a disabled module gets 404 from the router for
                everyone. No middleware runs, no role or ownership can unlock it, and nothing touches its tables.
            </p>

            <h2>Gating migrations</h2>
            <p>
                <code>migrations.lua</code> is one registry of every migration, built conditionally. Feature modules
                are loaded with <code>load_if_enabled</code>, and each registry entry is wrapped in{' '}
                <code>conditional</code> or <code>conditional_array</code>:
            </p>
            <pre><code>{`local crm_system_migrations = load_if_enabled(ProjectConfig.FEATURES.CRM, "migrations.crm-system") or {}

['500_crm_create_pipelines'] = conditional_array(ProjectConfig.FEATURES.CRM, crm_system_migrations, 1),`}</code></pre>
            <p>
                The detail that matters is what a disabled entry returns. It returns <code>nil</code>, not a no-op
                function, so the key is left out of the registry entirely. The comment in the file explains why: a
                no-op would be run and recorded in <code>lapis_migrations</code> as applied, so the day you enable
                the feature its tables would never be created and its routes would fail with "relation does not
                exist". Leaving the key out keeps the migration pending until the feature is on. Skips are still
                counted by <code>helper/migration-tracker.lua</code>, which also supports a dry run.
            </p>

            <h2>Why both places, every time</h2>
            <Figure caption="The top-right cell is the outage. Gate a new module's routes and its migrations on the same feature." minWidth={720}>
                <BothPlacesDiagram />
            </Figure>
            <p>Adding a module therefore touches the same feature name in several places:</p>
            <ol>
                <li>A migration module in <code>migrations/</code>, registered with <code>conditional</code> or <code>conditional_array</code> in <code>migrations.lua</code>.</li>
                <li>Model, queries and routes files, with the route loaded through <code>load_if</code> in <code>app.lua</code>.</li>
                <li>The RBAC modules under <code>PROJECT_MODULES</code> in <code>helper/project-config.lua</code>, so the role editor offers them.</li>
                <li>The feature added to the presets that should include it.</li>
            </ol>
            <div className="callout callout--amber">
                <p>
                    Anything every request depends on belongs in core, not in a feature. The error catalogue used to be
                    created only by the tax module; deployments without tax answered every error with a generic 500
                    until it moved to core.
                </p>
            </div>

            <h2>PROJECT_CODE is the only hard boundary</h2>
            <p>
                Because it's process-wide, <code>PROJECT_CODE</code> is the only control that holds for workspace owners
                and platform admins too. Roles restrict members; menu settings only hide pages. If one customer must
                only ever reach the business modules (CRM, timesheets, invoicing, accounting, kanban), give them a deployment and database of their own with a narrow preset
                such as <code>business</code>. Only the codes in the table above are recognised; an unknown one is
                skipped with a warning, so check the boot log after changing it. The
                live demo identity service runs <code>core_only</code> for exactly this reason: sign-in, users,
                workspaces and roles, and nothing else.
            </p>

            <h2>Local and CI usage</h2>
            <pre><code>{`./start.sh -e local -n -j core_only        # core + menu + themes tables
./start.sh -e local -n -j tax_copilot      # core + tax tables
docker exec -e PROJECT_CODE=ecommerce -it opsapi lapis migrate`}</code></pre>
        </>
    );
}

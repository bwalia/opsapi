import Figure, { Markers, Box, Table } from '@/components/Figure';

export const meta = {
    slug: 'modules-map',
    title: 'The modules map: what each PROJECT_CODE switches on',
    summary:
        'Every business module behind its feature flag, which deployment presets include which, how a preset decides what routes and tables exist, and how to call it all from TypeScript.',
    date: '2026-10-28',
    tags: ['modules', 'project_code', 'architecture', 'sdk'],
    audience: 'developers, DevOps',
    readMinutes: 8,
};

// Mirrors ProjectConfig.PROJECT_FEATURES in lapis/helper/project-config.lua
// (core is always on, so it isn't a column).
const MODULES = [
    'crm', 'invoicing', 'accounting', 'tax_copilot', 'bank_transactions', 'timesheets', 'kanban', 'chat',
    'notifications', 'ecommerce', 'delivery', 'reviews', 'shop', 'billing', 'hospital', 'field_service',
    'academy', 'cms', 'forms', 'ats', 'themes', 'vault', 'services', 'menu',
];
const PRESETS = {
    all: MODULES,
    business: ['crm', 'timesheets', 'invoicing', 'accounting', 'kanban', 'notifications', 'menu', 'forms', 'themes'],
    property: ['crm', 'kanban', 'invoicing', 'notifications', 'menu', 'forms', 'themes'],
    collaboration: ['chat', 'kanban', 'notifications', 'menu', 'vault', 'services', 'forms', 'themes'],
    ecommerce: ['ecommerce', 'delivery', 'notifications', 'reviews', 'menu', 'shop', 'forms', 'themes'],
    ecommerce_chat: ['ecommerce', 'delivery', 'chat', 'notifications', 'reviews', 'menu', 'forms', 'themes'],
    field_service: ['field_service', 'ecommerce', 'timesheets', 'invoicing', 'notifications', 'menu', 'forms', 'themes'],
    hospital: ['hospital', 'notifications', 'menu', 'forms', 'themes'],
    tax_copilot: ['tax_copilot', 'notifications', 'menu', 'themes'],
    billing: ['billing', 'notifications', 'menu', 'forms', 'themes'],
    academy: ['academy', 'menu', 'forms', 'themes'],
    cms: ['cms', 'menu', 'forms', 'themes'],
    core_only: ['menu', 'themes'],
    services: ['services'],
    forms: ['forms'],
    ats: ['ats'],
};

function PipelineDiagram() {
    return (
        <svg viewBox="0 0 940 280" role="img" aria-labelledby="mm-pipe-t">
            <title id="mm-pipe-t">PROJECT_CODE decides which route files load and which migrations run</title>
            <Markers />
            <Box x={10} y={100} w={190} h={80} title="PROJECT_CODE" lines={['e.g. business,cms', 'per deployment']} variant="amber" />
            <line x1="200" y1="140" x2="248" y2="140" className="dg-line" markerEnd="url(#ah)" />
            <Box x={250} y={100} w={200} h={80} title="Enabled features" lines={['presets merged,', 'core always on']} variant="accent" />
            <line x1="450" y1="125" x2="508" y2="70" className="dg-line" markerEnd="url(#ah)" />
            <line x1="450" y1="155" x2="508" y2="210" className="dg-line" markerEnd="url(#ah)" />
            <Box x={510} y={30} w={200} h={70} title="app.lua" lines={['load_if(feature, route)']} />
            <Box x={510} y={180} w={200} h={70} title="migrations.lua" lines={['load_if_enabled(...)']} />
            <line x1="710" y1="65" x2="758" y2="65" className="dg-line--accent" markerEnd="url(#ah-acc)" />
            <line x1="710" y1="215" x2="758" y2="215" className="dg-line--accent" markerEnd="url(#ah-acc)" />
            <Box x={760} y={30} w={170} h={70} title="Routes served" lines={['others answer 404']} variant="accent" />
            <Box x={760} y={180} w={170} h={70} title="Tables created" lines={['others never exist']} variant="accent" />
        </svg>
    );
}

function CoverageMatrix() {
    const rows = Object.keys(PRESETS);
    const x0 = 150;
    const step = 32;
    const y0 = 170;
    const rowH = 24;
    return (
        <svg viewBox={`0 0 960 ${y0 + rows.length * rowH + 10}`} role="img" aria-labelledby="mm-matrix-t">
            <title id="mm-matrix-t">Which modules each PROJECT_CODE preset switches on</title>
            {MODULES.map((m, j) => (
                <text key={m} transform={`translate(${x0 + j * step + 4},${y0 - 14}) rotate(-55)`} className="dg-mono">{m}</text>
            ))}
            {rows.map((p, i) => {
                const y = y0 + i * rowH;
                const on = new Set(PRESETS[p]);
                return (
                    <g key={p}>
                        {i % 2 === 0 ? <rect x="8" y={y - 12} width="900" height={rowH} className="dg-box--muted" style={{ stroke: 'none' }} /> : null}
                        <text x="14" y={y + 4} className="dg-text dg-strong">{p}</text>
                        {MODULES.map((m, j) => (on.has(m)
                            ? <circle key={m} cx={x0 + j * step} cy={y} r="7" className="dg-step" />
                            : <circle key={m} cx={x0 + j * step} cy={y} r="2.5" className="dg-head" />))}
                    </g>
                );
            })}
        </svg>
    );
}

export default function Body() {
    return (
        <>
            <p>
                One OpsAPI codebase carries every module. Each deployment picks which ones exist with a single
                environment variable, <code>PROJECT_CODE</code>. A preset name such as <code>business</code> or{' '}
                <code>ecommerce</code> maps to a list of feature flags; several presets can be combined with commas
                (<code>ecommerce,collaboration</code>), and <code>core</code> is always on.
            </p>

            <h2>How a preset decides</h2>
            <Figure caption="Route files for a disabled feature are never loaded, so their URLs answer 404 for everyone, workspace owners and platform admins included, and their tables are never created.">
                <PipelineDiagram />
            </Figure>
            <p>
                This is the only hard boundary between module sets. Roles inside a workspace can hide a module from a
                member (403), and the per-workspace menu can hide a page, but neither removes the route. If a tenant must
                never reach a module, give it its own deployment with a narrower <code>PROJECT_CODE</code>. A code that
                isn't a preset name is skipped with a warning, so combine preset names, not individual feature names.
            </p>

            <h2>Presets at a glance</h2>
            <Figure caption="A filled dot means the preset switches the module on. Every preset also includes core: sign-in, users, workspaces, roles, API keys, webhooks, audit and plugins." minWidth={860}>
                <CoverageMatrix />
            </Figure>

            <h2>The modules</h2>
            <Table
                head={['Module (flag)', 'What it covers', 'Example route']}
                rows={[
                    ['CRM (crm)', 'Accounts, contacts, deals, pipelines, leads, activities', <code key="1">/api/v2/crm/…</code>],
                    ['Invoicing (invoicing)', 'Invoice generation, PDFs and payments', <code key="2">/api/v2/invoices</code>],
                    ['Accounting (accounting)', 'Bookkeeping, VAT returns, trial balance, AI-assisted', <code key="3">/api/v2/accounting/accounts</code>],
                    ['Tax copilot (tax_copilot)', 'UK tax return agent with HMRC MTD filing', <code key="4">/api/v2/tax/file</code>],
                    ['Bank transactions (bank_transactions)', 'Bank transaction tracking', <code key="5">/api/v2/bank-transactions</code>],
                    ['Timesheets (timesheets)', 'Time tracking and approval', <code key="6">/api/v2/timesheets</code>],
                    ['Kanban (kanban)', 'Projects, boards, sprints, tasks, time tracking', <code key="7">/api/v2/kanban/…</code>],
                    ['Chat (chat)', 'Slack-like channels, messages, mentions, reactions', <code key="8">/api/chat/channels</code>],
                    ['Notifications (notifications)', 'Push notifications to devices', '—'],
                    ['E-commerce (ecommerce)', 'Stores, products, orders, payments', <code key="9">/api/v2/stores</code>],
                    ['Delivery (delivery)', 'Delivery partners, requests and pricing', <code key="10">/api/v2/delivery-requests</code>],
                    ['Reviews (reviews)', 'Product and store reviews', '—'],
                    ['Shop (shop)', 'Configurable catalogue, carts, quotes, Stripe checkout', '—'],
                    ['Billing (billing)', 'Apps, flat-tier plans, entitlements, licences', <code key="11">/api/v2/billing/plans</code>],
                    ['Hospital and care (hospital)', 'Hospitals, wards, patients, care plans, medications', <code key="12">/api/v2/hospitals</code>],
                    ['Field service (field_service)', 'Service jobs, phases, sites, engineer visits', <code key="13">/api/v2/field-service/jobs</code>],
                    ['Academy (academy)', 'Courses and lessons with rich content', <code key="14">/api/v2/academy/courses</code>],
                    ['CMS (cms)', 'Website pages and blog: posts, categories, tags, media', <code key="15">/api/v2/cms/posts</code>],
                    ['Forms (forms)', 'Form builder, public forms, responses', <code key="16">/api/v2/forms</code>],
                    ['Hiring (ats)', 'Jobs, candidates, AI first-round interviews', <code key="17">/api/v2/ats/…</code>],
                    ['Themes (themes)', 'Multi-tenant theming', <code key="18">/api/v2/themes/…</code>],
                    ['Vault (vault)', 'Secret vault', <code key="19">/api/v2/vault</code>],
                    ['Services (services)', 'GitHub workflow integration', <code key="20">/api/v2/namespace/services/…</code>],
                    ['Menu (menu)', 'Backend-driven navigation for the dashboard', <code key="21">/api/v2/user/menu</code>],
                ]}
            />
            <p>
                Plugins add to this list without forking: a plugin under <code>projects/&lt;name&gt;/</code> registers its
                own feature, routes and migrations at boot.
            </p>

            <h2>Calling it from TypeScript</h2>
            <p>
                <code>@opsapi/client</code> is a typed client for every endpoint, plugins included. A server or script
                uses an API key scoped to one workspace and the modules it needs:
            </p>
            <pre><code>{`import { createClient } from '@opsapi/client';

const opsapi = createClient({
  baseUrl: 'https://api.example.com',
  token: process.env.OPSAPI_KEY,   // an API key or a JWT
  namespace: 'acme',               // workspace slug or UUID
});

const { data } = await opsapi.GET('/api/v2/customers', { params: { query: { page: 1 } } });`}</code></pre>
            <p>
                Keys are created under <strong>My Workspace → API Keys</strong> or over the API with scopes such as{' '}
                <code>{`{ customers: ['read', 'create'], invoices: ['read'] }`}</code>. A route for a module your
                deployment doesn't include still exists in the types, but the server answers 404.
            </p>
        </>
    );
}

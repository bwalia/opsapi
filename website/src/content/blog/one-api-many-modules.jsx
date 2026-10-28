import Figure, { Markers, Box } from '@/components/Figure';

export const meta = {
    slug: 'one-api-many-modules',
    title: 'One API, many modules: why we stopped building a backend per product',
    summary:
        'A separate backend for every product means separate logins, user tables and security fixes. OpsAPI keeps one multi-tenant core and switches business modules on per deployment.',
    date: '2026-10-28',
    tags: ['architecture', 'multi-tenancy', 'cost', 'platform'],
    audience: 'technical managers',
    readMinutes: 6,
};

function CompareDiagram() {
    const left = [
        { x: 20, t: 'Shop app' },
        { x: 160, t: 'CRM app' },
        { x: 300, t: 'Tax app' },
    ];
    const rows = ['own sign-in', 'own users', 'own database'];
    return (
        <svg viewBox="0 0 900 290" role="img" aria-labelledby="oam-cmp-t">
            <title id="oam-cmp-t">Three products with three of everything, compared with one OpsAPI core and switchable modules</title>
            <Markers />
            <text x="20" y="30" className="dg-mono">A BACKEND PER PRODUCT</text>
            {left.map((c) => (
                <g key={c.t}>
                    <Box x={c.x} y={44} w={120} h={44} title={c.t} variant="violet" />
                    {rows.map((r, i) => (
                        <Box key={r} x={c.x} y={98 + i * 54} w={120} h={44} title={r} variant="red" />
                    ))}
                </g>
            ))}
            <line x1="450" y1="20" x2="450" y2="270" className="dg-life" />
            <text x="480" y="30" className="dg-mono">ONE OPSAPI, MODULES PER DEPLOYMENT</text>
            <Box x={480} y={44} w={120} h={44} title="Shop" variant="violet" />
            <Box x={620} y={44} w={120} h={44} title="CRM" variant="violet" />
            <Box x={760} y={44} w={120} h={44} title="Tax" variant="violet" />
            <Box x={480} y={108} w={400} h={70} title="OpsAPI core" lines={['sign-in, users, roles, workspaces, webhooks']} variant="accent" />
            <Box x={480} y={198} w={400} h={56} title="One PostgreSQL" lines={['every row tagged with its workspace']} />
        </svg>
    );
}

export default function Body() {
    return (
        <>
            <p>
                Most teams don't set out to run five backends. It happens one product at a time: a shop needs an API, so
                it gets one. Then a CRM, then a booking tool, then something for tax. Each arrives with its own sign-in,
                its own user table, its own idea of roles and its own copy of the same security fixes. Two years in,
                a password policy change is five tickets and a customer who uses two products has two accounts.
            </p>
            <p>
                OpsAPI takes the other route. There's one API with a shared core, and the business modules live behind
                it as switchable parts.
            </p>

            <Figure caption="On the left, every product repeats sign-in, users and storage. On the right, products are modules on one core: a fix to sign-in or roles lands once." minWidth={760}>
                <CompareDiagram />
            </Figure>

            <h2>What the core gives every module</h2>
            <ul>
                <li><strong>Sign-in</strong> with passwords and emailed codes, Google and Apple, lockout and rate limits.</li>
                <li><strong>Workspaces</strong>: each customer or company is a workspace, and every record is kept apart by workspace.</li>
                <li><strong>Roles and permissions</strong> per workspace, down to read, create, update and delete per module.</li>
                <li><strong>API keys, webhooks, an audit trail and plugins</strong>, the same for every module.</li>
            </ul>
            <p>
                A new module only has to describe its own data and rules. It inherits everything else, and so does every
                app built on it.
            </p>

            <h2>Modules are switched on per deployment</h2>
            <p>
                Not every customer should have every module. Each OpsAPI deployment sets one value,{' '}
                <code>PROJECT_CODE</code>, to a preset: <code>business</code> brings CRM, invoicing, accounting,
                timesheets and projects; <code>ecommerce</code> brings stores, orders, delivery and reviews;{' '}
                <code>hospital</code> brings patient and care management; <code>core_only</code> is just identity.
                Presets can be combined. A module that's switched off isn't hidden, it's absent: its addresses answer
                “not found” for everyone and its database tables are never created.
            </p>
            <p>
                That gives you a simple way to sell and run tiers. A product line is a preset. A customer who must never
                touch a module gets a deployment without it. And the code stays one codebase, so a fix ships everywhere.
            </p>

            <h2>Why this pays off</h2>
            <ul>
                <li><strong>Fewer moving parts.</strong> One service to patch, monitor and back up instead of one per product.</li>
                <li><strong>One person, one account.</strong> Customers and staff sign in once across products, with roles per workspace.</li>
                <li><strong>Faster new products.</strong> The tenth module costs less than the first because sign-in, roles and integrations are already there.</li>
                <li><strong>Integrations once.</strong> Webhooks, API keys and the TypeScript client work the same for every module, so partners integrate once.</li>
                <li><strong>Your infrastructure.</strong> It's open source and self-hosted, so data stays where you run it and there's no per-user fee.</li>
            </ul>

            <h2>What you still own</h2>
            <p>
                Self-hosting is a trade. You run a PostgreSQL database and take its backups. You upgrade OpsAPI when
                releases land; migrations run as part of a deploy, but they still need watching. You monitor it, and
                you secure the admin side, ideally behind a VPN or zero-trust access rather than on the open internet.
            </p>

            <h2>Honest limits</h2>
            <ul>
                <li><strong>Module sets are per deployment, not per workspace.</strong> Two workspaces on the same deployment have the same modules available; roles and menus can hide one from members, but a hard split needs a separate deployment.</li>
                <li><strong>One codebase means shared releases.</strong> An upgrade touches every module on that deployment, so test the ones you use.</li>
                <li><strong>Not an off-the-shelf identity standard.</strong> OpsAPI's sign-in isn't an OpenID Connect or SAML provider; apps use its own redirect and token contract.</li>
                <li><strong>Some modules are specialised.</strong> UK tax filing or hospital care won't matter to most teams; that's exactly why they're switchable.</li>
            </ul>

            <h2>Where to go next</h2>
            <p>
                The <a href="/technotes/modules-map/">modules map</a> shows every module and preset. The{' '}
                <a href="/demo/">live demo</a> runs the smallest preset, identity only, with two apps signing in through
                it.
            </p>
        </>
    );
}

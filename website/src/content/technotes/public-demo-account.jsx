import Figure, { Markers, Box, Table } from '@/components/Figure';

export const meta = {
    slug: 'public-demo-account',
    title: 'Building a safe public demo login',
    summary:
        'Publishing a password for a real admin dashboard without leaking anyone\'s data or letting visitors break it: a separate workspace, a read-only role and a reset job.',
    date: '2026-10-28',
    tags: ['security', 'rbac', 'demo', 'privacy'],
    audience: 'developers and SRE',
    readMinutes: 7,
};

function Separation() {
    return (
        <svg viewBox="0 0 920 360" role="img" aria-labelledby="pda-sep-t">
            <title id="pda-sep-t">The public demo login can read the showcase workspace only; real sign-ins land in a private workspace</title>
            <Markers />
            <Box x={20} y={60} w={190} h={64} title="Public visitor" lines={['demo login']} variant="violet" />
            <Box x={20} y={236} w={190} h={64} title="Real person" lines={['own Google account']} variant="violet" />
            <line x1="210" y1="92" x2="318" y2="92" className="dg-line" markerEnd="url(#ah)" />
            <line x1="210" y1="268" x2="318" y2="268" className="dg-line" markerEnd="url(#ah)" />

            <Box x={320} y={44} w={240} h={96} title="Role: viewer" lines={['read on every module', 'no create, update, delete']} variant="accent" />
            <Box x={320} y={220} w={240} h={96} title="Role: member" lines={['default for sign-ups', 'no admin rights']} />

            <line x1="560" y1="92" x2="648" y2="92" className="dg-line--accent" markerEnd="url(#ah-acc)" />
            <line x1="560" y1="268" x2="648" y2="268" className="dg-line" markerEnd="url(#ah)" />
            <line x1="560" y1="120" x2="648" y2="240" className="dg-line--red" markerEnd="url(#ah-red)" />
            <text x="566" y="190" className="dg-small">403</text>

            <rect x="650" y="40" width="250" height="108" rx="8" className="dg-zone" />
            <text x="666" y="64" className="dg-mono">SHOWCASE</text>
            <text x="666" y="90" className="dg-text">fictional example.com users</text>
            <text x="666" y="112" className="dg-text">fictional owner</text>
            <text x="666" y="134" className="dg-small">emailed code: off</text>

            <rect x="650" y="214" width="250" height="108" rx="8" className="dg-zone--amber" />
            <text x="666" y="238" className="dg-mono">DEMO</text>
            <text x="666" y="264" className="dg-text">real people's accounts</text>
            <text x="666" y="286" className="dg-text">real owner</text>
            <text x="666" y="308" className="dg-small">emailed code: on</text>
        </svg>
    );
}

function ResetLoop() {
    return (
        <svg viewBox="0 0 900 220" role="img" aria-labelledby="pda-reset-t">
            <title id="pda-reset-t">A CronJob restores the demo account every 30 minutes</title>
            <Markers />
            <Box x={20} y={70} w={180} h={70} title="Visitor" lines={['changes password', 'or deactivates']} variant="red" />
            <line x1="200" y1="105" x2="298" y2="105" className="dg-line--red" markerEnd="url(#ah-red)" />
            <Box x={300} y={60} w={200} h={90} title="users table" lines={['password hash', 'active flag', 'viewer role']} />
            <line x1="700" y1="105" x2="502" y2="105" className="dg-line--accent" markerEnd="url(#ah-acc)" />
            <Box x={700} y={60} w={180} h={90} title="CronJob" lines={['*/30 * * * *', 'psql reset.sql']} variant="accent" />
            <text x="600" y="96" textAnchor="middle" className="dg-small">restore</text>
            <text x="600" y="190" textAnchor="middle" className="dg-small">worst case: 30 minutes of a changed password</text>
        </svg>
    );
}

export default function Body() {
    return (
        <>
            <p>
                A demo that only shows screenshots convinces nobody. We wanted visitors to open the real OpsAPI admin
                dashboard and click around. That means publishing a password, and three things can go wrong: visitors
                see other people's data, visitors change things, and visitors lock the next visitor out.
            </p>

            <h2>1. Keep real people out of view</h2>
            <p>
                The apps in the demo let anyone sign in with Google, and those accounts go to a workspace called{' '}
                <code>demo</code>. If the published login could read that workspace, its user list would show the real
                email address of everyone who had tried the apps. So the published login lives somewhere else: a{' '}
                <code>showcase</code> workspace holding only fictional <code>example.com</code> users, owned by a
                fictional user too, so not even the owner's address is real.
            </p>
            <Figure caption="Workspaces are the boundary. A member of showcase asking for demo's members gets 403, whatever header it sends.">
                <Separation />
            </Figure>

            <h2>2. Let visitors see everything and change nothing</h2>
            <p>
                OpsAPI's roles are lists of <code>module.action</code> permissions per workspace. The seeded owner role
                has <code>manage</code> on every module; the demo login gets a <code>viewer</code> role built from the
                same module list with only <code>read</code>:
            </p>
            <pre><code>{`-- seed-showcase.lua
local read = {}
for module in pairs(cjson.decode(owner_role.permissions)) do read[module] = { "read" } end
-- => {"users":["read"],"roles":["read"],"settings":["read"], ...}`}</code></pre>
            <p>Every page in the dashboard opens; every write is refused by the permission middleware before it reaches a query:</p>
            <pre><code>{`POST /api/v2/users   (as demo@opsapi.org in showcase)
403 {"error":"Permission denied","required":{"module":"users","action":"create"}}`}</code></pre>

            <h2>3. Survive visitors who try anyway</h2>
            <p>
                Some actions belong to every signed-in user, whatever their role: changing your own password or
                deactivating your own account. A visitor could use either to lock everyone else out. A CronJob puts the
                account back every 30 minutes: the password hash of the published password, the active flag, and the
                viewer role.
            </p>
            <Figure caption="The reset only touches the demo account and the showcase workspace's sign-in setting." minWidth={680}>
                <ResetLoop />
            </Figure>

            <h2>4. No emailed code, in one workspace only</h2>
            <p>
                Members are asked for an emailed code when any workspace they belong to requires one. Nobody can read
                the demo account's inbox, so <code>showcase</code> has the code switched off. The private{' '}
                <code>demo</code> workspace keeps it on, and platform admins are always asked regardless.
            </p>

            <h2>Checklist</h2>
            <Table
                head={['Risk', 'Control', 'How we tested it']}
                rows={[
                    ['Visitors see real people', 'Separate showcase workspace, fictional owner', 'Member list over the public URL shows only example.com addresses'],
                    ['Visitors read the private workspace', 'Membership check per workspace', 'Request with X-Namespace-Slug: demo returns 403'],
                    ['Visitors change data', 'viewer role: read only', 'Creating a user returns 403 Permission denied'],
                    ['Visitors lock the account', '30-minute reset CronJob', 'Ran the job by hand; the published password signs in afterwards'],
                    ['Inbox nobody reads', 'Emailed code off in showcase only', 'Sign-in returns a token with no 2FA step'],
                ]}
            />

            <h2>One edge lesson</h2>
            <p>
                The first version failed every read with "Access denied to this namespace". The edge proxy had been set
                to add <code>X-Namespace-Slug: demo</code> to every request for the identity host, which overwrote the
                header the dashboard sent and pinned every call to the private workspace. Tenancy belongs to the
                client and the token, not to a proxy rule; removing the header fixed it.
            </p>
            <p>
                Try it on the <a href="/demo/">live demo</a>.
            </p>
        </>
    );
}

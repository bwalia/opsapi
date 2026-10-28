import Figure, { Markers, Box, Table } from '@/components/Figure';

export const meta = {
    slug: 'multi-tenancy-and-rbac',
    title: 'Workspaces and roles: how OpsAPI keeps tenants apart',
    summary:
        'How a request is tied to one workspace, what membership and module.action permissions decide, where platform admins and owners fit, and which of the three access layers is actually a hard boundary.',
    date: '2026-10-28',
    tags: ['multi-tenancy', 'rbac', 'security', 'namespaces'],
    audience: 'developers, DevOps and SRE',
    readMinutes: 10,
};

function ResolutionDiagram() {
    return (
        <svg viewBox="0 0 940 560" role="img" aria-labelledby="mt-res-t">
            <title id="mt-res-t">How requireNamespace picks the workspace and checks access</title>
            <Markers />
            <text x="20" y="28" className="dg-mono">WHICH WORKSPACE? (first match wins)</text>
            <Box x={20} y={42} w={200} h={52} title="X-Namespace-Id" lines={['header']} variant="accent" />
            <Box x={240} y={42} w={200} h={52} title="X-Namespace-Slug" lines={['header']} variant="accent" />
            <Box x={460} y={42} w={200} h={52} title="JWT namespace" lines={['uuid, else slug']} variant="accent" />
            <Box x={680} y={42} w={240} h={52} title="Subdomain" lines={['not www, api, dashboard']} variant="accent" />
            <line x1="220" y1="68" x2="238" y2="68" className="dg-line--dash" markerEnd="url(#ah)" />
            <line x1="440" y1="68" x2="458" y2="68" className="dg-line--dash" markerEnd="url(#ah)" />
            <line x1="660" y1="68" x2="678" y2="68" className="dg-line--dash" markerEnd="url(#ah)" />
            <text x="470" y="116" textAnchor="middle" className="dg-small">each one only if the previous is absent</text>

            <line x1="470" y1="124" x2="470" y2="150" className="dg-line" markerEnd="url(#ah)" />
            <Box x={330} y={152} w={280} h={50} title="Identifier found?" />
            <line x1="610" y1="177" x2="728" y2="177" className="dg-line--red" markerEnd="url(#ah-red)" />
            <Box x={730} y={154} w={190} h={46} title="400" lines={['provide a header']} variant="red" />

            <line x1="470" y1="202" x2="470" y2="228" className="dg-line" markerEnd="url(#ah)" />
            <Box x={330} y={230} w={280} h={50} title="Workspace exists?" />
            <line x1="610" y1="255" x2="728" y2="255" className="dg-line--red" markerEnd="url(#ah-red)" />
            <Box x={730} y={232} w={190} h={46} title="404" lines={['Namespace not found']} variant="red" />

            <line x1="470" y1="280" x2="470" y2="306" className="dg-line" markerEnd="url(#ah)" />
            <Box x={330} y={308} w={280} h={50} title="Status active?" />
            <line x1="610" y1="333" x2="728" y2="333" className="dg-line--red" markerEnd="url(#ah-red)" />
            <Box x={730} y={310} w={190} h={46} title="403" lines={['not accessible']} variant="red" />

            <line x1="470" y1="358" x2="470" y2="384" className="dg-line" markerEnd="url(#ah)" />
            <Box x={330} y={386} w={280} h={50} title="Member, or platform admin?" />
            <line x1="610" y1="411" x2="728" y2="411" className="dg-line--red" markerEnd="url(#ah-red)" />
            <Box x={730} y={388} w={190} h={46} title="403" lines={['Access denied']} variant="red" />

            <line x1="470" y1="436" x2="470" y2="462" className="dg-line" markerEnd="url(#ah)" />
            <Box x={290} y={464} w={360} h={70} title="Context set on self" lines={['namespace, namespace_permissions,', 'is_namespace_owner, is_platform_admin']} variant="violet" />
            <text x="40" y="420" className="dg-small">A member whose status</text>
            <text x="40" y="438" className="dg-small">isn't active also gets 403</text>
        </svg>
    );
}

function LayersDiagram() {
    return (
        <svg viewBox="0 0 920 330" role="img" aria-labelledby="mt-layers-t">
            <title id="mt-layers-t">The three access layers and who each one stops</title>
            <rect x="20" y="20" width="880" height="86" rx="8" className="dg-box dg-box--accent" />
            <text x="40" y="50" className="dg-title">1. PROJECT_CODE: per deployment, hard</text>
            <text x="40" y="74" className="dg-small">A disabled module's routes are never loaded and its tables don't exist.</text>
            <text x="40" y="94" className="dg-small">404 for everyone, owners and platform admins included.</text>
            <text x="760" y="64" className="dg-mono">stops: everyone</text>

            <rect x="20" y="122" width="880" height="86" rx="8" className="dg-box dg-box--violet" />
            <text x="40" y="152" className="dg-title">2. Workspace RBAC: per workspace, per role</text>
            <text x="40" y="176" className="dg-small">requirePermission(module, action) checks the member's role permissions.</text>
            <text x="40" y="196" className="dg-small">403 "Permission denied". Platform admins pass every check.</text>
            <text x="760" y="166" className="dg-mono">stops: members</text>

            <rect x="20" y="224" width="880" height="86" rx="8" className="dg-box dg-box--muted" />
            <text x="40" y="254" className="dg-title">3. Menu configuration: cosmetic</text>
            <text x="40" y="278" className="dg-small">namespace_menu_config hides a sidebar page for a workspace.</text>
            <text x="40" y="298" className="dg-small">The API route still answers; hiding a page is not access control.</text>
            <text x="760" y="268" className="dg-mono">stops: nobody</text>
        </svg>
    );
}

function PermissionDiagram() {
    return (
        <svg viewBox="0 0 920 230" role="img" aria-labelledby="mt-perm-t">
            <title id="mt-perm-t">How requirePermission decides</title>
            <Markers />
            <Box x={20} y={80} w={170} h={56} title="requirePermission" lines={['("users", "update")']} variant="violet" />
            <line x1="190" y1="108" x2="248" y2="108" className="dg-line" markerEnd="url(#ah)" />
            <Box x={250} y={80} w={170} h={56} title="Platform admin?" />
            <line x1="335" y1="80" x2="335" y2="44" className="dg-line--accent" />
            <line x1="335" y1="44" x2="748" y2="44" className="dg-line--accent" markerEnd="url(#ah-acc)" />
            <text x="350" y="36" className="dg-small">yes</text>
            <line x1="420" y1="108" x2="478" y2="108" className="dg-line" markerEnd="url(#ah)" />
            <Box x={480} y={80} w={200} h={56} title="permissions.users" lines={['contains update or manage?']} />
            <line x1="680" y1="96" x2="748" y2="58" className="dg-line--accent" markerEnd="url(#ah-acc)" />
            <line x1="680" y1="122" x2="748" y2="166" className="dg-line--red" markerEnd="url(#ah-red)" />
            <Box x={750} y={24} w={150} h={46} title="Handler runs" variant="accent" />
            <Box x={750} y={144} w={150} h={56} title="403" lines={['Permission denied']} variant="red" />
        </svg>
    );
}

export default function Body() {
    return (
        <>
            <p>
                Every business table in OpsAPI carries a <code>namespace_id</code>. A namespace is what the dashboard
                calls a workspace: one tenant, with its own members, roles, settings and data. Many workspaces share
                one deployment and one database. This note explains how a request is bound to exactly one of them, how
                roles decide what a member may do, and which controls are real boundaries.
            </p>

            <h2>Resolving the workspace</h2>
            <p>
                <code>NamespaceMiddleware.requireNamespace</code> in <code>middleware/namespace.lua</code> runs after
                authentication. It looks for the workspace in a fixed order and then checks that this user may use it:
            </p>
            <Figure caption="Every check that fails ends the request. Platform admins skip the membership check but are still scoped to the workspace they named." minWidth={760}>
                <ResolutionDiagram />
            </Figure>
            <pre><code>{`-- middleware/namespace.lua: priority 1 is the header
local header_id = self.req.headers["x-namespace-id"]
if header_id and header_id ~= "" then return header_id end
local header_slug = self.req.headers["x-namespace-slug"]
if header_slug and header_slug ~= "" then return header_slug end
-- priority 2: the JWT's namespace (uuid, else slug); priority 3: the subdomain`}</code></pre>
            <p>
                Once it passes, the handler can rely on <code>self.namespace</code>,{' '}
                <code>self.namespace_permissions</code>, <code>self.is_namespace_owner</code> and{' '}
                <code>self.is_platform_admin</code>. It also stores <code>ngx.ctx.namespace_id</code> so the activity
                log attributes the request to the workspace.
            </p>

            <h3>API keys</h3>
            <p>
                An API key (<code>opsk_…</code>) is bound to exactly one workspace and has no membership row. Its
                workspace comes from the key itself and its scopes act as its permissions. Sending a namespace header
                that doesn't match the key's own workspace is refused with 403, so a key can never reach another
                tenant. Keys are never owners or platform admins.
            </p>

            <h2>Roles and permissions</h2>
            <p>
                Permissions are a map of <strong>module</strong> to a list of <strong>actions</strong>:{' '}
                <code>read</code>, <code>create</code>, <code>update</code>, <code>delete</code>, or{' '}
                <code>manage</code>, which means all of them. A member's effective permissions are the union of their
                roles in that workspace. A route asks for one pair:
            </p>
            <Figure caption="The whole check: platform admins pass, otherwise the module must list the action or manage.">
                <PermissionDiagram />
            </Figure>
            <pre><code>{`for _, perm in ipairs(module_perms) do
    if perm == action or perm == "manage" then
        has_permission = true
        break
    end
end`}</code></pre>
            <p>
                New workspaces are seeded with default roles: <strong>owner</strong> with <code>manage</code> on every
                module, <strong>admin</strong> with <code>manage</code> on everything except <code>namespace</code>,
                which is <code>read</code>, and <strong>member</strong> with nothing until someone grants it. Owners
                and admins can add their own roles in the dashboard's role editor, for example a read-only viewer with{' '}
                <code>read</code> on every module.
            </p>

            <h3>Owners and platform admins</h3>
            <Table
                head={['Who', 'How they get access', 'Limits']}
                rows={[
                    ['Platform admin (role "administrative")', 'Passes every requirePermission check and may open any workspace without being a member', 'Still scoped to the workspace in the request; a module disabled by PROJECT_CODE still answers 404'],
                    ['Workspace owner', 'Through the owner role, which grants manage on everything. An owner left with no roles falls back to full owner permissions, so they can never be locked out', 'An owner given a narrower role is governed by that role; requireOwner routes accept owners and platform admins'],
                    ['Member', 'Only the permissions of their roles', 'Gets 403 for anything else'],
                    ['API key', 'Its scopes, in its one workspace', 'Never owner or admin'],
                ]}
            />

            <h2>The three access layers</h2>
            <p>
                Teams often ask for "this tenant should only have modules X and Y". OpsAPI has three mechanisms that
                look similar from the dashboard but behave very differently at the API:
            </p>
            <Figure caption="Only the first layer is a hard boundary for everyone. Per-workspace project_code and menu toggles change what people see, not what the API serves.">
                <LayersDiagram />
            </Figure>
            <p>
                <code>PROJECT_CODE</code> is an environment variable of the whole process, so two workspaces in the
                same deployment can't have different API-reachable module sets. To give a tenant a hard limit that
                holds for its owner too, run it in its own deployment and database with a narrower{' '}
                <code>PROJECT_CODE</code>. The per-workspace <code>namespaces.project_code</code> column only filters
                the menu and seeds the default roles' modules; it is never checked at request time. Billing
                entitlements are metadata and are not a request-time gate either.
            </p>

            <h2>Status codes you'll see</h2>
            <Table
                head={['Status', 'Meaning', 'Typical cause']}
                rows={[
                    ['401', 'Missing or invalid credentials', 'No Bearer header, expired JWT, unknown API key'],
                    ['400', 'No workspace given', 'Route needs a workspace and none came from header, JWT or subdomain'],
                    ['403', 'Route exists but access is refused', 'Not a member, inactive membership, suspended workspace, or missing module.action'],
                    ['404', 'Not here', 'Module not enabled by PROJECT_CODE, workspace not found, or a plugin turned off for this workspace (members and owners)'],
                ]}
            />

            <h2>Rules for module authors</h2>
            <ol>
                <li><strong>Scope every query by <code>namespace_id</code>.</strong> The middleware sets the workspace; it doesn't rewrite your SQL.</li>
                <li><strong>Re-check ownership on read, update and delete.</strong> Load the row, compare its <code>namespace_id</code> with <code>self.namespace.id</code>, and refuse if they differ.</li>
                <li><strong>Gate writes with <code>requirePermission</code></strong> and register the module's RBAC entry under <code>PROJECT_MODULES</code> in <code>helper/project-config.lua</code> so it appears in the role editor.</li>
                <li><strong>Never take <code>namespace_id</code> from the request body.</strong> Use the one the middleware resolved.</li>
                <li><strong>Index tenant tables on <code>namespace_id</code> first</strong>, because every query filters on it.</li>
            </ol>
            <div className="callout">
                <p>
                    The <a href="/demo/">live demo</a> shows this model in action: its public demo account has a
                    read-only role in a showcase workspace, so every page opens and every change answers 403, while
                    real sign-ups live in a different workspace it can't see.
                </p>
            </div>
        </>
    );
}

import Link from 'next/link';
import Figure, { Markers, Box, Table } from '@/components/Figure';
import CopyButton from '@/components/CopyButton';
import Sequence from '@/components/Sequence';
import { AUTH_FLOWS, AuthMap } from '@/content/demo-auth';

export const metadata = {
    title: 'Live demo',
    description: 'Try OpsAPI end to end: the full admin dashboard with every app and sample data, SAML single sign-on, and five apps in Java, PHP, Python, Rust and Go that share one sign-in.',
};

const DEMO = {
    email: 'demo@opsapi.org',
    password: 'OpsAPI-Demo-2026!',
    dashboard: 'https://showcase.demo.opsapi.org',
    showcaseApi: 'https://showcase-api.demo.opsapi.org',
    idp: 'https://saml-idp.demo.opsapi.org',
    identityDashboard: 'https://dashboard.demo.opsapi.org',
    identity: 'https://identity.demo.opsapi.org',
    java: 'https://hello-java.demo.opsapi.org',
    php: 'https://hello-php.demo.opsapi.org',
};

// The five demo apps: same sign-in flow, five languages.
const APPS = [
    { name: 'hello-java', label: 'Java', stack: 'Spring Boot', pages: '/api/secure/me, /api/secure/resource',
      code: 'https://github.com/bwalia/workflow-examples/tree/main/hello-java' },
    { name: 'hello-php', label: 'PHP', stack: 'PHP 8.3', pages: '/dashboard',
      code: 'https://github.com/bwalia/workflow-examples/tree/main/php-ringpromoter-cve-patching' },
    { name: 'hello-python', label: 'Python', stack: 'Python 3.13, standard library', pages: '/dashboard',
      code: 'https://github.com/bwalia/workflow-examples/tree/main/hello-sso-demos/python' },
    { name: 'hello-rust', label: 'Rust', stack: 'Rust, tiny_http + ureq', pages: '/dashboard',
      code: 'https://github.com/bwalia/workflow-examples/tree/main/hello-sso-demos/rust' },
    { name: 'hello-go', label: 'Go', stack: 'Go, standard library', pages: '/dashboard',
      code: 'https://github.com/bwalia/workflow-examples/tree/main/hello-sso-demos/go' },
].map((a) => ({ ...a, url: `https://${a.name}.demo.opsapi.org` }));

function DemoMap() {
    return (
        <svg viewBox="0 0 940 400" role="img" aria-labelledby="demo-map-t">
            <title id="demo-map-t">The live demo: five apps and a dashboard sharing one OpsAPI identity service and two workspaces</title>
            <Markers />
            {APPS.map((a, i) => (
                <g key={a.name}>
                    <Box x={20} y={14 + i * 54} w={200} h={44} title={a.name} variant="violet" />
                    <line x1="220" y1={36 + i * 54} x2="358" y2={160 + i * 10} className="dg-line" markerEnd="url(#ah)" />
                </g>
            ))}
            <Box x={20} y={300} w={200} h={56} title="Admin dashboard" lines={['Next.js']} variant="violet" />
            <line x1="220" y1="328" x2="358" y2="232" className="dg-line" markerEnd="url(#ah)" />
            <text x="262" y="326" className="dg-small">/auth/login</text>

            <Box x={360} y={140} w={220} h={110} title="OpsAPI identity" lines={['sign-in, 2FA, Google', 'users, roles, workspaces', 'core_only build']} variant="accent" />
            <line x1="580" y1="170" x2="688" y2="96" className="dg-line" markerEnd="url(#ah)" />
            <line x1="580" y1="222" x2="688" y2="292" className="dg-line" markerEnd="url(#ah)" />
            <line x1="470" y1="250" x2="470" y2="318" className="dg-line--dash" />
            <Box x={380} y={320} w={180} h={56} title="PostgreSQL" lines={['own database']} />

            <rect x="690" y="30" width="230" height="140" rx="8" className="dg-zone" />
            <text x="706" y="52" className="dg-mono">WORKSPACE: SHOWCASE</text>
            <text x="706" y="80" className="dg-text">demo@opsapi.org (read-only)</text>
            <text x="706" y="104" className="dg-text">6 fictional sample users</text>
            <text x="706" y="128" className="dg-text">no emailed code</text>
            <text x="706" y="152" className="dg-small">reset every 30 minutes</text>

            <rect x="690" y="226" width="230" height="140" rx="8" className="dg-zone--amber" />
            <text x="706" y="248" className="dg-mono">WORKSPACE: DEMO</text>
            <text x="706" y="276" className="dg-text">people who sign in with</text>
            <text x="706" y="296" className="dg-text">their own Google account</text>
            <text x="706" y="324" className="dg-small">private: the demo login</text>
            <text x="706" y="344" className="dg-small">can't see it</text>
        </svg>
    );
}

function Cred({ label, value }) {
    return (
        <>
            <dt>{label}</dt>
            <dd>{value}</dd>
            <CopyButton value={value} label={label} />
        </>
    );
}

export default function DemoPage() {
    return (
        <>
            <section className="band hero" style={{ paddingBlock: 'clamp(2.5rem, 2rem + 4vw, 4.5rem)' }}>
                <div className="container-x">
                    <p className="eyebrow">Live demo</p>
                    <h1 className="display-x">See OpsAPI working end to end</h1>
                    <p className="lead-x">
                        A real OpsAPI deployment with every app switched on and filled with sample data, single sign-on
                        through a SAML identity provider, and five apps in five languages (Java, PHP, Python, Rust and Go)
                        that share one sign-in. Look around the dashboard with a read-only account or SSO, then sign in to
                        the apps.
                    </p>
                    <div className="hero__actions">
                        <a target="_blank" rel="noopener noreferrer" className="btn-x btn-x--primary" href={DEMO.dashboard}>Open the dashboard</a>
                        <a className="btn-x btn-x--ghost" href="#saml">Try SAML sign-in</a>
                        <a className="btn-x btn-x--ghost" href="#auth">How sign-in works</a>
                        {APPS.map((a) => (
                            <a key={a.name} target="_blank" rel="noopener noreferrer" className="btn-x btn-x--ghost" href={a.url}>{a.label} app</a>
                        ))}
                    </div>
                </div>
            </section>

            <section className="section">
                <div className="container-x grid-2" style={{ alignItems: 'start' }}>
                    <div>
                        <h2>Demo login</h2>
                        <p>Use this on the dashboard, or on OpsAPI's sign-in page when an app sends you there.</p>
                        <dl className="cred">
                            <Cred label="Email" value={DEMO.email} />
                            <Cred label="Password" value={DEMO.password} />
                        </dl>
                        <div className="callout">
                            <p>
                                <strong>Read-only, and reset every 30 minutes.</strong> Every page opens, every change is
                                refused. The account lives in a <em>showcase</em> workspace whose other users are fictional,
                                so you never see a real person's details.
                            </p>
                        </div>
                    </div>
                    <div>
                        <h2>What's running</h2>
                        <Table
                            head={['Host', 'What it is']}
                            rows={[
                                [<a target="_blank" rel="noopener noreferrer" key="d" href={DEMO.dashboard}>showcase.demo.opsapi.org</a>, 'Admin dashboard: every app, with sample data'],
                                [<a target="_blank" rel="noopener noreferrer" key="s" href={`${DEMO.showcaseApi}/api/v2/system/info`}>showcase-api.demo.opsapi.org</a>, 'OpsAPI API behind it (every module on)'],
                                [<a target="_blank" rel="noopener noreferrer" key="p" href={`${DEMO.idp}/api/saml/metadata`}>saml-idp.demo.opsapi.org</a>, 'Demo SAML identity provider (Mock SAML)'],
                                [<a target="_blank" rel="noopener noreferrer" key="i" href={`${DEMO.identity}/health`}>identity.demo.opsapi.org</a>, 'OpsAPI sign-in for the five apps'],
                                ...APPS.map((a) => [<a target="_blank" rel="noopener noreferrer" key={a.name} href={a.url}>{a.name}.demo.opsapi.org</a>, `${a.label} demo app`]),
                            ]}
                        />
                    </div>
                </div>
            </section>

            <section className="section section--tint">
                <div className="container-x">
                    <h2>How the demo fits together</h2>
                    <Figure caption="All three front ends use the same identity service. The demo login and its sample users live in one workspace; real Google sign-ins land in another, so the public login can't see them.">
                        <DemoMap />
                    </Figure>
                </div>
            </section>

            <section className="section" id="auth">
                <div className="container-x">
                    <p className="eyebrow">Under the hood</p>
                    <h2>How each demo signs you in</h2>
                    <p className="lead-x">
                        Four ways in, all ending the same way: OpsAPI issues a short-lived JWT for one workspace, and every
                        API call is checked against that workspace's roles. The diagrams follow the real requests, step
                        by step.
                    </p>
                    <Figure caption="Two OpsAPI deployments back the demos. The full dashboard signs in with a password or SAML; the five apps use OpsAPI's hosted sign-in page with a password or Google." minWidth={760}>
                        <AuthMap />
                    </Figure>
                    <Table
                        head={['Method', 'Where to try it', 'Who checks the user', 'What you get']}
                        rows={[
                            [<a key="p" href="#auth-password">Email and password</a>, 'Full dashboard, demo login', 'OpsAPI (bcrypt, optional emailed code)', 'JWT + refresh cookie'],
                            [<a key="g" href="#auth-google">Google</a>, "The five apps' sign-in page", 'Google, verified email only', 'JWT on the callback'],
                            [<a key="h" href="#auth-hosted">Login with OpsAPI</a>, 'The five apps', 'OpsAPI hosted page; app checks a nonce, then /auth/me', 'App session + JWT'],
                            [<a key="s" href="#auth-saml">SAML single sign-on</a>, 'Full dashboard, Sign in with SSO', "The workspace's IdP; OpsAPI verifies the signature", 'One-time code → JWT'],
                        ]}
                    />

                    {AUTH_FLOWS.map((f, i) => (
                        <div key={f.id} id={`auth-${f.id}`} style={{ marginTop: '3rem' }}>
                            <p className="eyebrow">{`Flow ${i + 1} · ${f.demo}`}</p>
                            <h3 style={{ fontSize: 'var(--font-xl, 1.5rem)' }}>{f.name}</h3>
                            <p>{f.summary}</p>
                            <Figure caption="Solid arrows are requests, dashed arrows redirects and responses, green the result that matters. Boxes on a line are what that party checks or does." minWidth={760}>
                                <Sequence id={`seq-${f.id}`} title={`${f.name}: step-by-step sequence`} lanes={f.lanes} steps={f.steps} />
                            </Figure>
                            <Table head={['Concern', 'How it works']} rows={f.points} />
                            <p>
                                <a target="_blank" rel="noopener noreferrer" className="btn-x btn-x--ghost" href={f.tryHref}>Try it: {f.tryText}</a>
                            </p>
                        </div>
                    ))}
                </div>
            </section>

            <section className="section">
                <div className="container-x grid-2" style={{ alignItems: 'start' }}>
                    <div>
                        <h2>Tour the admin dashboard</h2>
                        <ol className="steps">
                            <li>Open <a target="_blank" rel="noopener noreferrer" href={DEMO.dashboard}>showcase.demo.opsapi.org</a> and sign in with the demo login. No emailed code is needed in this workspace.</li>
                            <li><strong>Apps:</strong> the catalog of every module this deployment runs; open CRM, invoices, projects, the shop, care home, hiring and more, each with sample records.</li>
                            <li><strong>Users:</strong> see the sample team and each person's role: owner, admin, developer, member.</li>
                            <li><strong>Roles:</strong> open a role to see its <code>module.action</code> permissions, and the read-only <em>viewer</em> role you're signed in with.</li>
                            <li><strong>Workspace and settings:</strong> see how a tenant is configured, including whether members need an emailed code, and the <strong>Single sign-on</strong> page with the workspace's SAML identity provider.</li>
                            <li>Try to change something. The API refuses it with 403, which is what a viewer should get.</li>
                        </ol>
                    </div>
                    <div>
                        <h2>Sign in to the apps</h2>
                        <ol className="steps">
                            <li>Open <a target="_blank" rel="noopener noreferrer" href={DEMO.java}>hello-java</a> and choose “Login with OpsAPI”. The app sends you to OpsAPI's sign-in page.</li>
                            <li>Sign in with the demo login, or with your own Google account. Google sign-ins join the private <em>demo</em> workspace as a member.</li>
                            <li>You come back signed in. The app asked OpsAPI who you are with one call to <code>/auth/me</code> and shows your workspace and role.</li>
                            <li>Open any of the others (<a target="_blank" rel="noopener noreferrer" href={DEMO.php}>PHP</a>, <a target="_blank" rel="noopener noreferrer" href="https://hello-python.demo.opsapi.org">Python</a>, <a target="_blank" rel="noopener noreferrer" href="https://hello-rust.demo.opsapi.org">Rust</a>, <a target="_blank" rel="noopener noreferrer" href="https://hello-go.demo.opsapi.org">Go</a>) and log in there too: same account, no second prompt.</li>
                            <li>Sign out everywhere from either app; the next sign-in asks again.</li>
                        </ol>
                    </div>
                </div>
            </section>

            <section className="section" id="saml">
                <div className="container-x grid-2" style={{ alignItems: 'start' }}>
                    <div>
                        <h2>Sign in with SAML single sign-on</h2>
                        <p>
                            The showcase workspace is connected to a demo SAML 2.0 identity provider. It stands in for
                            your company's Okta, Entra ID or Google Workspace, but asks for no password: any address at{' '}
                            <code>example.com</code> or <code>example.org</code> works.
                        </p>
                        <ol className="steps">
                            <li>Open the <a target="_blank" rel="noopener noreferrer" href={`${DEMO.dashboard}/login`}>dashboard sign-in page</a> and choose <strong>Sign in with SSO</strong>.</li>
                            <li>Enter a work email such as <code>visitor@example.com</code> and press <strong>Continue</strong>. OpsAPI finds the workspace's provider from the domain.</li>
                            <li>You land on the demo IdP at <code>saml-idp.demo.opsapi.org</code>. Press <strong>Sign In</strong>.</li>
                            <li>The IdP posts a signed SAML response back to OpsAPI, which checks the signature, audience, time window and request, then signs you in.</li>
                            <li>You are in the showcase as a read-only <em>viewer</em>, under the address you typed. Open <strong>Single sign-on</strong> in the sidebar to see how the provider is set up.</li>
                        </ol>
                        <div className="callout">
                            <p>
                                <strong>Same rules as production.</strong> The demo IdP is trusted by the showcase workspace
                                only, for its two domains only. A tampered, replayed, unsigned or misaddressed response is
                                refused, and so is an account that belongs to another workspace. Details in the{' '}
                                <Link href="/technotes/saml-single-sign-on/">SAML technote</Link>.
                            </p>
                        </div>
                    </div>
                    <div>
                        <h2>SAML endpoints</h2>
                        <Table
                            head={['Endpoint', 'What it does']}
                            rows={[
                                [<code key="d">GET /auth/saml/discover?email=</code>, 'Finds the provider for an email domain'],
                                [<code key="m">GET /auth/saml/:id/metadata</code>, 'Service-provider metadata to give your IdP'],
                                [<code key="l">GET /auth/saml/:id/login</code>, 'Starts sign-in: redirects to the IdP'],
                                [<code key="a">POST /auth/saml/:id/acs</code>, 'Receives the signed response, signs you in'],
                                [<code key="p">/api/v2/sso/saml/providers</code>, 'Workspace owners add and edit providers'],
                            ]}
                        />
                        <pre><code>{`# which provider handles example.com?
curl -s "${DEMO.showcaseApi}/auth/saml/discover?email=visitor@example.com"

# the demo IdP's metadata (entity ID, sign-in URL, certificate)
curl -s ${DEMO.idp}/api/saml/metadata`}</code></pre>
                        <p className="muted" style={{ fontSize: 'var(--font-sm)' }}>
                            To connect your own IdP, sign in to your workspace, open <strong>Workspace → Single sign-on</strong>,
                            paste the IdP metadata, then give the IdP the Entity ID and ACS URL shown there.
                        </p>
                    </div>
                </div>
            </section>

            <section className="section section--tint">
                <div className="container-x">
                    <h2>The five apps</h2>
                    <Table
                        head={['App', 'Stack', 'Signed-in pages', 'Code']}
                        rows={APPS.map((a) => [
                            <a key="u" target="_blank" rel="noopener noreferrer" href={a.url}>{a.name}</a>,
                            a.stack,
                            <code key="p">{a.pages}</code>,
                            <a key="c" target="_blank" rel="noopener noreferrer" href={a.code}>source</a>,
                        ])}
                    />
                    <p>
                        All five use the same routes (<code>/login</code>, <code>/auth/callback</code>, <code>/logout</code>),
                        check the token with <code>GET /auth/me</code>, and refuse a forged callback with 400.
                    </p>
                    <p>
                        Each app keeps a random nonce in its session when you click log in and only accepts the token back
                        if the nonce matches, so a link carrying someone else's token can't sign you in. The full sequence
                        is in the <Link href="/technotes/sso-sign-in-flow/">sign-in flow technote</Link>, and how the public
                        login is kept safe is in <Link href="/technotes/public-demo-account/">building a safe public demo login</Link>.
                    </p>

                    <h2 style={{ marginTop: '2.5rem' }}>Try the API directly</h2>
                    <pre><code>{`# sign in as the demo account (form-encoded)
curl -s -X POST ${DEMO.identity}/auth/login \\
  --data-urlencode username=${DEMO.email} \\
  --data-urlencode 'password=${DEMO.password}'

# who am I?
curl -s ${DEMO.identity}/auth/me -H "Authorization: Bearer $TOKEN"

# the showcase team (read access)
curl -s ${DEMO.identity}/api/v2/namespace/members \\
  -H "Authorization: Bearer $TOKEN" -H "X-Namespace-Slug: showcase"

# a change is refused (403)
curl -s -X POST ${DEMO.identity}/api/v2/users -H "Authorization: Bearer $TOKEN" \\
  -H "X-Namespace-Slug: showcase" --data-urlencode email=new@example.com`}</code></pre>
                    <p className="muted" style={{ fontSize: 'var(--font-sm)' }}>
                        <code>identity.demo.opsapi.org</code> runs a minimal <code>core_only</code> build (sign-in, users,
                        workspaces and roles) for the five apps; it has its own dashboard at{' '}
                        <a target="_blank" rel="noopener noreferrer" href={DEMO.identityDashboard}>dashboard.demo.opsapi.org</a>.
                        Every business module, with sample data, is on the showcase.
                    </p>
                </div>
            </section>
        </>
    );
}

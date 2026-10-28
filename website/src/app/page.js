import Link from 'next/link';
import { SITE } from '@/content/site';
import { FEATURE_GROUPS, PRESETS } from '@/content/features';
import { TECHNOTES } from '@/content/technotes';
import { POSTS } from '@/content/blog';
import { ListCard } from '@/components/ArticleLayout';
import Figure, { Markers, Box } from '@/components/Figure';

const businessCount = FEATURE_GROUPS.find((g) => g.id === 'business').items.length;

const PILLARS = [
    {
        k: 'Sign-in',
        t: 'One sign-in for every app',
        p: 'Passwords with emailed codes, Google and Apple, a hosted sign-in page and tokens your apps check with one call.',
        href: '/technotes/sso-sign-in-flow/',
    },
    {
        k: 'Tenancy',
        t: 'Workspaces from the first table',
        p: 'Every business row carries its workspace. Roles are module.action permissions per workspace.',
        href: '/technotes/multi-tenancy-and-rbac/',
    },
    {
        k: 'Modules',
        t: `${businessCount} business modules, switched per deployment`,
        p: 'CRM, invoicing, accounting, UK tax filing, e-commerce, care, field service and more. Load only what a product uses.',
        href: '/features/',
    },
    {
        k: 'Operations',
        t: 'Built to be run',
        p: 'One container, a Helm chart, secrets from a vault, health checks, Prometheus metrics and an error catalog with correlation ids.',
        href: '/technotes/kubernetes-deployment/',
    },
];

function MiniFlow() {
    return (
        <svg viewBox="0 0 900 200" role="img" aria-labelledby="mini-t">
            <title id="mini-t">Apps call one OpsAPI, which loads the modules a deployment needs and stores everything in PostgreSQL</title>
            <Markers />
            <Box x={10} y={20} w={170} h={50} title="Dashboard" variant="violet" />
            <Box x={10} y={80} w={170} h={50} title="Your apps" variant="violet" />
            <Box x={10} y={140} w={170} h={50} title="Mobile, scripts" variant="violet" />
            <line x1="180" y1="45" x2="268" y2="96" className="dg-line" markerEnd="url(#ah)" />
            <line x1="180" y1="105" x2="268" y2="105" className="dg-line" markerEnd="url(#ah)" />
            <line x1="180" y1="165" x2="268" y2="114" className="dg-line" markerEnd="url(#ah)" />
            <Box x={270} y={50} w={220} h={110} title="OpsAPI" lines={['sign-in · workspaces', 'roles · webhooks', 'plugins']} variant="accent" />
            <line x1="490" y1="105" x2="568" y2="105" className="dg-line" markerEnd="url(#ah)" />
            <rect x="570" y="20" width="180" height="170" rx="8" className="dg-zone" />
            <text x="584" y="42" className="dg-mono">PROJECT_CODE</text>
            <text x="584" y="70" className="dg-text">crm · invoicing</text>
            <text x="584" y="94" className="dg-text">accounting · tax</text>
            <text x="584" y="118" className="dg-text">ecommerce · cms</text>
            <text x="584" y="142" className="dg-text">hospital · …</text>
            <text x="584" y="172" className="dg-small">only these load</text>
            <line x1="750" y1="105" x2="788" y2="105" className="dg-line" markerEnd="url(#ah)" />
            <Box x={790} y={70} w={100} h={70} title="Postgres" variant="muted" />
        </svg>
    );
}

export default function Home() {
    return (
        <>
            <section className="band hero">
                <div className="container-x hero__grid">
                    <div>
                        <p className="eyebrow">Open source · OpenResty · Lua · PostgreSQL</p>
                        <h1 className="display-x">One API for sign-in, tenants and business modules</h1>
                        <p className="lead-x">
                            OpsAPI is a self-hosted, multi-tenant API platform. It signs your users in once for every app,
                            keeps each customer's data in its own workspace, and switches on the business modules a
                            product needs, from CRM to UK tax filing.
                        </p>
                        <div className="hero__actions">
                            <Link href="/demo/" className="btn-x btn-x--primary">Try the live demo</Link>
                            <a href={SITE.github} className="btn-x btn-x--ghost">View on GitHub</a>
                        </div>
                        <ul className="hero__chips" aria-label="Highlights">
                            <li>Lua in Nginx workers</li>
                            <li>{businessCount} business modules</li>
                            <li>{PRESETS.length} presets</li>
                            <li>Helm chart</li>
                            <li>TypeScript SDK</li>
                        </ul>
                    </div>
                    <div className="terminal" aria-label="Running OpsAPI locally">
                        <div className="terminal__bar"><span /><span /><span /></div>
                        <pre><code>
                            <span className="t-dim"># bring up API, dashboard, Postgres and friends</span>{'\n'}
                            <span className="t-acc">$</span> ./start.sh -e local -n -j all{'\n\n'}
                            <span className="t-dim"># is it up?</span>{'\n'}
                            <span className="t-acc">$</span> curl -s localhost:4010/health{'\n'}
                            {'{ '}<span className="t-amb">"status"</span>: <span className="t-amb">"healthy"</span>, …{' }'}{'\n\n'}
                            <span className="t-dim"># browse every endpoint</span>{'\n'}
                            <span className="t-acc">$</span> open localhost:4010/swagger
                        </code></pre>
                    </div>
                </div>
            </section>

            <section className="section">
                <div className="container-x">
                    <p className="eyebrow">What it does</p>
                    <h2>Four things every product rebuilds, done once</h2>
                    <div className="grid-auto" style={{ marginTop: '1.5rem' }}>
                        {PILLARS.map((p) => (
                            <Link key={p.k} href={p.href} className="card-x">
                                <span className="card-x__meta">{p.k}</span>
                                <h3>{p.t}</h3>
                                <p>{p.p}</p>
                                <span className="card-x__foot">Learn more →</span>
                            </Link>
                        ))}
                    </div>
                </div>
            </section>

            <section className="section section--tint">
                <div className="container-x">
                    <p className="eyebrow">How it fits</p>
                    <h2>Every client, one API, only the modules you need</h2>
                    <Figure caption="Lua runs inside OpenResty's Nginx workers, so a request never hops to a separate app server. The deployment's preset decides which modules exist." minWidth={680}>
                        <MiniFlow />
                    </Figure>
                    <Link href="/architecture/" className="btn-x btn-x--ghost">See the architecture</Link>
                </div>
            </section>

            <section className="section">
                <div className="container-x grid-2" style={{ alignItems: 'center' }}>
                    <div>
                        <p className="eyebrow">Live demo</p>
                        <h2>Click around a real deployment</h2>
                        <p className="lead-x">
                            Sign in to the admin dashboard with a read-only demo login, then log in to five apps in Java,
                            PHP, Python, Rust and Go that share one OpsAPI sign-in.
                        </p>
                        <div className="hero__actions">
                            <Link href="/demo/" className="btn-x btn-x--primary">Open the demo guide</Link>
                        </div>
                    </div>
                    <div className="stat-row">
                        <div className="stat"><div className="stat__n">6</div><div className="stat__l">front ends on one sign-in</div></div>
                        <div className="stat"><div className="stat__n">5</div><div className="stat__l">languages: Java, PHP, Python, Rust, Go</div></div>
                        <div className="stat"><div className="stat__n">1</div><div className="stat__l">call to check a token: /auth/me</div></div>
                    </div>
                </div>
            </section>

            <section className="section section--tint">
                <div className="container-x">
                    <p className="eyebrow">Technotes</p>
                    <h2>For developers, DevOps and SRE</h2>
                    <div className="grid-auto" style={{ marginTop: '1.25rem' }}>
                        {TECHNOTES.slice(0, 6).map((t) => <ListCard key={t.slug} href={`/technotes/${t.slug}/`} item={t} kind="Technote" />)}
                    </div>
                    <p style={{ marginTop: '1.25rem' }}><Link href="/technotes/">All technotes →</Link></p>
                </div>
            </section>

            <section className="section">
                <div className="container-x">
                    <p className="eyebrow">Blog</p>
                    <h2>For the people who choose the stack</h2>
                    <div className="grid-auto" style={{ marginTop: '1.25rem' }}>
                        {POSTS.slice(0, 3).map((p) => <ListCard key={p.slug} href={`/blog/${p.slug}/`} item={p} kind="Blog" />)}
                    </div>
                </div>
            </section>

            <section className="band section">
                <div className="container-x" style={{ textAlign: 'left' }}>
                    <h2>Read the code</h2>
                    <p className="lead-x">OpsAPI is open source. Run it from Docker Hub, or clone it and bring the whole stack up with one script.</p>
                    <div className="hero__actions">
                        <a href={SITE.github} className="btn-x btn-x--primary">bwalia/opsapi on GitHub</a>
                        <a href={SITE.dockerHub} className="btn-x btn-x--ghost">bwalia/opsapi on Docker Hub</a>
                    </div>
                </div>
            </section>
        </>
    );
}

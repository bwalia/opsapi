import Figure, { Markers, Box, Table } from '@/components/Figure';
import { TECHNOTES } from '@/content/technotes';
import { ListCard } from '@/components/ArticleLayout';

export const metadata = {
    title: 'Architecture',
    description: 'How OpsAPI is built: Lua inside Nginx workers, a layered request path, PostgreSQL per deployment, and the services around it.',
};

function SystemOverview() {
    const clients = [
        { y: 56, t: 'Admin dashboard', l: 'Next.js' },
        { y: 146, t: 'Your web apps', l: 'Java, PHP, Node, …' },
        { y: 236, t: 'Mobile apps', l: 'Google/Apple ID token' },
        { y: 326, t: 'Servers, scripts', l: 'API keys, TS SDK' },
    ];
    const layers = [
        { t: 'Nginx workers', l: 'Lua runs in-process' },
        { t: 'before_filter', l: 'public list, JWT check' },
        { t: 'Middleware', l: 'workspace + permissions' },
        { t: 'Routes', l: 'loaded per feature' },
        { t: 'Queries', l: 'logic, validation, SQL' },
        { t: 'Models', l: 'thin table wrappers' },
    ];
    const services = [
        { t: 'PostgreSQL', l: 'every table, per tenant', v: 'accent' },
        { t: 'Redis', l: 'cross-pod events' },
        { t: 'MinIO / S3', l: 'files and media' },
        { t: 'Kafka', l: 'audit and outbox' },
        { t: 'LLM provider', l: 'Ollama or hosted' },
        { t: 'Prometheus', l: 'scrapes /metrics' },
    ];
    return (
        <svg viewBox="0 0 960 520" role="img" aria-labelledby="sys-t">
            <title id="sys-t">OpsAPI system overview: clients, edge, the OpsAPI container and its services</title>
            <Markers />
            <text x="20" y="36" className="dg-mono">CLIENTS</text>
            {clients.map((c) => (
                <g key={c.t}>
                    <Box x={20} y={c.y} w={170} h={64} title={c.t} lines={[c.l]} variant="violet" />
                    <line x1="190" y1={c.y + 32} x2="228" y2="250" className="dg-line" markerEnd="url(#ah)" />
                </g>
            ))}

            <Box x={230} y={196} w={140} h={108} title="Edge proxy" lines={['TLS, routing', 'by host name']} />
            <line x1="370" y1="250" x2="428" y2="96" className="dg-line" markerEnd="url(#ah)" />

            <rect x="410" y="30" width="290" height="470" rx="10" className="dg-zone" />
            <text x="426" y="52" className="dg-mono">OPSAPI CONTAINER · OPENRESTY</text>
            {layers.map((l, i) => {
                const y = 66 + i * 72;
                return (
                    <g key={l.t}>
                        <Box x={430} y={y} w={250} h={52} title={l.t} lines={[l.l]} variant={i === 0 ? 'accent' : ''} />
                        {i < layers.length - 1 ? <line x1="555" y1={y + 52} x2="555" y2={y + 70} className="dg-line" markerEnd="url(#ah)" /> : null}
                    </g>
                );
            })}

            <text x="740" y="36" className="dg-mono">SERVICES</text>
            {services.map((s, i) => {
                const y = 50 + i * 66;
                return (
                    <g key={s.t}>
                        <line x1="700" y1={y + 27} x2="738" y2={y + 27} className="dg-line--dash" />
                        <Box x={740} y={y} w={200} h={54} title={s.t} lines={[s.l]} variant={s.v || ''} />
                    </g>
                );
            })}
            <Box x={740} y={448} w={200} h={52} title="External APIs" lines={['Google, Apple, Stripe, HMRC']} variant="amber" />
            <line x1="700" y1="474" x2="738" y2="474" className="dg-line--dash" />
        </svg>
    );
}

export default function ArchitecturePage() {
    return (
        <>
            <section className="band hero" style={{ paddingBlock: 'clamp(2.5rem, 2rem + 4vw, 4.5rem)' }}>
                <div className="container-x">
                    <p className="eyebrow">Architecture</p>
                    <h1 className="display-x">Lua inside Nginx, PostgreSQL underneath</h1>
                    <p className="lead-x">
                        OpsAPI is a Lapis application running inside OpenResty's Nginx workers, so there's no separate app
                        server. Every request takes the same layered path, every business row carries its workspace, and
                        a deployment loads only the modules its preset names.
                    </p>
                </div>
            </section>

            <section className="section">
                <div className="container-x">
                    <h2>The whole system</h2>
                    <p className="lead-x">Clients reach one API through the edge. Inside the container a request passes six layers; outside it, PostgreSQL holds the data and a few services do the rest.</p>
                    <Figure caption="Dashed lines are connections the API makes as needed. Redis, MinIO, Kafka and the LLM provider are optional: a minimal deployment needs only PostgreSQL.">
                        <SystemOverview />
                    </Figure>

                    <h2 style={{ marginTop: '3rem' }}>The stack</h2>
                    <Table
                        head={['Layer', 'What', 'Why']}
                        rows={[
                            ['Runtime', 'OpenResty (Nginx + LuaJIT)', 'Lua runs in the worker processes: no proxy hop to an app server'],
                            ['Framework', 'Lapis', 'Routing, models and migrations for Lua'],
                            ['Database', 'PostgreSQL (with pgvector)', 'One database per deployment; workspaces separate tenants inside it'],
                            ['Dashboard', 'Next.js (App Router), React, Zustand', 'Menu and permissions come from the API'],
                            ['Cache and events', 'Redis', 'Chat and notifications across pods'],
                            ['Files', 'MinIO or S3', 'Uploads, PDFs and media'],
                            ['Events', 'Kafka', 'Audit trail and outbox'],
                            ['AI', 'Ollama or a hosted model', 'Classification, extraction and chat agents'],
                            ['Monitoring', 'Prometheus, Grafana', '/metrics on every pod'],
                        ]}
                    />

                    <h2 style={{ marginTop: '3rem' }}>Where things live in the repository</h2>
                    <Table
                        head={['Path', 'Contents']}
                        rows={[
                            [<code key="1">lapis/</code>, 'The API: app.lua, routes/, queries/, models/, middleware/, migrations/, helper/, lib/'],
                            [<code key="2">opsapi-dashboard/</code>, 'The Next.js admin dashboard'],
                            [<code key="3">projects/</code>, 'Pluggable project modules with their own routes and migrations'],
                            [<code key="4">sdk/typescript/</code>, 'The @opsapi/client TypeScript SDK'],
                            [<code key="5">devops/</code>, 'Helm charts, Kubernetes manifests, the demo stack'],
                            [<code key="6">start.sh</code>, 'Local and server orchestration: compose, migrations, admin seed'],
                            [<code key="7">website/</code>, 'This site'],
                        ]}
                    />

                    <h2 style={{ marginTop: '3rem' }}>Deep dives</h2>
                    <p className="lead-x">Each technote takes one part of the system and draws it out.</p>
                    <div className="grid-auto" style={{ marginTop: '1.25rem' }}>
                        {TECHNOTES.map((t) => <ListCard key={t.slug} href={`/technotes/${t.slug}/`} item={t} kind="Technote" />)}
                    </div>
                </div>
            </section>
        </>
    );
}

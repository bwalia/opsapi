import Figure, { Markers, Box, Table } from '@/components/Figure';

export const meta = {
    slug: 'kubernetes-deployment',
    title: 'Running OpsAPI on Kubernetes: the Helm chart, piece by piece',
    summary:
        'What the OpsAPI chart creates, how secrets reach the pods, why migrations run as a pre-upgrade Job, how a rollout drains without dropping requests, and the start-up race we hit on a fast node.',
    date: '2026-10-28',
    tags: ['kubernetes', 'helm', 'devops', 'sre', 'postgres'],
    audience: 'DevOps and SRE',
    readMinutes: 11,
};

function ResourceMap() {
    return (
        <svg viewBox="0 0 960 410" role="img" aria-labelledby="k8s-map-t">
            <title id="k8s-map-t">Resources the OpsAPI Helm chart creates and how they connect</title>
            <Markers />
            <Box x={20} y={50} w={150} h={70} title="Ingress" lines={['routes by host']} />
            <line x1="170" y1="85" x2="198" y2="85" className="dg-line" markerEnd="url(#ah)" />
            <Box x={200} y={50} w={150} h={70} title="Service" lines={['ClusterIP :80']} />
            <line x1="350" y1="85" x2="378" y2="85" className="dg-line" markerEnd="url(#ah)" />
            <Box x={380} y={40} w={220} h={100} title="API pods" lines={['OpenResty + Lapis', '/live and /ready probes', 'RollingUpdate']} variant="accent" />
            <line x1="600" y1="90" x2="648" y2="90" className="dg-line" markerEnd="url(#ah)" />
            <Box x={650} y={40} w={270} h={100} title="Postgres StatefulSet" lines={['pgvector image', 'PVC per release']} variant="violet" />

            <Box x={20} y={200} w={180} h={60} title="Secrets vault" lines={['one path per release']} variant="amber" />
            <line x1="200" y1="230" x2="378" y2="230" className="dg-line" markerEnd="url(#ah)" />
            <text x="289" y="222" textAnchor="middle" className="dg-small">refresh 1m</text>
            <Box x={380} y={200} w={220} h={60} title="ExternalSecret" lines={['Secret + config.lua']} />
            <line x1="490" y1="200" x2="490" y2="142" className="dg-line" markerEnd="url(#ah)" />
            <Box x={650} y={200} w={270} h={60} title="Backup CronJobs" lines={['hourly + daily pg_dump']} />
            <line x1="785" y1="200" x2="785" y2="142" className="dg-line--dash" markerEnd="url(#ah)" />

            <Box x={20} y={320} w={180} h={60} title="Reloader" lines={['restarts on change']} />
            <path d="M200,340 C290,340 300,150 378,120" className="dg-line--dash" markerEnd="url(#ah)" />
            <Box x={380} y={320} w={220} h={60} title="Migrate Job" lines={['pre-upgrade hook']} variant="accent" />
            <path d="M600,350 L940,350 L940,90 L922,90" className="dg-line" markerEnd="url(#ah)" />
            <text x="770" y="342" textAnchor="middle" className="dg-small">lapis migrate + seed</text>
        </svg>
    );
}

function UpgradeTimeline() {
    const steps = [
        ['helm upgrade', 'values + image tag'],
        ['Migrate Job', 'runs, Helm waits'],
        ['Secret synced', 'ESO, then restart'],
        ['New pod ready', '/ready says true'],
        ['Old pod drains', 'preStop, then quit'],
    ];
    return (
        <svg viewBox="0 0 940 150" role="img" aria-labelledby="k8s-up-t">
            <title id="k8s-up-t">Order of events during helm upgrade</title>
            <Markers />
            {steps.map(([t, l], i) => {
                const x = 20 + i * 184;
                return (
                    <g key={t}>
                        <Box x={x} y={40} w={160} h={70} title={t} lines={[l]} variant={i === 1 ? 'accent' : ''} />
                        {i < steps.length - 1 ? (
                            <line x1={x + 160} y1="75" x2={x + 182} y2="75" className="dg-line" markerEnd="url(#ah)" />
                        ) : null}
                        <text x={x + 80} y="28" textAnchor="middle" className="dg-mono">{`step ${i + 1}`}</text>
                    </g>
                );
            })}
        </svg>
    );
}

function StartupRace() {
    return (
        <svg viewBox="0 0 900 230" role="img" aria-labelledby="k8s-race-t">
            <title id="k8s-race-t">The start-up race between nginx and the postStart hook</title>
            <Markers />
            <text x="20" y="62" className="dg-title">Container</text>
            <text x="20" y="152" className="dg-title">postStart hook</text>
            <line x1="150" y1="58" x2="880" y2="58" className="dg-life" />
            <line x1="150" y1="148" x2="880" y2="148" className="dg-life" />

            <rect x="170" y="38" width="200" height="40" rx="5" className="dg-box dg-box--red" />
            <text x="270" y="63" textAnchor="middle" className="dg-text">nginx loads default config</text>
            <rect x="330" y="128" width="200" height="40" rx="5" className="dg-box" />
            <text x="430" y="153" textAnchor="middle" className="dg-text">copies config.lua</text>
            <rect x="590" y="128" width="200" height="40" rx="5" className="dg-box dg-box--accent" />
            <text x="690" y="153" textAnchor="middle" className="dg-text">nginx -s reload (the fix)</text>
            <line x1="690" y1="128" x2="690" y2="80" className="dg-line--accent" markerEnd="url(#ah-acc)" />
            <rect x="590" y="38" width="200" height="40" rx="5" className="dg-box dg-box--accent" />
            <text x="690" y="63" textAnchor="middle" className="dg-text">workers read real config</text>
            <text x="270" y="105" textAnchor="middle" className="dg-small">without the reload: DB host = default,</text>
            <text x="270" y="120" textAnchor="middle" className="dg-small">/ready fails "connection refused" forever</text>
            <text x="150" y="210" className="dg-mono">time →</text>
        </svg>
    );
}

export default function Body() {
    return (
        <>
            <p>
                OpsAPI ships as one container image, <code>bwalia/opsapi</code>, and one Helm chart. The image is
                OpenResty with the Lapis application inside it; there's no separate app server. The chart turns that
                image into a release: pods, a Service, an Ingress, the secrets the pods need, a database, the migration
                step and the backups. This note goes through each piece in the order you meet it when something goes
                wrong.
            </p>

            <h2>What the chart creates</h2>
            <Figure caption="Solid arrows carry traffic or data; dashed ones are control (restarts, backups). Everything shown is created per release, so two releases never share a Secret, a Job or a database.">
                <ResourceMap />
            </Figure>
            <Table
                head={['Resource', 'Why it exists']}
                rows={[
                    ['Deployment', 'The API pods. Probes on /live (startup, liveness) and /ready (readiness).'],
                    ['Service + Ingress', 'ClusterIP on port 80; the Ingress routes the release hostname. TLS is terminated at the edge, so the Ingress has no tls block.'],
                    ['ExternalSecret', 'Pulls the release’s keys from the secrets vault every minute and renders config.lua into the same Secret.'],
                    ['Migrate Job', 'A pre-upgrade Helm hook that runs lapis migrate and the first-admin seed once per deploy.'],
                    ['Redis (optional)', 'Turned on when replicaCount > 1, so chat events and caches cross pods.'],
                    ['PodDisruptionBudget', 'Keeps a pod up during node drains when there are two or more.'],
                    ['Backup CronJobs', 'Hourly and daily pg_dump to object storage. Can be switched off (see below).'],
                ]}
            />

            <h2>Secrets never live in git</h2>
            <p>
                The values file names a vault path and a ClusterSecretStore; it never holds a password. The
                ExternalSecret extracts every key at that path into a Kubernetes Secret, and its template adds one more
                key, <code>LAPIS_CONFIG_LUA_FILE</code>, which becomes the pod’s <code>config.lua</code>. That file reads
                everything from the environment rather than having values templated into it:
            </p>
            <pre><code>{`config("production", {
  secret = os.getenv("JWT_SECRET_KEY"),
  postgres = {
    host = "<release-db>.<namespace>.svc.cluster.local",
    user = os.getenv("POSTGRES_USER"),
    password = os.getenv("POSTGRES_PASSWORD"),
    database = os.getenv("POSTGRES_DB") or "opsapi",
    ssl = os.getenv("POSTGRES_SSL") == "true"
  },
})`}</code></pre>
            <p>
                The pod has a <code>reloader.stakater.com/auto</code> annotation. When the vault value changes, External
                Secrets updates the Secret within a minute and Reloader rolls the pods, so rotating a key is a vault
                write, not a deploy.
            </p>
            <div className="callout callout--amber">
                <p>
                    <strong>Seeding a new vault path:</strong> we tried an External Secrets <code>PushSecret</code> to
                    write the first values. Our vault answers 404 to the metadata write that PushSecret makes first, so
                    new paths are seeded with a small script that writes the KV record directly.
                </p>
            </div>

            <h2>Migrations: once per deploy, before the pods roll</h2>
            <p>
                Migrations used to run in every pod’s start-up hook. With two replicas, both pods could see migration N
                as not applied and race to run it. They now run in a Job with these annotations:
            </p>
            <pre><code>{`metadata:
  annotations:
    helm.sh/hook: pre-upgrade
    helm.sh/hook-weight: "-5"
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
spec:
  backoffLimit: 2
  activeDeadlineSeconds: 900`}</code></pre>
            <p>
                Helm waits for the Job before touching the Deployment, so a failed migration stops the rollout instead
                of shipping pods against a half-migrated schema. Which migrations run depends on{' '}
                <code>PROJECT_CODE</code>: a release built for <code>core_only</code> creates only the core tables.
            </p>
            <Figure caption="helm upgrade, in order. The deploy pipeline also forces a restart when only the Secret changed, because a config-only change leaves the pod template untouched." minWidth={700}>
                <UpgradeTimeline />
            </Figure>
            <div className="callout">
                <p>
                    <strong>First install needs a second command.</strong> The hook is <code>pre-upgrade</code>, not{' '}
                    <code>pre-install</code>, because the Secret it mounts is created by External Secrets during the
                    install itself. On a brand-new release the database is empty and <code>/ready</code> reports
                    “connection refused” or missing tables. Run the same <code>helm upgrade</code> once more, then
                    restart the Deployment.
                </p>
            </div>

            <h2>Rollouts that don't drop requests</h2>
            <ul>
                <li><strong>RollingUpdate</strong> with <code>maxUnavailable: 0</code> and <code>maxSurge: 1</code>: a new pod must pass <code>/ready</code> before an old one goes.</li>
                <li><strong>preStop</strong>: the old pod sleeps a few seconds (default 8) so the Service and Ingress drop its endpoint, then sends nginx <code>SIGQUIT</code> to finish in-flight requests. PID 1 ignores <code>SIGTERM</code>, so without this every stop waited out the grace period and was killed mid-request.</li>
                <li><strong>/ready</strong> checks the database, that every plugin loaded, and, when chat requires it, that the Redis subscriber is connected. <code>/live</code> only says the process is up, so a database blip never restarts pods.</li>
            </ul>

            <h2>Placement</h2>
            <p>
                Values carry a <code>nodeSelector</code> by label rather than a single host name, for example a network
                region and <code>kubernetes.io/arch: amd64</code>. Pinning to one node kept failing in practice: a node
                hit its pod limit, another went NotReady, and pinned pods sat Pending. Selecting a pool lets the
                scheduler route around a bad node. The image is amd64, so arm64 nodes are excluded.
            </p>

            <h2>The database</h2>
            <p>
                Each release gets its own PostgreSQL StatefulSet using the pgvector image, because the tax classifier
                stores <code>vector(384)</code> embeddings. An init ConfigMap runs{' '}
                <code>CREATE EXTENSION IF NOT EXISTS vector</code> on a fresh volume, so a rebuilt volume heals itself
                before the first migration. The password comes from the same vault path the app reads.
            </p>
            <pre><code>{`readinessProbe:
  exec:
    command: ["sh", "-c", "pg_isready -U pguser -d <db> -h 127.0.0.1"]`}</code></pre>
            <p>
                Name the database in <code>pg_isready</code>. Without <code>-d</code> it connects to a database named
                after the user, and the Postgres log fills with “database does not exist” every probe.
            </p>

            <h2>Backups, and switching them off</h2>
            <p>
                Two CronJobs (<code>0 * * * *</code> and <code>0 4 * * *</code>) <code>pg_dump</code> the release’s
                database and upload the gzip to object storage. A release with no object storage would fail every hour
                with a missing-key error, so the chart has an opt-out:
            </p>
            <pre><code>{`backup:
  enabled: false   # unset = on, so existing releases render the same`}</code></pre>
            <p>The public demo uses it. A production release should keep backups on and test a restore.</p>

            <h2>Lesson: a start-up hook isn't a pre-start hook</h2>
            <p>
                The chart’s <code>postStart</code> hook copies <code>config.lua</code> from the mounted Secret into the
                app directory. Kubernetes runs that hook alongside the container’s entrypoint, not before it. On a slow
                node the copy usually won. On a fast node nginx started first, its workers loaded the image’s default
                configuration (database on localhost) and the pod stayed unready with “connection refused” until someone
                restarted it.
            </p>
            <Figure caption="The fix: if nginx is already running when the hook finishes, reload it. A graceful reload starts new workers that read the file the hook just wrote." minWidth={700}>
                <StartupRace />
            </Figure>
            <pre><code>{`if [ -s /app/logs/nginx.pid ]; then
  /usr/local/openresty/nginx/sbin/nginx -p /app/ -c nginx.conf.compiled -s reload \\
    || echo "[bootstrap] WARN: nginx reload failed; workers may hold a stale config"
fi`}</code></pre>
            <p>
                The reload is non-fatal on purpose: on nodes whose AppArmor profile denies the signal, the pod keeps the
                old behaviour instead of crash-looping. The general rule holds for any image: if a hook writes
                configuration, either make the entrypoint wait for it or reload after it.
            </p>

            <h2>Checklist for a new release</h2>
            <ol>
                <li>Write the release’s keys to its vault path (database password, <code>JWT_SECRET_KEY</code>, encryption key and IV, any OAuth and mail settings).</li>
                <li>Apply the database StatefulSet and wait for it to be ready.</li>
                <li><code>helm upgrade --install</code> with the release’s values file, then run the same upgrade again so the migrate Job runs.</li>
                <li>Restart the Deployment and check <code>/ready</code> returns <code>{'{"ready":true}'}</code>.</li>
                <li>Register the hostname at the edge (see the <a href="/technotes/edge-dns-and-tls/">edge technote</a>).</li>
                <li>Decide on backups: object storage and a restore test, or an explicit <code>backup.enabled: false</code>.</li>
            </ol>
        </>
    );
}

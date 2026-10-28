import Figure, { Markers, Box, Table } from '@/components/Figure';

export const meta = {
    slug: 'observability-and-errors',
    title: 'Seeing inside OpsAPI: probes, metrics, errors and audit trails',
    summary:
        'The three health endpoints and what each one is for, the Prometheus metrics, the error envelope with its correlation id, sign-in and activity records, the Kafka outbox, and why the error catalog had to move into the core.',
    date: '2026-10-28',
    tags: ['observability', 'prometheus', 'grafana', 'sre', 'errors'],
    audience: 'DevOps and SRE',
    readMinutes: 10,
};

function Probes() {
    return (
        <svg viewBox="0 0 940 260" role="img" aria-labelledby="obs-probes-t">
            <title id="obs-probes-t">Which caller uses which health endpoint</title>
            <Markers />
            <Box x={20} y={30} w={170} h={60} title="kubelet" lines={['startup + liveness']} />
            <Box x={20} y={110} w={170} h={60} title="kubelet" lines={['readiness']} />
            <Box x={20} y={190} w={170} h={60} title="Uptime checks" lines={['people, dashboards']} />
            <line x1="190" y1="60" x2="338" y2="60" className="dg-line" markerEnd="url(#ah)" />
            <line x1="190" y1="140" x2="338" y2="140" className="dg-line" markerEnd="url(#ah)" />
            <line x1="190" y1="220" x2="338" y2="220" className="dg-line" markerEnd="url(#ah)" />
            <Box x={340} y={30} w={150} h={60} title="/live" lines={['process is up']} variant="accent" />
            <Box x={340} y={110} w={150} h={60} title="/ready" lines={['can serve now']} variant="accent" />
            <Box x={340} y={190} w={150} h={60} title="/health" lines={['?detailed=true']} variant="accent" />
            <text x="520" y="65" className="dg-small">always 200 while nginx runs; never touches the database</text>
            <text x="520" y="135" className="dg-small">503 if: database down · a plugin failed to load ·</text>
            <text x="520" y="152" className="dg-small">chat requires Redis and the subscriber isn't connected</text>
            <text x="520" y="215" className="dg-small">healthy / degraded (200) / unhealthy (503); detailed adds</text>
            <text x="520" y="232" className="dg-small">Redis, object storage, disk, migrations, memory</text>
        </svg>
    );
}

function MetricsPipeline() {
    return (
        <svg viewBox="0 0 940 170" role="img" aria-labelledby="obs-metrics-t">
            <title id="obs-metrics-t">Metrics flow from the API pods to Prometheus, Grafana and alerts</title>
            <Markers />
            <Box x={20} y={45} w={180} h={80} title="API pods" lines={['GET /metrics', 'nginx-lua-prometheus']} variant="accent" />
            <line x1="200" y1="85" x2="268" y2="85" className="dg-line--dash" markerEnd="url(#ah)" />
            <text x="234" y="75" textAnchor="middle" className="dg-small">scrape</text>
            <Box x={270} y={45} w={180} h={80} title="Prometheus" lines={['scrape every 5s', 'alert rules']} />
            <line x1="450" y1="70" x2="518" y2="60" className="dg-line" markerEnd="url(#ah)" />
            <line x1="450" y1="100" x2="518" y2="115" className="dg-line" markerEnd="url(#ah)" />
            <Box x={520} y={20} w={190} h={70} title="Grafana" lines={['dashboards']} variant="violet" />
            <Box x={520} y={100} w={190} h={60} title="Alerts" lines={['to your notifier']} variant="amber" />
            <Box x={750} y={20} w={170} h={70} title="Reporting views" lines={['read-only DB role']} />
            <line x1="748" y1="55" x2="712" y2="55" className="dg-line" markerEnd="url(#ah)" />
        </svg>
    );
}

function ErrorFlow() {
    return (
        <svg viewBox="0 0 940 260" role="img" aria-labelledby="obs-errors-t">
            <title id="obs-errors-t">How a route handler produces a catalog-backed error response</title>
            <Markers />
            <Box x={20} y={40} w={170} h={70} title="Route handler" lines={['Errors.response()']} />
            <line x1="190" y1="75" x2="238" y2="75" className="dg-line" markerEnd="url(#ah)" />
            <Box x={240} y={40} w={190} h={70} title="Catalog lookup" lines={['code + locale, cached']} variant="accent" />
            <line x1="430" y1="75" x2="478" y2="75" className="dg-line" markerEnd="url(#ah)" />
            <Box x={480} y={40} w={200} h={70} title="error_occurrences" lines={['one sanitised row']} variant="violet" />
            <line x1="680" y1="75" x2="728" y2="75" className="dg-line" markerEnd="url(#ah)" />
            <Box x={730} y={40} w={190} h={70} title="Envelope" lines={['code, message,', 'correlation_id']} variant="accent" />

            <Box x={240} y={170} w={190} h={70} title="Catalog missing" lines={['tables not created']} variant="red" />
            <line x1="335" y1="110" x2="335" y2="168" className="dg-line--red" markerEnd="url(#ah-red)" />
            <line x1="430" y1="205" x2="728" y2="205" className="dg-line--red" markerEnd="url(#ah-red)" />
            <Box x={730} y={170} w={190} h={70} title="Bare SYSTEM_500" lines={['for every error']} variant="red" />
            <text x="580" y="195" textAnchor="middle" className="dg-small">the bug we fixed</text>
        </svg>
    );
}

function Outbox() {
    return (
        <svg viewBox="0 0 940 200" role="img" aria-labelledby="obs-outbox-t">
            <title id="obs-outbox-t">Kafka producer with a database outbox fallback</title>
            <Markers />
            <Box x={20} y={60} w={170} h={70} title="Business write" lines={['KafkaProducer.send']} />
            <line x1="190" y1="80" x2="338" y2="50" className="dg-line" markerEnd="url(#ah)" />
            <text x="250" y="52" textAnchor="middle" className="dg-small">broker up</text>
            <line x1="190" y1="110" x2="338" y2="145" className="dg-line--dash" markerEnd="url(#ah)" />
            <text x="250" y="148" textAnchor="middle" className="dg-small">broker down</text>
            <Box x={340} y={15} w={180} h={60} title="Kafka topic" variant="accent" />
            <Box x={340} y={115} w={180} h={70} title="kafka_outbox" lines={['status, next_retry_at']} variant="amber" />
            <line x1="520" y1="150" x2="618" y2="150" className="dg-line--dash" markerEnd="url(#ah)" />
            <Box x={620} y={115} w={180} h={70} title="Consumer" lines={['retries the outbox']} />
            <path d="M710,115 L710,45 L522,45" className="dg-line--dash" markerEnd="url(#ah)" />
            <text x="760" y="85" className="dg-small">marks rows sent</text>
        </svg>
    );
}

export default function Body() {
    return (
        <>
            <p>
                OpsAPI runs inside nginx workers, so the usual “attach a profiler to the app server” doesn’t apply. What
                you get instead is a small set of endpoints and records built for the people who run it: three health
                endpoints with distinct jobs, Prometheus metrics from every worker, one error envelope with a correlation
                id, and tables that record every sign-in and every user action.
            </p>

            <h2>Three health endpoints, three jobs</h2>
            <Figure caption="Point the liveness probe at /live, not /ready: a database blip should take a pod out of rotation, not restart it.">
                <Probes />
            </Figure>
            <pre><code>{`$ curl -s https://identity.demo.opsapi.org/ready
{"ready":true,"version":"1.0.281","timestamp":1793195573}

$ curl -s https://identity.demo.opsapi.org/health
{"status":"degraded","services":{"database":{"status":"healthy"},
 "minio":{"status":"unhealthy","error":"MinIO not reachable on any endpoint"}}, ...}`}</code></pre>
            <p>
                “Degraded” still returns 200: the demo has no object storage, which matters for uploads but not for
                sign-in. Use <code>/health</code> for humans and dashboards and <code>/ready</code> for anything that
                routes traffic.
            </p>

            <h2>Metrics</h2>
            <p>
                Every worker records into a shared dictionary through <code>nginx-lua-prometheus</code>, and{' '}
                <code>GET /metrics</code> exposes the lot. The sample Prometheus config scrapes the API every five
                seconds.
            </p>
            <Figure caption="The Grafana dashboards read Prometheus; reports about users read a set of database views through a read-only role that can't see passwords or tokens." minWidth={700}>
                <MetricsPipeline />
            </Figure>
            <Table
                head={['Metric', 'Labels', 'Use it for']}
                rows={[
                    [<code key="1">nginx_http_requests_total</code>, 'host, status, method, endpoint', 'Traffic and error ratio per route'],
                    [<code key="2">nginx_http_request_duration_seconds</code>, 'host, method, endpoint', 'Latency percentiles'],
                    [<code key="3">nginx_http_5xx_errors_total</code>, 'host, status, endpoint', 'The first alert to set'],
                    [<code key="4">api_auth_failures_total</code>, 'reason', 'Credential stuffing, broken clients'],
                    [<code key="5">api_database_query_duration_seconds</code>, 'operation', 'Slow queries'],
                    [<code key="6">nginx_http_rate_limited_total</code>, 'host, ip', 'Who is hitting the limits'],
                    [<code key="7">opsapi_auth_events_total</code>, 'event, result, method', 'Sign-in volume by outcome'],
                    [<code key="8">opsapi_activity_dropped_total</code>, 'reason', 'Activity rows lost under load (should be 0)'],
                ]}
            />
            <p>
                The repo’s alert rules include high error rate, slow responses, slow database queries, high
                authentication failure rate and request-rate spikes. Start with the 5xx rate and authentication
                failures; add the rest once you know your baseline.
            </p>

            <h2>One error envelope, with a correlation id</h2>
            <p>
                Route handlers return errors through <code>Errors.response(self, CODE, opts)</code>. The helper resolves
                the reader’s locale, looks the code up in the message catalog, writes one sanitised row to{' '}
                <code>error_occurrences</code> and returns the same shape every time:
            </p>
            <pre><code>{`HTTP/1.1 401
{"error":{
  "code":"AUTH_INVALID_CREDENTIALS",
  "title":"Invalid credentials",
  "message":"The email or password you entered is incorrect.",
  "category":"error",
  "correlation_id":"627512de-3867-4a88-9606-bc75ad743d1d",
  "occurrence_uuid":"43555f92-2f0c-45d1-a342-c5c1d8219212"
}}`}</code></pre>
            <p>
                If the caller sends <code>X-Request-ID</code>, that becomes the correlation id, so one id can follow a
                request from the edge through the API and into the database row. Support asks the user for the id; the
                occurrence row has the endpoint, method, status and request context with passwords redacted.
            </p>
            <Figure caption="The normal path along the top. Along the bottom, what happened when the catalog tables didn't exist." minWidth={700}>
                <ErrorFlow />
            </Figure>

            <h3>Lesson: anything every request needs belongs in the core</h3>
            <p>
                The catalog tables were created by the tax module’s migrations, but the error helper is used by every
                module. A deployment without tax, such as the minimal identity build behind the demo, had no catalog.
                Every error, including an ordinary wrong password, came back as a generic{' '}
                <code>SYSTEM_500 “Something went wrong”</code>, and the real cause (a failed catalog read, then a failed
                occurrence insert) only showed in the nginx debug log. The fix moved those three migrations into the core set; deployments that
                already had them don’t run them again.
            </p>
            <p>
                When you build a slim deployment, test an error path, not just a success path: a wrong password should
                be a 401 with a readable message.
            </p>

            <h2>Who signed in, and what they did</h2>
            <Table
                head={['Table', 'Holds', 'Kept for']}
                rows={[
                    [<code key="a">auth_events</code>, 'Every sign-in success or failure, 2FA, refresh, sign-out, password change', '1 year by default'],
                    [<code key="b">user_login_stats</code>, 'One row per user: last sign-in, count, consecutive failures, last seen', 'Life of the account'],
                    [<code key="c">user_activity</code>, 'What signed-in users did, partitioned by month', '90 days; whole partitions dropped'],
                    [<code key="d">user_activity_daily</code>, 'Per workspace, day, user and action counters', 'For the in-app Activity page'],
                ]}
            />
            <p>
                Login details are kept out of the <code>users</code> table on purpose: user rows are returned by many
                APIs, and new columns there would leak IP addresses. Deleting a user deletes their activity and auth
                events whatever path deleted them, which covers erasure requests.
            </p>

            <h2>Events that survive a broker outage</h2>
            <p>
                Audit and business events go to Kafka when it’s configured. If the producer can’t reach a broker, the
                event is written to a <code>kafka_outbox</code> table instead, and the consumer side works through the
                outbox and marks rows sent. A broker outage delays events; it doesn’t lose them, and it never fails the
                business write that produced them.
            </p>
            <Figure caption="The outbox turns an outage into a delay." minWidth={700}>
                <Outbox />
            </Figure>

            <h2>A starting runbook</h2>
            <ol>
                <li>Pods not ready: read <code>/ready</code> from inside the pod. The reason names the failing dependency.</li>
                <li>Users report “something went wrong”: ask for the correlation id and find the occurrence row.</li>
                <li>Error rate up: break <code>nginx_http_5xx_errors_total</code> down by endpoint before reading logs.</li>
                <li>Sign-in complaints: <code>auth_events</code> for that user shows each attempt and why it failed.</li>
                <li>Events missing downstream: count unsent rows in <code>kafka_outbox</code>.</li>
            </ol>
        </>
    );
}

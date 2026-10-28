import Figure, { Markers, Box, Table } from '@/components/Figure';

export const meta = {
    slug: 'webhooks-and-events',
    title: 'Webhooks: sending workspace events to your own systems',
    summary:
        'How OpsAPI turns business changes into signed HTTP deliveries, how retries and ordering work, how to verify a request, and how the CMS “website update” webhook refreshes a static site.',
    date: '2026-10-28',
    tags: ['webhooks', 'events', 'integrations', 'cms'],
    audience: 'developers',
    readMinutes: 9,
};

function DeliveryDiagram() {
    return (
        <svg viewBox="0 0 940 260" role="img" aria-labelledby="wh-delivery-t">
            <title id="wh-delivery-t">A business change becomes an event, then a signed delivery to your endpoint, retried until it succeeds</title>
            <Markers />
            <Box x={10} y={90} w={170} h={70} title="Business change" lines={['e.g. invoice paid']} />
            <line x1="180" y1="125" x2="228" y2="125" className="dg-line" markerEnd="url(#ah)" />
            <Box x={230} y={90} w={170} h={70} title="Event outbox" lines={['inside every worker']} variant="accent" />
            <line x1="400" y1="125" x2="448" y2="125" className="dg-line" markerEnd="url(#ah)" />
            <Box x={450} y={90} w={200} h={70} title="Signed delivery" lines={['HMAC-SHA256 + timestamp']} variant="accent" />
            <line x1="650" y1="125" x2="708" y2="125" className="dg-line--accent" markerEnd="url(#ah-acc)" />
            <Box x={710} y={90} w={220} h={70} title="Your endpoint" lines={['answer 2xx within 10 s']} variant="violet" />
            <path d="M820 160 V215 H550 V162" className="dg-line--dash" markerEnd="url(#ah)" />
            <text x="685" y="236" textAnchor="middle" className="dg-small">non-2xx or timeout: retry from 15 s, up to 1 h apart, 8 attempts</text>
            <text x="315" y="60" textAnchor="middle" className="dg-mono">one workspace's events only</text>
        </svg>
    );
}

function VerifyDiagram() {
    return (
        <svg viewBox="0 0 940 220" role="img" aria-labelledby="wh-verify-t">
            <title id="wh-verify-t">Verifying a webhook: rebuild the signature, compare in constant time, check the age, then handle once</title>
            <Markers />
            <Box x={10} y={40} w={205} h={70} title="Read raw body" lines={['+ X-Opsapi-Timestamp']} />
            <line x1="215" y1="75" x2="243" y2="75" className="dg-line" markerEnd="url(#ah)" />
            <Box x={245} y={40} w={205} h={70} title="HMAC-SHA256" lines={["timestamp + '.' + body"]} variant="accent" />
            <line x1="450" y1="75" x2="478" y2="75" className="dg-line" markerEnd="url(#ah)" />
            <Box x={480} y={40} w={205} h={70} title="Compare + age" lines={['constant time, < 5 min']} variant="accent" />
            <line x1="685" y1="75" x2="713" y2="75" className="dg-line--accent" markerEnd="url(#ah-acc)" />
            <Box x={715} y={40} w={205} h={70} title="Handle once" lines={['skip event ids seen']} variant="violet" />
            <line x1="582" y1="110" x2="582" y2="148" className="dg-line--red" markerEnd="url(#ah-red)" />
            <Box x={480} y={150} w={205} h={46} title="Reject" variant="red" />
        </svg>
    );
}

function CmsDiagram() {
    return (
        <svg viewBox="0 0 940 240" role="img" aria-labelledby="wh-cms-t">
            <title id="wh-cms-t">An editor triggers the CMS webhook; the website verifies it and refetches published posts</title>
            <Markers />
            <Box x={10} y={40} w={180} h={70} title="Editor" lines={['publishes, then notifies']} />
            <line x1="190" y1="75" x2="248" y2="75" className="dg-line" markerEnd="url(#ah)" />
            <Box x={250} y={40} w={190} h={70} title="OpsAPI CMS" lines={['POST …/trigger']} variant="accent" />
            <line x1="440" y1="75" x2="498" y2="75" className="dg-line--accent" markerEnd="url(#ah-acc)" />
            <Box x={500} y={40} w={190} h={70} title="Your website" lines={['checks the signature']} variant="violet" />
            <line x1="690" y1="75" x2="748" y2="75" className="dg-line" markerEnd="url(#ah)" />
            <Box x={750} y={40} w={180} h={70} title="Refresh content" lines={['revalidate or rebuild']} variant="violet" />
            <path d="M840 110 V180 H345 V112" className="dg-line--dash" markerEnd="url(#ah)" />
            <text x="592" y="200" textAnchor="middle" className="dg-mono">GET /api/v2/public/cms/:namespace/posts</text>
        </svg>
    );
}

export default function Body() {
    return (
        <>
            <p>
                Webhooks send a workspace's events to your own URL as they happen: an invoice is paid, a lead comes in,
                a task moves. Use them to connect OpsAPI to an ERP, Zapier, Make, n8n, Slack or your own code. They're
                set up in the dashboard under <strong>Dashboard → Webhooks</strong>; no code runs inside OpsAPI.
            </p>

            <h2>From change to delivery</h2>
            <Figure caption="Delivery runs inside every OpsAPI worker using the plugin event outbox, so there's no extra service to run. Each webhook keeps a delivery log with status, timing, retries and a Redeliver button.">
                <DeliveryDiagram />
            </Figure>

            <h2>Events</h2>
            <p>
                Every entity has <code>&lt;entity&gt;.created</code>, <code>.updated</code> and <code>.deleted</code>.
                Many also have business events that say what happened. A business event fires once, when a record{' '}
                <em>enters</em> the state: saving a paid invoice again doesn't repeat <code>invoice.paid</code>.
            </p>
            <Table
                head={['Entity', 'Business events']}
                rows={[
                    [<code key="a">invoice</code>, 'sent, paid, partially_paid, overdue, cancelled'],
                    [<code key="b">order</code>, 'confirmed, shipped, delivered, cancelled, paid, refunded'],
                    [<code key="c">crm.deal</code>, 'won, lost'],
                    [<code key="d">crm.lead</code>, 'qualified, converted, lost'],
                    [<code key="e">timesheet</code>, 'submitted, approved, rejected'],
                    [<code key="f">kanban.task</code>, 'completed, blocked'],
                    [<code key="g">fs.job</code>, 'scheduled, started, completed, cancelled'],
                    [<code key="h">member</code>, 'joined, suspended, left'],
                ]}
            />
            <p>
                Plugins can publish their own, such as <code>helpdesk.ticket.closed</code>. You only see entities enabled
                on your server, you can only subscribe to data your role can read, and a webhook only ever receives
                events from its own workspace.
            </p>

            <h2>The request</h2>
            <pre><code>{`POST /your/endpoint HTTP/1.1
Content-Type: application/json
User-Agent: OpsAPI-Webhooks/1
X-Opsapi-Event: invoice.updated
X-Opsapi-Delivery: 81234
X-Opsapi-Timestamp: 1790753496
X-Opsapi-Signature-256: sha256=5f2c…

{
  "id": "0b9f6c1e-…",
  "type": "invoice.updated",
  "created_at": "2026-09-30T07:31:36Z",
  "namespace": { "id": "…", "slug": "acme" },
  "data": {
    "object":  { "invoice_number": "INV-1042", "status": "paid", … },
    "changes": { "status": { "from": "sent", "to": "paid" } }
  }
}`}</code></pre>
            <p>
                <code>data.object</code> is the record after the change (before it, for deletes) and mirrors the
                database row, so read it defensively. <code>data.changes</code> lists only the fields that changed.
            </p>

            <h2>Verifying a request</h2>
            <Figure caption="Sign the timestamp and the raw body together, so a captured request can't be replayed later with a fresh timestamp." minWidth={760}>
                <VerifyDiagram />
            </Figure>
            <pre><code>{`// Node.js (Express: use express.raw({ type: 'application/json' }) for the raw body)
const crypto = require('crypto');
function verify(req, rawBody) {
  const ts = req.headers['x-opsapi-timestamp'];
  const expected = 'sha256=' + crypto.createHmac('sha256', process.env.OPSAPI_WEBHOOK_SECRET)
    .update(ts + '.' + rawBody).digest('hex');
  const given = req.headers['x-opsapi-signature-256'] || '';
  return given.length === expected.length
    && crypto.timingSafeEqual(Buffer.from(given), Buffer.from(expected))
    && Math.abs(Date.now() / 1000 - Number(ts)) < 300;
}`}</code></pre>
            <p>In TypeScript, the SDK does all of it, timestamp check included:</p>
            <pre><code>{`import { verifyWebhook } from '@opsapi/client';
const event = await verifyWebhook(rawBody, req.headers, { secret: process.env.OPSAPI_WEBHOOK_SECRET! });`}</code></pre>

            <h2>Retries and ordering</h2>
            <ul>
                <li><strong>Answer 2xx within 10 seconds</strong>; do slow work afterwards, for example on a queue. Connecting has a 3-second limit.</li>
                <li><strong>Anything else is retried</strong>, waiting 15 s, 30 s, 1 min and so on, up to an hour between tries. After 8 attempts the delivery is marked failed; fix the endpoint and press Redeliver.</li>
                <li><strong>At least once, in any order.</strong> Store the payload's <code>id</code> and skip ids you've handled. Compare timestamps when order matters.</li>
                <li>A paused webhook receives nothing, and events from while it was paused aren't sent later.</li>
            </ul>

            <h2>Security</h2>
            <ul>
                <li>URLs must be <code>https://</code> and resolve to public addresses. Private, loopback, link-local (cloud metadata) and cluster-internal destinations are refused when you save and on every send.</li>
                <li>Signing secrets are encrypted at rest and shown once. Rotating one invalidates the old secret immediately.</li>
                <li>Limits: 25 webhooks per workspace and 100 events per webhook.</li>
            </ul>

            <h2>The CMS “website update” webhook</h2>
            <p>
                The CMS module has its own, simpler webhook for websites that publish OpsAPI blog content. It never fires
                on its own: an editor triggers it from the post editor's publish dialog or the Webhooks tab, so several
                edits can go out as one update.
            </p>
            <Figure caption="The website re-reads published posts from the public CMS endpoint, which needs no token. A server-rendered site can revalidate its cache; a static site can start a rebuild.">
                <CmsDiagram />
            </Figure>
            <Table
                head={['', 'Workspace webhooks', 'CMS webhook']}
                rows={[
                    ['Fires', 'Automatically, on every subscribed event', <span key="a">When someone calls <code>POST /api/v2/cms/webhooks/:uuid/trigger</code></span>],
                    ['Events', 'Any entity or business event', <code key="b">post.created, post.updated, post.deleted</code>],
                    ['Signature', <span key="c">HMAC of <code>timestamp + '.' + body</code></span>, 'HMAC-SHA256 of the raw body'],
                    ['Header', <code key="d">X-Opsapi-Signature-256</code>, <code key="e">X-Opsapi-Signature-256</code>],
                    ['Retries', 'Yes, with a delivery log', 'No: one synchronous attempt, result shown to the editor'],
                ]}
            />
            <p>A Next.js receiver for the CMS webhook, as the Workstation website runs it:</p>
            <pre><code>{`const raw = await req.text();
const provided = (await headers()).get('x-opsapi-signature-256') || '';
const expected = 'sha256=' + crypto.createHmac('sha256', secret).update(raw).digest('hex');
const a = Buffer.from(provided), b = Buffer.from(expected);
if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) {
  return Response.json({ ok: false }, { status: 401 });
}
revalidateTag('cms-posts');   // the next request re-fetches published posts`}</code></pre>

            <h2>Over the API</h2>
            <p>Everything the dashboard does is available with a JWT or API key, <code>X-Namespace-Id</code> and the <code>webhooks</code> permission:</p>
            <Table
                head={['Method', 'Path']}
                rows={[
                    ['GET', <code key="1">/api/v2/namespace/webhooks/events</code>],
                    ['GET / POST', <code key="2">/api/v2/namespace/webhooks</code>],
                    ['GET / PUT / DELETE', <code key="3">/api/v2/namespace/webhooks/:id</code>],
                    ['POST', <code key="4">/api/v2/namespace/webhooks/:id/rotate-secret</code>],
                    ['POST', <code key="5">/api/v2/namespace/webhooks/:id/test</code>],
                    ['GET', <code key="6">/api/v2/namespace/webhooks/:id/deliveries</code>],
                    ['POST', <code key="7">/api/v2/namespace/webhooks/:id/deliveries/:delivery_id/redeliver</code>],
                ]}
            />
        </>
    );
}

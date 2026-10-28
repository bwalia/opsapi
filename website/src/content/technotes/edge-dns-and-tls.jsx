import Figure, { Markers, Box, Table } from '@/components/Figure';

export const meta = {
    slug: 'edge-dns-and-tls',
    title: 'From DNS to pod: the edge in front of OpsAPI',
    summary:
        'How a request for an OpsAPI host travels: a DNS-only CNAME, an edge PoP that terminates TLS and picks a rule, the cluster ingress and the pod. Plus how opsapi.org itself is a GitHub Pages site behind the same edge.',
    date: '2026-10-28',
    tags: ['edge', 'dns', 'tls', 'wslproxy', 'devops'],
    audience: 'DevOps and SRE',
    readMinutes: 10,
};

function RequestPath() {
    return (
        <svg viewBox="0 0 960 300" role="img" aria-labelledby="edge-path-t">
            <title id="edge-path-t">Request path from the browser through DNS, an edge PoP and the cluster ingress to the pod</title>
            <Markers />
            <Box x={20} y={115} w={120} h={70} title="Browser" lines={['https://…']} />
            <Box x={190} y={20} w={190} h={70} title="Cloudflare DNS" lines={['CNAME, DNS-only']} variant="amber" />
            <path d="M80,115 L80,55 L188,55" className="dg-line--dash" markerEnd="url(#ah)" />
            <text x="132" y="47" textAnchor="middle" className="dg-small">lookup</text>

            <Box x={420} y={110} w={180} h={70} title="Edge PoP A" lines={['TLS + rules']} variant="accent" />
            <Box x={420} y={200} w={180} h={70} title="Edge PoP B" lines={['mirror of A']} variant="accent" />
            <line x1="140" y1="150" x2="418" y2="145" className="dg-line" markerEnd="url(#ah)" />
            <text x="280" y="138" textAnchor="middle" className="dg-small">HTTPS to the IP DNS gave</text>
            <path d="M380,55 L510,55 L510,108" className="dg-line--dash" markerEnd="url(#ah)" />
            <text x="450" y="47" textAnchor="middle" className="dg-small">resolves to A or B</text>

            <Box x={650} y={150} w={150} h={70} title="Ingress" lines={['by Host header']} />
            <line x1="600" y1="145" x2="648" y2="175" className="dg-line" markerEnd="url(#ah)" />
            <line x1="600" y1="235" x2="648" y2="200" className="dg-line" markerEnd="url(#ah)" />
            <text x="625" y="130" textAnchor="middle" className="dg-small">plain HTTP</text>
            <Box x={830} y={150} w={110} h={70} title="Pod" lines={['OpsAPI']} variant="violet" />
            <line x1="800" y1="185" x2="828" y2="185" className="dg-line" markerEnd="url(#ah)" />
        </svg>
    );
}

function RuleEvaluation() {
    return (
        <svg viewBox="0 0 940 210" role="img" aria-labelledby="edge-rule-t">
            <title id="edge-rule-t">How an edge PoP picks a rule and acts on it</title>
            <Markers />
            <Box x={20} y={60} w={160} h={80} title="Server JSON" lines={['host:<fqdn>', 'TLS, headers']} />
            <line x1="180" y1="100" x2="208" y2="100" className="dg-line" markerEnd="url(#ah)" />
            <Box x={210} y={60} w={170} h={80} title="Candidate rules" lines={['rules linked', 'to the server']} />
            <line x1="380" y1="100" x2="408" y2="100" className="dg-line" markerEnd="url(#ah)" />
            <Box x={410} y={60} w={180} h={80} title="Match + select" lines={['path, IP, country', 'priority wins']} variant="accent" />
            <line x1="590" y1="100" x2="618" y2="100" className="dg-line" markerEnd="url(#ah)" />
            <Box x={620} y={60} w={140} h={80} title="Response" lines={['code 305', '= proxy pass']} />
            <line x1="760" y1="100" x2="788" y2="100" className="dg-line" markerEnd="url(#ah)" />
            <Box x={790} y={60} w={130} h={80} title="Backend" lines={['ingress or', 'Pages']} variant="violet" />
            <text x="500" y="170" textAnchor="middle" className="dg-small">ties: priority, then path specificity, then condition count, then rule id</text>
            <text x="470" y="35" textAnchor="middle" className="dg-mono">read from disk on every request: a rule change needs no reload</text>
        </svg>
    );
}

function PagesBehindEdge() {
    return (
        <svg viewBox="0 0 940 230" role="img" aria-labelledby="edge-pages-t">
            <title id="edge-pages-t">opsapi.org served from GitHub Pages through the edge</title>
            <Markers />
            <Box x={20} y={60} w={170} h={80} title="opsapi.org/demo/" lines={['browser request']} />
            <line x1="190" y1="100" x2="238" y2="100" className="dg-line" markerEnd="url(#ah)" />
            <Box x={240} y={50} w={230} h={100} title="Edge PoP" lines={['TLS for opsapi.org', 'rule: 305 to', 'bwalia.github.io/opsapi']} variant="accent" />
            <line x1="470" y1="100" x2="538" y2="100" className="dg-line" markerEnd="url(#ah)" />
            <text x="504" y="90" textAnchor="middle" className="dg-small">path prefixed</text>
            <Box x={540} y={50} w={230} h={100} title="GitHub Pages" lines={['/opsapi/demo/', 'Host: bwalia.github.io', 'no custom domain']} variant="amber" />
            <line x1="770" y1="100" x2="818" y2="100" className="dg-line--dash" markerEnd="url(#ah)" />
            <Box x={820} y={60} w={100} h={80} title="HTML" lines={['static']} />
            <text x="470" y="200" textAnchor="middle" className="dg-small">a custom domain on Pages would redirect back to opsapi.org: a loop</text>
        </svg>
    );
}

function GitOps() {
    return (
        <svg viewBox="0 0 940 170" role="img" aria-labelledby="edge-gitops-t">
            <title id="edge-gitops-t">Edge records flow from git through a workflow to the PoPs</title>
            <Markers />
            <Box x={20} y={45} w={190} h={80} title="Repo files" lines={['servers/prod/*.json', 'rules/prod/*.json']} />
            <line x1="210" y1="85" x2="258" y2="85" className="dg-line" markerEnd="url(#ah)" />
            <Box x={260} y={45} w={190} h={80} title="Workflow" lines={['validate, then', 'import (same ids)']} variant="accent" />
            <line x1="450" y1="85" x2="498" y2="85" className="dg-line" markerEnd="url(#ah)" />
            <Box x={500} y={45} w={190} h={80} title="Control plane" lines={['servers + rules', 'config_status']} />
            <line x1="690" y1="85" x2="738" y2="85" className="dg-line" markerEnd="url(#ah)" />
            <Box x={740} y={45} w={180} h={80} title="PoPs A and B" lines={['B mirrors A']} variant="violet" />
        </svg>
    );
}

export default function Body() {
    return (
        <>
            <p>
                Every public OpsAPI host, from the demo identity service to this website, goes through the same edge: a
                DNS record that only points the way, an edge proxy that terminates TLS and chooses a backend, and the
                Kubernetes ingress that hands the request to a pod. Knowing which layer owns what saves a lot of time
                when something returns the wrong status.
            </p>

            <h2>The path, hop by hop</h2>
            <Figure caption="DNS only resolves the name; it never carries traffic. TLS ends at the edge PoP, which proxies plain HTTP to the cluster ingress.">
                <RequestPath />
            </Figure>
            <Table
                head={['Layer', 'Owns', 'Where to look when it breaks']}
                rows={[
                    ['Cloudflare DNS', 'Name → edge. A CNAME per host, DNS-only (grey cloud)', 'dig the host; it must return the edge, not a Cloudflare proxy IP'],
                    ['Edge PoP (wslproxy)', 'TLS certificate, server + rule records, headers, rate limits', 'Response headers; the PoP’s access and error log for the host'],
                    ['Ingress (traefik)', 'Host → Service', 'kubectl get ingress; a 404 “page not found” is the ingress'],
                    ['Pod', 'The application', '/ready and the pod log'],
                ]}
            />

            <h3>Why DNS-only</h3>
            <p>
                The records are not proxied by Cloudflare. The edge issues its own Let’s Encrypt certificate per host,
                and the HTTP-01 challenge has to reach the edge on port 80. A proxied record would also put a second TLS
                hop and a second set of limits in front of the edge. The cost is that the edge’s addresses are public,
                so the edge is also where per-host WAF policies and rate limits are switched on.
            </p>
            <pre><code>{`identity.demo   300  IN  CNAME  <edge hostname>.   ; DNS-only
dashboard.demo  300  IN  CNAME  <edge hostname>.
opsapi.org      300  IN  CNAME  <edge hostname>.   ; apex: CNAME flattening`}</code></pre>

            <h2>Inside the edge: servers and rules</h2>
            <p>
                The edge is wslproxy, an OpenResty gateway. A <strong>server</strong> record describes a hostname: its
                listeners, TLS settings, extra upstream headers and which rules apply. A <strong>rule</strong> says what
                to do with a matching request. Rules are read from disk on every request, so changing one needs no
                reload.
            </p>
            <Figure caption="One request, inside one PoP." minWidth={700}>
                <RuleEvaluation />
            </Figure>
            <pre><code>{`{
  "id": "host:identity.demo.opsapi.org",
  "server_name": "identity.demo.opsapi.org",
  "rules": "opsapi-demo-default",
  "listens": [{ "listen": "80" }],
  "ssl_enabled": true,
  "ssl_force_https": true,
  "ssl_auto_renew": true,
  "custom_headers": []
}`}</code></pre>
            <pre><code>{`{
  "id": "opsapi-demo-default",
  "priority": 1,
  "match": {
    "rules": { "path": "/", "path_key": "starts_with" },
    "response": {
      "code": 305,
      "redirect_uri": "<cluster ingress>:<port>",
      "backends": [{ "address": "<cluster ingress>:<port>", "weight": 100 }],
      "routing": { "mode": "least_conn" }
    }
  },
  "servers": ["host:identity.demo.opsapi.org", "host:dashboard.demo.opsapi.org"]
}`}</code></pre>
            <Table
                head={['Rule code', 'What the edge does']}
                rows={[
                    ['305', 'Proxy pass to the backend (the normal case)'],
                    ['301 / 302', 'Redirect, e.g. www → apex'],
                    ['200 / 403', 'Serve a stored HTML body, with that status'],
                    ['306', 'CAPTCHA challenge, then proxy'],
                ]}
            />
            <p>
                One rule can serve many hosts because the ingress routes by the Host header: all the demo hosts share a
                single rule pointing at the cluster ingress.
            </p>
            <div className="callout callout--amber">
                <p>
                    <strong>Headers set at the edge apply to every request.</strong> We once had the edge force{' '}
                    <code>X-Namespace-Slug: demo</code> on the identity host. It pinned every API call to one workspace,
                    and when a second workspace was added, every request to it was refused. Tenant selection belongs in
                    the client, not the proxy.
                </p>
            </div>

            <h2>Edge records are GitOps</h2>
            <p>
                Server and rule files live in the repo under <code>.github/wslproxy/data/</code>. A workflow validates
                them (every rule a server references must exist), then imports them into the edge control plane with
                their ids preserved, and takes them live. The second PoP mirrors the first.
            </p>
            <Figure caption="A new hostname is a pull request: one server file and either a new rule or the host added to an existing rule's servers list." minWidth={700}>
                <GitOps />
            </Figure>
            <ol>
                <li>Add <code>servers/prod/host:&lt;fqdn&gt;.json</code> and point its <code>rules</code> at a rule id.</li>
                <li>Add the host to that rule’s <code>servers</code> list, or add a new rule file.</li>
                <li>Create the DNS-only CNAME to the edge.</li>
                <li>Run the workflow (dry run first), then check the certificate and a <code>curl -I</code>.</li>
            </ol>

            <h2>opsapi.org: a static site behind the same edge</h2>
            <p>
                This website is a Next.js static export published to GitHub Pages from the <code>website/</code> folder
                of the <a href="https://github.com/bwalia/opsapi">bwalia/opsapi</a> repo. Pages has no custom domain
                configured. The edge owns <code>opsapi.org</code> and <code>www.opsapi.org</code>, terminates TLS, and
                proxies to <code>https://bwalia.github.io/opsapi</code>, prefixing the repo path to every request.
            </p>
            <Figure caption="Because the edge adds /opsapi to every path, the site is built without a basePath and its links stay root-relative." minWidth={700}>
                <PagesBehindEdge />
            </Figure>
            <ul>
                <li><strong>No custom domain on Pages.</strong> If Pages knew about opsapi.org it would redirect requests for the github.io address back to opsapi.org, which comes back through the edge: a loop.</li>
                <li><strong>No basePath.</strong> The edge already maps <code>/x</code> to <code>/opsapi/x</code>, so <code>/_next/…</code> assets resolve. The flip side is that the raw github.io URL won’t render correctly; that’s fine, nobody should use it.</li>
                <li><strong>Trailing slashes.</strong> The export writes <code>/demo/index.html</code>; links use <code>/demo/</code> so Pages serves the file without a redirect.</li>
            </ul>

            <h2>Checks that catch most problems</h2>
            <pre><code>{`dig +short identity.demo.opsapi.org            # the edge, not a Cloudflare proxy address
curl -sI https://identity.demo.opsapi.org/ready  # 200 from the app
curl -sI https://opsapi.org/                     # 200, served by the edge from Pages
curl -s  https://opsapi.org/ | grep -o '<title>[^<]*'`}</code></pre>
            <p>
                A bare <code>404 page not found</code> comes from the ingress (no route for that Host). A 502 or 504 with
                the edge’s own page means the edge couldn’t reach the backend. A certificate for the wrong name means the
                host isn’t registered at the edge yet, or DNS points somewhere else.
            </p>
        </>
    );
}

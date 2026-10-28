import Figure, { Markers, Box, Table } from '@/components/Figure';

export const meta = {
    slug: 'zero-trust-admin-access',
    title: 'Keeping admin dashboards off the internet: VPN and zero-trust access',
    summary:
        'Customer apps are public; the dashboards that run the platform shouldn’t be. How to put OpsAPI admin, the edge admin, the vault UI, Grafana and the Kubernetes API behind a VPN or ZTNA broker, with OpsAPI sign-in and roles still on top.',
    date: '2026-10-28',
    tags: ['zero trust', 'security', 'vpn', 'sre', 'access control'],
    audience: 'DevOps, SRE and security',
    readMinutes: 10,
};

function TwoDoors() {
    return (
        <svg viewBox="0 0 940 320" role="img" aria-labelledby="zt-doors-t">
            <title id="zt-doors-t">Public apps for customers and brokered access for staff to admin dashboards</title>
            <Markers />
            <text x="20" y="28" className="dg-mono">CUSTOMER DOOR (PUBLIC)</text>
            <Box x={20} y={40} w={150} h={64} title="Customer" lines={['any device']} />
            <line x1="170" y1="72" x2="278" y2="72" className="dg-line" markerEnd="url(#ah)" />
            <Box x={280} y={40} w={200} h={64} title="Edge + public apps" lines={['hello-java, hello-php']} variant="violet" />
            <line x1="480" y1="72" x2="618" y2="72" className="dg-line" markerEnd="url(#ah)" />
            <Box x={620} y={40} w={300} h={64} title="OpsAPI sign-in" lines={['password + code, or Google']} variant="accent" />

            <text x="20" y="160" className="dg-mono">STAFF DOOR (BROKERED)</text>
            <Box x={20} y={172} w={150} h={64} title="Staff device" lines={['managed, posture']} />
            <line x1="170" y1="204" x2="278" y2="204" className="dg-line--accent" markerEnd="url(#ah-acc)" />
            <Box x={280} y={172} w={200} h={64} title="VPN / ZTNA broker" lines={['per-app policy']} variant="amber" />
            <line x1="480" y1="204" x2="618" y2="204" className="dg-line--accent" markerEnd="url(#ah-acc)" />
            <Box x={620} y={172} w={300} h={64} title="Admin dashboards" lines={['then OpsAPI sign-in + MFA + role']} variant="accent" />

            <Box x={280} y={264} w={200} h={44} title="Anyone else" variant="red" />
            <line x1="480" y1="286" x2="618" y2="236" className="dg-line--red" markerEnd="url(#ah-red)" />
            <text x="640" y="290" className="dg-small">no DNS answer, or refused at the edge</text>
        </svg>
    );
}

function ConnectorModel() {
    return (
        <svg viewBox="0 0 940 300" role="img" aria-labelledby="zt-conn-t">
            <title id="zt-conn-t">A connector inside the cluster dials out to the broker, so no inbound port is opened</title>
            <Markers />
            <Box x={20} y={110} w={150} h={70} title="Staff device" lines={['broker client']} />
            <line x1="170" y1="145" x2="298" y2="145" className="dg-line--accent" markerEnd="url(#ah-acc)" />
            <text x="234" y="135" textAnchor="middle" className="dg-small">tunnel</text>
            <Box x={300} y={100} w={200} h={90} title="Broker (cloud)" lines={['identity + device', 'checks, app policy']} variant="amber" />

            <rect x="560" y="20" width="360" height="260" rx="10" className="dg-zone" />
            <text x="580" y="44" className="dg-mono">YOUR KUBERNETES CLUSTER</text>
            <Box x={580} y={110} w={130} h={70} title="Connector" lines={['outbound only']} variant="accent" />
            <path d="M580,130 L520,130 L502,130" className="dg-line--accent" markerEnd="url(#ah-acc)" />
            <text x="540" y="122" textAnchor="middle" className="dg-small">dials out</text>
            <Box x={760} y={60} w={140} h={50} title="OpsAPI admin" />
            <Box x={760} y={120} w={140} h={50} title="Grafana" />
            <Box x={760} y={180} w={140} h={50} title="Vault UI" />
            <line x1="710" y1="135" x2="758" y2="85" className="dg-line" markerEnd="url(#ah)" />
            <line x1="710" y1="145" x2="758" y2="145" className="dg-line" markerEnd="url(#ah)" />
            <line x1="710" y1="155" x2="758" y2="205" className="dg-line" markerEnd="url(#ah)" />
            <text x="740" y="262" textAnchor="middle" className="dg-small">ClusterIP services, no public Ingress</text>
        </svg>
    );
}

function Layers() {
    const rows = [
        ['Device + network', 'Is this a managed device on our private path?', ''],
        ['Access policy', 'Is this person in a group allowed to reach this app?', 'amber'],
        ['Application sign-in', 'Who exactly is this, and did they pass MFA?', 'accent'],
        ['Authorisation', 'What may they do in this workspace?', 'accent'],
        ['Revocation', 'Can we remove them in minutes?', 'violet'],
    ];
    return (
        <svg viewBox="0 0 900 330" role="img" aria-labelledby="zt-layers-t">
            <title id="zt-layers-t">Five layers of control in front of an admin dashboard</title>
            {rows.map(([t, q, v], i) => {
                const y = 20 + i * 60;
                return (
                    <g key={t}>
                        <rect x={20 + i * 14} y={y} width={860 - i * 28} height={50} rx="6"
                            className={`dg-box${v ? ` dg-box--${v}` : ''}`} />
                        <text x={40 + i * 14} y={y + 30} className="dg-title">{t}</text>
                        <text x={250} y={y + 30} className="dg-text">{q}</text>
                    </g>
                );
            })}
        </svg>
    );
}

export default function Body() {
    return (
        <>
            <p>
                An OpsAPI deployment has two very different audiences. Customers use the apps: they need those on the
                public internet, and OpsAPI signs them in. Staff run the platform through admin dashboards, and those
                dashboards are where a stolen password does the most damage. The pattern we recommend is simple to state:
                public apps stay public, and every admin surface is reachable only through a VPN or a zero-trust network
                access (ZTNA) broker, with OpsAPI’s own sign-in, emailed codes and roles still enforced inside.
            </p>

            <h2>Which surfaces count as admin</h2>
            <Table
                head={['Surface', 'Why it matters', 'Behind the broker?']}
                rows={[
                    ['OpsAPI admin dashboard', 'Users, roles, workspaces, settings', 'Yes'],
                    ['Edge proxy admin', 'Can reroute any hostname', 'Yes'],
                    ['Secrets vault UI', 'Every credential the platform uses', 'Yes'],
                    ['Grafana and Prometheus', 'Traffic, user activity, sometimes personal data', 'Yes'],
                    ['Kubernetes API', 'Everything', 'Yes, plus short-lived credentials'],
                    ['Customer apps and the sign-in page', 'Must work from anywhere', 'No: public, behind the edge'],
                ]}
            />

            <h2>Two doors</h2>
            <Figure caption="Customers and staff never share a path. An admin hostname either has no public DNS record or is refused at the edge for anyone not coming through the broker.">
                <TwoDoors />
            </Figure>
            <p>
                The same OpsAPI sign-in sits behind both doors. That’s deliberate: the broker proves the device and the
                network path, OpsAPI proves the person and their role. Neither replaces the other.
            </p>

            <h2>App segments, not a flat network</h2>
            <p>
                A classic full-tunnel VPN puts a laptop on the network, and then everything reachable from that network
                is reachable from the laptop. ZTNA products publish <strong>one application at a time</strong> to named
                groups instead. Examples of the approach include Zscaler Private Access (app segments and access
                policies), Cisco Secure Client with Duo device checks, Cloudflare Access, or a self-hosted WireGuard VPN
                with tight per-peer rules. We describe the pattern, not a product; check each vendor’s current
                documentation for its terms.
            </p>
            <Figure caption="The connector runs inside the cluster and opens the connection outwards, so the admin services keep ClusterIP addresses and no Ingress, and there's no inbound port to scan." minWidth={720}>
                <ConnectorModel />
            </Figure>
            <ul>
                <li><strong>No public Ingress for admin apps.</strong> They stay ClusterIP services; the connector reaches them from inside.</li>
                <li><strong>Outbound only.</strong> The connector dials the broker; firewalls need no new inbound rule.</li>
                <li><strong>Per-app policy.</strong> “SRE on-call may reach Grafana and the Kubernetes API; support may reach the OpsAPI admin.” Nobody gets the whole network.</li>
                <li><strong>Device posture.</strong> Brokers can require a managed, patched, encrypted device before the tunnel opens.</li>
            </ul>

            <h2>Five layers in front of an admin dashboard</h2>
            <Figure caption="Each layer answers a different question. Losing one doesn't open the dashboard." minWidth={700}>
                <Layers />
            </Figure>
            <Table
                head={['Layer', 'Question', 'Answered by']}
                rows={[
                    ['Device + network', 'Managed device on our private path?', 'Broker client and device checks, or a VPN key per person'],
                    ['Access policy', 'In a group allowed to reach this app?', 'Broker app segments mapped to workforce directory groups'],
                    ['Application sign-in', 'Who is this, did they pass MFA?', 'OpsAPI sign-in; platform admins always get an emailed code'],
                    ['Authorisation', 'What may they do here?', 'OpsAPI workspace roles (module.action permissions)'],
                    ['Revocation', 'Can we remove them fast?', 'Disable in the broker and deactivate the OpsAPI user'],
                ]}
            />

            <h2>Workforce identity and customer identity are different</h2>
            <p>
                The broker normally trusts the company’s workforce directory: the people employed to run the platform.
                OpsAPI holds the people who use the apps, plus the staff accounts inside each workspace. Keep the two
                separate in your head and in your tooling. We don’t wire OpsAPI up as the identity source for a ZTNA
                product, and OpsAPI isn’t a SAML or OpenID Connect provider, so most brokers couldn’t use it directly
                anyway.
            </p>

            <h2>Logging that names a person</h2>
            <p>
                Behind a single VPN exit address, the edge log shows the same IP for every member of staff. Per-person
                audit comes from two places that do know who someone is: the broker’s access log (who reached which app,
                from which device) and OpsAPI’s <code>auth_events</code> and activity tables (who signed in, what they
                changed). Ship both to the same place and keep the clocks in sync.
            </p>

            <h2>Offboarding is two actions</h2>
            <ol>
                <li>Remove the person from the broker (or delete their VPN peer). Admin dashboards become unreachable.</li>
                <li>Deactivate their OpsAPI account. Their tokens stop working at the next check and they can’t sign in to any app.</li>
            </ol>
            <p>Do both, and test it: a leaver’s browser should get no admin page at all, and their OpsAPI login should fail.</p>

            <h2>The public demo is the exception</h2>
            <div className="callout callout--amber">
                <p>
                    <code>dashboard.demo.opsapi.org</code> is on the public internet on purpose, so anyone can look
                    around. It still needs a sign-in, and the published demo account is <strong>read-only</strong> in
                    its own showcase workspace of fictional users: every change is refused, and the account is reset
                    every 30 minutes. Real people who sign in to the demo apps live in a different workspace the demo
                    account can’t see. Don’t copy this setup to production.
                </p>
            </div>

            <h2>Rollout checklist</h2>
            <ol>
                <li>List every admin surface (the table above is a start) and remove public DNS records or edge rules for each.</li>
                <li>Publish each one through the broker as its own app, with a group-based policy.</li>
                <li>Keep OpsAPI MFA on for every workspace that has staff accounts.</li>
                <li>From an unmanaged device off the broker, confirm every admin hostname fails before it reaches a login page.</li>
                <li>Run an offboarding drill with a test account: broker removal plus OpsAPI deactivation, then check both paths fail.</li>
            </ol>
        </>
    );
}

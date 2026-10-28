import Figure, { Markers, Box } from '@/components/Figure';

export const meta = {
    slug: 'one-sign-in-every-app',
    title: 'One sign-in for every app, run on our own cluster',
    summary:
        'Two demo apps in two languages share one self-hosted sign-in. What that changes for a team that keeps adding apps, and where admin access belongs.',
    date: '2026-10-28',
    tags: ['sso', 'identity', 'zero trust', 'cost'],
    audience: 'technical managers',
    readMinutes: 6,
};

function TwoDoors() {
    return (
        <svg viewBox="0 0 900 330" role="img" aria-labelledby="doors-t">
            <title id="doors-t">Customers reach public apps; staff reach admin dashboards only through a VPN or zero-trust broker</title>
            <Markers />
            <text x="20" y="30" className="dg-mono">CUSTOMERS</text>
            <Box x={20} y={44} w={140} h={60} title="Customer" lines={['any browser']} />
            <line x1="160" y1="74" x2="268" y2="74" className="dg-line" markerEnd="url(#ah)" />
            <Box x={270} y={40} w={200} h={68} title="Public apps" lines={['hello-java, hello-php']} variant="violet" />
            <line x1="470" y1="74" x2="598" y2="74" className="dg-line" markerEnd="url(#ah)" />
            <Box x={600} y={40} w={280} h={68} title="OpsAPI sign-in" lines={['password + code, or Google']} variant="accent" />

            <text x="20" y="176" className="dg-mono">STAFF</text>
            <Box x={20} y={190} w={140} h={60} title="Staff device" lines={['managed']} />
            <line x1="160" y1="220" x2="268" y2="220" className="dg-line--accent" markerEnd="url(#ah-acc)" />
            <Box x={270} y={186} w={200} h={68} title="VPN / ZTNA broker" lines={['per-app access policy']} variant="amber" />
            <line x1="470" y1="220" x2="598" y2="220" className="dg-line--accent" markerEnd="url(#ah-acc)" />
            <Box x={600} y={186} w={280} h={68} title="Admin dashboards" lines={['OpsAPI admin, edge, vault, metrics']} variant="accent" />

            <Box x={270} y={276} w={200} h={44} title="Anyone else" variant="red" />
            <line x1="470" y1="298" x2="598" y2="250" className="dg-line--red" markerEnd="url(#ah-red)" />
            <text x="640" y="300" className="dg-small">refused before it reaches a login page</text>
        </svg>
    );
}

export default function Body() {
    return (
        <>
            <p>
                Every new app tends to grow its own login: a password table, a reset email, a lockout rule, maybe
                two-factor if someone had time. Each one is a little different, and each one is another place where
                personal data lives.
            </p>
            <p>
                The OpsAPI demo shows the alternative. The two demo apps, hello-java and hello-php, never see a password
                and never talk to Google. They send the user to OpsAPI at <code>identity.demo.opsapi.org</code>, which
                signs them in with Google (or email and a 2FA code), adds them to the demo workspace, and hands back a
                token that the app checks with a single API call. Connecting another app takes a login redirect and one
                small callback page, not a new identity system. Everything runs in our own Kubernetes cluster behind our
                own edge, so user data and running costs stay with us, and there's no per-user identity bill.
            </p>

            <h2>What changes for the team</h2>
            <ul>
                <li><strong>One user directory.</strong> A person is one account across every app, with a role per workspace.</li>
                <li><strong>Security in one place.</strong> Two-factor codes, lockout after failed attempts, rate limits and the audit trail are OpsAPI's job, not each app's.</li>
                <li><strong>A small cost per new app.</strong> Allow the app's address, add a login redirect and a callback page. No SDK, no client registration.</li>
                <li><strong>Any language.</strong> The demo has Java and PHP side by side; anything that can make an HTTP call can join.</li>
                <li><strong>Your infrastructure.</strong> The sign-in service and its database run where your other services run.</li>
            </ul>

            <h2>Keep the admin side off the internet</h2>
            <p>
                Customer-facing apps have to be public. The dashboards that run the platform don't. In production we
                recommend putting every admin surface (the OpsAPI dashboard, the edge proxy's admin, the secrets vault,
                monitoring and the Kubernetes API) behind a VPN or a zero-trust access broker such as Zscaler Private
                Access, Cisco Secure Client or a self-hosted WireGuard VPN, with access granted per app to named groups.
                OpsAPI's own sign-in, emailed codes and roles still apply on top.
            </p>
            <Figure caption="Two doors: customers sign in through OpsAPI on public apps; staff reach admin dashboards only through the broker, then sign in again with MFA." minWidth={680}>
                <TwoDoors />
            </Figure>
            <div className="callout callout--amber">
                <p>
                    The public demo is the exception on purpose: its dashboard is open so you can look around with a
                    read-only demo account. It still requires a sign-in, and the demo account can't change anything.
                </p>
            </div>

            <h2>Honest limits</h2>
            <ul>
                <li>OpsAPI isn't an OpenID Connect or SAML provider. Apps use its redirect-and-token contract, so off-the-shelf OIDC clients won't plug straight in.</li>
                <li>Running it means running it: a PostgreSQL database, backups, upgrades and monitoring are yours.</li>
            </ul>

            <h2>See it working</h2>
            <p>
                Open the <a href="/demo/">live demo</a>, sign in to the Java app, then open the PHP app. The{' '}
                <a href="/technotes/sso-sign-in-flow/">sign-in flow technote</a> has every step for your developers.
            </p>
        </>
    );
}

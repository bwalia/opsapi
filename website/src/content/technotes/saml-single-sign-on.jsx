import Figure, { Markers, Box, Table } from '@/components/Figure';

export const meta = {
    slug: 'saml-single-sign-on',
    title: 'SAML single sign-on per workspace',
    summary:
        'Each workspace connects its own SAML 2.0 identity provider. How the sign-in round trip works, what OpsAPI checks in every response, and why an IdP can only vouch for its own workspace.',
    date: '2026-10-29',
    tags: ['security', 'sso', 'saml', 'identity'],
    audience: 'developers, SRE and IT admins',
    readMinutes: 8,
};

function Flow() {
    return (
        <svg viewBox="0 0 940 330" role="img" aria-labelledby="saml-flow-t">
            <title id="saml-flow-t">SP-initiated SAML sign-in: dashboard, OpsAPI, the identity provider and back</title>
            <Markers />
            <Box x={20} y={40} w={190} h={74} title="Dashboard" lines={['Sign in with SSO', 'work email']} variant="violet" />
            <Box x={370} y={40} w={200} h={74} title="OpsAPI" lines={['/auth/saml/:id/login']} variant="accent" />
            <Box x={730} y={40} w={190} h={74} title="Identity provider" lines={['Okta, Entra ID, …']} />

            <line x1="210" y1="66" x2="368" y2="66" className="dg-line" markerEnd="url(#ah)" />
            <text x="289" y="58" textAnchor="middle" className="dg-small">1. discover by domain</text>
            <line x1="570" y1="66" x2="728" y2="66" className="dg-line" markerEnd="url(#ah)" />
            <text x="649" y="58" textAnchor="middle" className="dg-small">2. AuthnRequest</text>

            <line x1="825" y1="114" x2="825" y2="196" className="dg-line" markerEnd="url(#ah)" />
            <text x="835" y="160" className="dg-small">3. user signs in</text>

            <Box x={730} y={198} w={190} h={74} title="Signed response" lines={['HTTP-POST']} />
            <line x1="728" y1="232" x2="572" y2="232" className="dg-line--accent" markerEnd="url(#ah-acc)" />
            <Box x={370} y={198} w={200} h={100} title="OpsAPI ACS" lines={['verify signature', 'check audience, time,', 'request, replay']} variant="accent" />
            <line x1="368" y1="232" x2="212" y2="232" className="dg-line" markerEnd="url(#ah)" />
            <text x="289" y="224" textAnchor="middle" className="dg-small">5. token</text>
            <text x="649" y="224" textAnchor="middle" className="dg-small">4. SAMLResponse</text>
            <Box x={20} y={198} w={190} h={74} title="Dashboard" lines={['/auth/callback']} variant="violet" />
        </svg>
    );
}

export default function Body() {
    return (
        <>
            <p>
                Companies want their people to sign in with the account they already have: Okta, Microsoft Entra ID,
                Google Workspace, OneLogin, JumpCloud, Keycloak. All of them speak SAML 2.0, so OpsAPI does too. Each
                workspace connects its own identity provider (IdP) from <strong>Workspace → Single sign-on</strong>,
                and its people choose <strong>Sign in with SSO</strong> on the login page.
            </p>

            <h2>The round trip</h2>
            <Figure caption="Service-provider-initiated sign-in. The browser carries every message; OpsAPI and the IdP never talk directly.">
                <Flow />
            </Figure>
            <ol className="steps">
                <li>The user types a work email. <code>GET /auth/saml/discover?email=…</code> finds the workspace&apos;s provider from the domain.</li>
                <li><code>/auth/saml/:id/login</code> sends the browser to the IdP with a deflated AuthnRequest (HTTP-Redirect binding), and keeps the request ID in a short-lived signed cookie.</li>
                <li>The user signs in at the IdP, with whatever MFA the company requires there.</li>
                <li>The IdP posts a signed SAMLResponse to OpsAPI&apos;s assertion consumer service, <code>/auth/saml/:id/acs</code>.</li>
                <li>OpsAPI checks it, finds or creates the account, and sends the browser to the dashboard with a token, the same way Google sign-in does.</li>
            </ol>

            <h2>Setting it up</h2>
            <p>
                Paste the IdP&apos;s metadata XML and press <em>Fill in from metadata</em>: OpsAPI reads the entity ID, the
                sign-in URL and the signing certificate. Then give the IdP the three values on the provider&apos;s card:
            </p>
            <Table
                head={['OpsAPI shows', 'The IdP calls it']}
                rows={[
                    ['Entity ID (Audience), also the metadata URL', 'Audience URI, SP Entity ID, Identifier'],
                    ['ACS URL', 'Single sign-on URL, Reply URL, Assertion Consumer Service'],
                    ['NameID format: email address', 'Name ID format; send email, firstName, lastName attributes'],
                ]}
            />

            <h2>What every response must pass</h2>
            <p>
                Signature checking is where SAML implementations go wrong, so OpsAPI does it narrowly. It parses with
                libxml2 (already in the OpenResty image), refuses any document with a DTD, and never fetches anything.
                A response is accepted only when all of these hold:
            </p>
            <Table
                head={['Check', 'Stops']}
                rows={[
                    ['Signature by the certificate saved for this provider (any certificate inside the message is ignored)', 'Forged responses'],
                    ['The signature sits on the element it signs, references that element\'s unique ID, and exactly one Assertion exists', 'Signature-wrapping attacks'],
                    ['RSA-SHA256 or stronger; SHA-1 refused', 'Weak digests'],
                    ['Issuer is the IdP; Audience is this workspace\'s provider; Recipient and Destination are its ACS URL', 'Responses meant for another service'],
                    ['NotBefore / NotOnOrAfter, with 3 minutes of clock skew', 'Old responses'],
                    ['InResponseTo matches the request in the signed cookie', 'Login CSRF and unsolicited responses'],
                    ['Each assertion ID accepted once', 'Replays'],
                ]}
            />

            <h2>An IdP vouches for its own workspace only</h2>
            <p>
                Accounts in OpsAPI are global and found by email, but an IdP is configured by a workspace owner. Without a
                limit, an owner who runs their own IdP could assert someone else&apos;s address and sign in as them. So:
            </p>
            <ul>
                <li>Only addresses at the provider&apos;s <strong>email domains</strong> are accepted.</li>
                <li>An existing account that also belongs to <strong>another workspace</strong>, or is a platform admin, can&apos;t sign in through SAML; it uses its password.</li>
                <li>New people get an account and join the workspace with the provider&apos;s default role (or must be invited first, if auto-provisioning is off).</li>
                <li>IdP-initiated sign-in (from the IdP&apos;s app tile) is off unless the owner turns it on.</li>
            </ul>

            <h2>Try it</h2>
            <p>
                The <a href="/demo/#saml">live demo</a> is connected to a demo IdP: choose <em>Sign in with SSO</em>, type any
                address at <code>example.com</code>, and you are back in the showcase workspace as a read-only viewer
                through a real signed SAML response.
            </p>
        </>
    );
}

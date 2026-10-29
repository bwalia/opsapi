// How each live demo signs people in. Every step here matches the code in
// bwalia/opsapi: lapis/routes/auth.lua (password, emailed code, Google,
// refresh), routes/auth-signin.lua + lib/hosted-signin.lua (hosted sign-in for
// the five apps) and routes/saml.lua + lib/saml/* (SAML).

import { Markers, Box } from '@/components/Figure';

const BROWSER = { key: 'browser', title: 'Browser', sub: 'the visitor' };

export const AUTH_FLOWS = [
    {
        id: 'password',
        name: 'Email and password (+ emailed code)',
        demo: 'showcase.demo.opsapi.org, with the demo login',
        tryHref: 'https://showcase.demo.opsapi.org/login',
        tryText: 'Sign in with demo@opsapi.org',
        summary:
            'The dashboard posts the password to OpsAPI. OpsAPI checks it, asks for an emailed code when the workspace requires one, and returns a short-lived JWT plus a refresh token in an HttpOnly cookie. Every API call then carries the JWT and the workspace, and the role decides read or write.',
        lanes: [
            BROWSER,
            { key: 'dash', title: 'Dashboard', sub: 'Next.js', variant: 'violet' },
            { key: 'api', title: 'OpsAPI', sub: 'showcase-api', variant: 'accent' },
            { key: 'mail', title: 'Email', sub: 'only if required', variant: 'amber' },
        ],
        steps: [
            { from: 'browser', to: 'dash', label: 'Email + password', sub: 'demo@opsapi.org' },
            { from: 'dash', to: 'api', label: 'POST /auth/login', sub: '10/min per IP · lockout per account' },
            { from: 'api', to: 'api', label: 'bcrypt check · account active', sub: 'users table' },
            { from: 'api', to: 'api', label: 'Does a workspace require a code?', sub: 'showcase: no · platform admins: always' },
            { from: 'api', to: 'mail', label: 'Six-digit code (when required)', sub: 'stored hashed, 5/min' },
            { from: 'api', to: 'dash', label: '{ requires_2fa, session_token }', kind: 'reply' },
            { from: 'dash', to: 'api', label: 'POST /auth/2fa/verify', sub: '{ session_token, code }' },
            { from: 'api', to: 'dash', label: 'JWT + refresh_token cookie', sub: 'HttpOnly, Secure', kind: 'accent' },
            { from: 'dash', to: 'api', label: 'GET /api/v2/…', sub: 'Authorization: Bearer JWT · X-Namespace-Slug: showcase' },
            { from: 'api', to: 'api', label: 'JWT · membership · module.action', sub: 'viewer role = read on every module' },
            { from: 'api', to: 'dash', label: '200 for reads · 403 for any change', kind: 'reply' },
            { from: 'dash', to: 'api', label: 'POST /auth/refresh when the JWT expires', sub: 'cookie in, new JWT out' },
        ],
        points: [
            ['Where the password lives', 'Only OpsAPI sees it; bcrypt hashes in users'],
            ['Second factor', 'Emailed code, per workspace setting (off in showcase, nobody reads the demo inbox)'],
            ['Session', 'JWT in the Authorization header; refresh token only in an HttpOnly cookie'],
            ['What the demo login can do', 'Read everything in showcase; every change is refused with 403'],
        ],
    },
    {
        id: 'google',
        name: 'Google sign-in (OAuth 2.0 / OpenID Connect)',
        demo: "the five apps' sign-in page (identity.demo.opsapi.org)",
        tryHref: 'https://hello-java.demo.opsapi.org',
        tryText: 'Log in to the Java app, then Continue with Google',
        summary:
            'OpsAPI runs the whole OAuth exchange: the dashboard only sends the browser to /auth/google. A nonce rides in both the state and a cookie so nobody can finish their own Google sign-in in your browser. Only an email Google has verified can sign in or be linked.',
        lanes: [
            BROWSER,
            { key: 'dash', title: 'Dashboard', sub: 'or the hosted page', variant: 'violet' },
            { key: 'api', title: 'OpsAPI', sub: 'identity', variant: 'accent' },
            { key: 'google', title: 'Google', sub: 'accounts.google.com', variant: 'amber' },
        ],
        steps: [
            { from: 'browser', to: 'dash', label: 'Continue with Google' },
            { from: 'dash', to: 'api', label: 'GET /auth/google', sub: '?frontend_url=<origin>&from=<path>' },
            { from: 'api', to: 'api', label: 'Random nonce → cookie and state', sub: 'opsapi_oauth_nonce, 10 min' },
            { from: 'api', to: 'google', label: '302 to Google consent', sub: 'client_id · redirect_uri · openid profile email · state', kind: 'reply' },
            { from: 'google', to: 'google', label: 'Pick account, consent', sub: "Google's own 2-step if on" },
            { from: 'google', to: 'api', label: 'GET /auth/google/callback', sub: '?code=…&state=…', kind: 'reply' },
            { from: 'api', to: 'api', label: 'state nonce = cookie nonce?', sub: 'else 400: login CSRF' },
            { from: 'api', to: 'google', label: 'Swap code for access token', sub: 'server to server, client secret' },
            { from: 'api', to: 'google', label: 'GET userinfo', sub: 'email · verified_email · name' },
            { from: 'api', to: 'api', label: 'Verified? find or create user · join workspace', sub: 'new users join the sign-up workspace', kind: 'accent' },
            { from: 'api', to: 'dash', label: '/auth/callback?token=JWT', sub: 'trusted origins only · + refresh cookie', kind: 'accent' },
            { from: 'dash', to: 'dash', label: 'Adopt session, strip token from the URL' },
        ],
        points: [
            ['Who talks to Google', 'Only OpsAPI; apps never hold a Google client secret'],
            ['Login CSRF', 'Nonce in state must equal the nonce cookie'],
            ['Account linking', 'By email, and only when Google says the email is verified'],
            ['Where tokens may go', 'Only origins on the CORS / allowed-origins list'],
        ],
    },
    {
        id: 'hosted',
        name: 'Login with OpsAPI (hosted sign-in for your apps)',
        demo: 'hello-java, hello-php, hello-python, hello-rust, hello-go',
        tryHref: 'https://hello-java.demo.opsapi.org',
        tryText: 'Open the Java app',
        summary:
            'Your app never sees a password. It sends the browser to OpsAPI\'s hosted page with a nonce, gets a JWT back on its callback, checks the nonce, and asks /auth/me who the user is. A second app finds the OpsAPI session already there and gets its token without a prompt.',
        lanes: [
            BROWSER,
            { key: 'app', title: 'Your app', sub: 'hello-java …', variant: 'violet' },
            { key: 'api', title: 'OpsAPI', sub: 'identity.demo', variant: 'accent' },
            { key: 'google', title: 'Google', sub: 'optional', variant: 'amber' },
        ],
        steps: [
            { from: 'browser', to: 'app', label: 'Log in' },
            { from: 'app', to: 'app', label: 'Random nonce in the session' },
            { from: 'app', to: 'api', label: 'Redirect to the hosted page', sub: '/auth/signin?frontend_url=<app>&from=<nonce>', kind: 'reply' },
            { from: 'api', to: 'api', label: 'Already signed in to OpsAPI? skip the form', sub: 'silent sign-in for the 2nd, 3rd … app' },
            { from: 'api', to: 'google', label: 'Password (+ code) or Google', sub: 'same checks as the two flows above' },
            { from: 'api', to: 'api', label: 'Origin trusted? sign the JWT', kind: 'accent' },
            { from: 'api', to: 'app', label: '/auth/callback?token=JWT&redirect=<nonce>', kind: 'reply' },
            { from: 'app', to: 'app', label: 'nonce = session nonce?', sub: 'else 400, a forged link' },
            { from: 'app', to: 'api', label: 'GET /auth/me', sub: 'Authorization: Bearer JWT' },
            { from: 'api', to: 'app', label: 'user · workspace · role', kind: 'accent' },
            { from: 'app', to: 'app', label: 'New session id, own cookie' },
            { from: 'app', to: 'api', label: 'Log out everywhere', sub: '/auth/signout', kind: 'reply' },
        ],
        points: [
            ['What the app stores', 'Its own session and the JWT; never a password'],
            ['How it checks the token', 'One call to /auth/me; the signing key never leaves OpsAPI'],
            ['Forged callback links', 'Refused: the nonce must match the session'],
            ['Single sign-on across apps', 'One OpsAPI session, a fresh token per app'],
        ],
    },
    {
        id: 'saml',
        name: 'SAML 2.0 single sign-on',
        demo: 'showcase.demo.opsapi.org → Sign in with SSO, with the demo IdP',
        tryHref: 'https://showcase.demo.opsapi.org/login',
        tryText: 'Sign in with SSO as visitor@example.com',
        summary:
            'The workspace\'s own identity provider vouches for the user. OpsAPI sends a SAML AuthnRequest, the IdP posts back a signed response, and OpsAPI checks the signature against the certificate saved for that workspace before anything else. The dashboard then swaps a one-time code for the JWT, so the token never appears in a URL.',
        lanes: [
            BROWSER,
            { key: 'dash', title: 'Dashboard', sub: 'login page', variant: 'violet' },
            { key: 'api', title: 'OpsAPI', sub: 'service provider', variant: 'accent' },
            { key: 'idp', title: 'Identity provider', sub: 'saml-idp.demo', variant: 'amber' },
        ],
        steps: [
            { from: 'browser', to: 'dash', label: 'Sign in with SSO', sub: 'visitor@example.com' },
            { from: 'dash', to: 'api', label: 'GET /auth/saml/discover', sub: '?email=… → provider for example.com' },
            { from: 'dash', to: 'api', label: 'GET /auth/saml/:id/login' },
            { from: 'api', to: 'api', label: 'Request ID → signed state cookie', sub: 'HMAC, 10 min' },
            { from: 'api', to: 'idp', label: '302 with SAMLRequest', sub: 'HTTP-Redirect: deflate + base64', kind: 'reply' },
            { from: 'idp', to: 'idp', label: 'User signs in (MFA at the IdP)', sub: 'response signed RSA-SHA256' },
            { from: 'idp', to: 'api', label: 'POST /auth/saml/:id/acs', sub: 'SAMLResponse, auto-submitted form' },
            { from: 'api', to: 'api', label: 'Signature by the saved cert · one Assertion', sub: 'Issuer · Audience · Recipient · time · InResponseTo' },
            { from: 'api', to: 'api', label: 'Assertion ID unused · email domain allowed', sub: 'not in another workspace · join as viewer' },
            { from: 'api', to: 'dash', label: '/auth/callback?saml_code=…', sub: 'one-time, 2 minutes', kind: 'reply' },
            { from: 'dash', to: 'api', label: 'POST /auth/saml/exchange', sub: '{ code } – single use' },
            { from: 'api', to: 'dash', label: 'JWT for the showcase workspace', kind: 'accent' },
        ],
        points: [
            ['Trust', "The IdP's certificate saved per workspace; certificates inside messages are ignored"],
            ['Refused', 'Tampered, wrapped, unsigned, replayed, expired or misaddressed responses; DTDs; SHA-1'],
            ['Scope of trust', 'An IdP vouches for its own workspace and email domains only'],
            ['Demo IdP', 'Mock SAML: no password, so only the read-only showcase trusts it'],
        ],
    },
];

// Every demo front end, the OpsAPI it uses, and how people sign in there.
export function AuthMap() {
    return (
        <svg viewBox="0 0 960 470" role="img" aria-labelledby="auth-map-t">
            <title id="auth-map-t">The live demos: which front end uses which OpsAPI, and which sign-in methods each offers</title>
            <Markers />
            <text x="20" y="24" className="dg-mono">FRONT ENDS</text>
            <text x="370" y="24" className="dg-mono">OPSAPI DEPLOYMENTS</text>
            <text x="730" y="24" className="dg-mono">WHO VOUCHES FOR THE USER</text>

            <Box x={20} y={40} w={260} h={74} title="Full dashboard" lines={['showcase.demo.opsapi.org', 'every app, sample data']} variant="violet" />
            <Box x={20} y={150} w={260} h={74} title="curl / your scripts" lines={['Bearer JWT from /auth/login']} variant="violet" />
            <Box x={20} y={270} w={260} h={74} title="Five apps" lines={['hello-java, php, python,', 'rust, go']} variant="violet" />
            <Box x={20} y={380} w={260} h={64} title="Identity dashboard" lines={['dashboard.demo.opsapi.org']} variant="violet" />

            <Box x={370} y={70} w={240} h={120} title="showcase-api" lines={['PROJECT_CODE=all', 'workspace: showcase', 'own Postgres']} variant="accent" />
            <Box x={370} y={290} w={240} h={120} title="identity.demo" lines={['PROJECT_CODE=core_only', 'hosted sign-in page', 'workspaces: showcase, demo']} variant="accent" />

            <line x1="280" y1="77" x2="368" y2="110" className="dg-line" markerEnd="url(#ah)" />
            <line x1="280" y1="187" x2="368" y2="160" className="dg-line" markerEnd="url(#ah)" />
            <line x1="280" y1="307" x2="368" y2="330" className="dg-line" markerEnd="url(#ah)" />
            <line x1="280" y1="412" x2="368" y2="380" className="dg-line" markerEnd="url(#ah)" />

            <Box x={730} y={40} w={210} h={64} title="Password (+ code)" lines={['OpsAPI itself']} />
            <Box x={730} y={130} w={210} h={64} title="SAML IdP" lines={['saml-idp.demo.opsapi.org']} variant="amber" />
            <Box x={730} y={290} w={210} h={64} title="Password (+ code)" lines={['OpsAPI itself']} />
            <Box x={730} y={380} w={210} h={64} title="Google" lines={['OAuth 2.0 / OIDC']} variant="amber" />

            <line x1="610" y1="100" x2="728" y2="74" className="dg-line--accent" markerEnd="url(#ah-acc)" />
            <line x1="610" y1="150" x2="728" y2="162" className="dg-line--accent" markerEnd="url(#ah-acc)" />
            <text x="668" y="128" textAnchor="middle" className="dg-small">SSO</text>
            <line x1="610" y1="330" x2="728" y2="322" className="dg-line--accent" markerEnd="url(#ah-acc)" />
            <line x1="610" y1="380" x2="728" y2="410" className="dg-line--accent" markerEnd="url(#ah-acc)" />

            <line x1="490" y1="190" x2="490" y2="288" className="dg-line--dash" />
            <text x="500" y="244" className="dg-small">separate deployments,</text>
            <text x="500" y="260" className="dg-small">separate databases</text>
        </svg>
    );
}

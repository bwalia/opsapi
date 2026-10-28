import Figure, { Markers, Table } from '@/components/Figure';

export const meta = {
    slug: 'sso-sign-in-flow',
    title: 'Single sign-on for any app: the OpsAPI sign-in flow',
    summary:
        'How a Java app and a PHP app share one sign-in through OpsAPI: the hosted sign-in page, the nonce, the token hand-back and the one call that proves who the user is.',
    date: '2026-10-28',
    tags: ['sso', 'auth', 'security', 'java', 'php'],
    audience: 'developers',
    readMinutes: 9,
};

function Step({ n, y }) {
    return (
        <g>
            <circle cx="22" cy={y} r="10" className="dg-step" />
            <text x="22" y={y + 4} textAnchor="middle" className="dg-step-t">{n}</text>
        </g>
    );
}

function SequenceDiagram() {
    const lanes = [
        { x: 110, title: 'Browser', sub: 'the user', v: '' },
        { x: 350, title: 'Your app', sub: 'hello-java / hello-php', v: 'violet' },
        { x: 610, title: 'OpsAPI', sub: 'identity service', v: 'accent' },
        { x: 850, title: 'Google', sub: 'optional', v: 'amber' },
    ];
    return (
        <svg viewBox="0 0 960 700" role="img" aria-labelledby="sso-seq-t">
            <title id="sso-seq-t">Sign-in sequence between the browser, your app, OpsAPI and Google</title>
            <Markers />
            {lanes.map((l) => (
                <g key={l.title}>
                    <rect x={l.x - 80} y="14" width="160" height="56" rx="6" className={`dg-box${l.v ? ` dg-box--${l.v}` : ''}`} />
                    <text x={l.x} y="38" textAnchor="middle" className="dg-title">{l.title}</text>
                    <text x={l.x} y="56" textAnchor="middle" className="dg-mono">{l.sub}</text>
                    <line x1={l.x} y1="70" x2={l.x} y2="690" className="dg-life" />
                </g>
            ))}

            <Step n="1" y={108} />
            <line x1="110" y1="108" x2="348" y2="108" className="dg-line" markerEnd="url(#ah)" />
            <text x="230" y="100" textAnchor="middle" className="dg-text">Click “Log in”</text>
            <rect x="358" y="92" width="160" height="32" rx="4" className="dg-box dg-box--violet" />
            <text x="438" y="112" textAnchor="middle" className="dg-mono">save a nonce in session</text>

            <Step n="2" y={164} />
            <line x1="350" y1="164" x2="112" y2="164" className="dg-line--dash" markerEnd="url(#ah)" />
            <text x="230" y="156" textAnchor="middle" className="dg-text">Redirect to OpsAPI</text>
            <text x="230" y="182" textAnchor="middle" className="dg-mono">/auth/signin?frontend_url=app&amp;from=nonce</text>

            <Step n="3" y={222} />
            <line x1="110" y1="222" x2="608" y2="222" className="dg-line" markerEnd="url(#ah)" />
            <text x="360" y="214" textAnchor="middle" className="dg-text">Hosted sign-in page: email + password (+ emailed code) or Google</text>

            <Step n="4" y={270} />
            <line x1="610" y1="270" x2="848" y2="270" className="dg-line" markerEnd="url(#ah)" />
            <text x="730" y="262" textAnchor="middle" className="dg-text">With Google: consent</text>

            <Step n="5" y={318} />
            <line x1="850" y1="318" x2="612" y2="318" className="dg-line--dash" markerEnd="url(#ah)" />
            <text x="730" y="310" textAnchor="middle" className="dg-text">Back with ?code</text>
            <text x="730" y="336" textAnchor="middle" className="dg-mono">/auth/google/callback</text>

            <Step n="6" y={366} />
            <line x1="610" y1="366" x2="848" y2="366" className="dg-line" markerEnd="url(#ah)" />
            <text x="730" y="358" textAnchor="middle" className="dg-text">Swap code, read verified email</text>
            <text x="730" y="384" textAnchor="middle" className="dg-mono">server to server</text>

            <Step n="7" y={420} />
            <rect x="452" y="402" width="316" height="38" rx="4" className="dg-box dg-box--accent" />
            <text x="610" y="425" textAnchor="middle" className="dg-text">Find or create user · join workspace · sign JWT</text>

            <Step n="8" y={476} />
            <line x1="610" y1="476" x2="352" y2="476" className="dg-line--dash" markerEnd="url(#ah)" />
            <text x="480" y="468" textAnchor="middle" className="dg-text">Redirect back to the app</text>
            <text x="480" y="494" textAnchor="middle" className="dg-mono">/auth/callback?token=JWT&amp;redirect=nonce</text>
            <rect x="182" y="504" width="160" height="32" rx="4" className="dg-box dg-box--violet" />
            <text x="262" y="524" textAnchor="middle" className="dg-mono">nonce must match session</text>

            <Step n="9" y={568} />
            <line x1="350" y1="568" x2="608" y2="568" className="dg-line--accent" markerEnd="url(#ah-acc)" />
            <text x="480" y="560" textAnchor="middle" className="dg-text">GET /auth/me</text>
            <text x="480" y="586" textAnchor="middle" className="dg-mono">Authorization: Bearer JWT</text>

            <Step n="10" y={620} />
            <line x1="610" y1="620" x2="352" y2="620" className="dg-line--dash" markerEnd="url(#ah)" />
            <text x="480" y="612" textAnchor="middle" className="dg-text">User + workspace + role</text>

            <Step n="11" y={668} />
            <line x1="350" y1="668" x2="112" y2="668" className="dg-line--dash" markerEnd="url(#ah)" />
            <text x="230" y="660" textAnchor="middle" className="dg-text">App session cookie, signed in</text>
        </svg>
    );
}

export default function Body() {
    return (
        <>
            <p>
                OpsAPI signs people in once and hands each of your apps a token it can check with a single call. Your
                apps never store passwords, never talk to Google and never build their own reset, lockout or two-factor
                screens. This note walks through the flow the two live demo apps use, step by step.
            </p>

            <h2>The flow</h2>
            <Figure caption="Solid arrows are requests, dashed ones are redirects or responses. With email and password, steps 4–6 don't happen: OpsAPI checks the password, and the emailed code when the workspace requires one, on its own page.">
                <SequenceDiagram />
            </Figure>

            <ol>
                <li><strong>Log in.</strong> The app makes a random nonce, keeps it in the user's session and sends the browser to OpsAPI.</li>
                <li><strong>Hosted sign-in.</strong> <code>GET /auth/signin?frontend_url=&lt;app origin&gt;&amp;from=&lt;nonce&gt;</code> shows OpsAPI's own page. If the browser already has an OpsAPI session it can go straight back with a fresh token.</li>
                <li><strong>Google, if chosen.</strong> OpsAPI redirects to Google, swaps the returned code server to server and reads the email. Unverified Google emails are refused.</li>
                <li><strong>User and workspace.</strong> A first-time user is created and added to the sign-up workspace; then OpsAPI signs a JWT.</li>
                <li><strong>Hand-back.</strong> The browser goes to <code>&lt;app&gt;/auth/callback?token=&lt;JWT&gt;&amp;redirect=&lt;nonce&gt;</code>, but only if the app's origin is on OpsAPI's trust list.</li>
                <li><strong>Check.</strong> The app compares the nonce with its session, then calls <code>GET /auth/me</code> with the token as a Bearer header and starts its own session from the answer.</li>
            </ol>

            <div className="callout">
                <p><strong>Never verify the JWT inside your app.</strong> It's signed with a key that never leaves OpsAPI. Asking <code>/auth/me</code> is the check, and it also tells you the user's workspace and role.</p>
            </div>

            <h2>What each side does</h2>
            <Table
                head={['Concern', 'OpsAPI', 'Your app']}
                rows={[
                    ['Passwords, Google, Apple', 'Handles all of it', 'Never sees them'],
                    ['Two-factor code', 'Emails and checks it (always for platform admins)', 'Nothing'],
                    ['Lockout and rate limits', 'Per account and per IP', 'Nothing'],
                    ['Who may receive a token', 'Trusted origins only', 'Has its origin allowed'],
                    ['Forged callback links', '—', 'Nonce check, refuses with 400'],
                    ['Session', 'Its own sign-in session', 'Its own cookie after /auth/me'],
                    ['Roles', 'Per workspace', 'Reads them from /auth/me'],
                ]}
            />

            <h2>The app side in four routes</h2>
            <p>
                The demo apps add <code>/login</code>, <code>/auth/callback</code> and <code>/logout</code>. This is the
                Spring Boot callback from <code>OpsApiAuthController.java</code>, trimmed:
            </p>
            <pre><code>{`@GetMapping("/auth/callback")
public String callback(@RequestParam String token,
                       @RequestParam(name = "redirect", required = false) String nonce,
                       HttpServletRequest request) {
    HttpSession session = request.getSession(false);
    Object expected = session == null ? null : session.getAttribute(NONCE);
    if (expected == null || nonce == null || !MessageDigest.isEqual(
            expected.toString().getBytes(UTF_8), nonce.getBytes(UTF_8))) {
        throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "Sign-in was not started here. Go to /login.");
    }

    Map<String, Object> me = opsapi.me(token);   // GET /auth/me with Authorization: Bearer <token>

    request.changeSessionId();   // a session id seen before login must not survive it
    session.removeAttribute(NONCE);
    session.setAttribute(USER, me);
    session.setAttribute(TOKEN, token);
    return "redirect:" + appUrl + session.getAttribute(NEXT);
}`}</code></pre>
            <p>
                <code>/logout?everywhere=true</code> also sends the browser to <code>/auth/signout</code>, so the next
                sign-in in any app prompts again.
            </p>
            <p>
                The PHP app does the same in <code>OpsApiAuth.php</code>. Both live in{' '}
                <a href="https://github.com/bwalia/workflow-examples">bwalia/workflow-examples</a>.
            </p>

            <h2>Settings that matter on the OpsAPI side</h2>
            <Table
                head={['Setting', 'What it does']}
                rows={[
                    [<code key="a">CORS_ALLOWED_DOMAINS</code>, 'A domain and all its subdomains that may call the API and receive tokens'],
                    [<code key="b">PASSWORD_RESET_ALLOWED_ORIGINS</code>, 'Extra exact origins allowed to receive tokens and reset links'],
                    [<code key="c">SIGNUP_NAMESPACE_SLUG</code>, 'The workspace a first-time sign-in joins'],
                    [<code key="d">GOOGLE_CLIENT_ID / _SECRET / _REDIRECT_URI</code>, 'The Google OAuth client; the redirect URI must be registered on it'],
                ]}
            />

            <h2>What it isn't</h2>
            <p>
                OpsAPI isn't an OpenID Connect or SAML provider: there are no client registrations and no{' '}
                <code>/authorize</code> or <code>/token</code> endpoints, so a stock OIDC client such as Spring Security's{' '}
                <code>oauth2Login()</code> can't use it directly. Apps integrate with the redirect, token and{' '}
                <code>/auth/me</code> contract above. Mobile apps post a Google or Apple ID token to{' '}
                <code>POST /auth/oauth/validate</code> instead.
            </p>

            <h2>Try it</h2>
            <p>
                The <a href="/demo/">live demo</a> runs exactly this flow with a Java app and a PHP app. Sign in to one,
                then open the other.
            </p>
        </>
    );
}

import Figure, { Markers, Box, Table } from '@/components/Figure';

export const meta = {
    slug: 'hmrc-mtd-filing',
    title: 'Filing a UK tax return through HMRC Making Tax Digital',
    summary:
        'The six-step “File your tax” wizard, the HMRC endpoints and API versions behind it, the sandbox behaviour that is expensive to rediscover, and what production needs.',
    date: '2026-10-28',
    tags: ['hmrc', 'mtd', 'tax', 'integrations'],
    audience: 'developers',
    readMinutes: 11,
};

const STEPS = [
    { t: '1 Connect', l: ['HMRC sign-in (OAuth)', 'you click'] },
    { t: '2 Business', l: ['Business Details v2', 'runs itself'] },
    { t: '3 Obligations', l: ['Obligations v3', 'runs itself'] },
    { t: '4 Check figures', l: ['totals + fixes', 'runs itself'] },
    { t: '5 Preview', l: ['cumulative + in-year', 'you click'] },
    { t: '6 Declare', l: ['final declaration', 'checkbox + click'] },
];

function WizardDiagram() {
    const w = 146;
    const xs = [8, 166, 324, 482, 640, 798];
    return (
        <svg viewBox="0 0 960 230" role="img" aria-labelledby="mtd-wiz-t">
            <title id="mtd-wiz-t">The six steps of the File your tax wizard, five non-binding and one binding</title>
            <Markers />
            <rect x="8" y="18" width="770" height="26" rx="4" className="dg-box dg-box--muted" />
            <text x="393" y="36" textAnchor="middle" className="dg-small">non-binding: nothing here files a return</text>
            <rect x="798" y="18" width="146" height="26" rx="4" className="dg-box dg-box--red" />
            <text x="871" y="36" textAnchor="middle" className="dg-small">binding</text>
            {STEPS.map((s, i) => (
                <g key={s.t}>
                    <Box x={xs[i]} y={62} w={w} h={96} title={s.t} lines={s.l}
                        variant={i === 5 ? 'red' : i >= 1 && i <= 3 ? 'accent' : ''} />
                    {i < 5 ? <line x1={xs[i] + w} y1="110" x2={xs[i + 1] - 2} y2="110" className="dg-line" markerEnd="url(#ah)" /> : null}
                </g>
            ))}
            <text x="8" y="190" className="dg-small">Green steps run on their own as soon as the step before them has an answer;</text>
            <text x="8" y="208" className="dg-small">only the steps that need a person ask for a click.</text>
        </svg>
    );
}

function SelfHealDiagram() {
    return (
        <svg viewBox="0 0 940 300" role="img" aria-labelledby="mtd-heal-t">
            <title id="mtd-heal-t">In the sandbox, a not-found error provisions a test business and retries once</title>
            <Markers />
            <Box x={10} y={110} w={170} h={70} title="calculate-preview" lines={['OpsAPI route']} variant="accent" />
            <line x1="180" y1="145" x2="228" y2="145" className="dg-line" markerEnd="url(#ah)" />
            <Box x={230} y={110} w={180} h={70} title="HMRC calculation" lines={['Calculations v8']} variant="amber" />
            <line x1="410" y1="128" x2="458" y2="72" className="dg-line--accent" markerEnd="url(#ah-acc)" />
            <Box x={460} y={40} w={210} h={60} title="Success" lines={['figures parsed']} variant="accent" />
            <line x1="410" y1="162" x2="458" y2="222" className="dg-line--red" markerEnd="url(#ah-red)" />
            <Box x={460} y={190} w={210} h={70} title="Not found" lines={['MATCHING_RESOURCE_NOT_FOUND']} variant="red" />
            <line x1="670" y1="225" x2="708" y2="225" className="dg-line" markerEnd="url(#ah)" />
            <Box x={710} y={190} w={220} h={70} title="Provision test business" lines={['create + set ITSA status']} />
            <path d="M820 190 V150 H412" className="dg-line--dash" markerEnd="url(#ah)" />
            <text x="700" y="143" textAnchor="middle" className="dg-small">store as default business, retry once</text>
            <text x="820" y="284" textAnchor="middle" className="dg-mono">sandbox only</text>
        </svg>
    );
}

function FraudHeadersDiagram() {
    return (
        <svg viewBox="0 0 940 170" role="img" aria-labelledby="mtd-fraud-t">
            <title id="mtd-fraud-t">Anti-fraud signals travel from the browser through OpsAPI to HMRC</title>
            <Markers />
            <Box x={10} y={40} w={200} h={84} title="Browser" lines={['screens, timezone,', 'window size, user agent']} />
            <line x1="210" y1="82" x2="248" y2="82" className="dg-line" markerEnd="url(#ah)" />
            <Box x={250} y={40} w={200} h={84} title="Dashboard" lines={['lib/hmrc-fraud.ts', 'sends X-Gov-Client-*']} variant="violet" />
            <line x1="450" y1="82" x2="488" y2="82" className="dg-line" markerEnd="url(#ah)" />
            <Box x={490} y={40} w={200} h={84} title="OpsAPI" lines={['build_fraud_headers()', 'adds IPs + vendor']} variant="accent" />
            <line x1="690" y1="82" x2="728" y2="82" className="dg-line" markerEnd="url(#ah)" />
            <Box x={730} y={40} w={200} h={84} title="HMRC" lines={['Gov-Client-*', 'Gov-Vendor-*']} variant="amber" />
            <text x="470" y="152" textAnchor="middle" className="dg-small">The X-Gov-Client-* names are allowed through CORS so the browser can send them.</text>
        </svg>
    );
}

export default function Body() {
    return (
        <>
            <p>
                OpsAPI's tax module (<code>tax_copilot</code>) can file a UK Self Assessment return end to end against
                HMRC's Making Tax Digital (MTD) APIs: connect, find the business, find what's due, check the figures,
                preview the tax, then make the binding final declaration. This note maps each step to code and lists
                the HMRC behaviour that costs the most time to rediscover.
            </p>

            <h2>The wizard</h2>
            <Figure caption="Steps 2–4 start themselves through guarded effects in the dashboard (one run per business or tax year). Step 6 is the only binding call, and it's gated on a declaration checkbox.">
                <WizardDiagram />
            </Figure>

            <Table
                head={['Step', 'Dashboard calls', 'HMRC API (Accept version)']}
                rows={[
                    ['1 Connect', <code key="1">/auth/hmrc/initiate → /auth/hmrc/callback</code>, 'OAuth with read:self-assessment and write:self-assessment'],
                    ['2 Business', <code key="2">POST /api/v2/hmrc/businesses/fetch</code>, 'Business Details (2.0)'],
                    ['3 Obligations', <code key="3">POST /api/v2/hmrc/obligations/fetch</code>, 'Obligations (3.0)'],
                    ['4 Check figures', <code key="4">GET /api/v2/tax/hmrc/aggregate-preview</code>, 'None: totals classified transactions locally'],
                    ['5 Preview', <code key="5">POST /api/v2/tax/hmrc/calculate-preview</code>, 'Self-Employment cumulative (5.0), Individual Calculations (8.0)'],
                    ['6 Declare', <code key="6">POST /api/v2/tax/hmrc/submit-final-declaration</code>, 'Individual Calculations (8.0) final declaration'],
                ]}
            />

            <h2>Layers</h2>
            <ul>
                <li><code>lib/hmrc-mtd-client.lua</code>: one function per HMRC endpoint. <code>HMRC_ENVIRONMENT</code> switches between <code>test-api.service.hmrc.gov.uk</code> and <code>api.service.hmrc.gov.uk</code>; every request carries <code>Accept: application/vnd.hmrc.&lt;version&gt;+json</code>.</li>
                <li><code>helper/hmrc.lua</code>: OAuth token storage and refresh, and the anti-fraud headers.</li>
                <li><code>lib/hmrc-aggregator.lua</code>: rolls classified transactions into the cumulative body and flags negative fields, usually a credit filed as an expense, which HMRC rejects. Step 4 lets the user fix them inline.</li>
                <li>Routes in <code>tax-hmrc-auth.lua</code>, <code>tax-hmrc-data.lua</code> and <code>tax-hmrc-filing.lua</code>.</li>
            </ul>

            <h2>The final declaration</h2>
            <p>
                The declaration must reference an <strong>intent-to-finalise</strong> calculation, not the in-year one
                from step 5. So the route triggers a fresh <code>intent-to-finalise</code> calculation, waits for it,
                then posts the declaration against that id. It refuses to run at all unless the request carries{' '}
                <code>declaration_accepted</code>: this call is binding. Real HMRC also rejects finalising a tax year
                before it has ended (<code>RULE_FINAL_DECLARATION_TAX_YEAR</code>); the sandbox lets it through.
            </p>

            <h2>Sandbox behaviour worth knowing</h2>
            <h3>Obligations ignore your dates unless you ask</h3>
            <p>
                By default the sandbox returns a fixed 2018-era sample whatever <code>from</code> and <code>to</code>{' '}
                you send. <code>Gov-Test-Scenario: DYNAMIC</code> makes it echo periods for the dates requested. It
                then returns synthetic business ids for all three business types (<code>XBIS…</code> self-employment,{' '}
                <code>XPIS…</code> UK property, <code>XFIS…</code> foreign property), so OpsAPI keeps the
                self-employment ones and doesn't filter by your real business id in the sandbox. The header is dropped
                outside the sandbox.
            </p>

            <h3>Calculations only work against a test business</h3>
            <p>
                Cumulative submissions are sent with <code>Gov-Test-Scenario: STATEFUL</code>, and stateful
                calculations only work for a business created through the Self Assessment Test Support API. The
                businesses Business Details hands back aren't fileable, and HMRC answers{' '}
                <code>MATCHING_RESOURCE_NOT_FOUND</code>. Both the preview and the declaration routes heal themselves:
            </p>
            <Figure caption="The self-heal creates a test business, sets its MTD ITSA status, stores it as the default business and retries once. Outside the sandbox the error is returned as is.">
                <SelfHealDiagram />
            </Figure>

            <h3>The figures are nested</h3>
            <p>
                Tax figures sit under <code>calculation.taxCalculation</code>, with sub-totals in{' '}
                <code>.incomeTax</code> and <code>allowancesAndDeductions</code>, not at the top level.{' '}
                <code>parse_figures</code> reads those paths. The sandbox always returns{' '}
                <code>-99999999999.99</code> as the grand total; OpsAPI flags it as a placeholder so the dashboard
                doesn't show it as a real bill. The other figures are real.
            </p>

            <h2>Anti-fraud headers</h2>
            <p>
                HMRC requires <code>Gov-Client-*</code> and <code>Gov-Vendor-*</code> headers on every call. Some
                signals only exist in the browser, so the dashboard collects them and sends them as{' '}
                <code>X-Gov-Client-*</code>; <code>build_fraud_headers()</code> maps them to the real names and adds the
                server-side ones.
            </p>
            <Figure caption="The connection method is WEB_APP_VIA_SERVER. Gov-Vendor-Public-IP and Gov-Vendor-Forwarded need the server's public egress address configured; they're left out when it isn't, because HMRC rejects private addresses.">
                <FraudHeadersDiagram />
            </Figure>
            <p>
                These headers pass HMRC's Test Fraud Prevention Headers validator. The one remaining note is a
                non-blocking <code>Gov-Client-Multi-Factor</code> warning, which is acceptable for sign-in with a
                password and an emailed code.
            </p>

            <h2>Production readiness</h2>
            <p>Switching <code>HMRC_ENVIRONMENT</code> to <code>production</code> isn't enough on its own. You also need:</p>
            <ul>
                <li>Verified TLS: requests verify certificates outside the sandbox, so nginx needs <code>lua_ssl_trusted_certificate</code> pointing at the system CA bundle (already in the shipped config).</li>
                <li><code>HMRC_CLIENT_ID</code>, <code>HMRC_CLIENT_SECRET</code>, <code>HMRC_REDIRECT_URI</code> and <code>HMRC_SERVER_PUBLIC_IP</code>.</li>
                <li>The HMRC application subscribed to Business Details, Obligations, Self Employment Business and Individual Calculations (MTD).</li>
            </ul>

            <div className="callout callout--amber">
                <p>
                    <strong>Testing without a browser:</strong> the routes need an OpsAPI user with a stored HMRC token.
                    The repo's CLAUDE.md describes minting a test JWT for such a user and syntax-checking Lua inside the
                    container.
                </p>
            </div>
        </>
    );
}

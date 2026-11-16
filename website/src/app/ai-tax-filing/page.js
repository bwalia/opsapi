import Link from 'next/link';
import content from '@/content/ai-tax-filing.json';

// Same content as tenthmatrix.com/en/ai-tax-filing (src/content/ai-tax-filing.json is copied from
// the TenthMatrix site's English data; links to TenthMatrix pages are absolute). The app it shows
// runs on OpsAPI's tax module.
const { header, intro, videosTitle, videos, pillars, steps, features, agents, aiAngle, deploy, faq, cta, related } = content;
const BROCHURE = deploy.ctaHref;

export const metadata = {
    title: 'AI Tax Filing',
    description:
        'A UK tax return application built on OpsAPI, with an AI agent that reads bank statements, sorts every ' +
        'transaction into HMRC categories and files Income Tax and VAT through Making Tax Digital. Seven recorded scenarios and a brochure.',
};

const ext = (href) => href.startsWith('http');
function A({ href, className, children }) {
    return ext(href)
        ? <a href={href} className={className} target="_blank" rel="noopener">{children}</a>
        : <a href={href} className={className}>{children}</a>;
}

export default function AiTaxFilingPage() {
    return (
        <>
            <section className="band hero" style={{ paddingBlock: 'clamp(2.5rem, 2rem + 4vw, 4.5rem)' }}>
                <div className="container-x">
                    <p className="eyebrow">Built on OpsAPI · UK tax</p>
                    <h1 className="display-x">{header.title}</h1>
                    <p className="lead-x"><strong>{header.subtitle}</strong> {header.description}</p>
                    <div className="hero__actions">
                        <a href={BROCHURE} className="btn-x btn-x--primary">{deploy.ctaLabel}</a>
                        <a href="#videos" className="btn-x btn-x--ghost">Watch the scenarios</a>
                    </div>
                </div>
            </section>

            <section className="section">
                <div className="container-x">
                    <h2>{intro.title}</h2>
                    <p className="lead-x">{intro.body}</p>
                    <p className="muted" style={{ fontSize: 'var(--font-sm)' }}>
                        The application runs on OpsAPI&apos;s tax module (<code>PROJECT_CODE=tax_copilot</code>): statement
                        reading, the transaction classifier and HMRC Making Tax Digital filing.{' '}
                        <Link href="/features/">See the features</Link>.
                    </p>
                </div>
            </section>

            <section className="section section--tint" id="videos">
                <div className="container-x">
                    <h2>{videosTitle}</h2>
                    <div className="grid-2" style={{ marginTop: '1.5rem' }}>
                        {videos.map((v) => (
                            <div key={v.watchUrl} className="card-x">
                                <a href={v.watchUrl} target="_blank" rel="noopener" style={{ position: 'relative', display: 'block' }}>
                                    {/* eslint-disable-next-line @next/next/no-img-element */}
                                    <img src={v.thumbnail} alt={v.thumbnailAlt} loading="lazy" width="1280" height="720"
                                        style={{ width: '100%', height: 'auto', borderRadius: 8, border: '1px solid var(--line)' }} />
                                    {v.duration && (
                                        <span className="tag" style={{ position: 'absolute', right: 8, bottom: 8, margin: 0, background: 'rgba(0,0,0,0.75)', color: '#fff' }}>
                                            ▶ {v.duration}
                                        </span>
                                    )}
                                </a>
                                <h3>{v.title}</h3>
                                <p>{v.caption}</p>
                                <a className="card-x__foot" href={v.watchUrl} target="_blank" rel="noopener">Watch on YouTube →</a>
                            </div>
                        ))}
                    </div>
                </div>
            </section>

            <section className="section">
                <div className="container-x">
                    <h2>{pillars.title}</h2>
                    <div className="grid-auto" style={{ marginTop: '1.25rem' }}>
                        {pillars.items.map((p) => (
                            <div key={p.title} className="card-x"><h3>{p.title}</h3><p>{p.text}</p></div>
                        ))}
                    </div>

                    <h2 style={{ marginTop: '3rem' }}>{steps.title}</h2>
                    <div className="grid-auto" style={{ marginTop: '1.25rem' }}>
                        {steps.items.map((s) => (
                            <div key={s.n} className="card-x">
                                <span className="card-x__meta">Step {s.n}</span>
                                <h3>{s.title}</h3>
                                <p>{s.text}</p>
                            </div>
                        ))}
                    </div>
                </div>
            </section>

            <section className="section section--tint">
                <div className="container-x">
                    <h2>{features.title}</h2>
                    <div className="grid-auto" style={{ marginTop: '1.25rem' }}>
                        {features.items.map((f) => (
                            <div key={f.title} className="card-x"><h3>{f.title}</h3><p>{f.text}</p></div>
                        ))}
                    </div>

                    <h2 style={{ marginTop: '3rem' }}>{agents.title}</h2>
                    <p className="lead-x">{agents.intro}</p>
                    <div className="grid-auto" style={{ marginTop: '1.25rem' }}>
                        {agents.items.map((f) => (
                            <div key={f.title} className="card-x"><h3>{f.title}</h3><p>{f.text}</p></div>
                        ))}
                    </div>
                </div>
            </section>

            <section className="section">
                <div className="container-x">
                    <h2>{aiAngle.title}</h2>
                    <p className="lead-x">{aiAngle.intro}</p>
                    <ul>
                        {aiAngle.points.map((p) => <li key={p} style={{ color: 'var(--ink-2)', marginBottom: '0.4rem' }}>{p}</li>)}
                    </ul>

                    <div className="card-x" style={{ marginTop: '2.5rem' }}>
                        <h2 style={{ margin: 0 }}>{deploy.title}</h2>
                        <p>{deploy.body}</p>
                        <div className="hero__actions" style={{ marginTop: '0.5rem' }}>
                            <a href={BROCHURE} className="btn-x btn-x--primary">{deploy.ctaLabel}</a>
                        </div>
                    </div>
                </div>
            </section>

            <section className="section section--tint">
                <div className="container-x">
                    <h2>{faq.title}</h2>
                    {faq.items.map((q) => (
                        <details key={q.question} className="card-x" style={{ marginTop: '0.75rem' }}>
                            <summary style={{ fontWeight: 600, cursor: 'pointer' }}>{q.question}</summary>
                            <p style={{ marginTop: '0.5rem' }}>{q.answer}</p>
                        </details>
                    ))}
                </div>
            </section>

            <section className="band section">
                <div className="container-x">
                    <h2>{cta.title}</h2>
                    <p className="lead-x">{cta.description}</p>
                    <div className="hero__actions">
                        <A href={cta.primary.href} className="btn-x btn-x--primary">{cta.primary.label}</A>
                        <A href={cta.secondary.href} className="btn-x btn-x--ghost">{cta.secondary.label}</A>
                    </div>
                    <p style={{ marginTop: '2rem', fontSize: 'var(--font-sm)' }}>
                        {related.title}:{' '}
                        {related.items.map((r, i) => (
                            <span key={r.href}>{i > 0 && ' · '}<A href={r.href}>{r.title}</A></span>
                        ))}
                        {' · '}<a href="https://www.tenthmatrix.com/en/ai-tax-filing/" target="_blank" rel="noopener">This page on TenthMatrix</a>
                    </p>
                </div>
            </section>
        </>
    );
}

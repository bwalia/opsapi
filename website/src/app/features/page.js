import Link from 'next/link';
import { FEATURE_GROUPS, PRESETS } from '@/content/features';
import { Table } from '@/components/Figure';

export const metadata = {
    title: 'Features',
    description: 'Everything OpsAPI does today: sign-in and security, workspaces and roles, plugins and webhooks, and business modules from CRM to UK tax filing.',
};

const count = FEATURE_GROUPS.reduce((n, g) => n + g.items.length, 0);

export default function FeaturesPage() {
    return (
        <>
            <section className="band hero" style={{ paddingBlock: 'clamp(2.5rem, 2rem + 4vw, 4.5rem)' }}>
                <div className="container-x">
                    <p className="eyebrow">Features</p>
                    <h1 className="display-x">Everything behind one API</h1>
                    <p className="lead-x">
                        {count} capabilities in five groups, all in the open-source code on GitHub. Business modules are
                        switched on per deployment, so a product only carries what it uses.
                    </p>
                    <ul className="hero__chips" aria-label="Jump to a group">
                        {FEATURE_GROUPS.map((g) => <li key={g.id}><a href={`#${g.id}`} style={{ color: 'inherit', textDecoration: 'none' }}>{g.title}</a></li>)}
                    </ul>
                </div>
            </section>

            <section className="section" style={{ paddingTop: '1rem' }}>
                <div className="container-x">
                    {FEATURE_GROUPS.map((g) => (
                        <div key={g.id} id={g.id} className="feature-group">
                            <div className="feature-group__head">
                                <h2>{g.title}</h2>
                                <span className="muted">{g.blurb}</span>
                            </div>
                            <div className="grid-auto">
                                {g.items.map((f) => (
                                    <div key={f.name} className="card-x">
                                        <span className="code-chip">{f.flag === 'core' ? 'always on' : `feature: ${f.flag}`}</span>
                                        <h3>{f.name}</h3>
                                        <p>{f.text}</p>
                                    </div>
                                ))}
                            </div>
                        </div>
                    ))}

                    <div className="feature-group" id="presets">
                        <div className="feature-group__head">
                            <h2>Presets</h2>
                            <span className="muted">Pick one per deployment with PROJECT_CODE, or combine presets: <code>ecommerce,collaboration</code>. Only preset names count; anything else is skipped.</span>
                        </div>
                        <Table
                            head={['PROJECT_CODE', 'Modules it loads (plus sign-in, workspaces and roles)']}
                            rows={PRESETS.map((p) => [<code key={p.code}>{p.code}</code>, p.modules.join(', ')])}
                        />
                        <p className="muted" style={{ fontSize: 'var(--font-sm)' }}>
                            A module that isn't loaded answers 404 for everyone and has no tables. How that works:{' '}
                            <Link href="/technotes/project-code-feature-gating/">feature gating technote</Link>.
                        </p>
                    </div>
                </div>
            </section>
        </>
    );
}

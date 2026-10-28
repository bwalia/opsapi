import { TECHNOTES } from '@/content/technotes';
import { ListCard } from '@/components/ArticleLayout';

export const metadata = {
    title: 'Technotes',
    description: 'Visual deep dives into how OpsAPI works: sign-in, tenancy, modules, deployment, the edge and operations.',
};

export default function TechnotesPage() {
    return (
        <>
            <section className="band hero" style={{ paddingBlock: 'clamp(2.5rem, 2rem + 4vw, 4.5rem)' }}>
                <div className="container-x">
                    <p className="eyebrow">Technotes</p>
                    <h1 className="display-x">How OpsAPI works, drawn out</h1>
                    <p className="lead-x">
                        Diagram-first notes for developers, DevOps and SRE: the request path, tenancy, sign-in, modules,
                        deployment and the edge. Each one is checked against the code on GitHub.
                    </p>
                </div>
            </section>
            <section className="section">
                <div className="container-x grid-auto">
                    {TECHNOTES.map((t) => <ListCard key={t.slug} href={`/technotes/${t.slug}/`} item={t} kind="Technote" />)}
                </div>
            </section>
        </>
    );
}

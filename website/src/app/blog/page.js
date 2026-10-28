import { POSTS } from '@/content/blog';
import { ListCard } from '@/components/ArticleLayout';

export const metadata = {
    title: 'Blog',
    description: 'Why OpsAPI exists and what it changes for teams that run many apps: sign-in, tenancy, cost and control.',
};

export default function BlogPage() {
    return (
        <>
            <section className="band hero" style={{ paddingBlock: 'clamp(2.5rem, 2rem + 4vw, 4.5rem)' }}>
                <div className="container-x">
                    <p className="eyebrow">Blog</p>
                    <h1 className="display-x">Notes for the people who choose the stack</h1>
                    <p className="lead-x">
                        Shorter reads for technical managers and leads: what OpsAPI changes, what it costs and where it fits.
                    </p>
                </div>
            </section>
            <section className="section">
                <div className="container-x grid-auto">
                    {POSTS.map((p) => <ListCard key={p.slug} href={`/blog/${p.slug}/`} item={p} kind="Blog" />)}
                </div>
            </section>
        </>
    );
}

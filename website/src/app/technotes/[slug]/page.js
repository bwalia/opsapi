import { notFound } from 'next/navigation';
import { TECHNOTES, getTechnote } from '@/content/technotes';
import ArticleLayout from '@/components/ArticleLayout';

export const dynamicParams = false;

export function generateStaticParams() {
    return TECHNOTES.map((t) => ({ slug: t.slug }));
}

export async function generateMetadata({ params }) {
    const { slug } = await params;
    const t = getTechnote(slug);
    return t ? { title: t.title, description: t.summary } : {};
}

export default async function TechnotePage({ params }) {
    const { slug } = await params;
    const t = getTechnote(slug);
    if (!t) notFound();
    const Body = t.Body;
    return (
        <ArticleLayout kind="Technotes" kindHref="/technotes/" item={t}>
            <Body />
        </ArticleLayout>
    );
}

import { notFound } from 'next/navigation';
import { POSTS, getPost } from '@/content/blog';
import ArticleLayout from '@/components/ArticleLayout';

export const dynamicParams = false;

export function generateStaticParams() {
    return POSTS.map((t) => ({ slug: t.slug }));
}

export async function generateMetadata({ params }) {
    const { slug } = await params;
    const t = getPost(slug);
    return t ? { title: t.title, description: t.summary } : {};
}

export default async function BlogPostPage({ params }) {
    const { slug } = await params;
    const t = getPost(slug);
    if (!t) notFound();
    const Body = t.Body;
    return (
        <ArticleLayout kind="Blog" kindHref="/blog/" item={t}>
            <Body />
        </ArticleLayout>
    );
}

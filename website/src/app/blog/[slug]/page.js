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
    if (!t) return {};
    // A post with an image gets a share card (LinkedIn, X, Slack); one without keeps the site default.
    const images = t.image ? [{ url: t.image, width: 1200, height: 627, alt: t.title }] : undefined;
    return {
        title: t.title,
        description: t.summary,
        openGraph: { title: t.title, description: t.summary, url: `/blog/${t.slug}/`, type: 'article', images },
        twitter: { card: images ? 'summary_large_image' : 'summary', title: t.title, description: t.summary, images },
    };
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

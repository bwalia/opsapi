import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { EndpointCard } from '@/components/docs/EndpointCard';
import { loadOpenApi } from '@/lib/openapi/loader';
import { findDomain, parseOpenApi } from '@/lib/openapi/parser';

interface Params {
  params: Promise<{ tag: string }>;
}

export async function generateStaticParams() {
  const doc = await loadOpenApi();
  const domains = parseOpenApi(doc);
  return domains.map((d) => ({ tag: d.slug }));
}

export async function generateMetadata({ params }: Params): Promise<Metadata> {
  const { tag } = await params;
  const doc = await loadOpenApi();
  const domain = findDomain(parseOpenApi(doc), tag);
  return {
    title: domain ? `${domain.tag} — OpsAPI Docs` : 'OpsAPI Docs',
  };
}

export const dynamic = 'force-dynamic';

export default async function TagPage({ params }: Params) {
  const { tag } = await params;
  const doc = await loadOpenApi();
  const domains = parseOpenApi(doc);
  const domain = findDomain(domains, tag);
  if (!domain) notFound();

  return (
    <div className="space-y-6">
      <header className="space-y-2">
        <div className="text-xs font-semibold uppercase tracking-wider text-primary-500">
          API Reference
        </div>
        <h1 className="text-3xl font-bold tracking-tight text-secondary-900">
          {domain.tag}
        </h1>
        <p className="text-secondary-600">
          {domain.endpoints.length} endpoint
          {domain.endpoints.length === 1 ? '' : 's'} in this domain.
        </p>
      </header>
      <div className="space-y-8">
        {domain.endpoints.map((e) => (
          <EndpointCard key={e.id} endpoint={e} />
        ))}
      </div>
    </div>
  );
}

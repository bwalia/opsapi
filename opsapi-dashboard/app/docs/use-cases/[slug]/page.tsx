import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { Callout } from '@/components/docs/Callout';
import { EndpointCard } from '@/components/docs/EndpointCard';
import { useCases } from '@/content/use-cases';
import { loadOpenApi } from '@/lib/openapi/loader';
import { flattenEndpoints, parseOpenApi } from '@/lib/openapi/parser';

interface Params {
  params: Promise<{ slug: string }>;
}

export async function generateStaticParams() {
  return useCases.map((uc) => ({ slug: uc.slug }));
}

export async function generateMetadata({ params }: Params): Promise<Metadata> {
  const { slug } = await params;
  const uc = useCases.find((u) => u.slug === slug);
  return { title: uc ? `${uc.title} — OpsAPI Docs` : 'OpsAPI Docs' };
}

export const dynamic = 'force-dynamic';

export default async function UseCasePage({ params }: Params) {
  const { slug } = await params;
  const uc = useCases.find((u) => u.slug === slug);
  if (!uc) notFound();

  const doc = await loadOpenApi();
  const endpoints = flattenEndpoints(parseOpenApi(doc));

  const resolved = uc.steps.map((step) => ({
    ...step,
    endpoint: endpoints.find(
      (e) =>
        e.method === step.match.method.toLowerCase() &&
        e.path === step.match.path,
    ),
  }));

  return (
    <div className="space-y-8">
      <header className="space-y-2">
        <div className="text-xs font-semibold uppercase tracking-wider text-primary-500">
          Use case
        </div>
        <h1 className="text-3xl font-bold tracking-tight text-secondary-900">
          {uc.title}
        </h1>
        <p className="text-secondary-600">{uc.subtitle}</p>
      </header>
      <p className="max-w-2xl text-sm text-secondary-700">{uc.intro}</p>
      <Callout kind="tip">
        Make sure you have an OpsAPI server running and have set{' '}
        <code className="rounded bg-secondary-100 px-1 py-0.5 font-mono text-xs">
          OPSAPI_TOKEN
        </code>{' '}
        in your shell before running the curl snippets below.
      </Callout>
      <ol className="list-none space-y-10 pl-0">
        {resolved.map((step, i) => (
          <li key={i} className="space-y-3">
            <h2 className="text-lg font-semibold text-secondary-900">
              {step.title}
            </h2>
            <p className="max-w-2xl text-sm text-secondary-600">
              {step.description}
            </p>
            {step.endpoint ? (
              <EndpointCard endpoint={step.endpoint} />
            ) : (
              <div className="rounded-md border border-dashed border-secondary-300 p-4 text-xs text-secondary-500">
                Endpoint{' '}
                <code className="font-mono">
                  {step.match.method.toUpperCase()} {step.match.path}
                </code>{' '}
                not found in the current spec.
              </div>
            )}
          </li>
        ))}
      </ol>
    </div>
  );
}

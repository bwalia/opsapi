import type { Metadata } from 'next';
import Link from 'next/link';
import { MethodBadge } from '@/components/docs/MethodBadge';
import { loadOpenApi } from '@/lib/openapi/loader';
import { parseOpenApi } from '@/lib/openapi/parser';

export const metadata: Metadata = {
  title: 'API Reference — OpsAPI Docs',
};

export const dynamic = 'force-dynamic';

export default async function ApiIndexPage() {
  const doc = await loadOpenApi();
  const domains = parseOpenApi(doc);
  const totalEndpoints = domains.reduce((acc, d) => acc + d.endpoints.length, 0);

  return (
    <div className="space-y-10">
      <header>
        <h1 className="text-3xl font-bold tracking-tight text-secondary-900">
          API Reference
        </h1>
        <p className="mt-2 text-secondary-600">
          {domains.length} domain{domains.length === 1 ? '' : 's'},{' '}
          {totalEndpoints} endpoint{totalEndpoints === 1 ? '' : 's'}. Organized
          by tag, generated live from the OpenAPI spec.
        </p>
      </header>

      {domains.length === 0 ? (
        <div className="rounded-lg border border-dashed border-secondary-300 p-8 text-center text-sm text-secondary-500">
          No endpoints yet. Make sure the OpsAPI server is running and the
          Swagger spec is reachable.
        </div>
      ) : (
        domains.map((d) => (
          <section key={d.slug}>
            <div className="flex items-baseline justify-between">
              <h2 className="text-xl font-semibold text-secondary-900">
                <Link
                  href={`/docs/api/${d.slug}`}
                  className="hover:text-primary-600"
                >
                  {d.tag}
                </Link>
              </h2>
              <span className="text-xs text-secondary-500">
                {d.endpoints.length} endpoint
                {d.endpoints.length === 1 ? '' : 's'}
              </span>
            </div>
            <div className="mt-3 divide-y divide-secondary-100 overflow-hidden rounded-lg border border-secondary-200">
              {d.endpoints.map((e) => (
                <Link
                  key={e.id}
                  href={`/docs/api/${d.slug}#${e.id}`}
                  className="flex items-center gap-3 px-4 py-2.5 hover:bg-secondary-50"
                >
                  <MethodBadge method={e.method} />
                  <code className="truncate font-mono text-xs text-secondary-800">
                    {e.path}
                  </code>
                  <span className="flex-1 truncate text-xs text-secondary-500">
                    {e.summary}
                  </span>
                </Link>
              ))}
            </div>
          </section>
        ))
      )}
    </div>
  );
}

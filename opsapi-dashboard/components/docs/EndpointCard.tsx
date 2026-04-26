import { ExternalLink, Lock } from 'lucide-react';
import type { OpenApiSchema, ParsedEndpoint } from '@/lib/openapi/types';
import { generateSamples } from '@/lib/openapi/samples';
import { CodeBlock } from './CodeBlock';
import { MethodBadge } from './MethodBadge';
import { ParamTable } from './ParamTable';

function getBodyProperties(
  schema: OpenApiSchema | undefined,
): Array<[string, OpenApiSchema]> {
  if (!schema) return [];
  if (schema.type === 'object' && schema.properties) {
    return Object.entries(schema.properties);
  }
  if (schema.type === 'array' && schema.items?.properties) {
    return Object.entries(schema.items.properties);
  }
  return [];
}

export function EndpointCard({ endpoint }: { endpoint: ParsedEndpoint }) {
  const baseUrl = process.env.NEXT_PUBLIC_API_URL || 'http://127.0.0.1:4010';
  const swaggerUrl = `${baseUrl}/swagger#/${encodeURIComponent(endpoint.tag)}/${endpoint.operationId}`;
  const samples = generateSamples(endpoint, baseUrl);

  const pathParams = endpoint.parameters.filter((p) => p.in === 'path');
  const queryParams = endpoint.parameters.filter((p) => p.in === 'query');

  const bodySchemaEntry = endpoint.requestBody?.content
    ? Object.entries(endpoint.requestBody.content)[0]
    : undefined;
  const bodyProperties = getBodyProperties(bodySchemaEntry?.[1]?.schema);

  const responseEntries = Object.entries(endpoint.responses);

  return (
    <article
      id={endpoint.id}
      className="scroll-mt-20 rounded-xl border border-secondary-200 bg-surface p-5 shadow-sm"
    >
      <header className="flex flex-wrap items-start justify-between gap-3 border-b border-secondary-100 pb-4">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <MethodBadge method={endpoint.method} />
            <code className="break-all font-mono text-sm text-secondary-900">
              {endpoint.path}
            </code>
            {endpoint.requiresAuth && (
              <span className="inline-flex items-center gap-1 text-[10px] text-secondary-500">
                <Lock className="h-3 w-3" /> Auth
              </span>
            )}
          </div>
          <h3 className="mt-2 text-base font-semibold text-secondary-900">
            {endpoint.summary}
          </h3>
          {endpoint.description && (
            <p className="mt-1 text-sm text-secondary-600">
              {endpoint.description}
            </p>
          )}
        </div>
        <a
          href={swaggerUrl}
          target="_blank"
          rel="noreferrer"
          className="inline-flex shrink-0 items-center gap-1 rounded-md border border-secondary-200 px-3 py-1.5 text-xs font-medium text-secondary-700 hover:border-primary-500 hover:text-primary-600"
        >
          Try in Swagger <ExternalLink className="h-3 w-3" />
        </a>
      </header>

      <div className="mt-5 grid gap-5 lg:grid-cols-2">
        <div className="space-y-5">
          <ParamTable title="Path parameters" params={pathParams} />
          <ParamTable title="Query parameters" params={queryParams} />
          {bodyProperties.length > 0 && (
            <div>
              <h4 className="mb-2 text-xs font-semibold uppercase tracking-wider text-secondary-500">
                Request body
              </h4>
              <div className="overflow-hidden rounded-md border border-secondary-200">
                <table className="w-full text-xs">
                  <thead className="bg-secondary-50 text-left text-secondary-600">
                    <tr>
                      <th className="px-3 py-2 font-medium">Field</th>
                      <th className="px-3 py-2 font-medium">Type</th>
                      <th className="px-3 py-2 font-medium">Description</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-secondary-200">
                    {bodyProperties.map(([name, prop]) => (
                      <tr key={name}>
                        <td className="px-3 py-2 font-mono text-secondary-900">
                          {name}
                        </td>
                        <td className="px-3 py-2 text-secondary-600">
                          {prop?.type || 'string'}
                        </td>
                        <td className="px-3 py-2 text-secondary-600">
                          {prop?.description || '—'}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          )}
          {responseEntries.length > 0 && (
            <div>
              <h4 className="mb-2 text-xs font-semibold uppercase tracking-wider text-secondary-500">
                Responses
              </h4>
              <ul className="space-y-1 text-xs">
                {responseEntries.map(([code, resp]) => {
                  const ok = code.startsWith('2');
                  return (
                    <li key={code} className="flex items-center gap-2">
                      <span
                        className={`rounded px-1.5 py-0.5 font-mono text-[10px] ${
                          ok
                            ? 'bg-accent-100 text-accent-700'
                            : 'bg-error-500/10 text-error-600'
                        }`}
                      >
                        {code}
                      </span>
                      <span className="text-secondary-600">
                        {resp?.description || '—'}
                      </span>
                    </li>
                  );
                })}
              </ul>
            </div>
          )}
        </div>
        <div>
          <CodeBlock
            tabs={[
              { label: 'curl', language: 'bash', code: samples.curl },
              {
                label: 'JavaScript',
                language: 'javascript',
                code: samples.javascript,
              },
              { label: 'Python', language: 'python', code: samples.python },
            ]}
          />
        </div>
      </div>
    </article>
  );
}

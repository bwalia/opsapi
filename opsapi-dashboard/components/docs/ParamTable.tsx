import type { OpenApiParameter } from '@/lib/openapi/types';

export function ParamTable({
  title,
  params,
}: {
  title: string;
  params: OpenApiParameter[];
}) {
  if (!params.length) return null;
  return (
    <div>
      <h4 className="mb-2 text-xs font-semibold uppercase tracking-wider text-secondary-500">
        {title}
      </h4>
      <div className="overflow-hidden rounded-md border border-secondary-200">
        <table className="w-full text-xs">
          <thead className="bg-secondary-50 text-left text-secondary-600">
            <tr>
              <th className="px-3 py-2 font-medium">Name</th>
              <th className="px-3 py-2 font-medium">Type</th>
              <th className="px-3 py-2 font-medium">Required</th>
              <th className="px-3 py-2 font-medium">Description</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-secondary-200">
            {params.map((p) => (
              <tr key={`${p.in}-${p.name}`}>
                <td className="px-3 py-2 font-mono text-secondary-900">
                  {p.name}
                </td>
                <td className="px-3 py-2 text-secondary-600">
                  {p.schema?.type || 'string'}
                </td>
                <td className="px-3 py-2 text-secondary-600">
                  {p.required ? 'yes' : 'no'}
                </td>
                <td className="px-3 py-2 text-secondary-600">
                  {p.description || '—'}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

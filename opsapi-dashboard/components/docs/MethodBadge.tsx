import type { HttpMethod } from '@/lib/openapi/types';

const COLORS: Record<HttpMethod, string> = {
  get: 'bg-info-500/10 text-info-600 border-info-500/20',
  post: 'bg-accent-500/10 text-accent-700 border-accent-500/20',
  put: 'bg-warning-500/10 text-warning-600 border-warning-500/20',
  patch: 'bg-warning-500/10 text-warning-600 border-warning-500/20',
  delete: 'bg-error-500/10 text-error-600 border-error-500/20',
  options: 'bg-secondary-200 text-secondary-600 border-secondary-300',
  head: 'bg-secondary-200 text-secondary-600 border-secondary-300',
};

export function MethodBadge({ method }: { method: HttpMethod }) {
  return (
    <span
      className={`inline-flex items-center justify-center rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wider border ${COLORS[method]}`}
    >
      {method}
    </span>
  );
}

'use client';

import { useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { Search } from 'lucide-react';
import type { ParsedDomain } from '@/lib/openapi/types';
import { flattenEndpoints } from '@/lib/openapi/parser';

export function SearchBox({ domains }: { domains: ParsedDomain[] }) {
  const router = useRouter();
  const [q, setQ] = useState('');
  const [open, setOpen] = useState(false);
  const endpoints = useMemo(() => flattenEndpoints(domains), [domains]);

  const results = useMemo(() => {
    const needle = q.trim().toLowerCase();
    if (!needle) return [];
    return endpoints
      .filter(
        (e) =>
          e.path.toLowerCase().includes(needle) ||
          e.summary.toLowerCase().includes(needle) ||
          e.tag.toLowerCase().includes(needle) ||
          e.method.toLowerCase() === needle,
      )
      .slice(0, 10);
  }, [q, endpoints]);

  return (
    <div className="relative">
      <div className="flex items-center gap-2 rounded-md border border-secondary-200 bg-surface px-2 py-1.5">
        <Search className="h-4 w-4 text-secondary-400" />
        <input
          value={q}
          onChange={(e) => {
            setQ(e.target.value);
            setOpen(true);
          }}
          onFocus={() => setOpen(true)}
          onBlur={() => setTimeout(() => setOpen(false), 150)}
          placeholder="Search endpoints…"
          className="w-40 bg-transparent text-sm outline-none placeholder:text-secondary-400 md:w-56"
          aria-label="Search API endpoints"
        />
      </div>
      {open && results.length > 0 && (
        <div className="absolute right-0 top-11 z-50 max-h-96 w-80 overflow-auto rounded-md border border-secondary-200 bg-surface shadow-lg">
          {results.map((e) => (
            <button
              key={e.id}
              type="button"
              onMouseDown={(ev) => {
                ev.preventDefault();
                router.push(`/docs/api/${e.tagSlug}#${e.id}`);
                setOpen(false);
                setQ('');
              }}
              className="flex w-full flex-col items-start gap-0.5 border-b border-secondary-100 px-3 py-2 text-left text-xs last:border-0 hover:bg-secondary-50"
            >
              <div className="flex items-center gap-2">
                <span className="font-mono text-[10px] uppercase text-primary-600">
                  {e.method}
                </span>
                <span className="font-mono text-secondary-700">{e.path}</span>
              </div>
              <div className="w-full truncate text-secondary-500">
                {e.summary}
              </div>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

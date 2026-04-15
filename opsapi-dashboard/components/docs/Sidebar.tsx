'use client';

import { useState } from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { ChevronRight } from 'lucide-react';
import type { ParsedDomain } from '@/lib/openapi/types';

const topLevel = [
  { href: '/docs', label: 'Overview', matchExact: true },
  { href: '/docs/guides', label: 'Getting Started' },
  { href: '/docs/use-cases', label: 'Use Cases' },
];

export function Sidebar({ domains }: { domains: ParsedDomain[] }) {
  const pathname = usePathname();
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>({});

  const isActive = (href: string, exact = false) => {
    if (!pathname) return false;
    return exact ? pathname === href : pathname.startsWith(href);
  };

  const toggle = (slug: string) =>
    setCollapsed((prev) => ({ ...prev, [slug]: !prev[slug] }));

  const linkClass = (active: boolean) =>
    `block rounded px-2 py-1 ${
      active
        ? 'bg-primary-50 text-primary-700 font-medium'
        : 'text-secondary-700 hover:bg-secondary-100'
    }`;

  return (
    <nav className="sticky top-20 space-y-1 text-sm">
      {topLevel.map((item) => (
        <Link
          key={item.href}
          href={item.href}
          className={linkClass(isActive(item.href, item.matchExact))}
        >
          {item.label}
        </Link>
      ))}

      <div className="px-2 pt-4 pb-2 text-xs font-semibold uppercase tracking-wider text-secondary-400">
        API Reference
      </div>
      <Link
        href="/docs/api"
        className={linkClass(pathname === '/docs/api')}
      >
        All endpoints
      </Link>

      {domains.map((d) => {
        const open = !collapsed[d.slug];
        const domainActive = pathname?.includes(`/docs/api/${d.slug}`) ?? false;
        return (
          <div key={d.slug}>
            <button
              type="button"
              onClick={() => toggle(d.slug)}
              className={`flex w-full items-center justify-between rounded px-2 py-1 text-left ${
                domainActive
                  ? 'text-primary-700 font-medium'
                  : 'text-secondary-700 hover:bg-secondary-100'
              }`}
            >
              <span className="truncate">{d.tag}</span>
              <ChevronRight
                className={`h-4 w-4 shrink-0 transition-transform ${
                  open ? 'rotate-90' : ''
                }`}
              />
            </button>
            {open && (
              <div className="ml-3 border-l border-secondary-200">
                {d.endpoints.map((e) => (
                  <Link
                    key={e.id}
                    href={`/docs/api/${d.slug}#${e.id}`}
                    className="block truncate rounded pl-3 pr-2 py-1 text-xs text-secondary-600 hover:bg-secondary-100 hover:text-secondary-900"
                  >
                    <span className="mr-1 text-[10px] uppercase text-secondary-400">
                      {e.method}
                    </span>
                    {e.path}
                  </Link>
                ))}
              </div>
            )}
          </div>
        );
      })}
    </nav>
  );
}

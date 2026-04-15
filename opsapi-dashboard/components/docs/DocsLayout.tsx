import Link from 'next/link';
import type { ParsedDomain } from '@/lib/openapi/types';
import { SearchBox } from './SearchBox';
import { Sidebar } from './Sidebar';

const baseUrl = process.env.NEXT_PUBLIC_API_URL || 'http://127.0.0.1:4010';

export function DocsLayout({
  domains,
  children,
}: {
  domains: ParsedDomain[];
  children: React.ReactNode;
}) {
  return (
    <div className="min-h-screen bg-white text-secondary-900">
      <header className="sticky top-0 z-40 border-b border-secondary-200 bg-white/90 backdrop-blur">
        <div className="mx-auto flex h-14 max-w-7xl items-center gap-6 px-4">
          <Link href="/docs" className="flex items-center gap-2">
            <div className="h-7 w-7 rounded-md bg-primary-500" />
            <span className="font-semibold text-secondary-900">OpsAPI</span>
            <span className="hidden text-secondary-400 sm:inline">docs</span>
          </Link>
          <nav className="hidden items-center gap-5 text-sm text-secondary-600 md:flex">
            <Link href="/docs" className="hover:text-secondary-900">
              Overview
            </Link>
            <Link href="/docs/api" className="hover:text-secondary-900">
              API
            </Link>
            <Link href="/docs/use-cases" className="hover:text-secondary-900">
              Use Cases
            </Link>
            <Link href="/docs/guides" className="hover:text-secondary-900">
              Guides
            </Link>
          </nav>
          <div className="flex-1" />
          <SearchBox domains={domains} />
          <a
            href={`${baseUrl}/swagger`}
            target="_blank"
            rel="noreferrer"
            className="hidden items-center rounded-md bg-secondary-900 px-3 py-1.5 text-xs font-medium text-white hover:bg-secondary-800 sm:inline-flex"
          >
            Open Swagger
          </a>
        </div>
      </header>
      <div className="mx-auto flex max-w-7xl gap-8 px-4 py-8">
        <aside className="hidden w-64 shrink-0 lg:block">
          <Sidebar domains={domains} />
        </aside>
        <main id="main-content" className="min-w-0 flex-1">
          {children}
        </main>
      </div>
    </div>
  );
}

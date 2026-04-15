import type { Metadata } from 'next';
import Link from 'next/link';
import { ArrowRight } from 'lucide-react';
import { useCases } from '@/content/use-cases';

export const metadata: Metadata = {
  title: 'Use Cases — OpsAPI Docs',
};

export default function UseCasesIndexPage() {
  return (
    <div className="space-y-6">
      <header>
        <h1 className="text-3xl font-bold tracking-tight text-secondary-900">
          Use Cases
        </h1>
        <p className="mt-2 text-secondary-600">
          End-to-end walkthroughs with real API calls. Each one stitches
          several endpoints into a complete flow.
        </p>
      </header>
      <div className="grid gap-4 md:grid-cols-2">
        {useCases.map((uc) => (
          <Link
            key={uc.slug}
            href={`/docs/use-cases/${uc.slug}`}
            className="group rounded-xl border border-secondary-200 p-5 transition hover:border-primary-500/50 hover:shadow-sm"
          >
            <h2 className="text-lg font-semibold text-secondary-900 group-hover:text-primary-600">
              {uc.title}
            </h2>
            <p className="mt-1 text-sm text-secondary-600">{uc.subtitle}</p>
            <span className="mt-3 inline-flex items-center gap-1 text-xs font-medium text-primary-600">
              Read walkthrough <ArrowRight className="h-3 w-3" />
            </span>
          </Link>
        ))}
      </div>
    </div>
  );
}

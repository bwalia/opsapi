'use client';

/**
 * Segment error boundary for the whole authenticated dashboard.
 *
 * Next.js renders this when a page under /dashboard throws during render, so a
 * single bad API response degrades to a recoverable message instead of
 * white-screening the entire shell. `reset()` re-renders the failed segment.
 */

import { useEffect } from 'react';
import Link from 'next/link';
import { AlertTriangle } from 'lucide-react';
import { Button } from '@/components/ui';

export default function DashboardError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    // Surfaced to the console/monitoring; the user sees the friendly card below.
    console.error('[dashboard] render error:', error);
  }, [error]);

  return (
    <div className="flex min-h-[60vh] items-center justify-center p-6">
      <div className="w-full max-w-md rounded-xl border border-secondary-200 bg-surface p-8 text-center shadow-sm">
        <div className="mx-auto mb-4 flex h-12 w-12 items-center justify-center rounded-full bg-red-50 text-red-600">
          <AlertTriangle className="h-6 w-6" />
        </div>
        <h1 className="text-lg font-semibold text-secondary-900">Something went wrong</h1>
        <p className="mt-2 text-sm text-secondary-600">
          This page hit an unexpected error. You can try again, or head back to the dashboard.
        </p>
        {error?.digest && <p className="mt-2 text-xs text-secondary-400">Ref: {error.digest}</p>}
        <div className="mt-6 flex justify-center gap-2">
          <Button onClick={() => reset()}>Try again</Button>
          <Link href="/dashboard">
            <Button variant="secondary">Back to dashboard</Button>
          </Link>
        </div>
      </div>
    </div>
  );
}

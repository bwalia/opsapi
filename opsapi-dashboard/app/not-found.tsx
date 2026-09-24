'use client';

import React from 'react';
import Link from 'next/link';
import { Home, ArrowLeft, Compass, LifeBuoy } from 'lucide-react';
import { Button } from '@/components/ui';

export default function NotFound() {
  return (
    <div className="relative min-h-dvh flex items-center justify-center overflow-hidden bg-gradient-to-br from-secondary-100 via-secondary-50 to-primary-100/50 p-4 dark:from-secondary-950 dark:via-secondary-900 dark:to-secondary-900">
      {/* Depth: brand glows + subtle grid (stronger than before so it isn't washed out) */}
      <div className="pointer-events-none absolute inset-0 overflow-hidden">
        <div className="absolute -top-24 -right-24 h-96 w-96 rounded-full bg-primary-500/15 blur-3xl" />
        <div className="absolute -bottom-24 -left-24 h-96 w-96 rounded-full bg-primary-400/10 blur-3xl" />
        <div
          className="absolute inset-0 opacity-[0.04] dark:opacity-[0.06]"
          style={{
            backgroundImage:
              "url(\"data:image/svg+xml,%3Csvg width='40' height='40' viewBox='0 0 40 40' xmlns='http://www.w3.org/2000/svg'%3E%3Cpath d='M0 .5H39.5V40' fill='none' stroke='%23999' stroke-width='0.5'/%3E%3C/svg%3E\")",
          }}
        />
      </div>

      <div className="relative z-10 w-full max-w-lg text-center">
        {/* 404 — bold, high-contrast gradient */}
        <div className="mb-8">
          <div className="relative inline-block">
            <h1 className="select-none bg-gradient-to-br from-primary-500 via-primary-600 to-primary-700 bg-clip-text text-[150px] font-black leading-none text-transparent drop-shadow-sm sm:text-[200px]">
              404
            </h1>
            <div className="absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2">
              <div className="flex h-20 w-20 items-center justify-center rounded-2xl bg-surface shadow-xl ring-1 ring-secondary-900/10 sm:h-24 sm:w-24">
                <Compass className="h-10 w-10 text-primary-600 sm:h-12 sm:w-12" />
              </div>
            </div>
          </div>
        </div>

        {/* Solid, well-separated card */}
        <div className="rounded-2xl border border-secondary-200 bg-surface p-8 shadow-2xl ring-1 ring-secondary-900/5 sm:p-10 dark:border-secondary-800">
          <h2 className="mb-3 text-2xl font-bold text-secondary-900 sm:text-3xl">Page not found</h2>
          <p className="mb-8 leading-relaxed text-secondary-600">
            The page you&apos;re looking for doesn&apos;t exist or has moved. Check the URL, or head
            back to a page you know.
          </p>

          <div className="flex flex-col items-center justify-center gap-3 sm:flex-row">
            <Link href="/dashboard" className="w-full sm:w-auto">
              <Button size="lg" className="w-full sm:w-auto">
                <Home className="mr-2 h-5 w-5" />
                Go to Dashboard
              </Button>
            </Link>
            <Button
              variant="outline"
              size="lg"
              className="w-full sm:w-auto"
              onClick={() => window.history.back()}
            >
              <ArrowLeft className="mr-2 h-5 w-5" />
              Go Back
            </Button>
          </div>

          <div className="mt-8 border-t border-secondary-100 pt-6 dark:border-secondary-800">
            <p className="text-sm text-secondary-500">
              Need help?{' '}
              <Link
                href="/dashboard/settings"
                className="inline-flex items-center gap-1 font-medium text-primary-600 hover:text-primary-700"
              >
                <LifeBuoy className="h-4 w-4" />
                Contact Support
              </Link>
            </p>
          </div>
        </div>

        <p className="mt-6 text-xs font-medium uppercase tracking-wide text-secondary-400">
          Error 404 · Page not found
        </p>
      </div>
    </div>
  );
}

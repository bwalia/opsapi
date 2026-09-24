'use client';

/**
 * BuildFooter — shows exactly which dashboard build is live and what it's
 * connected to. Values are baked at `next build` from NEXT_PUBLIC_BUILD_* (see
 * Dockerfile + deploy-workstation-dashboard.yml), so they reflect the deployed
 * image, not the repo's shared git tag. In local dev they're unset → "dev".
 *
 * The commit SHA (+ build time) is the unambiguous identifier of this build —
 * the version string is the release tag it was cut from. The relative time is
 * computed after mount (refreshed each minute) to avoid a hydration mismatch.
 */

import React, { useEffect, useState } from 'react';
import { formatRelativeTime } from '@/lib/utils';

const VERSION = process.env.NEXT_PUBLIC_BUILD_VERSION || 'dev';
const SHA = process.env.NEXT_PUBLIC_BUILD_SHA || '';
const BUILT_AT = process.env.NEXT_PUBLIC_BUILD_TIME || '';
const API_URL = process.env.NEXT_PUBLIC_API_URL || '';

function apiHost(): string {
  try {
    return new URL(API_URL).host;
  } catch {
    return API_URL.replace(/^https?:\/\//, '').replace(/\/.*$/, '');
  }
}

/** Derive the environment from the backend host it talks to. */
function envBadge(): { label: string; cls: string } {
  const h = apiHost().toLowerCase();
  if (!h || h.includes('localhost') || h.includes('127.0.0.1'))
    return { label: 'DEV', cls: 'bg-secondary-200 text-secondary-700' };
  if (h.startsWith('int-')) return { label: 'INT', cls: 'bg-blue-100 text-blue-700' };
  if (h.startsWith('acc-')) return { label: 'ACC', cls: 'bg-amber-100 text-amber-700' };
  if (h.startsWith('test-')) return { label: 'TEST', cls: 'bg-purple-100 text-purple-700' };
  return { label: 'PROD', cls: 'bg-green-100 text-green-700' };
}

export function BuildFooter() {
  const [ago, setAgo] = useState('');

  useEffect(() => {
    if (!BUILT_AT) return;
    const tick = () => setAgo(formatRelativeTime(BUILT_AT));
    tick();
    const id = setInterval(tick, 60_000);
    return () => clearInterval(id);
  }, []);

  const env = envBadge();
  const host = apiHost();
  const commitUrl = SHA ? `https://github.com/bwalia/opsapi/commit/${SHA}` : '';
  const builtExact = BUILT_AT ? new Date(BUILT_AT).toLocaleString() : '';

  return (
    <footer className="border-t border-secondary-200 bg-surface px-4 py-3 text-xs text-secondary-500 sm:px-6">
      <div className="flex flex-wrap items-center gap-x-4 gap-y-1.5">
        <span className="inline-flex items-center gap-1.5 font-semibold text-secondary-700">
          <span className="h-2 w-2 rounded-full bg-primary-500" aria-hidden />
          OpsAPI Dashboard
        </span>

        <span className={`inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-bold tracking-wide ${env.cls}`}>
          {env.label}
        </span>

        <span className="text-secondary-300" aria-hidden>|</span>

        <span title="Dashboard build tag (release + dashboard build number)">
          <span className="text-secondary-400">build</span>{' '}
          <span className="font-mono text-secondary-700">{VERSION}</span>
        </span>

        {SHA && (
          <span title="The git commit this dashboard build was made from">
            <span className="text-secondary-400">commit</span>{' '}
            <a
              href={commitUrl}
              target="_blank"
              rel="noopener noreferrer"
              className="font-mono text-primary-600 hover:underline"
            >
              {SHA}
            </a>
          </span>
        )}

        {BUILT_AT && (
          <span title={builtExact}>
            <span className="text-secondary-400">built</span> {ago || 'recently'}
          </span>
        )}

        {host && (
          <>
            <span className="hidden text-secondary-300 sm:inline" aria-hidden>|</span>
            <span className="hidden sm:inline" title="Backend API this dashboard is connected to">
              <span className="text-secondary-400">API</span>{' '}
              <span className="font-mono text-secondary-600">{host}</span>
            </span>
          </>
        )}

        <span className="ml-auto hidden text-secondary-400 md:inline">
          © {new Date().getFullYear()} Workstation
        </span>
      </div>
    </footer>
  );
}

export default BuildFooter;

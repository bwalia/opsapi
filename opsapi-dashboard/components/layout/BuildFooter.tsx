'use client';

/**
 * BuildFooter — shows which build is live: the git version/tag, short sha, and
 * how long ago it was built/deployed. Values are baked at `next build` from
 * NEXT_PUBLIC_BUILD_* (see Dockerfile + deploy-workstation-dashboard.yml), so
 * they reflect the deployed image. In local dev they're unset → shows "dev".
 *
 * The relative time is computed after mount (and refreshed each minute) so the
 * server and first client render match — no hydration mismatch.
 */

import React, { useEffect, useState } from 'react';
import { formatRelativeTime } from '@/lib/utils';

const VERSION = process.env.NEXT_PUBLIC_BUILD_VERSION || 'dev';
const SHA = process.env.NEXT_PUBLIC_BUILD_SHA || '';
const BUILT_AT = process.env.NEXT_PUBLIC_BUILD_TIME || '';

export function BuildFooter() {
  const [ago, setAgo] = useState('');

  useEffect(() => {
    if (!BUILT_AT) return;
    const tick = () => setAgo(formatRelativeTime(BUILT_AT));
    tick();
    const id = setInterval(tick, 60_000);
    return () => clearInterval(id);
  }, []);

  return (
    <footer className="px-4 sm:px-6 py-3 border-t border-secondary-200 text-xs text-secondary-400">
      <div className="flex flex-wrap items-center gap-x-2 gap-y-0.5">
        <span className="font-medium text-secondary-500">OpsAPI</span>
        <span aria-hidden>·</span>
        <span title="Build version (git describe)">
          {VERSION}
          {SHA ? ` · ${SHA}` : ''}
        </span>
        {BUILT_AT && (
          <>
            <span aria-hidden>·</span>
            <span title={BUILT_AT}>deployed {ago || 'recently'}</span>
          </>
        )}
      </div>
    </footer>
  );
}

export default BuildFooter;

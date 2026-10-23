'use client';

import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import { FlaskConical } from 'lucide-react';
import { marketingService } from '@/services/opsapi-marketing.service';

const SETTINGS_HREF = '/dashboard/namespace/plugins#plugin-opsapi_marketing';

/** Is test mode (dry run) on for this workspace? false when unknown (no settings access). */
export function useTestMode(): boolean {
  const [on, setOn] = useState(false);
  useEffect(() => {
    let cancelled = false;
    marketingService
      .sendingInfo()
      .then((res) => {
        if (!cancelled) setOn(!!(res.data?.data ?? res.data)?.dry_run);
      })
      .catch(() => {
        /* no settings access: no banner */
      });
    return () => {
      cancelled = true;
    };
  }, []);
  return on;
}

/** Says plainly that nothing is really being sent, so "sent" numbers aren't mistaken for real ones. */
export function TestModeBanner({ on }: { on: boolean }) {
  if (!on) return null;
  return (
    <div
      role="status"
      className="flex items-start gap-3 rounded-xl border border-warning-500/40 bg-warning-500/10 p-4 text-base text-secondary-800 dark:text-secondary-100"
    >
      <FlaskConical className="mt-0.5 h-5 w-5 shrink-0 text-warning-600" aria-hidden="true" />
      <p>
        <strong>Test mode is on.</strong> Emails only pretend to be sent — nobody receives anything, and “sent” numbers
        here are not real.{' '}
        <Link href={SETTINGS_HREF} className="font-medium underline underline-offset-2">
          Switch test mode off
        </Link>{' '}
        when you’re ready to send for real.
      </p>
    </div>
  );
}

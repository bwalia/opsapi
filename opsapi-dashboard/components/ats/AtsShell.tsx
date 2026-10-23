'use client';

/**
 * Hiring section chrome: the page header, the section tabs and the activation
 * banner. Every Hiring page renders inside it.
 */

import React from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { Briefcase } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { ProtectedPage } from '@/components/permissions';
import type { Activation, Stage } from '@/services/ats.service';
import { STAGE_LABEL } from '@/services/ats.service';

const TABS = [
  { href: '/dashboard/ats', label: 'Overview', exact: true },
  { href: '/dashboard/ats/jobs', label: 'Jobs' },
  { href: '/dashboard/ats/candidates', label: 'Candidates' },
  { href: '/dashboard/ats/kits', label: 'Interview kits' },
  { href: '/dashboard/ats/interviews', label: 'Interviews' },
  { href: '/dashboard/ats/reports', label: 'Fairness' },
  { href: '/dashboard/ats/settings', label: 'Settings' },
];

export function AtsShell({
  title,
  description,
  actions,
  module = 'ats_jobs',
  children,
}: {
  title: string;
  description?: string;
  actions?: React.ReactNode;
  module?: string;
  children: React.ReactNode;
}) {
  const path = usePathname() || '';
  return (
    <ProtectedPage module={module} title={title}>
      <div className="space-y-6">
        <PageHeader title={title} description={description} actions={actions} icon={<Briefcase className="h-5 w-5" />} />
        <nav aria-label="Hiring" className="-mx-1 flex gap-1 overflow-x-auto border-b border-secondary-200 pb-px">
          {TABS.map((t) => {
            const active = t.exact ? path === t.href : path.startsWith(t.href);
            return (
              <Link
                key={t.href}
                href={t.href}
                aria-current={active ? 'page' : undefined}
                className={`whitespace-nowrap rounded-t-md px-3 py-2 text-sm font-medium ${
                  active ? 'border-b-2 border-primary-500 text-primary-600' : 'text-secondary-500 hover:text-secondary-800'
                }`}
              >
                {t.label}
              </Link>
            );
          })}
        </nav>
        {children}
      </div>
    </ProtectedPage>
  );
}

export function ActivationBanner({ activation }: { activation?: Activation }) {
  if (!activation || activation.active) return null;
  return (
    <div role="status" className="rounded-xl border border-amber-300 bg-amber-50 p-4 text-sm text-amber-900">
      <strong>Snazzy Interview isn&apos;t active for this workspace.</strong> You can read, review and export what&apos;s here,
      but you can&apos;t invite candidates until it&apos;s activated.{' '}
      <Link href="/dashboard/ats/settings" className="font-semibold underline">Activate it in Settings</Link>.
    </div>
  );
}

const STAGE_COLOURS: Record<Stage, string> = {
  applied: 'bg-secondary-100 text-secondary-700',
  screening: 'bg-sky-100 text-sky-800',
  interview: 'bg-primary-100 text-primary-800',
  review: 'bg-amber-100 text-amber-900',
  offer: 'bg-emerald-100 text-emerald-800',
  hired: 'bg-emerald-200 text-emerald-900',
  rejected: 'bg-red-100 text-red-800',
  withdrawn: 'bg-secondary-200 text-secondary-700',
};

export function StageBadge({ stage }: { stage: Stage }) {
  return (
    <span className={`inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ${STAGE_COLOURS[stage]}`}>
      {STAGE_LABEL[stage]}
    </span>
  );
}

/** A small badge for interviews taken offline in Snazzy Pro on the candidate's own Mac. */
export function OfflineBadge({ delivery }: { delivery?: string }) {
  if (delivery !== 'offline') return null;
  return (
    <span className="inline-flex items-center rounded-full bg-indigo-50 px-2 py-0.5 text-xs font-medium text-indigo-700"
      title="Taken offline in Snazzy Pro on the candidate's own Mac">
      Offline (candidate&apos;s Mac)
    </span>
  );
}

export function Empty({ children }: { children: React.ReactNode }) {
  return <div className="rounded-xl border border-dashed border-secondary-300 p-8 text-center text-secondary-500">{children}</div>;
}

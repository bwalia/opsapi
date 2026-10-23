'use client';

import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import { Check, CircleHelp } from 'lucide-react';
import { buttonClass } from '@/components/ui';
import { marketingService } from '@/services/opsapi-marketing.service';

export const GUIDE_HREF = '/dashboard/opsapi-marketing/guide';
const PLUGIN_SETTINGS = '/dashboard/namespace/plugins#plugin-opsapi_marketing';

/** "How does this work?" — opens the guide at the right section. */
export function HelpLink({ topic, children }: { topic: string; children?: React.ReactNode }) {
  return (
    <Link
      href={`${GUIDE_HREF}#${topic}`}
      className="inline-flex items-center gap-1.5 rounded-lg px-2 py-1.5 text-sm font-medium text-primary-700 hover:bg-primary-50 hover:underline dark:text-primary-300 dark:hover:bg-primary-900/30"
    >
      <CircleHelp className="h-4 w-4" aria-hidden="true" />
      {children || 'How does this work?'}
    </Link>
  );
}

/** An example contacts file (made in the browser) so people can see what to upload. */
export function downloadExampleCsv() {
  const csv =
    'Email,First name,Last name,Company\r\n' +
    'jane@example-plumbing.co.uk,Jane,Smith,Example Plumbing Ltd\r\n' +
    'info@example-bakery.co.uk,,,Example Bakery\r\n';
  const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv' }));
  const a = document.createElement('a');
  a.href = url;
  a.download = 'example-contacts.csv';
  a.click();
  URL.revokeObjectURL(url);
}

type Progress = {
  via?: string;
  addressSet?: boolean;
  dryRun?: boolean;
  lists: number;
  people: number;
  templates: number;
  campaigns: number;
  sent: number;
};

type Step = {
  title: string;
  why: string;
  href: string;
  action: string;
  guide: string;
  optional?: boolean;
  done: (p: Progress) => boolean;
};

const STEPS: Step[] = [
  {
    title: 'Connect your email account',
    why: 'So your emails come from your own address, like hello@yourbusiness.co.uk.',
    href: '/dashboard/namespace/email',
    action: 'Connect email',
    guide: 'connect-email',
    done: (p) => p.via === 'workspace',
  },
  {
    title: 'Add your business name and address',
    why: 'The law says every promotional email must show who sent it.',
    href: PLUGIN_SETTINGS,
    action: 'Add address',
    guide: 'business-address',
    done: (p) => !!p.addressSet,
  },
  {
    title: 'Make a list',
    why: 'A list is the group of people who will get your email.',
    href: '/dashboard/opsapi-marketing/lists',
    action: 'Make a list',
    guide: 'make-list',
    done: (p) => p.lists > 0,
  },
  {
    title: 'Add people to your list',
    why: 'Type their email addresses, upload a spreadsheet, or tick people in your contacts.',
    href: '/dashboard/opsapi-marketing/lists',
    action: 'Add people',
    guide: 'add-people',
    done: (p) => p.people > 0,
  },
  {
    title: 'Design an email template',
    why: 'A ready-made design you can reuse for every email. You can skip this.',
    href: '/dashboard/opsapi-marketing/studio',
    action: 'Open the Studio',
    guide: 'templates',
    optional: true,
    done: (p) => p.templates > 0,
  },
  {
    title: 'Write your email',
    why: 'Give it a subject and the words you want to say.',
    href: '/dashboard/opsapi-marketing/campaigns',
    action: 'Write an email',
    guide: 'write-email',
    done: (p) => p.campaigns > 0,
  },
  {
    title: 'Switch off test mode',
    why: 'While test mode is on, nothing is really sent. Switch it off when you are ready.',
    href: PLUGIN_SETTINGS,
    action: 'Open settings',
    guide: 'test-mode',
    done: (p) => p.dryRun === false,
  },
  {
    title: 'Send yourself a test, then send to your list',
    why: 'Check it in your own inbox first, then press Send now (or pick a time).',
    href: '/dashboard/opsapi-marketing/campaigns',
    action: 'Go to my emails',
    guide: 'send',
    done: (p) => p.sent > 0,
  },
];

const arr = (res: { data?: { data?: unknown } & Record<string, unknown> } | null): unknown[] => {
  const d = res?.data?.data ?? res?.data;
  if (Array.isArray(d)) return d;
  const items = (d as { items?: unknown } | undefined)?.items;
  return Array.isArray(items) ? items : [];
};

function useProgress(): Progress | null {
  const [p, setP] = useState<Progress | null>(null);
  useEffect(() => {
    let cancelled = false;
    void Promise.all([
      marketingService.sendingInfo().catch(() => null),
      marketingService.listLists({ per_page: 100 }).catch(() => null),
      marketingService.listCounts().catch(() => null),
      marketingService.listTemplates({ per_page: 1 }).catch(() => null),
      marketingService.listCampaigns({ per_page: 100 }).catch(() => null),
    ]).then(([sending, lists, counts, templates, campaigns]) => {
      if (cancelled) return;
      const s = (sending?.data?.data ?? sending?.data) as
        { via?: string; sender_address_set?: boolean; dry_run?: boolean } | undefined;
      const c = counts?.data?.data ?? counts?.data;
      const people =
        c && typeof c === 'object' && !Array.isArray(c)
          ? Object.values(c as Record<string, number>).reduce((a, n) => a + (Number(n) || 0), 0)
          : 0;
      const camps = arr(campaigns) as { status?: string }[];
      setP({
        via: s?.via,
        addressSet: s?.sender_address_set,
        dryRun: s?.dry_run,
        lists: arr(lists).length,
        people,
        templates: arr(templates).length,
        campaigns: camps.length,
        sent: camps.filter((x) => x.status === 'sending' || x.status === 'completed').length,
      });
    });
    return () => {
      cancelled = true;
    };
  }, []);
  return p;
}

/**
 * The getting-started checklist, ticked from what the workspace has really done.
 * compact: a one-card "next step" for the Overview page (hidden once everything is done).
 */
export function GettingStarted({ compact = false }: { compact?: boolean }) {
  const p = useProgress();
  if (!p) return compact ? null : <div className="h-64 animate-pulse rounded-xl border border-secondary-200" />;

  const required = STEPS.filter((s) => !s.optional);
  const doneCount = required.filter((s) => s.done(p)).length;
  const next = STEPS.find((s) => !s.optional && !s.done(p));

  if (compact) {
    if (!next) return null;
    return (
      <section className="rounded-xl border-2 border-primary-500 bg-primary-50 p-5 dark:bg-primary-900/30">
        <p className="text-sm font-medium text-primary-800 dark:text-primary-200">
          Getting started: {doneCount} of {required.length} steps done
        </p>
        <div
          className="mt-2 h-2 overflow-hidden rounded-full bg-primary-100 dark:bg-primary-900"
          role="progressbar"
          aria-valuenow={doneCount}
          aria-valuemin={0}
          aria-valuemax={required.length}
          aria-label="Getting started progress"
        >
          <div
            className="h-full rounded-full bg-primary-600"
            style={{ width: `${(doneCount / required.length) * 100}%` }}
          />
        </div>
        <h2 className="mt-3 text-lg font-semibold">Next: {next.title}</h2>
        <p className="text-base text-secondary-700 dark:text-secondary-300">{next.why}</p>
        <div className="mt-3 flex flex-wrap items-center gap-2">
          <Link href={next.href} className={buttonClass('primary', 'lg')}>
            {next.action}
          </Link>
          <Link href={GUIDE_HREF} className={buttonClass('outline', 'lg')}>
            See all the steps
          </Link>
        </div>
      </section>
    );
  }

  return (
    <section
      aria-labelledby="checklist-title"
      className="rounded-2xl border border-secondary-200 bg-surface p-5 shadow-sm sm:p-6"
    >
      <h2 id="checklist-title" className="text-xl font-semibold">
        Your checklist
      </h2>
      <p className="text-base text-secondary-600">
        {next
          ? `${doneCount} of ${required.length} steps done. Steps tick themselves when you finish them.`
          : 'All done — you’re ready to send emails whenever you like.'}
      </p>
      <ol className="@container mt-4 space-y-3">
        {STEPS.map((s, i) => {
          const done = s.done(p);
          const isNext = s === next;
          return (
            <li
              key={s.title}
              className={`grid grid-cols-[auto_minmax(0,1fr)] items-start gap-x-3 gap-y-2 rounded-xl @xl:grid-cols-[auto_minmax(0,1fr)_auto] border p-4 ${
                isNext ? 'border-2 border-primary-500 bg-primary-50 dark:bg-primary-900/30' : 'border-secondary-200'
              }`}
            >
              <span
                className={`flex h-9 w-9 shrink-0 items-center justify-center rounded-full text-base font-semibold ${
                  done ? 'bg-success-600 text-white' : isNext ? 'bg-primary-600 text-white' : 'bg-secondary-200'
                }`}
                aria-hidden="true"
              >
                {done ? <Check className="h-5 w-5" /> : i + 1}
              </span>
              <div className="min-w-0">
                <p className="text-base font-semibold">
                  {s.title}
                  {s.optional && <span className="font-normal text-secondary-500"> (optional)</span>}
                  <span className="sr-only">{done ? ' — done' : ' — not done yet'}</span>
                </p>
                <p className="text-base text-secondary-600">{s.why}</p>
              </div>
              <div className="col-start-2 -ml-3 flex flex-wrap items-center gap-2 @xl:col-start-3 @xl:row-start-1 @xl:ml-0">
                <a href={`#${s.guide}`} className={buttonClass('ghost', 'md')}>
                  Show me how
                </a>
                {!done && (
                  <Link href={s.href} className={buttonClass(isNext ? 'primary' : 'outline', 'md')}>
                    {s.action}
                  </Link>
                )}
              </div>
            </li>
          );
        })}
      </ol>
    </section>
  );
}

'use client';

import React from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { ArrowRight, Check, ChevronRight, PartyPopper } from 'lucide-react';
import { buttonClass } from '@/components/ui';
import { AskAI, STEPS, useProgress } from './GettingStarted';

const HOME = '/dashboard/opsapi-marketing';

/**
 * The bar at the top of every Marketing page: every step from "Connect email" to
 * "Test & send" joined by arrows (ticked when done, the next one highlighted),
 * and one big "Next" button — plus "Ask AI to do it" — pointing at what to do now.
 */
export default function MarketingJourney() {
  const p = useProgress();
  const pathname = usePathname() || '';
  if (!p) return <div className="mx-6 mt-6 h-[104px] animate-pulse rounded-2xl border border-secondary-200" />;

  const required = STEPS.filter((s) => !s.optional);
  const doneCount = required.filter((s) => s.done(p)).length;
  const next = STEPS.find((s) => !s.optional && !s.done(p));
  const nextIndex = next ? STEPS.indexOf(next) : -1;
  const here = (href: string) => href.startsWith(HOME) && pathname.startsWith(href.split('#')[0]);

  return (
    <section
      aria-label="Your marketing steps"
      className="mx-6 mt-6 rounded-2xl border border-secondary-200 bg-surface p-4 shadow-sm"
    >
      <nav aria-label="Steps">
        <ol className="flex items-center gap-1 overflow-x-auto pb-1">
          {STEPS.map((s, i) => {
            const done = s.done(p);
            const isNext = i === nextIndex;
            const current = here(s.href);
            return (
              <li key={s.title} className="flex shrink-0 items-center gap-1">
                <Link
                  href={s.href}
                  aria-current={current ? 'page' : undefined}
                  title={`${s.title}${done ? ' (done)' : ''}`}
                  className={`flex items-center gap-2 rounded-full px-3 py-1.5 text-sm transition-colors ${
                    isNext
                      ? 'bg-primary-600 font-semibold text-white shadow-sm hover:bg-primary-700'
                      : done
                        ? 'text-secondary-600 hover:bg-secondary-100 dark:text-secondary-300'
                        : 'text-secondary-500 hover:bg-secondary-100'
                  } ${current && !isNext ? 'ring-2 ring-primary-400' : ''}`}
                >
                  <span
                    className={`flex h-5 w-5 items-center justify-center rounded-full text-[11px] font-semibold ${
                      done
                        ? 'bg-success-600 text-white'
                        : isNext
                          ? 'bg-white text-primary-700'
                          : 'border border-secondary-300'
                    }`}
                    aria-hidden="true"
                  >
                    {done ? <Check className="h-3 w-3" /> : i + 1}
                  </span>
                  {s.short}
                  <span className="sr-only">{done ? ' — done' : isNext ? ' — do this next' : ''}</span>
                </Link>
                {i < STEPS.length - 1 && (
                  <ChevronRight className="h-4 w-4 shrink-0 text-secondary-400" aria-hidden="true" />
                )}
              </li>
            );
          })}
        </ol>
      </nav>

      <div className="mt-3 flex flex-col gap-3 border-t border-secondary-200 pt-3 sm:flex-row sm:items-center">
        {next ? (
          <>
            <div className="min-w-0 flex-1">
              <p className="text-xs font-medium uppercase tracking-wide text-primary-700 dark:text-primary-300">
                Step {nextIndex + 1} of {STEPS.length} · {doneCount} of {required.length} done
              </p>
              <p className="text-base font-semibold">Next: {next.title}</p>
              <p className="text-sm text-secondary-600">{next.why}</p>
            </div>
            <div className="flex flex-wrap items-center gap-2">
              <AskAI text={next.ai} />
              <Link href={next.href} className={buttonClass('primary', 'md')}>
                {next.action}
                <ArrowRight className="h-4 w-4" aria-hidden="true" />
              </Link>
            </div>
          </>
        ) : (
          <>
            <div className="flex min-w-0 flex-1 items-center gap-2">
              <PartyPopper className="h-5 w-5 shrink-0 text-primary-600" aria-hidden="true" />
              <p className="text-base font-semibold">All set up — write another email or see how they did.</p>
            </div>
            <div className="flex flex-wrap items-center gap-2">
              <AskAI
                text="Write a new email for me: ask me what it is about and who should get it."
                label="Write one with AI"
              />
              <Link href={`${HOME}/overview`} className={buttonClass('outline', 'md')}>
                See results
              </Link>
              <Link href={`${HOME}/campaigns`} className={buttonClass('primary', 'md')}>
                Write an email
                <ArrowRight className="h-4 w-4" aria-hidden="true" />
              </Link>
            </div>
          </>
        )}
      </div>
    </section>
  );
}

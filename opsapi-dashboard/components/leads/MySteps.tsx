'use client';

/**
 * "Your next steps": what this person should do now — late steps first,
 * then today's, then today's meetings — and how many leads nobody owns yet.
 */
import React from 'react';
import Link from 'next/link';
import { AlertTriangle, CalendarClock, CheckCircle2, Inbox, Phone, Video } from 'lucide-react';
import { cn } from '@/lib/utils';
import type { MySteps as Steps, StepItem } from '@/services/leads.service';
import { dateTime, dueText, fullName, ScoreBadge, STEP_LABEL } from './ui';

function StepRow({ s }: { s: StepItem }) {
  const due = dueText(s.next_action_at);
  return (
    <li>
      <Link href={`/dashboard/leads/${s.uuid}`}
        className="flex items-center gap-3 rounded-lg px-2 py-2 hover:bg-secondary-50 focus:outline-none focus-visible:ring-2 focus-visible:ring-primary-300">
        <span className={cn('flex h-8 w-8 shrink-0 items-center justify-center rounded-full',
          due.overdue ? 'bg-error-50 text-error-600' : 'bg-primary-500/10 text-primary-600')}>
          {s.next_action_type === 'call' ? <Phone className="h-4 w-4" aria-hidden="true" /> : <CalendarClock className="h-4 w-4" aria-hidden="true" />}
        </span>
        <span className="min-w-0 flex-1">
          <span className="block truncate text-sm font-medium text-secondary-900">
            {STEP_LABEL[s.next_action_type ?? ''] ?? 'Follow up'} {fullName(s)}
          </span>
          <span className={cn('block text-xs', due.overdue ? 'font-medium text-error-600' : 'text-secondary-500')}>
            {due.text}{s.company_name ? ` · ${s.company_name}` : ''}
          </span>
        </span>
        <ScoreBadge score={s.ai_score} />
      </Link>
    </li>
  );
}

export function MyStepsPanel({ steps, onShowUnassigned }: { steps: Steps; onShowUnassigned: () => void }) {
  const nothing = steps.overdue.length === 0 && steps.today.length === 0 && steps.meetings.length === 0;
  return (
    <section className="rounded-xl border border-secondary-200 bg-white p-4" aria-labelledby="my-steps-title">
      <div className="flex items-center justify-between gap-2">
        <h2 id="my-steps-title" className="text-sm font-semibold text-secondary-900">Your next steps</h2>
        {steps.overdue.length > 0 && (
          <span className="inline-flex items-center gap-1 rounded-full bg-error-50 px-2 py-0.5 text-xs font-medium text-error-700">
            <AlertTriangle className="h-3 w-3" aria-hidden="true" />{steps.overdue.length} late
          </span>
        )}
      </div>
      {nothing ? (
        <p className="mt-3 flex items-center gap-2 text-sm text-secondary-500">
          <CheckCircle2 className="h-4 w-4 text-emerald-500" aria-hidden="true" />Nothing due today. Nice work.
        </p>
      ) : (
        <ul className="mt-2 -mx-2 space-y-0.5">
          {steps.overdue.slice(0, 6).map((s) => <StepRow key={`o-${s.uuid}`} s={s} />)}
          {steps.today.slice(0, 6).map((s) => <StepRow key={`t-${s.uuid}`} s={s} />)}
          {steps.meetings.map((m) => (
            <li key={m.uuid}>
              <Link href={`/dashboard/leads/${m.lead_uuid}`} className="flex items-center gap-3 rounded-lg px-2 py-2 hover:bg-secondary-50">
                <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-amber-50 text-amber-700">
                  <Video className="h-4 w-4" aria-hidden="true" />
                </span>
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-sm font-medium text-secondary-900">{m.subject}</span>
                  <span className="block text-xs text-secondary-500">{dateTime(m.starts_at)}</span>
                </span>
              </Link>
            </li>
          ))}
        </ul>
      )}
      {steps.unassigned > 0 && (
        <button type="button" onClick={onShowUnassigned}
          className="mt-3 flex w-full items-center gap-2 rounded-lg border border-dashed border-secondary-300 px-3 py-2 text-left text-sm text-secondary-700 hover:border-primary-300 hover:bg-primary-50/40">
          <Inbox className="h-4 w-4 text-secondary-500" aria-hidden="true" />
          {steps.unassigned} {steps.unassigned === 1 ? 'lead has' : 'leads have'} no owner yet — {steps.is_manager ? 'give them out' : 'take one'}
        </button>
      )}
    </section>
  );
}

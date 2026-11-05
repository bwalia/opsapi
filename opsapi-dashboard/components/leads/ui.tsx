'use client';

/**
 * Small shared pieces for the lead pipeline screens: stage colours, score and
 * money formatting, "due in 20 min" text, initials, field errors.
 */
import React from 'react';
import { cn } from '@/lib/utils';
import type { LeadStage } from '@/services/leads.service';

export const STAGE_STYLE: Record<LeadStage, { dot: string; chip: string; bar: string }> = {
  new: { dot: 'bg-sky-500', chip: 'bg-sky-50 text-sky-700 ring-sky-200', bar: 'bg-sky-500' },
  contacting: { dot: 'bg-indigo-500', chip: 'bg-indigo-50 text-indigo-700 ring-indigo-200', bar: 'bg-indigo-500' },
  qualified: { dot: 'bg-violet-500', chip: 'bg-violet-50 text-violet-700 ring-violet-200', bar: 'bg-violet-500' },
  meeting: { dot: 'bg-amber-500', chip: 'bg-amber-50 text-amber-800 ring-amber-200', bar: 'bg-amber-500' },
  converted: { dot: 'bg-emerald-500', chip: 'bg-emerald-50 text-emerald-700 ring-emerald-200', bar: 'bg-emerald-500' },
  nurture: { dot: 'bg-teal-500', chip: 'bg-teal-50 text-teal-700 ring-teal-200', bar: 'bg-teal-500' },
  lost: { dot: 'bg-secondary-400', chip: 'bg-secondary-100 text-secondary-600 ring-secondary-200', bar: 'bg-secondary-400' },
};

export function StageBadge({ stage, label, className }: { stage: LeadStage; label?: string; className?: string }) {
  const s = STAGE_STYLE[stage] ?? STAGE_STYLE.new;
  return (
    <span className={cn('inline-flex items-center gap-1.5 rounded-full px-2.5 py-0.5 text-xs font-medium ring-1 ring-inset', s.chip, className)}>
      <span className={cn('h-1.5 w-1.5 rounded-full', s.dot)} aria-hidden="true" />
      {label ?? stage}
    </span>
  );
}

/** AI fit score: green 70+, amber 40-69, grey below. */
export function ScoreBadge({ score, className }: { score: number | null | undefined; className?: string }) {
  if (score === null || score === undefined) return null;
  const tone = score >= 70 ? 'bg-emerald-600 text-white' : score >= 40 ? 'bg-amber-100 text-amber-800' : 'bg-secondary-100 text-secondary-600';
  return (
    <span title={`AI fit score: ${score} out of 100`} className={cn('inline-flex h-6 min-w-[2.25rem] items-center justify-center rounded-md px-1.5 text-xs font-bold tabular-nums', tone, className)}>
      {score}
    </span>
  );
}

export function money(value: number | string | null | undefined, currency = 'GBP', compact = false): string {
  const n = typeof value === 'string' ? Number(value) : value;
  if (n === null || n === undefined || Number.isNaN(n)) return '—';
  try {
    return new Intl.NumberFormat(undefined, {
      style: 'currency', currency: currency || 'GBP', maximumFractionDigits: compact || n >= 1000 ? 0 : 2,
      notation: compact && Math.abs(n) >= 100000 ? 'compact' : 'standard',
    }).format(n);
  } catch {
    return `${n.toLocaleString()} ${currency}`;
  }
}

export function fullName(l: { first_name?: string | null; last_name?: string | null; email?: string | null; company_name?: string | null }): string {
  const n = `${l.first_name ?? ''} ${l.last_name ?? ''}`.trim();
  return n || l.company_name || l.email || 'Unnamed lead';
}

export function initials(name: string | null | undefined): string {
  if (!name) return '?';
  const parts = name.trim().split(/\s+/);
  return ((parts[0]?.[0] ?? '') + (parts.length > 1 ? parts[parts.length - 1][0] : '')).toUpperCase() || '?';
}

export function Avatar({ name, className }: { name: string | null | undefined; className?: string }) {
  return (
    <span title={name ?? 'Unassigned'} className={cn('inline-flex h-7 w-7 shrink-0 items-center justify-center rounded-full text-[11px] font-semibold',
      name ? 'bg-primary-500/10 text-primary-700' : 'border border-dashed border-secondary-300 text-secondary-400', className)}>
      {name ? initials(name) : '?'}
    </span>
  );
}

/** "in 25 min", "3 h overdue", "tomorrow 09:30". */
export function dueText(iso: string | null | undefined): { text: string; overdue: boolean; soon: boolean } {
  if (!iso) return { text: '', overdue: false, soon: false };
  const t = new Date(iso).getTime();
  if (Number.isNaN(t)) return { text: '', overdue: false, soon: false };
  const diff = Math.round((t - Date.now()) / 60000);
  const abs = Math.abs(diff);
  const span = abs < 60 ? `${abs} min` : abs < 48 * 60 ? `${Math.round(abs / 60)} h` : `${Math.round(abs / 1440)} days`;
  if (diff < 0) return { text: `${span} overdue`, overdue: true, soon: false };
  if (diff <= 60) return { text: `in ${span}`, overdue: false, soon: true };
  return { text: dateTime(iso), overdue: false, soon: false };
}

export function dateTime(iso: string | null | undefined): string {
  if (!iso) return '—';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '—';
  return d.toLocaleString(undefined, { weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
}

export function dateOnly(iso: string | null | undefined): string {
  if (!iso) return '—';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '—';
  return d.toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
}

export function minutesText(m: number | null | undefined): string {
  if (m === null || m === undefined) return '—';
  if (m < 60) return `${m} min`;
  if (m < 48 * 60) return `${Math.round((m / 60) * 10) / 10} h`;
  return `${Math.round(m / 1440)} days`;
}

/** A local datetime-local value (YYYY-MM-DDTHH:MM) -> ISO string in UTC. */
export function localToIso(v: string): string | undefined {
  if (!v) return undefined;
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? undefined : d.toISOString();
}

/** An ISO string -> the value a datetime-local input shows (local time). */
export function isoToLocal(iso: string | null | undefined): string {
  if (!iso) return '';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export function inHours(h: number): string {
  return isoToLocal(new Date(Date.now() + h * 3600 * 1000).toISOString());
}

export function FieldError({ message }: { message?: string }) {
  if (!message) return null;
  return <p className="mt-1 text-xs text-error-600">{message}</p>;
}

export const STEP_LABEL: Record<string, string> = {
  call: 'Call', email: 'Email', follow_up: 'Follow up', meeting: 'Meeting', task: 'Task',
};

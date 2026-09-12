'use client';

/**
 * Field service shared building blocks: sub-navigation, status/priority
 * colour maps + labels, small presentational helpers and a reusable prompt
 * dialog. Used by every page under /dashboard/field-service.
 */

import React, { useState } from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { ChevronDown } from 'lucide-react';
import { Modal, Button, Input, Textarea } from '@/components/ui';
import { cn, extractApiError } from '@/lib/utils';
import type { FsJob, FsVisit, FsSite, JobPriority, JobStatus, PhaseStatus, VisitStatus } from '@/services/field-service.service';

// ============================================================
// Sub-navigation
// ============================================================

const NAV = [
  { href: '/dashboard/field-service', label: 'Jobs', match: (p: string) => p === '/dashboard/field-service' || p.startsWith('/dashboard/field-service/jobs') },
  { href: '/dashboard/field-service/visits', label: 'Site Visits', match: (p: string) => p.startsWith('/dashboard/field-service/visits') },
  { href: '/dashboard/field-service/sites', label: 'Sites', match: (p: string) => p.startsWith('/dashboard/field-service/sites') },
  { href: '/dashboard/field-service/job-types', label: 'Job Types', match: (p: string) => p.startsWith('/dashboard/field-service/job-types') },
];

export function FieldServiceNav() {
  const pathname = usePathname() || '';
  return (
    <nav className="flex gap-1 overflow-x-auto border-b border-secondary-200" aria-label="Field service">
      {NAV.map((item) => {
        const active = item.match(pathname);
        return (
          <Link
            key={item.href}
            href={item.href}
            className={cn(
              'whitespace-nowrap px-4 py-2.5 text-sm font-medium border-b-2 -mb-px transition-colors',
              active
                ? 'border-primary-500 text-primary-600'
                : 'border-transparent text-secondary-500 hover:text-secondary-800 hover:border-secondary-300'
            )}
            aria-current={active ? 'page' : undefined}
          >
            {item.label}
          </Link>
        );
      })}
    </nav>
  );
}

// ============================================================
// Status maps
// ============================================================

export const JOB_STATUS_LABELS: Record<JobStatus, string> = {
  draft: 'Draft',
  scheduled: 'Scheduled',
  in_progress: 'In progress',
  on_hold: 'On hold',
  completed: 'Completed',
  cancelled: 'Cancelled',
};

export const JOB_STATUS_COLORS: Record<JobStatus, string> = {
  draft: 'bg-secondary-100 text-secondary-700',
  scheduled: 'bg-blue-50 text-blue-700',
  in_progress: 'bg-amber-50 text-amber-700',
  on_hold: 'bg-orange-50 text-orange-700',
  completed: 'bg-green-50 text-green-700',
  cancelled: 'bg-red-50 text-red-700',
};

export const JOB_PRIORITY_LABELS: Record<JobPriority, string> = {
  low: 'Low',
  normal: 'Normal',
  high: 'High',
  urgent: 'Urgent',
};

export const JOB_PRIORITY_COLORS: Record<JobPriority, string> = {
  low: 'bg-secondary-100 text-secondary-600',
  normal: 'bg-blue-50 text-blue-700',
  high: 'bg-amber-50 text-amber-700',
  urgent: 'bg-red-50 text-red-700',
};

export const PHASE_STATUS_LABELS: Record<PhaseStatus, string> = {
  pending: 'Pending',
  in_progress: 'In progress',
  blocked: 'Blocked',
  completed: 'Completed',
  skipped: 'Skipped',
};

export const PHASE_STATUS_COLORS: Record<PhaseStatus, string> = {
  pending: 'bg-secondary-100 text-secondary-700',
  in_progress: 'bg-amber-50 text-amber-700',
  blocked: 'bg-red-50 text-red-700',
  completed: 'bg-green-50 text-green-700',
  skipped: 'bg-secondary-100 text-secondary-500',
};

export const VISIT_STATUS_LABELS: Record<VisitStatus, string> = {
  scheduled: 'Scheduled',
  en_route: 'En route',
  on_site: 'On site',
  completed: 'Completed',
  cancelled: 'Cancelled',
  no_access: 'No access',
};

export const VISIT_STATUS_COLORS: Record<VisitStatus, string> = {
  scheduled: 'bg-blue-50 text-blue-700',
  en_route: 'bg-violet-50 text-violet-700',
  on_site: 'bg-amber-50 text-amber-700',
  completed: 'bg-green-50 text-green-700',
  cancelled: 'bg-secondary-100 text-secondary-500',
  no_access: 'bg-red-50 text-red-700',
};

export const JOB_STATUS_OPTIONS = [
  { value: 'open', label: 'Open jobs' },
  { value: 'all', label: 'All statuses' },
  ...(Object.keys(JOB_STATUS_LABELS) as JobStatus[]).map((s) => ({ value: s, label: JOB_STATUS_LABELS[s] })),
];

export const VISIT_STATUS_OPTIONS = [
  { value: 'all', label: 'All statuses' },
  { value: 'open', label: 'Open visits' },
  ...(Object.keys(VISIT_STATUS_LABELS) as VisitStatus[]).map((s) => ({ value: s, label: VISIT_STATUS_LABELS[s] })),
];

export const PRIORITY_OPTIONS = (Object.keys(JOB_PRIORITY_LABELS) as JobPriority[]).map((p) => ({
  value: p,
  label: JOB_PRIORITY_LABELS[p],
}));

/** Label shown on the button that moves a job to a given status. */
export const JOB_TRANSITION_LABELS: Record<JobStatus, string> = {
  draft: 'Reopen as draft',
  scheduled: 'Mark scheduled',
  in_progress: 'Start work',
  on_hold: 'Put on hold',
  completed: 'Complete job',
  cancelled: 'Cancel job',
};

// ============================================================
// Presentational helpers
// ============================================================

export function Pill({ className, children }: { className?: string; children: React.ReactNode }) {
  return (
    <span className={cn('inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium whitespace-nowrap', className)}>
      {children}
    </span>
  );
}

export function JobStatusPill({ status }: { status: JobStatus }) {
  return <Pill className={JOB_STATUS_COLORS[status]}>{JOB_STATUS_LABELS[status] ?? status}</Pill>;
}

export function JobPriorityPill({ priority }: { priority: JobPriority }) {
  return <Pill className={JOB_PRIORITY_COLORS[priority]}>{JOB_PRIORITY_LABELS[priority] ?? priority}</Pill>;
}

export function PhaseStatusPill({ status }: { status: PhaseStatus }) {
  return <Pill className={PHASE_STATUS_COLORS[status]}>{PHASE_STATUS_LABELS[status] ?? status}</Pill>;
}

export function VisitStatusPill({ status }: { status: VisitStatus }) {
  return <Pill className={VISIT_STATUS_COLORS[status]}>{VISIT_STATUS_LABELS[status] ?? status}</Pill>;
}

interface StatCardProps {
  title: string;
  value: string | number;
  icon: React.ReactNode;
  color: 'primary' | 'success' | 'warning' | 'info' | 'violet' | 'error';
}

export function StatCard({ title, value, icon, color }: StatCardProps) {
  const colorClasses: Record<StatCardProps['color'], string> = {
    primary: 'bg-primary-50 text-primary-600',
    success: 'bg-green-50 text-green-600',
    warning: 'bg-amber-50 text-amber-600',
    info: 'bg-blue-50 text-blue-600',
    violet: 'bg-violet-50 text-violet-600',
    error: 'bg-red-50 text-red-600',
  };
  return (
    <div className="bg-surface rounded-xl border border-secondary-200 p-5 shadow-sm">
      <div className="flex items-center justify-between">
        <div>
          <p className="text-sm font-medium text-secondary-500">{title}</p>
          <p className="text-2xl font-bold text-secondary-900 mt-1">{value}</p>
        </div>
        <div className={`w-12 h-12 rounded-xl flex items-center justify-center ${colorClasses[color]}`}>{icon}</div>
      </div>
    </div>
  );
}

/** Native select styled like the leads page filters. */
export function FilterSelect({
  value,
  onChange,
  options,
  ariaLabel,
}: {
  value: string;
  onChange: (value: string) => void;
  options: { value: string; label: string }[];
  ariaLabel: string;
}) {
  return (
    <div className="relative">
      <select
        value={value}
        onChange={(e) => onChange(e.target.value)}
        aria-label={ariaLabel}
        className="appearance-none px-4 py-2.5 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-surface cursor-pointer"
      >
        {options.map((opt) => (
          <option key={opt.value} value={opt.value}>
            {opt.label}
          </option>
        ))}
      </select>
      <ChevronDown className="w-4 h-4 absolute right-3 top-1/2 -translate-y-1/2 text-secondary-400 pointer-events-none" />
    </div>
  );
}

/** Labelled checkbox row. */
export function CheckboxField({
  label,
  checked,
  onChange,
  hint,
}: {
  label: string;
  checked: boolean;
  onChange: (checked: boolean) => void;
  hint?: string;
}) {
  return (
    <label className="flex items-start gap-2.5 cursor-pointer select-none">
      <input
        type="checkbox"
        checked={checked}
        onChange={(e) => onChange(e.target.checked)}
        className="mt-0.5 h-4 w-4 rounded border-secondary-300 text-primary-600 focus:ring-primary-500"
      />
      <span>
        <span className="text-sm font-medium text-secondary-700">{label}</span>
        {hint && <span className="block text-xs text-secondary-500">{hint}</span>}
      </span>
    </label>
  );
}

export function SectionCard({
  title,
  actions,
  children,
  className,
}: {
  title: string;
  actions?: React.ReactNode;
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <section className={cn('bg-surface rounded-xl border border-secondary-200 shadow-sm', className)}>
      <header className="flex flex-wrap items-center justify-between gap-2 px-5 py-3.5 border-b border-secondary-200">
        <h2 className="text-base font-semibold text-secondary-900">{title}</h2>
        {actions && <div className="flex flex-wrap items-center gap-2">{actions}</div>}
      </header>
      <div className="p-5">{children}</div>
    </section>
  );
}

// ============================================================
// Address / maps helpers
// ============================================================

type AddressLike = {
  address_line1?: string | null;
  address_line2?: string | null;
  city?: string | null;
  postal_code?: string | null;
};

export function siteAddressFromJob(job: Pick<FsJob, 'site_address_line1' | 'site_address_line2' | 'site_city' | 'site_postal_code'> | Pick<FsVisit, 'site_address_line1' | 'site_address_line2' | 'site_city' | 'site_postal_code'>): string {
  return formatAddress({
    address_line1: job.site_address_line1,
    address_line2: job.site_address_line2,
    city: job.site_city,
    postal_code: job.site_postal_code,
  });
}

export function formatAddress(a: AddressLike | FsSite): string {
  return [a.address_line1, a.address_line2, a.city, a.postal_code].filter(Boolean).join(', ');
}

export function mapsUrl(address: string, lat?: number | null, lng?: number | null): string | null {
  if (lat && lng) return `https://www.google.com/maps/search/?api=1&query=${lat},${lng}`;
  if (!address) return null;
  return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(address)}`;
}

export function money(value: number | string | null | undefined, currency = 'GBP'): string {
  const n = Number(value ?? 0);
  if (!isFinite(n)) return '—';
  return new Intl.NumberFormat('en-GB', { style: 'currency', currency: currency || 'GBP' }).format(n);
}

export function hours(value: number | string | null | undefined): string {
  const n = Number(value ?? 0);
  if (!isFinite(n)) return '—';
  return `${n.toFixed(2).replace(/\.?0+$/, '')} h`;
}

export function apiError(err: unknown, fallback: string): string {
  return extractApiError(err, fallback);
}

/** HTTP status of an axios-style error, if any. */
export function apiStatus(err: unknown): number | undefined {
  return (err as { response?: { status?: number } })?.response?.status;
}

/** Turn an empty string into undefined (and numeric strings into numbers when asked). */
export function optional(value: string): string | undefined {
  const v = value.trim();
  return v === '' ? undefined : v;
}

export function optionalNumber(value: string): number | undefined {
  const v = value.trim();
  if (v === '') return undefined;
  const n = Number(v);
  return isFinite(n) ? n : undefined;
}

// ============================================================
// Prompt dialog (reason / sign-off name / etc.)
// ============================================================

export interface PromptDialogProps {
  isOpen: boolean;
  title: string;
  message?: string;
  label: string;
  placeholder?: string;
  required?: boolean;
  multiline?: boolean;
  confirmText?: string;
  variant?: 'primary' | 'danger';
  initialValue?: string;
  onClose: () => void;
  onSubmit: (value: string) => Promise<void> | void;
}

export function PromptDialog(props: PromptDialogProps) {
  return (
    <Modal isOpen={props.isOpen} onClose={props.onClose} title={props.title} size="sm">
      {/* Mounted only while open so the field starts fresh each time. */}
      {props.isOpen && <PromptForm {...props} />}
    </Modal>
  );
}

function PromptForm({
  message,
  label,
  placeholder,
  required = false,
  multiline = false,
  confirmText = 'Confirm',
  variant = 'primary',
  initialValue = '',
  onClose,
  onSubmit,
}: PromptDialogProps) {
  const [value, setValue] = useState(initialValue);
  const [busy, setBusy] = useState(false);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (required && !value.trim()) return;
    setBusy(true);
    try {
      await onSubmit(value.trim());
    } finally {
      setBusy(false);
    }
  };

  return (
    <form onSubmit={submit} className="space-y-4">
      {message && <p className="text-sm text-secondary-600">{message}</p>}
      {multiline ? (
        <Textarea label={label} value={value} onChange={(e) => setValue(e.target.value)} placeholder={placeholder} rows={3} />
      ) : (
        <Input label={label} value={value} onChange={(e) => setValue(e.target.value)} placeholder={placeholder} autoFocus />
      )}
      <div className="flex justify-end gap-2">
        <Button type="button" variant="ghost" onClick={onClose}>
          Cancel
        </Button>
        <Button type="submit" variant={variant} isLoading={busy} disabled={required && !value.trim()}>
          {confirmText}
        </Button>
      </div>
    </form>
  );
}

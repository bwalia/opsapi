'use client';

import React from 'react';
import { isAxiosError, type AxiosResponse } from 'axios';

// ---------------------------------------------------------------------------
// Types mirroring the opsapi-marketing campaign API
// ---------------------------------------------------------------------------

export type CampaignStatus =
  | 'draft'
  | 'validated'
  | 'awaiting_approval'
  | 'scheduled'
  | 'sending'
  | 'completed'
  | 'paused'
  | 'cancelled'
  | 'failed';

export type AbVariant = {
  key: string;
  subject?: string;
  body_html?: string;
  body_text?: string;
  weight?: number;
};

export type AbConfig = { enabled?: boolean; variants?: AbVariant[] };

export type UtmConfig = {
  enabled?: boolean;
  source?: string;
  medium?: string;
  campaign?: string;
  content?: string;
};

export type TrackingConfig = {
  track_opens?: boolean;
  track_clicks?: boolean;
  attribution?: boolean;
  utm?: UtmConfig;
  goal_event?: string;
};

export type Campaign = {
  id: number;
  uuid: string;
  name: string;
  objective?: string | null;
  channel: string;
  message_type?: string | null;
  status: CampaignStatus;
  list_id?: number | null;
  subject?: string | null;
  preview_text?: string | null;
  body_html?: string | null;
  body_text?: string | null;
  from_email?: string | null;
  from_name?: string | null;
  reply_to?: string | null;
  scheduled_at?: string | null;
  approval_required?: boolean | null;
  max_deliveries?: number | null;
  /** Send in batches: batch_size messages, then the next batch batch_interval_minutes later. */
  batch_size?: number | null;
  batch_interval_minutes?: number | null;
  ab_config?: AbConfig | null;
  tracking?: TrackingConfig | null;
  rejected_reason?: string | null;
  approval_notes?: string | null;
  started_at?: string | null;
  completed_at?: string | null;
  created_at?: string | null;
};

export type MktList = {
  id: number;
  uuid: string;
  name: string;
  list_type?: string;
  channel?: string;
};

export type ListMember = {
  contact_uuid: string;
  first_name?: string | null;
  last_name?: string | null;
  email?: string | null;
  phone?: string | null;
};

export type AudiencePreview = {
  audience_total: number;
  eligible: number;
  suppressed: number;
  no_consent: number;
  missing_address: number;
  other?: number;
  other_excluded?: number;
  sampled?: number;
  exact?: boolean;
};

export type CampaignAnalytics = {
  deliveries?: {
    total?: number;
    sent?: number;
    accepted?: number;
    delivered?: number;
    bounced?: number;
    failed?: number;
    skipped?: number;
    queued?: number;
    opened_estimated?: number;
    clicked?: number;
    converted?: number;
  };
  conversions?: { conversions?: number; revenue?: number; converters?: number; currency?: string | null };
  rates?: {
    open_rate?: number;
    click_rate?: number;
    click_to_open_rate?: number;
    conversion_rate?: number;
    bounce_rate?: number;
    revenue_per_recipient?: number;
  };
  funnel?: { stage: string; count: number; estimated?: boolean }[];
  variants?: {
    variant: string;
    total?: number;
    sent?: number;
    opened_estimated?: number;
    clicked?: number;
    converted?: number;
    revenue?: number;
    open_rate?: number;
    click_rate?: number;
    conversion_rate?: number;
  }[];
  ab_winner?: {
    variant: string;
    metric: 'clicked' | 'converted';
    rate?: number;
    runner_up?: string;
    runner_up_rate?: number;
    lift?: number;
    confidence?: number;
    significant?: boolean;
  } | null;
  tracking?: { opens_raw?: number; clicks_raw?: number; bot_events?: number; bot_opens?: number; bot_clicks?: number };
  top_links?: { url: string; clicks?: number; unique_clicks?: number }[];
  timeline?: { hour: string; opens?: number; clicks?: number; conversions?: number }[];
  reply_classes?: { classification: string; n: number }[];
  notes?: Record<string, unknown> | string[] | string | null;
};

export type AttributionRow = {
  uuid: string;
  name: string;
  status?: string;
  channel?: string;
  started_at?: string | null;
  sent?: number;
  opened?: number;
  clicked?: number;
  converted?: number;
  conversions?: number;
  revenue?: number;
  open_rate?: number;
  click_rate?: number;
  conversion_rate?: number;
  revenue_per_recipient?: number;
};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

export const EDITABLE_STATUSES: CampaignStatus[] = ['draft', 'validated', 'awaiting_approval', 'paused'];
export const AB_EDITABLE_STATUSES: CampaignStatus[] = ['draft', 'validated'];
export const LIVE_STATUSES: CampaignStatus[] = ['sending', 'completed', 'paused'];

export const STATUS_LABELS: Record<CampaignStatus, string> = {
  draft: 'Draft',
  validated: 'Validated',
  awaiting_approval: 'Awaiting approval',
  scheduled: 'Scheduled',
  sending: 'Sending',
  completed: 'Completed',
  paused: 'Paused',
  cancelled: 'Cancelled',
  failed: 'Failed',
};

const STATUS_STYLES: Record<CampaignStatus, string> = {
  draft: 'bg-secondary-100 text-secondary-500',
  validated: 'bg-blue-100 text-blue-800 dark:bg-blue-500/15 dark:text-blue-300',
  awaiting_approval: 'bg-amber-100 text-amber-800 dark:bg-amber-500/15 dark:text-amber-300',
  scheduled: 'bg-indigo-100 text-indigo-800 dark:bg-indigo-500/15 dark:text-indigo-300',
  sending: 'bg-sky-100 text-sky-800 dark:bg-sky-500/15 dark:text-sky-300',
  completed: 'bg-green-100 text-green-800 dark:bg-green-500/15 dark:text-green-300',
  paused: 'bg-orange-100 text-orange-800 dark:bg-orange-500/15 dark:text-orange-300',
  cancelled: 'bg-secondary-100 text-secondary-500 line-through',
  failed: 'bg-red-100 text-red-800 dark:bg-red-500/15 dark:text-red-300',
};

/** A new campaign's sample email (campaigns page "Create draft", lists page "Write an email"). */
export const STARTER = {
  channel: 'email',
  message_type: 'marketing',
  subject: 'Hello {{contact.first_name}}',
  preview_text: 'A quick update we think you will find useful — take a look inside.',
  body_html: [
    '<div style="font-family:\'Helvetica Neue\',Helvetica,Arial,sans-serif;max-width:600px;margin:0 auto;padding:36px 32px;background:#ffffff;color:#1f2937;font-size:16px;line-height:1.65;border:1px solid #e5e7eb;border-radius:16px">',
    '<p style="margin:0 0 28px;font-size:13px;font-weight:700;letter-spacing:2px;text-transform:uppercase;color:#e11d48">[Your business name]</p>',
    '<h1 style="margin:0 0 16px;font-size:28px;line-height:1.25;font-weight:800;color:#111827">Hi {{contact.first_name}},</h1>',
    '<p style="margin:0 0 20px;font-size:18px;color:#374151">We have something new to share with you.</p>',
    '<p style="margin:0 0 16px">[Write your message here. Keep it short: say what’s new, why it matters to them, and what to do next.]</p>',
    '<p style="margin:28px 0;text-align:center"><a href="https://yourwebsite.co.uk" style="display:inline-block;background:#e11d48;color:#ffffff;padding:14px 28px;border-radius:8px;text-decoration:none;font-weight:600">Find out more</a></p>',
    '<p style="margin:28px 0 0">Best wishes,<br><strong>[Your name]</strong><br>[Your business name]</p>',
    '<p style="margin:32px 0 0;padding-top:20px;border-top:1px solid #e5e7eb;font-size:12px;line-height:1.5;color:#6b7280;text-align:center">You’re getting this because you’re a customer or asked to hear from us.<br><a href="{{unsubscribe_url}}" style="color:#6b7280">Unsubscribe</a> · <a href="{{preferences_url}}" style="color:#6b7280">Email preferences</a></p>',
    '</div>',
  ].join('\n'),
  body_text:
    'Hi {{contact.first_name}},\n\nWe have something new to share with you.\n\nFind out more: https://yourwebsite.co.uk\n\nUnsubscribe: {{unsubscribe_url}}',
};

export const INPUT_CLASS = 'rounded border border-secondary-200 bg-surface px-2 py-1.5 text-sm text-secondary-900';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

export function apiErrorMessage(e: unknown, fallback: string): string {
  if (isAxiosError(e)) {
    const data = e.response?.data as
      | { error?: string; message?: string; details?: Record<string, unknown>; errors?: Record<string, unknown> }
      | undefined;
    // Field validation (422) puts { field: message } in details/errors — surface them.
    const fieldErrors = data?.errors ?? (data?.details && !('code' in data.details) ? data.details : undefined);
    if (fieldErrors && typeof fieldErrors === 'object') {
      const parts = Object.entries(fieldErrors)
        .filter(([, v]) => typeof v === 'string')
        .map(([k, v]) => `${k.replace(/_/g, ' ')} ${String(v)}`);
      if (parts.length > 0) return `${data?.error ? `${data.error}: ` : ''}${parts.join('; ')}`;
    }
    if (data?.error) return String(data.error);
    if (data?.message) return String(data.message);
    if (e.message) return e.message;
  }
  if (e instanceof Error) return e.message;
  return fallback;
}

export function apiErrorCode(e: unknown): string | undefined {
  if (isAxiosError(e)) {
    const data = e.response?.data as { details?: { code?: string } } | undefined;
    return data?.details?.code;
  }
  return undefined;
}

/** Unwrap the `{success, data, meta}` envelope (falls back to the raw body). */
export function unwrap<T>(res: AxiosResponse): T {
  const body = res.data;
  return (body?.data ?? body) as T;
}

export function unwrapArray<T>(res: AxiosResponse): T[] {
  const data = unwrap<T[] | { items?: T[] } | null>(res);
  if (Array.isArray(data)) return data;
  return data?.items ?? [];
}

/** jsonb columns can arrive as an object or a JSON string depending on the driver path. */
export function parseJsonObject<T extends object>(v: unknown): T | null {
  if (v == null) return null;
  if (typeof v === 'string') {
    try {
      const parsed: unknown = JSON.parse(v);
      return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? (parsed as T) : null;
    } catch {
      return null;
    }
  }
  return typeof v === 'object' && !Array.isArray(v) ? (v as T) : null;
}

export function normaliseCampaign(raw: Campaign): Campaign {
  return {
    ...raw,
    ab_config: parseJsonObject<AbConfig>(raw.ab_config),
    tracking: parseJsonObject<TrackingConfig>(raw.tracking),
  };
}

export function slugify(s: string): string {
  return s
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60);
}

export function fmtInt(n: number | null | undefined): string {
  return new Intl.NumberFormat().format(Number(n ?? 0));
}

export function fmtPct(n: number | null | undefined, digits = 1): string {
  if (n == null || Number.isNaN(Number(n))) return '—';
  return `${Number(n).toFixed(digits)}%`;
}

export function fmtMoney(n: number | null | undefined, currency?: string | null): string {
  const v = Number(n ?? 0);
  try {
    return new Intl.NumberFormat(undefined, {
      style: 'currency',
      currency: currency || 'GBP',
      maximumFractionDigits: 2,
    }).format(v);
  } catch {
    return v.toFixed(2);
  }
}

export function fmtDateTime(s: string | null | undefined): string {
  if (!s) return '—';
  const d = new Date(s);
  if (Number.isNaN(d.getTime())) return s;
  return d.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
}

/** ISO string → value for `<input type="datetime-local">` in the viewer's local time. */
export function toLocalInput(iso: string | null | undefined): string {
  const d = iso ? new Date(iso) : new Date(Date.now() + 60 * 60 * 1000);
  if (Number.isNaN(d.getTime())) return '';
  const pad = (x: number) => String(x).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export function contactLabel(m: ListMember): string {
  const name = [m.first_name, m.last_name].filter(Boolean).join(' ');
  if (name && m.email) return `${name} <${m.email}>`;
  return name || m.email || m.phone || m.contact_uuid;
}

// ---------------------------------------------------------------------------
// Small presentational pieces
// ---------------------------------------------------------------------------

export function StatusBadge({ status }: { status: string }) {
  const known = status in STATUS_STYLES;
  const style = known ? STATUS_STYLES[status as CampaignStatus] : 'bg-secondary-100 text-secondary-500';
  const label = known ? STATUS_LABELS[status as CampaignStatus] : status;
  return (
    <span className={`inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ${style}`}>
      {status === 'sending' && (
        <span className="mr-1.5 inline-block h-1.5 w-1.5 animate-pulse rounded-full bg-current" aria-hidden="true" />
      )}
      {label}
    </span>
  );
}

export function KpiTile({
  label,
  value,
  hint,
  tone,
}: {
  label: string;
  value: React.ReactNode;
  hint?: string;
  tone?: 'good' | 'bad';
}) {
  const toneClass =
    tone === 'good'
      ? 'text-green-700 dark:text-green-400'
      : tone === 'bad'
        ? 'text-red-700 dark:text-red-400'
        : '';
  return (
    <div className="rounded-lg border border-secondary-200 p-3">
      <div className="text-xs text-secondary-500">{label}</div>
      <div className={`mt-1 text-2xl font-semibold tabular-nums ${toneClass}`}>{value}</div>
      {hint && <div className="mt-0.5 text-[11px] text-secondary-500">{hint}</div>}
    </div>
  );
}

export function Notice({
  tone = 'info',
  children,
}: {
  tone?: 'info' | 'warn' | 'error' | 'success';
  children: React.ReactNode;
}) {
  const styles = {
    info: 'border-secondary-200 bg-secondary-100/60 text-secondary-900',
    warn: 'border-amber-300 bg-amber-50 text-amber-900 dark:border-amber-500/40 dark:bg-amber-500/10 dark:text-amber-200',
    error: 'border-red-300 bg-red-50 text-red-900 dark:border-red-500/40 dark:bg-red-500/10 dark:text-red-200',
    success:
      'border-green-300 bg-green-50 text-green-900 dark:border-green-500/40 dark:bg-green-500/10 dark:text-green-200',
  };
  return (
    <div role={tone === 'error' ? 'alert' : 'status'} className={`rounded-md border px-3 py-2 text-sm ${styles[tone]}`}>
      {children}
    </div>
  );
}

export function Toggle({
  id,
  label,
  description,
  checked,
  disabled,
  onChange,
}: {
  id: string;
  label: string;
  description?: React.ReactNode;
  checked: boolean;
  disabled?: boolean;
  onChange: (v: boolean) => void;
}) {
  return (
    <div className="flex items-start gap-3">
      <input
        id={id}
        type="checkbox"
        className="mt-0.5 h-4 w-4 rounded border-secondary-200"
        checked={checked}
        disabled={disabled}
        onChange={(e) => onChange(e.target.checked)}
      />
      <label htmlFor={id} className="text-sm">
        <span className="font-medium">{label}</span>
        {description && <span className="mt-0.5 block text-xs text-secondary-500">{description}</span>}
      </label>
    </div>
  );
}

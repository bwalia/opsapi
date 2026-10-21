import { isAxiosError } from 'axios';

export type InstallStatus = 'waiting' | 'active' | 'stale';

export type Pixel = {
  uuid: string;
  name: string;
  public_key: string;
  allowed_domains: string[];
  attribution_window_days: number;
  is_active: boolean;
  last_event_at?: string | null;
  install_status: InstallStatus;
  events_24h?: number;
  conversions_30d?: number;
  created_at?: string;
};

export type PixelSnippet = {
  public_key: string;
  html: string;
  script_url?: string;
  events_url?: string;
  gif_url?: string;
  examples?: Partial<Record<'purchase' | 'lead' | 'identify' | 'consent' | 'declarative', string>>;
};

export type PixelEvent = {
  id: number;
  uuid: string;
  event_name: string;
  url?: string | null;
  referrer?: string | null;
  value?: number | string | null;
  currency?: string | null;
  order_id?: string | null;
  utm_source?: string | null;
  utm_medium?: string | null;
  utm_campaign?: string | null;
  properties?: unknown;
  is_bot?: boolean;
  is_test?: boolean;
  is_conversion?: boolean;
  contact_uuid?: string | null;
  contact_name?: string | null;
  visitor_key?: string | null;
  campaign_name?: string | null;
  campaign_uuid?: string | null;
  created_at: string;
};

export type ForwardDestination = 'meta' | 'ga4' | 'error';
export type ForwardStatus = 'sent' | 'failed' | 'dry_run';

export type PixelStats = {
  days: number;
  totals: {
    events: number;
    visitors: number;
    identified: number;
    attributed_events: number;
    conversions: number;
    revenue: number | string;
    bot_events: number;
  };
  daily: { day: string; page_views: number; conversions: number; visitors: number }[];
  top_events: { event_name: string; n: number }[];
  top_pages: { page: string; n: number }[];
  forwards: { destination: ForwardDestination; status: ForwardStatus; n: number }[];
};

export type ForwardLog = {
  destination: ForwardDestination;
  status: ForwardStatus;
  http_status?: number | null;
  response?: string | null;
  created_at: string;
  event_name?: string | null;
};

export const INPUT_CLASS = 'rounded border border-secondary-200 bg-surface px-2 py-1.5 text-sm';

export function apiErrorMessage(e: unknown, fallback: string): string {
  if (isAxiosError(e)) {
    const data = e.response?.data as { error?: string; message?: string } | undefined;
    if (data?.error) return String(data.error);
    if (data?.message) return String(data.message);
    if (e.message) return e.message;
  }
  if (e instanceof Error) return e.message;
  return fallback;
}

/** Unwrap the `{success, data}` envelope (falls back to the raw body). */
export function unwrap<T>(res: { data?: unknown }): T {
  const body = res.data as { data?: unknown } | undefined;
  return ((body && typeof body === 'object' && 'data' in body ? body.data : body) ?? null) as T;
}

/** Split a free-form "a.com, b.com\nc.com" string into a clean domain list. */
export function parseDomains(text: string): string[] {
  return Array.from(
    new Set(
      text
        .split(/[\s,;]+/)
        .map((d) => d.trim().toLowerCase())
        .filter(Boolean),
    ),
  );
}

export function toNumber(v: unknown): number {
  const n = typeof v === 'number' ? v : Number(v);
  return Number.isFinite(n) ? n : 0;
}

export function formatMoney(value: unknown, currency?: string | null): string {
  const n = toNumber(value);
  if (currency) {
    try {
      return new Intl.NumberFormat(undefined, { style: 'currency', currency }).format(n);
    } catch {
      // Unknown ISO code — fall through to plain formatting.
    }
  }
  return `${n.toLocaleString(undefined, { maximumFractionDigits: 2 })}${currency ? ` ${currency}` : ''}`;
}

export function formatDateTime(iso?: string | null): string {
  if (!iso) return '—';
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? iso : d.toLocaleString();
}

export function relativeTime(iso?: string | null): string {
  if (!iso) return 'never';
  const t = new Date(iso).getTime();
  if (Number.isNaN(t)) return iso;
  const s = Math.max(0, Math.round((Date.now() - t) / 1000));
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  if (s < 86400) return `${Math.round(s / 3600)}h ago`;
  return `${Math.round(s / 86400)}d ago`;
}

export const STATUS_META: Record<InstallStatus, { label: string; dot: string; text: string }> = {
  waiting: {
    label: 'Waiting for first event',
    dot: 'bg-amber-500',
    text: 'text-amber-700 dark:text-amber-400',
  },
  active: { label: 'Active', dot: 'bg-green-500', text: 'text-green-700 dark:text-green-400' },
  stale: { label: 'No recent events', dot: 'bg-gray-400', text: 'text-secondary-500' },
};

export const DEST_LABEL: Record<string, string> = {
  meta: 'Meta Conversions API',
  ga4: 'Google Analytics 4',
  error: 'Error',
};

export const FORWARD_STATUS_CLASS: Record<string, string> = {
  sent: 'text-green-700 dark:text-green-400',
  failed: 'text-error-600',
  dry_run: 'text-amber-700 dark:text-amber-400',
};

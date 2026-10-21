'use client';

import React, { useCallback, useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import { FlaskConical, Pause, Play, Send } from 'lucide-react';
import { Button } from '@/components/ui';
import { marketingService } from '@/services/opsapi-marketing.service';
import { apiErrorMessage, formatMoney, unwrap, type Pixel, type PixelEvent } from './shared';

const POLL_MS = 3000;
const MAX_ROWS = 200;

type Filter = 'all' | 'conversions' | 'attributed' | 'bots';

const FILTERS: { value: Filter; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: 'conversions', label: 'Conversions' },
  { value: 'attributed', label: 'Attributed' },
  { value: 'bots', label: 'Bots' },
];

const BADGE = 'inline-flex items-center rounded px-1.5 py-0.5 text-[11px] font-medium';

function matches(ev: PixelEvent, filter: Filter): boolean {
  switch (filter) {
    case 'conversions':
      return !!ev.is_conversion;
    case 'attributed':
      return !!ev.campaign_uuid;
    case 'bots':
      return !!ev.is_bot;
    default:
      return true;
  }
}

function merge(existing: PixelEvent[], incoming: PixelEvent[]): PixelEvent[] {
  if (incoming.length === 0) return existing;
  const seen = new Set(existing.map((e) => e.id));
  const fresh = incoming.filter((e) => !seen.has(e.id));
  if (fresh.length === 0) return existing;
  return [...fresh, ...existing].sort((a, b) => b.id - a.id).slice(0, MAX_ROWS);
}

function pathOf(url?: string | null): string {
  if (!url) return '';
  try {
    const u = new URL(url);
    return `${u.host}${u.pathname}${u.search}`;
  } catch {
    return url;
  }
}

export function LiveEventsTab({ pixel, onActivity }: { pixel: Pixel; onActivity?: () => void }) {
  const [events, setEvents] = useState<PixelEvent[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [paused, setPaused] = useState(false);
  const [filter, setFilter] = useState<Filter>('all');
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [sending, setSending] = useState(false);

  const newestId = useRef(0);
  const inFlight = useRef(false);

  const poll = useCallback(async () => {
    if (inFlight.current) return;
    inFlight.current = true;
    try {
      const params = newestId.current > 0 ? { limit: 100, after_id: newestId.current } : { limit: 50 };
      const res = await marketingService.pixelEvents(pixel.uuid, params);
      const rows = unwrap<PixelEvent[]>(res);
      const list = Array.isArray(rows) ? rows : [];
      if (list.length > 0) {
        newestId.current = Math.max(newestId.current, ...list.map((e) => e.id));
        setEvents((prev) => merge(prev, list));
      }
      setError(null);
    } catch (e: unknown) {
      setError(apiErrorMessage(e, 'Failed to load events'));
    } finally {
      inFlight.current = false;
      setLoaded(true);
    }
  }, [pixel.uuid]);

  // Note: the parent remounts this component per pixel (key={uuid}), so state never leaks across pixels.
  useEffect(() => {
    if (paused) return;
    void poll();
    const t = setInterval(() => {
      if (document.visibilityState === 'visible') void poll();
    }, POLL_MS);
    return () => clearInterval(t);
  }, [paused, poll]);

  const sendTest = async () => {
    setSending(true);
    setError(null);
    setNotice(null);
    try {
      await marketingService.pixelTestEvent(pixel.uuid);
      setNotice('Test event sent — it should appear below within a few seconds.');
      await poll();
      onActivity?.();
    } catch (e: unknown) {
      setError(apiErrorMessage(e, 'Failed to send test event'));
    } finally {
      setSending(false);
    }
  };

  const visible = events.filter((e) => matches(e, filter));

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex flex-wrap items-center gap-2">
          <Button
            size="sm"
            variant="outline"
            leftIcon={paused ? <Play className="h-4 w-4" /> : <Pause className="h-4 w-4" />}
            onClick={() => setPaused((p) => !p)}
            aria-pressed={paused}
          >
            {paused ? 'Resume' : 'Pause'}
          </Button>
          <span className="flex items-center gap-1.5 text-xs text-secondary-500" aria-live="polite">
            <span
              className={`inline-block h-2 w-2 rounded-full ${paused ? 'bg-gray-400' : 'animate-pulse bg-green-500'}`}
              aria-hidden="true"
            />
            {paused ? 'Paused' : 'Live — refreshing every 3s'}
          </span>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <div role="radiogroup" aria-label="Filter events" className="flex rounded border border-secondary-200">
            {FILTERS.map((f) => (
              <button
                key={f.value}
                type="button"
                role="radio"
                aria-checked={filter === f.value}
                className={`px-2.5 py-1 text-xs first:rounded-l last:rounded-r ${
                  filter === f.value ? 'bg-secondary-100 font-medium' : 'text-secondary-500 hover:bg-secondary-50'
                }`}
                onClick={() => setFilter(f.value)}
              >
                {f.label}
              </button>
            ))}
          </div>
          <Button
            size="sm"
            leftIcon={<Send className="h-4 w-4" />}
            disabled={sending || !pixel.is_active}
            onClick={() => void sendTest()}
            title={pixel.is_active ? undefined : 'Activate the pixel in Settings to receive events'}
          >
            {sending ? 'Sending…' : 'Send test event'}
          </Button>
        </div>
      </div>

      {!pixel.is_active && (
        <p className="text-sm text-amber-700 dark:text-amber-400">
          This pixel is paused — new events are rejected until it is re-activated in Settings.
        </p>
      )}
      {error && <p className="text-sm text-error-600">{error}</p>}
      {notice && <p className="text-sm text-green-700 dark:text-green-400">{notice}</p>}

      <div className="rounded-lg border border-secondary-200">
        {!loaded ? (
          <p className="p-4 text-sm text-secondary-500" role="status">
            Loading events…
          </p>
        ) : visible.length === 0 ? (
          <p className="p-4 text-sm text-secondary-500">
            {events.length === 0
              ? 'No events yet. Install the snippet and load a page on your site, or click “Send test event”.'
              : 'No events match this filter.'}
          </p>
        ) : (
          <ul className="max-h-[560px] divide-y divide-secondary-200 overflow-auto" aria-label="Pixel events, newest first">
            {visible.map((ev) => (
              <li key={ev.id} className="space-y-1 p-3 text-sm">
                <div className="flex flex-wrap items-center gap-1.5">
                  <span className="font-mono font-medium">{ev.event_name}</span>
                  {ev.is_conversion && (
                    <span className={`${BADGE} bg-green-100 text-green-800 dark:bg-green-900/40 dark:text-green-300`}>
                      conversion
                      {ev.value != null && ev.value !== '' && ` · ${formatMoney(ev.value, ev.currency)}`}
                    </span>
                  )}
                  {ev.is_test && (
                    <span className={`${BADGE} bg-blue-100 text-blue-800 dark:bg-blue-900/40 dark:text-blue-300`}>
                      <FlaskConical className="mr-1 h-3 w-3" aria-hidden="true" />
                      test
                    </span>
                  )}
                  {ev.is_bot && <span className={`${BADGE} bg-secondary-100 text-secondary-500`}>bot</span>}
                  {ev.campaign_uuid && (
                    <Link
                      href={`/dashboard/opsapi-marketing/campaigns/${ev.campaign_uuid}`}
                      className={`${BADGE} bg-amber-100 text-amber-800 hover:underline dark:bg-amber-900/40 dark:text-amber-300`}
                    >
                      campaign: {ev.campaign_name || 'view'}
                    </Link>
                  )}
                  {ev.contact_name && (
                    <span
                      className={`${BADGE} bg-purple-100 text-purple-800 dark:bg-purple-900/40 dark:text-purple-300`}
                    >
                      {ev.contact_name}
                    </span>
                  )}
                  <time className="ml-auto text-xs text-secondary-500" dateTime={ev.created_at}>
                    {new Date(ev.created_at).toLocaleTimeString()}
                  </time>
                </div>
                {ev.url && (
                  <div className="truncate text-xs text-secondary-500" title={ev.url}>
                    {pathOf(ev.url)}
                  </div>
                )}
                {(ev.utm_source || ev.utm_campaign || ev.order_id || ev.referrer) && (
                  <div className="flex flex-wrap gap-x-3 text-xs text-secondary-500">
                    {ev.utm_source && (
                      <span>
                        utm: {[ev.utm_source, ev.utm_medium, ev.utm_campaign].filter(Boolean).join(' / ')}
                      </span>
                    )}
                    {ev.order_id && <span>order: {ev.order_id}</span>}
                    {ev.referrer && <span className="truncate">ref: {pathOf(ev.referrer)}</span>}
                  </div>
                )}
              </li>
            ))}
          </ul>
        )}
      </div>
      {events.length >= MAX_ROWS && (
        <p className="text-xs text-secondary-500">Showing the latest {MAX_ROWS} events.</p>
      )}
    </div>
  );
}

'use client';

import React, { useCallback, useEffect, useState } from 'react';
import { Activity, BarChart3, Code2, Crosshair, Loader2, Plus, RefreshCw, Settings, X } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button } from '@/components/ui';
import { marketingService } from '@/services/opsapi-marketing.service';
import { InstallTab } from './InstallTab';
import { LiveEventsTab } from './LiveEventsTab';
import { PerformanceTab } from './PerformanceTab';
import { SettingsTab } from './SettingsTab';
import {
  apiErrorMessage,
  INPUT_CLASS,
  parseDomains,
  relativeTime,
  STATUS_META,
  toNumber,
  unwrap,
  type Pixel,
} from './shared';

type Tab = 'install' | 'live' | 'performance' | 'settings';

const TABS: { id: Tab; label: string; icon: React.ReactNode }[] = [
  { id: 'install', label: 'Install', icon: <Code2 className="h-4 w-4" /> },
  { id: 'live', label: 'Live events', icon: <Activity className="h-4 w-4" /> },
  { id: 'performance', label: 'Performance', icon: <BarChart3 className="h-4 w-4" /> },
  { id: 'settings', label: 'Settings', icon: <Settings className="h-4 w-4" /> },
];

function normalizePixel(p: Pixel): Pixel {
  return {
    ...p,
    allowed_domains: Array.isArray(p.allowed_domains) ? p.allowed_domains : [],
    attribution_window_days: toNumber(p.attribution_window_days) || 30,
    install_status: p.install_status || 'waiting',
  };
}

function StatusDot({ pixel }: { pixel: Pixel }) {
  const meta = STATUS_META[pixel.install_status] ?? STATUS_META.waiting;
  return (
    <span
      className={`inline-block h-2.5 w-2.5 shrink-0 rounded-full ${pixel.is_active ? meta.dot : 'bg-gray-400'}`}
      aria-hidden="true"
    />
  );
}

function statusLabel(pixel: Pixel): string {
  if (!pixel.is_active) return 'Paused';
  return (STATUS_META[pixel.install_status] ?? STATUS_META.waiting).label;
}

function EmptyState({ onCreate }: { onCreate: () => void }) {
  const steps = [
    ['Email click', 'A contact clicks a link in your campaign; the link carries a private click-through token.'],
    ['Site visit', 'The pixel on your website picks up the token and links the visit to that contact and campaign.'],
    ['Conversion', 'When they buy or sign up, you fire mkt(’track’, ’purchase’, …) with the value.'],
    ['Revenue per campaign', 'Marketing reports show conversions and revenue credited to each campaign.'],
  ];
  return (
    <div className="space-y-4 rounded-lg border border-dashed border-secondary-200 p-6">
      <div className="flex items-center gap-2">
        <Crosshair className="h-5 w-5 text-secondary-500" aria-hidden="true" />
        <h2 className="text-lg font-semibold">Close the loop from email to revenue</h2>
      </div>
      <p className="text-sm text-secondary-500">
        A tracking pixel is a small script you add to your website. It connects what happens on your site back to the
        campaign that sent the visitor, so you can see which emails actually drive sales — not just opens and clicks.
      </p>
      <ol className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {steps.map(([title, body], i) => (
          <li key={title} className="rounded-lg border border-secondary-200 p-3">
            <div className="text-xs text-secondary-500">Step {i + 1}</div>
            <div className="text-sm font-medium">{title}</div>
            <p className="mt-1 text-xs text-secondary-500">{body}</p>
          </li>
        ))}
      </ol>
      <p className="text-xs text-secondary-500">
        Privacy-first: first-party cookies only, and Global Privacy Control / Do Not Track visitors are tracked
        cookieless.
      </p>
      <Button size="sm" leftIcon={<Plus className="h-4 w-4" />} onClick={onCreate}>
        Create your first pixel
      </Button>
    </div>
  );
}

export default function MarketingPixelsPage() {
  const [pixels, setPixels] = useState<Pixel[]>([]);
  const [loading, setLoading] = useState(true);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>('install');
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const [showNew, setShowNew] = useState(false);
  const [newName, setNewName] = useState('');
  const [newDomains, setNewDomains] = useState('');
  const [newWindow, setNewWindow] = useState('30');
  const [creating, setCreating] = useState(false);

  const loadPixels = useCallback(async () => {
    const res = await marketingService.listPixels();
    const data = unwrap<Pixel[] | { items?: Pixel[] }>(res);
    const rows = (Array.isArray(data) ? data : data?.items || []).map(normalizePixel);
    setPixels(rows);
    setSelectedId((cur) => (cur && rows.some((p) => p.uuid === cur) ? cur : rows[0]?.uuid ?? null));
    return rows;
  }, []);

  useEffect(() => {
    void (async () => {
      try {
        await loadPixels();
      } catch (e: unknown) {
        setError(apiErrorMessage(e, 'Failed to load pixels'));
      } finally {
        setLoading(false);
      }
    })();
  }, [loadPixels]);

  const refresh = async () => {
    setError(null);
    try {
      await loadPixels();
    } catch (e: unknown) {
      setError(apiErrorMessage(e, 'Failed to refresh pixels'));
    }
  };

  const createPixel = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setNotice(null);
    const name = newName.trim();
    const days = Number(newWindow);
    if (!name) {
      setError('Pixel name is required');
      return;
    }
    if (!Number.isInteger(days) || days < 1 || days > 90) {
      setError('Attribution window must be a whole number of days between 1 and 90');
      return;
    }
    setCreating(true);
    try {
      const res = await marketingService.createPixel({
        name,
        allowed_domains: parseDomains(newDomains),
        attribution_window_days: days,
      });
      const created = unwrap<Pixel>(res);
      setNewName('');
      setNewDomains('');
      setNewWindow('30');
      setShowNew(false);
      await loadPixels();
      if (created?.uuid) setSelectedId(created.uuid);
      setTab('install');
      setNotice('Pixel created — paste the snippet below into your site, then check Live events.');
    } catch (e: unknown) {
      setError(apiErrorMessage(e, 'Failed to create pixel'));
    } finally {
      setCreating(false);
    }
  };

  const onUpdated = (p: Pixel) => {
    const next = normalizePixel(p);
    setPixels((list) => list.map((x) => (x.uuid === next.uuid ? { ...x, ...next } : x)));
  };

  const onDeleted = (uuid: string) => {
    const rest = pixels.filter((x) => x.uuid !== uuid);
    setPixels(rest);
    setSelectedId(rest[0]?.uuid ?? null);
    setTab('install');
    setNotice('Pixel deleted.');
  };

  const selected = pixels.find((p) => p.uuid === selectedId) ?? null;

  const openNew = () => {
    setShowNew(true);
    setNotice(null);
  };

  return (
    <div className="space-y-6 p-6">
      <PageHeader
        title="Pixels & attribution"
        description="Track site visits and conversions from your campaigns, and see the revenue each campaign drives."
        icon={<Crosshair className="h-5 w-5" />}
        actions={
          <div className="flex gap-2">
            <Button
              size="sm"
              variant="ghost"
              leftIcon={<RefreshCw className="h-4 w-4" />}
              onClick={() => void refresh()}
              aria-label="Refresh pixels"
            >
              Refresh
            </Button>
            <Button size="sm" leftIcon={<Plus className="h-4 w-4" />} onClick={openNew} aria-expanded={showNew}>
              New pixel
            </Button>
          </div>
        }
      />

      {error && (
        <p className="text-sm text-error-600" role="alert">
          {error}
        </p>
      )}
      {notice && <p className="text-sm text-green-700 dark:text-green-400">{notice}</p>}

      {showNew && (
        <form
          className="space-y-3 rounded-lg border border-secondary-200 p-4"
          onSubmit={(e) => void createPixel(e)}
          aria-labelledby="new-pixel-heading"
        >
          <div className="flex items-center justify-between">
            <h2 id="new-pixel-heading" className="text-sm font-medium">
              New pixel
            </h2>
            <button
              type="button"
              className="p-1 text-secondary-500 hover:text-secondary-900"
              aria-label="Close new pixel form"
              onClick={() => setShowNew(false)}
            >
              <X className="h-4 w-4" />
            </button>
          </div>
          <div className="grid gap-3 md:grid-cols-[1fr_1fr_auto]">
            <div className="space-y-1">
              <label htmlFor="new-pixel-name" className="text-sm">
                Name
              </label>
              <input
                id="new-pixel-name"
                className={`w-full ${INPUT_CLASS}`}
                placeholder="e.g. Main website"
                value={newName}
                onChange={(e) => setNewName(e.target.value)}
                required
                autoFocus
              />
            </div>
            <div className="space-y-1">
              <label htmlFor="new-pixel-domains" className="text-sm">
                Allowed domains <span className="text-secondary-500">(optional)</span>
              </label>
              <textarea
                id="new-pixel-domains"
                className={`h-[34px] min-h-[34px] w-full resize-y font-mono ${INPUT_CLASS}`}
                placeholder="example.com, shop.example.com"
                value={newDomains}
                onChange={(e) => setNewDomains(e.target.value)}
                aria-describedby="new-pixel-domains-help"
              />
              <p id="new-pixel-domains-help" className="text-xs text-secondary-500">
                Comma or newline separated. Empty accepts any domain.
              </p>
            </div>
            <div className="space-y-1">
              <label htmlFor="new-pixel-window" className="text-sm">
                Attribution window (days)
              </label>
              <input
                id="new-pixel-window"
                type="number"
                min={1}
                max={90}
                step={1}
                className={`w-28 ${INPUT_CLASS}`}
                value={newWindow}
                onChange={(e) => setNewWindow(e.target.value)}
              />
            </div>
          </div>
          <div className="flex gap-2">
            <Button type="submit" size="sm" leftIcon={<Plus className="h-4 w-4" />} disabled={creating}>
              {creating ? 'Creating…' : 'Create pixel'}
            </Button>
            <Button type="button" size="sm" variant="ghost" onClick={() => setShowNew(false)}>
              Cancel
            </Button>
          </div>
        </form>
      )}

      {loading ? (
        <p className="flex items-center gap-2 text-sm text-secondary-500" role="status">
          <Loader2 className="h-4 w-4 animate-spin" /> Loading pixels…
        </p>
      ) : pixels.length === 0 ? (
        !showNew && <EmptyState onCreate={openNew} />
      ) : (
        <div className="grid gap-6 lg:grid-cols-[300px_1fr]">
          <ul className="h-fit divide-y divide-secondary-200 rounded-lg border border-secondary-200" aria-label="Pixels">
            {pixels.map((p) => (
              <li key={p.uuid}>
                <button
                  type="button"
                  className={`w-full p-3 text-left text-sm hover:bg-secondary-50 ${
                    selectedId === p.uuid ? 'bg-secondary-100' : ''
                  }`}
                  aria-current={selectedId === p.uuid ? 'true' : undefined}
                  onClick={() => setSelectedId(p.uuid)}
                >
                  <div className="flex items-center gap-2">
                    <StatusDot pixel={p} />
                    <span className="truncate font-medium">{p.name}</span>
                  </div>
                  <div className="mt-0.5 pl-[18px] text-xs text-secondary-500">
                    {statusLabel(p)} · {toNumber(p.events_24h).toLocaleString()} events / 24h
                  </div>
                </button>
              </li>
            ))}
          </ul>

          {!selected ? (
            <p className="text-sm text-secondary-500">Select a pixel.</p>
          ) : (
            <div className="min-w-0 space-y-4">
              <div className="flex flex-wrap items-start justify-between gap-2">
                <div>
                  <h2 className="text-lg font-semibold">{selected.name}</h2>
                  <p className="flex flex-wrap items-center gap-x-2 text-xs text-secondary-500">
                    <span
                      className={`flex items-center gap-1.5 ${
                        selected.is_active
                          ? (STATUS_META[selected.install_status] ?? STATUS_META.waiting).text
                          : 'text-secondary-500'
                      }`}
                    >
                      <StatusDot pixel={selected} />
                      {statusLabel(selected)}
                    </span>
                    <span>· last event {relativeTime(selected.last_event_at)}</span>
                    <span>· {toNumber(selected.conversions_30d).toLocaleString()} conversions / 30d</span>
                    <span>· {selected.attribution_window_days}-day window</span>
                  </p>
                </div>
              </div>

              <div role="tablist" aria-label="Pixel sections" className="flex flex-wrap gap-1 border-b border-secondary-200">
                {TABS.map((t) => (
                  <button
                    key={t.id}
                    id={`pixel-tab-${t.id}`}
                    type="button"
                    role="tab"
                    aria-selected={tab === t.id}
                    aria-controls={`pixel-panel-${t.id}`}
                    className={`-mb-px flex items-center gap-1.5 border-b-2 px-3 py-2 text-sm ${
                      tab === t.id
                        ? 'border-primary-500 font-medium'
                        : 'border-transparent text-secondary-500 hover:text-secondary-900'
                    }`}
                    onClick={() => setTab(t.id)}
                  >
                    {t.icon}
                    {t.label}
                  </button>
                ))}
              </div>

              <div role="tabpanel" id={`pixel-panel-${tab}`} aria-labelledby={`pixel-tab-${tab}`}>
                {tab === 'install' && <InstallTab key={selected.uuid} pixel={selected} />}
                {tab === 'live' && (
                  <LiveEventsTab key={selected.uuid} pixel={selected} onActivity={() => void refresh()} />
                )}
                {tab === 'performance' && <PerformanceTab key={selected.uuid} pixel={selected} />}
                {tab === 'settings' && (
                  <SettingsTab key={selected.uuid} pixel={selected} onUpdated={onUpdated} onDeleted={onDeleted} />
                )}
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

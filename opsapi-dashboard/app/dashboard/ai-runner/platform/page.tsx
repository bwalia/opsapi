'use client';

/**
 * AI Runs platform settings (docs/AI_RUNNER.md §27.5): timings and limits for every workspace, platform admins only.
 * The server decides who may see them (403 for everyone else), so the page shows nothing to others even when their
 * cached roles are stale; AI run settings links here only for platform admins (no sidebar entry: plugin menu items
 * can't be admin-only). Only the fields shown are saved.
 */
import React, { useEffect, useState } from 'react';
import { Lock, SlidersHorizontal } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, Card, Input } from '@/components/ui';
import { ErrorNote, Spinner } from '@/components/property-deals/ui';
import { AiRunnerPage, PRODUCT, useAiData } from '@/components/ai-runner/ui';
import { shown, typed } from '@/components/ai-runner/fields';
import { aiRunner, aiErrorText, type Bounds, type PlatformValues } from '@/services/ai-runner.service';

export default function AiRunsPlatformPage() {
  return (
    <AiRunnerPage>
      <div className="space-y-6">
        <PageHeader title="AI Runs platform settings" description="Timings and limits for every workspace. Only platform admins see this page."
          icon={<SlidersHorizontal className="h-6 w-6" />} />
        <Platform />
      </div>
    </AiRunnerPage>
  );
}

type Field = { key: string; label: string; min: number; max: number; def: number; help: string };
type Group = { title: string; intro?: string; group?: 'guard_max'; fields: Field[] };

// Fallback bounds and defaults, as the server checks them (projects/ai-runner R.PLATFORM_BOUNDS / R.PLATFORM_DEFAULTS);
// GET /platform/settings sends its own `bounds` and `defaults`, which win.
const GROUPS: Group[] = [
  {
    title: 'Runner protocol',
    intro: 'Runners follow the heartbeat and claim timings the server sends them. Keep the lease and the online window well above the heartbeat.',
    fields: [
      { key: 'heartbeat_s', label: 'Heartbeat every (seconds)', min: 5, max: 300, def: 15, help: 'How often runners report in.' },
      { key: 'claim_wait_s', label: 'Claim wait (seconds)', min: 1, max: 25, def: 25, help: 'How long a runner asking for work waits for a queued run.' },
      { key: 'lease_s', label: 'Run lease (seconds)', min: 30, max: 3600, def: 60, help: "A run whose runner stops reporting for this long is lost." },
      { key: 'online_s', label: 'Online within (seconds)', min: 10, max: 3600, def: 45, help: 'A runner that reported within this counts as online.' },
    ],
  },
  {
    title: 'Timeouts',
    fields: [
      { key: 'queue_timeout_hours', label: 'Queued run timeout (hours)', min: 1, max: 720, def: 24, help: 'A run no runner claims in this time fails.' },
      { key: 'approval_timeout_hours', label: 'Approval timeout (hours)', min: 1, max: 720, def: 72, help: 'A run nobody approves in this time is cancelled.' },
    ],
  },
  {
    title: 'Per-run limits',
    fields: [
      { key: 'max_events_per_run', label: 'Log events per run', min: 100, max: 1_000_000, def: 20_000, help: 'After this, the run log is truncated.' },
      { key: 'max_queued_followups', label: 'Waiting follow-ups per run', min: 1, max: 1000, def: 50, help: 'Messages waiting for the agent; more are refused.' },
      { key: 'max_requests_per_run', label: 'Permission requests per run', min: 10, max: 10_000, def: 500, help: 'After this, requests are denied automatically.' },
      {
        key: 'max_tracked_per_heartbeat_cap', label: 'New tracked tasks per heartbeat, at most', min: 1, max: 1000, def: 100,
        help: "The highest a workspace may set for New tasks per heartbeat.",
      },
    ],
  },
  {
    title: 'Highest values a workspace may set',
    intro: 'Upper bounds for AI run settings. A workspace with a higher value is held to this.',
    group: 'guard_max',
    fields: [
      { key: 'max_open_runs_per_user', label: 'Max open runs per person', min: 1, max: 10_000, def: 100, help: '' },
      { key: 'max_open_runs_per_workspace', label: 'Max open runs in a workspace', min: 1, max: 100_000, def: 1000, help: '' },
      { key: 'daily_token_limit', label: 'Daily token limit', min: 1, max: 2_000_000_000, def: 1_000_000_000, help: '' },
      { key: 'retention_days', label: 'Keep run logs (days)', min: 30, max: 36_500, def: 3650, help: '' },
      { key: 'max_run_minutes', label: 'Max run minutes', min: 1, max: 10_080, def: 1440, help: '' },
    ],
  },
];

const n = (v: number) => v.toLocaleString('en-GB');
/** obj[key], or obj[group][key] for a grouped field. */
function at<T>(obj: Record<string, unknown> | undefined, g: Group, key: string): T | undefined {
  const o = g.group ? obj?.[g.group] : obj;
  return o && typeof o === 'object' ? ((o as Record<string, unknown>)[key] as T) : undefined;
}

function Platform() {
  const loaded = useAiData(() => aiRunner.getPlatformSettings(), []);
  const [v, setV] = useState<PlatformValues | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => { if (loaded.data) setV(loaded.data.values); }, [loaded.data]);

  if (loaded.error?.status === 403) {
    return (
      <div className="flex items-center gap-2 rounded-lg bg-warning-500/10 p-3 text-sm text-warning-700">
        <Lock className="h-4 w-4" aria-hidden /> Only platform admins can see and change these settings.
      </div>
    );
  }
  if (!v || !loaded.data) return loaded.error ? <ErrorNote error={loaded.error} product={PRODUCT} /> : <Spinner />;
  const meta = loaded.data;
  // The server's bounds and defaults when it sends them; this page's copy otherwise.
  const limits = (g: Group, f: Field) => {
    const b = at<Bounds>(meta.bounds, g, f.key);
    const def = at<number>(meta.defaults, g, f.key);
    return { min: b?.min ?? f.min, max: b?.max ?? f.max, def: typeof def === 'number' ? def : f.def };
  };
  const value = (g: Group, f: Field) => {
    const x = at<number>(v, g, f.key);
    return typeof x === 'number' ? x : undefined;
  };
  const set = (g: Group, f: Field, x: number) => setV(g.group
    ? { ...v, [g.group]: { ...(typeof v[g.group] === 'object' ? v[g.group] as Record<string, number> : {}), [f.key]: x } }
    : { ...v, [f.key]: x });

  async function save(e: React.FormEvent) {
    e.preventDefault();
    if (!v) return;
    // Only the fields on this page (the server keeps the rest).
    const body: PlatformValues = {};
    for (const g of GROUPS) {
      for (const f of g.fields) {
        const x = value(g, f);
        if (x === undefined) continue;
        if (g.group) body[g.group] = { ...(body[g.group] as Record<string, number> | undefined), [f.key]: x };
        else body[f.key] = x;
      }
    }
    setBusy(true);
    try {
      setV((await aiRunner.savePlatformSettings(body)).values);
      toast.success('Platform settings saved. Every server uses them within a minute.');
    } catch (err) {
      toast.error(aiErrorText(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Card>
      <form onSubmit={save} className="space-y-6">
        <p className="text-sm text-secondary-600">
          These apply to every workspace on this platform. Workspaces set their own AI run settings within the bounds below.
        </p>
        {GROUPS.map((g) => (
          <fieldset key={g.title} className="min-w-0 space-y-3 border-t border-secondary-200 pt-4 first-of-type:border-t-0 first-of-type:pt-0">
            <legend className="sr-only">{g.title}</legend>
            <h2 className="text-sm font-semibold text-secondary-800" aria-hidden>{g.title}</h2>
            {g.intro && <p className="text-xs text-secondary-500">{g.intro}</p>}
            <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
              {g.fields.map((f) => {
                const l = limits(g, f);
                return (
                  <Input key={f.key} id={`air-p-${g.group ? `${g.group}-` : ''}${f.key}`} label={f.label} type="number" required
                    min={l.min} max={l.max} step={1} value={shown(value(g, f))} placeholder={String(l.def)}
                    onChange={(e) => set(g, f, typed(e.target.value))}
                    helperText={`${f.help ? `${f.help} ` : ''}${n(l.min)}–${n(l.max)}, default ${n(l.def)}.`} />
                );
              })}
            </div>
          </fieldset>
        ))}
        <div className="flex justify-end">
          <Button type="submit" isLoading={busy}>Save platform settings</Button>
        </div>
      </form>
    </Card>
  );
}

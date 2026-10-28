'use client';

/**
 * AI Runs building blocks: the page guard (plugin off / no access, like PaPage), the
 * "is the plugin on here" probe, status badges (text + colour) and small formatters.
 */
import React, { useCallback, useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import { Copy, Lock, Power } from 'lucide-react';
import toast from 'react-hot-toast';
import apiClient from '@/lib/api-client';
import { Badge, Button, Card } from '@/components/ui';
import { Spinner } from '@/components/property-deals/ui';
import { usePermissions } from '@/contexts/PermissionsContext';
import { useNamespaceStore } from '@/store/namespace.store';
import {
  aiRunner, aiError, type AiError, type RateLimit, type Run, type RunRequest, type RunStatus, type RunnerProfile,
  type RunnerStatus,
} from '@/services/ai-runner.service';

export const BASE = '/dashboard/ai-runner';
export const PRODUCT = 'AI Runs';

/** §28: a built-in run's "folder" is a GitHub repository ("github:owner/name") or none; a machine run's is a path. */
export const isRepoRef = (path?: string | null) => path === 'none' || !!path?.startsWith('github:');
export const repoText = (path?: string | null) =>
  path === 'none' ? 'No repository' : path?.startsWith('github:') ? `GitHub ${path.slice(7)}` : path || '—';

// Plugin on/off per workspace, probed at most once a minute. Every plugin route answers
// 404 (PLUGIN_DISABLED, or no route when the plugin isn't deployed) before it checks the role,
// so a 403 still means "on".
const onCache: Record<string, { on: boolean; at: number }> = {};
const inflight: Record<string, Promise<boolean | undefined>> = {};
const fresh = (c?: { at: number }) => !!c && Date.now() - c.at < 60_000;

function probe(ns: string): Promise<boolean | undefined> {
  inflight[ns] ??= aiRunner.listRuns({ per_page: 1 }).then(
    () => true,
    (e) => {
      const s = aiError(e).status;
      // No answer: unknown (callers treat it as on, the page's own requests then say why); ask again next time.
      return s === 0 ? undefined : s !== 404;
    },
  ).then((on) => {
    if (on !== undefined) onCache[ns] = { on, at: Date.now() };
    delete inflight[ns];
    return on;
  });
  return inflight[ns];
}

/** On (true), off (false) or not known yet (undefined). `enabled = false` skips the probe. */
export function useAiRunnerOn(enabled = true): boolean | undefined {
  const ns = useNamespaceStore((s) => s.currentNamespace?.uuid || 'default');
  const [probed, setProbed] = useState<{ ns: string; on: boolean } | null>(null);
  useEffect(() => {
    if (!enabled || fresh(onCache[ns])) return;
    let live = true;
    probe(ns).then((on) => { if (live) setProbed({ ns, on: on !== false }); });
    return () => { live = false; };
  }, [ns, enabled]);
  if (probed?.ns === ns) return probed.on;
  return fresh(onCache[ns]) ? onCache[ns].on : undefined;
}

/**
 * Load something with refresh() and optional polling (ms) that pauses while the tab is hidden.
 * Keeps old data while refreshing; only the latest request wins. Errors are readable (aiError).
 */
export function useAiData<T>(loader: () => Promise<T>, deps: unknown[], pollMs?: number) {
  const [data, setData] = useState<T>();
  const [error, setError] = useState<AiError>();
  const [loading, setLoading] = useState(true);
  const loaderRef = useRef(loader);
  loaderRef.current = loader;
  const seq = useRef(0);
  const refresh = useCallback(async () => {
    const id = ++seq.current;
    try {
      const v = await loaderRef.current();
      if (id === seq.current) { setData(v); setError(undefined); }
    } catch (e) {
      if (id === seq.current) setError(aiError(e));
    } finally {
      if (id === seq.current) setLoading(false);
    }
  }, []);
  useEffect(() => {
    setLoading(true);
    refresh();
    const t = pollMs ? setInterval(() => { if (document.visibilityState === 'visible') refresh(); }, pollMs) : undefined;
    return () => {
      if (t) clearInterval(t);
      seq.current += 1; // inputs changed or unmounted: drop what's still in flight
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, pollMs]);
  return { data, error, loading, refresh };
}

export function NoAccess({ what = 'this page' }: { what?: string }) {
  return (
    <div className="mt-6 flex items-center gap-2 rounded-lg bg-warning-500/10 p-3 text-sm text-warning-700">
      <Lock className="h-4 w-4" aria-hidden /> You don&apos;t have access to {what}. Ask a workspace admin for an {PRODUCT} role.
    </div>
  );
}

/** Wraps every AI Runs page: the plugin must be on here and, when `module` is given, the user must hold it. */
export function AiRunnerPage({ module, action, children }: {
  module?: 'ai_runs' | 'ai_runners' | 'ai_runs_settings';
  action?: 'read' | 'create' | 'manage';
  children: React.ReactNode;
}) {
  const { isLoading, hasPermission, canAccess } = usePermissions();
  const on = useAiRunnerOn();
  if (isLoading || on === undefined) return <Spinner />;
  if (!on) {
    return (
      <Card className="mx-auto mt-10 max-w-xl text-center">
        <Power className="mx-auto mb-3 h-8 w-8 text-secondary-400" aria-hidden />
        <h2 className="text-lg font-semibold text-secondary-900">{PRODUCT} is switched off</h2>
        <p className="mt-1 text-sm text-secondary-500">
          {canAccess('namespace') ? (
            <>Switch it on under <Link className="text-primary-600 underline" href="/dashboard/namespace/plugins">Workspace → Plugins</Link>.</>
          ) : (
            'Ask a workspace admin to switch it on for this workspace.'
          )}
        </p>
      </Card>
    );
  }
  if (module && !(action ? hasPermission(module, action) : canAccess(module))) return <NoAccess />;
  return <>{children}</>;
}

const RUN_STATUS: Record<RunStatus, { label: string; variant: 'default' | 'success' | 'warning' | 'error' | 'info' | 'secondary' }> = {
  pending_approval: { label: 'Needs approval', variant: 'warning' },
  queued: { label: 'Queued', variant: 'default' },
  claimed: { label: 'Claimed', variant: 'info' },
  starting: { label: 'Starting', variant: 'info' },
  running: { label: 'Running', variant: 'info' },
  waiting_permission: { label: 'Waiting for permission', variant: 'warning' },
  needs_input: { label: 'Needs input', variant: 'warning' },
  cancelling: { label: 'Cancelling', variant: 'warning' },
  succeeded: { label: 'Succeeded', variant: 'success' },
  failed: { label: 'Failed', variant: 'error' },
  cancelled: { label: 'Cancelled', variant: 'secondary' },
  lost: { label: 'Lost', variant: 'error' },
};

export function RunStatusBadge({ status }: { status: string }) {
  const s = RUN_STATUS[status as RunStatus] || { label: status, variant: 'default' as const };
  return <Badge size="sm" variant={s.variant}>{s.label}</Badge>;
}
export const RUN_STATUSES = Object.keys(RUN_STATUS) as RunStatus[];
export const runStatusLabel = (s: string) => RUN_STATUS[s as RunStatus]?.label || s;

const RUNNER_STATUS: Record<RunnerStatus, { label: string; variant: 'success' | 'secondary' | 'warning' | 'error' }> = {
  online: { label: 'Online', variant: 'success' },
  offline: { label: 'Offline', variant: 'secondary' },
  paused: { label: 'Paused', variant: 'warning' },
  revoked: { label: 'Revoked', variant: 'error' },
};
export function RunnerStatusBadge({ status }: { status: string }) {
  const s = RUNNER_STATUS[status as RunnerStatus] || { label: status, variant: 'secondary' as const };
  return <Badge size="sm" variant={s.variant}>{s.label}</Badge>;
}

export const OUTPUT_MODES: { value: 'pull_request' | 'branch' | 'local'; label: string }[] = [
  { value: 'pull_request', label: 'Pull request' },
  { value: 'branch', label: 'Push a branch' },
  { value: 'local', label: 'Local commit only' },
];
export const outputModeLabel = (m?: string | null) => OUTPUT_MODES.find((o) => o.value === m)?.label || m || '—';

/** A timestamp from the API (ISO, Postgres "YYYY-MM-DD hh:mm:ss" in UTC, or epoch seconds / ms) as a Date. */
export function toDate(v?: string | number | null): Date | null {
  if (!v) return null;
  if (typeof v === 'number' || /^\d+$/.test(v)) {
    const n = Number(v);
    return new Date(n < 1e12 ? n * 1000 : n);
  }
  let s = v.includes('T') ? v : v.replace(' ', 'T');
  if (!/([zZ]|[+-]\d\d(:?\d\d)?)$/.test(s)) s += 'Z';
  s = s.replace(/(T[\d:.]+[+-]\d\d)(\d\d)?$/, (_, t: string, m?: string) => `${t}:${m || '00'}`);
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? null : d;
}
export function when(v?: string | number | null): string {
  const d = toDate(v);
  return d ? d.toLocaleString('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }) : '—';
}
export function ago(v?: string | null): string {
  const d = toDate(v);
  if (!d) return 'never';
  const s = Math.max(0, Math.round((Date.now() - d.getTime()) / 1000));
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  if (s < 86400) return `${Math.round(s / 3600)}h ago`;
  return `${Math.round(s / 86400)}d ago`;
}
/** 75 → "1m 15s", 3900 → "1h 5m". */
export function elapsed(seconds: number): string {
  const s = Math.max(0, Math.round(seconds));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  return h ? `${h}h ${m}m` : m ? `${m}m ${s % 60}s` : `${s}s`;
}
/** Elapsed time of a run: started → finished, or → now while it runs. */
export function duration(run: Pick<Run, 'started_at' | 'finished_at'>): string {
  const a = toDate(run.started_at);
  if (!a) return '—';
  const b = toDate(run.finished_at) || new Date();
  return elapsed((b.getTime() - a.getTime()) / 1000);
}

/** The fields a run view needs, from whichever shape the API sent (see Run in the service). */
export function runView(run: Run) {
  const t = run.task || run.task_snapshot || {};
  const project = run.project_uuid || t.project_uuid;
  const number = t.task_number ?? t.number;
  return {
    taskLabel: `${number != null ? `#${number} ` : ''}${t.title || 'Task'}`,
    taskHref: project ? `/dashboard/projects/${project}/tasks/${run.task_uuid}` : null,
    requester: run.requester?.name || run.requested_by_name || run.requester?.email || '—',
    requesterUuid: run.requester?.uuid || run.requested_by || null,
    runner: run.runner?.name || run.runner_name || '—',
    profile: run.model ? `${run.profile} · ${run.model}` : run.profile,
  };
}

const compactFmt = new Intl.NumberFormat('en-GB', { notation: 'compact', maximumFractionDigits: 1 });
/** 1234 → "1.2K". */
export const compact = (n?: number | null) => compactFmt.format(Number(n) || 0);
/** Claude's own estimate in US dollars (also on a subscription, where nothing is billed per token). */
export function cost(n?: number | string | null): string {
  const v = Number(n) || 0;
  return `$${v > 0 && v < 0.01 ? v.toFixed(4) : v.toFixed(2)}`;
}

const LIMIT_NAMES: Record<string, string> = {
  five_hour: '5-hour', seven_day: '7-day', seven_day_opus: '7-day Opus', seven_day_sonnet: '7-day Sonnet',
};
/** "53% of the 7-day limit used, resets 14 Oct, 09:00" from a profile's rate_limit; null when there is none. */
export function rateLimitText(rl?: RateLimit | null): string | null {
  if (!rl || (rl.utilization == null && !rl.status)) return null;
  const name = `${LIMIT_NAMES[rl.type || ''] || rl.type?.replace(/_/g, ' ') || 'usage'} limit`;
  const u = rl.utilization;
  const used = rl.status === 'rejected'
    ? `${name} reached`
    : typeof u === 'number' ? `${Math.round(u <= 1 ? u * 100 : u)}% of the ${name} used` : `${name}: ${rl.status}`;
  return toDate(rl.resets_at) ? `${used}, resets ${when(rl.resets_at)}` : used;
}

/** A runner's agent profiles: name, health (§24.3: a logged-out or locked agent takes no work) and plan usage. */
export function ProfileList({ profiles }: { profiles?: RunnerProfile[] | null }) {
  if (!profiles?.length) return <span className="text-secondary-400">—</span>;
  return (
    <ul className="space-y-1">
      {profiles.map((p) => {
        const limit = rateLimitText(p.rate_limit);
        return (
          <li key={p.key}>
            {p.label || p.key}{' '}
            {p.available === false ? (
              <span className="text-xs font-medium text-error-600">
                Unavailable{p.unavailable_reason ? ` — ${p.unavailable_reason}` : ''}
              </span>
            ) : (
              <span className="text-xs text-success-700">Available</span>
            )}
            {limit && <span className="block text-xs text-secondary-500">{limit}</span>}
          </li>
        );
      })}
    </ul>
  );
}

/** The command, file or other input a permission request is about, for display. */
export function requestTarget(r: Pick<RunRequest, 'input' | 'input_summary'>): { label: string; value: string } | null {
  const i = r.input && typeof r.input === 'object' && !Array.isArray(r.input) ? r.input : null;
  if (typeof i?.command === 'string') return { label: 'Command', value: i.command };
  if (typeof i?.file_path === 'string') return { label: 'File', value: i.file_path };
  if (typeof i?.path === 'string') return { label: 'Path', value: i.path };
  if (typeof i?.url === 'string') return { label: 'URL', value: i.url };
  if (typeof r.input === 'string' && r.input) return { label: 'Input', value: r.input };
  if (r.input_summary) return { label: 'Input', value: r.input_summary };
  if (i && Object.keys(i).length) return { label: 'Input', value: JSON.stringify(i) };
  return null;
}

/** What the agent wants to do: tool, command or file, the path it touches and its own description. */
export function RequestWants({ r }: { r: RunRequest }) {
  const t = requestTarget(r);
  const rows: [string, React.ReactNode][] = [['Tool', <span key="t" className="font-medium">{r.tool}</span>]];
  if (t) rows.push([t.label, <code key="v" className="block max-h-40 overflow-auto whitespace-pre-wrap break-all rounded bg-secondary-100 px-2 py-1 font-mono text-xs text-secondary-900">{t.value}</code>]);
  if (r.blocked_path && r.blocked_path !== t?.value) rows.push(['Path', <code key="p" className="break-all font-mono text-xs">{r.blocked_path}</code>]);
  if (r.description) rows.push(['Description', r.description]);
  return (
    <dl className="grid gap-x-4 gap-y-1.5 text-sm sm:grid-cols-[7rem_minmax(0,1fr)]">
      {rows.map(([k, v], i) => (
        <React.Fragment key={i}>
          <dt className="text-xs font-medium uppercase tracking-wide text-secondary-500 sm:pt-0.5">{k}</dt>
          <dd className="min-w-0 text-secondary-900">{v}</dd>
        </React.Fragment>
      ))}
    </dl>
  );
}

/** A pull request link, or the short commit when there is no PR. */
export function RunResult({ run }: { run: Pick<Run, 'pr_url' | 'commit_sha'> }) {
  if (run.pr_url && /^https?:\/\//.test(run.pr_url)) {
    return <a href={run.pr_url} target="_blank" rel="noreferrer" className="text-primary-600 underline">Pull request</a>;
  }
  if (run.commit_sha) return <span className="font-mono text-xs">{run.commit_sha.slice(0, 10)}</span>;
  return <span className="text-secondary-400">—</span>;
}

/** This API's public address, as the browser reaches it (for config a machine needs). */
export function opsapiUrl(): string {
  const base = apiClient.defaults.baseURL || '';
  return /^https?:\/\//.test(base) ? base.replace(/\/$/, '') : `${window.location.origin}${base}`.replace(/\/$/, '');
}

export function copy(text: string, what: string) {
  navigator.clipboard.writeText(text).then(() => toast.success(`${what} copied`), () => toast.error('Could not copy'));
}

/** A block of text to paste somewhere else (a token, a config file, a command), with a Copy button. */
export function CopyBlock({ text, what, testId }: { text: string; what: string; testId?: string }) {
  return (
    <div className="relative">
      <pre data-testid={testId} className="overflow-x-auto whitespace-pre rounded-lg bg-secondary-900 p-3 pr-24 font-mono text-xs text-secondary-100">{text}</pre>
      <Button size="sm" variant="ghost" className="absolute right-1.5 top-1.5 bg-surface/90" onClick={() => copy(text, what)}
        leftIcon={<Copy className="h-3.5 w-3.5" aria-hidden />} aria-label={`Copy ${what.toLowerCase()}`}>
        Copy
      </Button>
    </div>
  );
}

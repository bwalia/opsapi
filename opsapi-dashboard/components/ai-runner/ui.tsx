'use client';

/**
 * AI Runs building blocks: the page guard (plugin off / no access, like PaPage), the
 * "is the plugin on here" probe, status badges (text + colour) and small formatters.
 */
import React, { useCallback, useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import { Lock, Power } from 'lucide-react';
import { Badge, Card } from '@/components/ui';
import { Spinner } from '@/components/property-deals/ui';
import { usePermissions } from '@/contexts/PermissionsContext';
import { useNamespaceStore } from '@/store/namespace.store';
import { aiRunner, aiError, type AiError, type Run, type RunStatus, type RunnerStatus } from '@/services/ai-runner.service';

export const BASE = '/dashboard/ai-runner';
export const PRODUCT = 'AI Runs';

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
  queued: { label: 'Queued', variant: 'default' },
  claimed: { label: 'Claimed', variant: 'info' },
  starting: { label: 'Starting', variant: 'info' },
  running: { label: 'Running', variant: 'info' },
  waiting_permission: { label: 'Waiting for approval', variant: 'warning' },
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

/** A timestamp from the API (ISO, or Postgres "YYYY-MM-DD hh:mm:ss" in UTC) as a Date. */
export function toDate(v?: string | null): Date | null {
  if (!v) return null;
  let s = v.includes('T') ? v : v.replace(' ', 'T');
  if (!/([zZ]|[+-]\d\d(:?\d\d)?)$/.test(s)) s += 'Z';
  s = s.replace(/(T[\d:.]+[+-]\d\d)(\d\d)?$/, (_, t: string, m?: string) => `${t}:${m || '00'}`);
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? null : d;
}
export function when(v?: string | null): string {
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
/** Elapsed time of a run: started → finished, or → now while it runs. */
export function duration(run: Pick<Run, 'started_at' | 'finished_at'>): string {
  const a = toDate(run.started_at);
  if (!a) return '—';
  const b = toDate(run.finished_at) || new Date();
  const s = Math.max(0, Math.round((b.getTime() - a.getTime()) / 1000));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  return h ? `${h}h ${m}m` : m ? `${m}m ${s % 60}s` : `${s}s`;
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

/** A pull request link, or the short commit when there is no PR. */
export function RunResult({ run }: { run: Pick<Run, 'pr_url' | 'commit_sha'> }) {
  if (run.pr_url && /^https?:\/\//.test(run.pr_url)) {
    return <a href={run.pr_url} target="_blank" rel="noreferrer" className="text-primary-600 underline">Pull request</a>;
  }
  if (run.commit_sha) return <span className="font-mono text-xs">{run.commit_sha.slice(0, 10)}</span>;
  return <span className="text-secondary-400">—</span>;
}

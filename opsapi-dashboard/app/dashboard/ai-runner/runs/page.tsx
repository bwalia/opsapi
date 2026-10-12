'use client';

/**
 * AI Runs — every run the user may see (own; all with ai_runs.manage), live: polls every 10 s while the tab is visible.
 * On top, "Waiting on you": permission requests and start approvals the user may decide, with quick actions.
 */
import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import { Bot, Hand, RefreshCw } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Badge, Button, Pagination, Select, Table } from '@/components/ui';
import { ErrorNote } from '@/components/property-deals/ui';
import {
  AiRunnerPage, useAiData, BASE, PRODUCT, RUN_STATUSES, RunResult, RunStatusBadge, ago, compact, duration, requestTarget,
  runStatusLabel, runView, when,
} from '@/components/ai-runner/ui';
import { aiRunner, aiErrorText, type Run, type Runner, type Waiting, type WaitingRequest } from '@/services/ai-runner.service';

const PER_PAGE = 20;

export default function AiRunsPage() {
  return (
    <AiRunnerPage module="ai_runs">
      <Runs />
    </AiRunnerPage>
  );
}

/** The run a waiting request belongs to, as far as the request carries it (for runView). */
const requestRun = (r: WaitingRequest) => ({
  ...r.run,
  uuid: r.run_uuid,
  task_uuid: r.run?.task_uuid || r.task?.uuid || '',
  project_uuid: r.project_uuid || r.run?.project_uuid || r.task?.project_uuid,
  task: r.task || r.run?.task || (r.task_title ? { title: r.task_title, task_number: r.task_number ?? undefined } : null),
  task_snapshot: r.task_snapshot || r.run?.task_snapshot,
}) as Run;

function WaitingOnYou({ waiting, onChanged }: { waiting: Waiting; onChanged: () => void }) {
  const [busy, setBusy] = useState<string | null>(null);
  const n = waiting.requests.length + waiting.approvals.length;
  if (!n) return null;

  async function go(key: string, fn: () => Promise<unknown>, ok: string) {
    setBusy(key);
    try {
      await fn();
      toast.success(ok);
    } catch (e) {
      toast.error(aiErrorText(e));
    } finally {
      setBusy(null);
      onChanged();
    }
  }
  const open = (runUuid: string, label: string) => (
    <Link href={`${BASE}/runs/${runUuid}`} className="text-sm font-medium text-primary-600 hover:underline" aria-label={`Open the run of ${label}`}>
      Open run
    </Link>
  );

  return (
    <section aria-labelledby="air-waiting-title" className="rounded-xl border border-warning-300 bg-warning-500/10 p-4">
      <h2 id="air-waiting-title" className="mb-2 flex items-center gap-2 font-semibold text-warning-800">
        <Hand className="h-5 w-5" aria-hidden /> Waiting on you <span className="font-normal">({n})</span>
      </h2>
      <ul aria-live="polite" className="divide-y divide-warning-500/20">
        {waiting.requests.map((r) => {
          const label = runView(requestRun(r)).taskLabel;
          const t = requestTarget(r);
          return (
            <li key={r.uuid} className="flex flex-wrap items-center gap-x-4 gap-y-2 py-2">
              <Badge size="sm" variant="warning">Permission</Badge>
              <div className="min-w-0 flex-1 text-sm">
                <div className="font-medium text-secondary-900">{label}</div>
                <div className="truncate text-xs text-secondary-600" title={t?.value}>
                  {r.tool}{t && <> · <code className="font-mono">{t.value}</code></>}
                  {r.created_at && <> · asked {ago(r.created_at)}</>}
                </div>
              </div>
              <div className="flex items-center gap-2">
                <Button size="sm" isLoading={busy === `allow:${r.uuid}`} disabled={!!busy} aria-label={`Allow ${r.tool} for ${label}`}
                  onClick={() => go(`allow:${r.uuid}`, () => aiRunner.decide(r.run_uuid, r.uuid, 'allow'), 'Allowed')}>Allow</Button>
                <Button size="sm" variant="danger" isLoading={busy === `deny:${r.uuid}`} disabled={!!busy} aria-label={`Deny ${r.tool} for ${label}`}
                  onClick={() => go(`deny:${r.uuid}`, () => aiRunner.decide(r.run_uuid, r.uuid, 'deny'), 'Denied')}>Deny</Button>
                {open(r.run_uuid, label)}
              </div>
            </li>
          );
        })}
        {waiting.approvals.map((run) => {
          const v = runView(run);
          return (
            <li key={run.uuid} className="flex flex-wrap items-center gap-x-4 gap-y-2 py-2">
              <Badge size="sm" variant="warning">Start approval</Badge>
              <div className="min-w-0 flex-1 text-sm">
                <div className="font-medium text-secondary-900">{v.taskLabel}</div>
                <div className="truncate text-xs text-secondary-600">
                  by {v.requester} · {v.profile} on {v.runner} · {ago(run.created_at)}
                </div>
              </div>
              <div className="flex items-center gap-2">
                <Button size="sm" isLoading={busy === `approve:${run.uuid}`} disabled={!!busy} aria-label={`Approve the run of ${v.taskLabel}`}
                  onClick={() => go(`approve:${run.uuid}`, () => aiRunner.approve(run.uuid), 'Approved: the run is queued')}>Approve</Button>
                <Button size="sm" variant="danger" isLoading={busy === `reject:${run.uuid}`} disabled={!!busy} aria-label={`Reject the run of ${v.taskLabel}`}
                  onClick={() => go(`reject:${run.uuid}`, () => aiRunner.reject(run.uuid), 'Rejected: the run is cancelled')}>Reject</Button>
                {open(run.uuid, v.taskLabel)}
              </div>
            </li>
          );
        })}
      </ul>
    </section>
  );
}

function Runs() {
  const [status, setStatus] = useState('');
  const [mine, setMine] = useState(false);
  const [runnerUuid, setRunnerUuid] = useState('');
  const [page, setPage] = useState(1);
  const [runners, setRunners] = useState<Runner[]>([]);
  useEffect(() => {
    aiRunner.listRunners().then(setRunners, () => setRunners([])); // needs ai_runs.create: without it, no runner filter
  }, []);

  const runs = useAiData(
    () => aiRunner.listRuns({ status, mine, runner_uuid: runnerUuid, page, per_page: PER_PAGE }),
    [status, mine, runnerUuid, page],
    10_000,
  );
  const data = runs.data;
  // What waits on the user, refreshed with the list; an error here only hides the panel (the list says why).
  const waiting = useAiData(() => aiRunner.waiting(), [], 10_000);
  const refreshAll = () => { runs.refresh(); waiting.refresh(); };

  // Kept to seven compact columns so the table fits a 1280 px screen next to the sidebar.
  const columns = [
    {
      key: 'status', header: 'Status', render: (r: Run) => (
        <span className="block">
          <RunStatusBadge status={r.status} />
          <span className="mt-0.5 block text-xs text-secondary-500">{duration(r)}</span>
          {Number(r.pending_requests) > 0 && (
            <span className="block text-xs font-medium text-warning-700">
              {r.pending_requests} {r.pending_requests === 1 ? 'request' : 'requests'} waiting
            </span>
          )}
        </span>
      ),
    },
    {
      key: 'task', header: 'Task', render: (r: Run) => {
        const v = runView(r);
        return (
          <span className="block min-w-[8rem]">
            {v.taskHref ? <Link href={v.taskHref} className="text-primary-600 hover:underline">{v.taskLabel}</Link> : v.taskLabel}
            <span className="block text-xs text-secondary-500">by {v.requester}</span>
          </span>
        );
      },
    },
    {
      key: 'where', header: 'Runner / folder', render: (r: Run) => {
        const v = runView(r);
        return (
          <span className="block max-w-[13rem] text-xs">
            <span className="block truncate text-sm" title={`${v.runner} · ${v.profile}`}>{v.runner} · {v.profile}</span>
            <span className="block truncate font-mono" title={r.repo_path}>{r.repo_path}</span>
            {r.work_branch && <span className="block truncate font-mono text-secondary-500" title={r.work_branch}>{r.work_branch}</span>}
          </span>
        );
      },
    },
    { key: 'started', header: 'Started', render: (r: Run) => <span className="whitespace-nowrap">{when(r.started_at || r.created_at)}</span> },
    {
      key: 'usage', header: 'Usage', render: (r: Run) => {
        const tokens = (Number(r.tokens_in) || 0) + (Number(r.tokens_out) || 0);
        if (!tokens && !r.turns) return <span className="text-secondary-400">—</span>;
        return (
          <span className="block whitespace-nowrap text-xs" title={`${Number(r.tokens_in) || 0} tokens in, ${Number(r.tokens_out) || 0} out`}>
            <span className="block">{compact(tokens)} tokens</span>
            <span className="block text-secondary-500">{r.turns || 0} {r.turns === 1 ? 'turn' : 'turns'}</span>
          </span>
        );
      },
    },
    { key: 'pr', header: 'Result', render: (r: Run) => <RunResult run={r} /> },
    {
      key: 'open', header: '', render: (r: Run) => (
        <Link href={`${BASE}/runs/${r.uuid}`} className="text-sm font-medium text-primary-600 hover:underline" aria-label={`Open run of ${runView(r).taskLabel}`}>
          Open
        </Link>
      ),
    },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title={PRODUCT}
        description="Tasks handed to an AI coding agent on one of your machines. Updates every 10 seconds."
        icon={<Bot className="h-6 w-6" />}
        actions={<Button variant="outline" leftIcon={<RefreshCw className="h-4 w-4" aria-hidden />} onClick={refreshAll}>Refresh</Button>}
      />
      {waiting.data && <WaitingOnYou waiting={waiting.data} onChanged={refreshAll} />}
      <div className="flex flex-wrap items-end gap-4">
        <div className="w-48">
          <Select id="air-f-status" label="Status" value={status} onChange={(e) => { setStatus(e.target.value); setPage(1); }}>
            <option value="">All</option>
            {RUN_STATUSES.map((s) => <option key={s} value={s}>{runStatusLabel(s)}</option>)}
          </Select>
        </div>
        {runners.length > 0 && (
          <div className="w-56">
            <Select id="air-f-runner" label="Runner" value={runnerUuid} onChange={(e) => { setRunnerUuid(e.target.value); setPage(1); }}>
              <option value="">All runners</option>
              {runners.map((r) => <option key={r.uuid} value={r.uuid}>{r.name}</option>)}
            </Select>
          </div>
        )}
        <label className="flex h-10 items-center gap-2 text-sm text-secondary-700">
          <input type="checkbox" checked={mine} onChange={(e) => { setMine(e.target.checked); setPage(1); }} /> Only mine
        </label>
      </div>
      <ErrorNote error={runs.error} product={PRODUCT} />
      <Table<Run>
        caption="AI runs"
        columns={columns}
        data={data?.items || []}
        keyExtractor={(r) => r.uuid}
        isLoading={runs.loading && !data}
        emptyMessage="No AI runs yet. Open a task and press Start with AI."
      />
      {data && data.totalPages > 1 && (
        <Pagination currentPage={data.page} totalPages={data.totalPages} totalItems={data.total} perPage={PER_PAGE} onPageChange={setPage} />
      )}
    </div>
  );
}

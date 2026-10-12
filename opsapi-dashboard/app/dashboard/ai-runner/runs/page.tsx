'use client';

/** AI Runs — every run the user may see (own; all with ai_runs.manage), live: polls every 10 s while the tab is visible. */
import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import { Bot, RefreshCw } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, Pagination, Select, Table } from '@/components/ui';
import { ErrorNote } from '@/components/property-deals/ui';
import { AiRunnerPage, useAiData, BASE, PRODUCT, RUN_STATUSES, RunResult, RunStatusBadge, duration, runStatusLabel, runView, when } from '@/components/ai-runner/ui';
import { aiRunner, type Run, type Runner } from '@/services/ai-runner.service';

const PER_PAGE = 20;

export default function AiRunsPage() {
  return (
    <AiRunnerPage module="ai_runs">
      <Runs />
    </AiRunnerPage>
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

  const columns = [
    { key: 'status', header: 'Status', render: (r: Run) => <RunStatusBadge status={r.status} /> },
    {
      key: 'task', header: 'Task', render: (r: Run) => {
        const v = runView(r);
        return v.taskHref ? <Link href={v.taskHref} className="text-primary-600 hover:underline">{v.taskLabel}</Link> : v.taskLabel;
      },
    },
    { key: 'requester', header: 'Requested by', render: (r: Run) => runView(r).requester },
    { key: 'runner', header: 'Runner', render: (r: Run) => runView(r).runner },
    { key: 'profile', header: 'Profile', render: (r: Run) => runView(r).profile },
    {
      key: 'repo', header: 'Folder / branch', render: (r: Run) => (
        <span className="block max-w-[16rem] font-mono text-xs">
          <span className="block truncate" title={r.repo_path}>{r.repo_path}</span>
          {r.work_branch && <span className="block truncate text-secondary-500" title={r.work_branch}>{r.work_branch}</span>}
        </span>
      ),
    },
    { key: 'started', header: 'Started', render: (r: Run) => when(r.started_at || r.created_at) },
    { key: 'duration', header: 'Duration', render: (r: Run) => duration(r) },
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
        actions={<Button variant="outline" leftIcon={<RefreshCw className="h-4 w-4" aria-hidden />} onClick={runs.refresh}>Refresh</Button>}
      />
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

'use client';

/**
 * Machines (docs/AI_RUNNER.md §24.4, ai_runners.manage): every runner with its status and each agent profile's
 * health and plan usage, then every session it last reported — runs it manages (linked to the run) and sessions
 * started by hand (linked to their task once tracking created one, §26.4). Refreshes every 15 seconds while the tab
 * is visible.
 */
import React, { useState } from 'react';
import Link from 'next/link';
import { Monitor, RefreshCw } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { Badge, Button, Card, Pagination, Select, Table } from '@/components/ui';
import { ErrorNote } from '@/components/property-deals/ui';
import {
  AiRunnerPage, BASE, PRODUCT, ProfileList, RunnerStatusBadge, ago, useAiData, when,
} from '@/components/ai-runner/ui';
import { aiRunner, type MachineSession, type Runner } from '@/services/ai-runner.service';

const PER_PAGE = 50;
const POLL_MS = 15_000;
// Statuses the server counts as not working on anything (busy=1 hides them).
const IDLE = ['idle', 'done', 'finished', 'stopped', 'exited', 'ended', 'completed', 'closed', 'inactive'];

export default function MachinesPage() {
  return (
    <AiRunnerPage module="ai_runners" action="manage">
      <Machines />
    </AiRunnerPage>
  );
}

const sessionColumns = [
  {
    key: 'session', header: 'Session', render: (s: MachineSession) => (
      <span className="block whitespace-nowrap">
        <span className="block font-medium">{s.tool || '—'}</span>
        <Badge size="sm" variant={IDLE.includes((s.status || '').toLowerCase()) ? 'secondary' : 'info'}>{s.status || 'unknown'}</Badge>
      </span>
    ),
  },
  {
    key: 'where', header: 'Folder / branch', render: (s: MachineSession) => (
      <span className="block max-w-[16rem] text-xs">
        <span className="block truncate font-mono" title={s.cwd || undefined}>{s.cwd || '—'}</span>
        {s.branch && <span className="block truncate font-mono text-secondary-500" title={s.branch}>{s.branch}</span>}
      </span>
    ),
  },
  {
    key: 'run', header: 'Run', render: (s: MachineSession) => {
      if (s.run?.uuid) {
        const label = `${s.run.task_number != null ? `#${s.run.task_number} ` : ''}${s.run.task_title || 'Open run'}`;
        return <Link href={`${BASE}/runs/${s.run.uuid}`} className="block min-w-[8rem] text-primary-600 hover:underline">{label}</Link>;
      }
      const t = s.task; // §26: the task tracking created for a session started by hand
      return (
        <span className="block whitespace-nowrap text-secondary-500">
          {s.managed ? 'Managed run' : 'Started by hand'}
          {t?.uuid && t.project_uuid && (
            <Link href={`/dashboard/projects/${t.project_uuid}/tasks/${t.uuid}`} title={t.title || undefined}
              className="block text-primary-600 hover:underline">
              Task{t.task_number != null ? ` #${t.task_number}` : ''} →
            </Link>
          )}
        </span>
      );
    },
  },
  {
    key: 'prompt', header: 'Prompt', render: (s: MachineSession) => s.prompt_preview
      ? <span className="line-clamp-2 block min-w-[10rem] max-w-[18rem] text-xs text-secondary-600" title={s.prompt_preview}>{s.prompt_preview}</span>
      : <span className="text-secondary-400">—</span>,
  },
  {
    key: 'updated', header: 'Updated', render: (s: MachineSession) => (
      <span className="whitespace-nowrap" title={when(s.updated_at || s.seen_at)}>{ago(s.updated_at || s.seen_at)}</span>
    ),
  },
];

type Machine = Pick<Runner, 'uuid' | 'name' | 'status'> & Partial<Runner>;

function Machines() {
  const [runnerUuid, setRunnerUuid] = useState('');
  const [busy, setBusy] = useState(false);
  const [page, setPage] = useState(1);
  const runners = useAiData(() => aiRunner.listRunners(), [], POLL_MS);
  const sessions = useAiData(
    () => aiRunner.sessions({ runner_uuid: runnerUuid, busy, page, per_page: PER_PAGE }),
    [runnerUuid, busy, page],
    POLL_MS,
  );
  const rows = sessions.data?.items || [];
  const pages = sessions.data?.totalPages || 1;

  // A section per registered runner, plus any runner only the sessions name (e.g. revoked since).
  const machines: Machine[] = [...(runners.data || [])];
  for (const s of rows) {
    if (s.runner?.uuid && !machines.some((m) => m.uuid === s.runner?.uuid)) {
      machines.push({ uuid: s.runner.uuid, name: s.runner.name || 'Runner', status: (s.runner.status || 'offline') as Runner['status'] });
    }
  }
  const shown = runnerUuid ? machines.filter((m) => m.uuid === runnerUuid) : machines;
  const loading = (runners.loading && !runners.data) || (sessions.loading && !sessions.data);
  const refresh = () => { runners.refresh(); sessions.refresh(); };

  return (
    <div className="space-y-6">
      <PageHeader
        title="Machines"
        description="Every runner and every session it reported: AI runs it manages and sessions started by hand. Updates every 15 seconds."
        icon={<Monitor className="h-6 w-6" />}
        actions={<Button variant="outline" leftIcon={<RefreshCw className="h-4 w-4" aria-hidden />} onClick={refresh}>Refresh</Button>}
      />
      <div className="flex flex-wrap items-end gap-4">
        <div className="w-56 max-w-full">
          <Select id="air-m-runner" label="Runner" value={runnerUuid} onChange={(e) => { setRunnerUuid(e.target.value); setPage(1); }}>
            <option value="">All runners</option>
            {machines.map((m) => <option key={m.uuid} value={m.uuid}>{m.name}</option>)}
          </Select>
        </div>
        <label className="flex h-10 items-center gap-2 text-sm text-secondary-700">
          <input type="checkbox" checked={busy} onChange={(e) => { setBusy(e.target.checked); setPage(1); }} /> Busy only
        </label>
      </div>
      <ErrorNote error={sessions.error || runners.error} product={PRODUCT} />

      {!loading && !shown.length && !sessions.error && !runners.error && (
        <Card className="text-center text-sm text-secondary-600">
          No runners yet. Register one under <Link href={`${BASE}/runners`} className="text-primary-600 underline">Runners</Link>,
          then start PromptPilot on that machine.
        </Card>
      )}

      {shown.map((m) => {
        const mine = rows.filter((s) => s.runner?.uuid === m.uuid);
        const machine = [m.host, m.os, m.version && `v${m.version}`].filter(Boolean).join(' · ');
        return (
          <section key={m.uuid} aria-labelledby={`air-m-${m.uuid}`} className="space-y-3" data-testid="air-machine">
            <div className="flex flex-wrap items-start justify-between gap-x-6 gap-y-3 rounded-xl border border-secondary-200 bg-surface p-4">
              <div className="min-w-0">
                <h2 id={`air-m-${m.uuid}`} className="flex flex-wrap items-center gap-2 font-semibold text-secondary-900">
                  <span className="break-all">{m.name}</span> <RunnerStatusBadge status={m.status} />
                </h2>
                <p className="mt-0.5 text-xs text-secondary-500">
                  {machine && <>{machine} · </>}last heartbeat {ago(m.last_heartbeat_at)}
                </p>
              </div>
              <div className="min-w-0 text-sm">
                <ProfileList profiles={m.capabilities?.profiles} />
              </div>
            </div>
            <Table<MachineSession>
              caption={`Sessions on ${m.name}`}
              columns={sessionColumns}
              data={mine}
              keyExtractor={(s) => `${s.key ?? ''}:${s.cwd ?? ''}:${s.updated_at ?? ''}`}
              isLoading={sessions.loading && !sessions.data}
              emptyMessage={pages > 1 ? 'None on this page.' : busy ? 'No busy sessions.' : 'No sessions reported.'}
            />
          </section>
        );
      })}

      {pages > 1 && sessions.data && (
        <Pagination currentPage={sessions.data.page} totalPages={pages} totalItems={sessions.data.total} perPage={PER_PAGE} onPageChange={setPage} />
      )}
    </div>
  );
}

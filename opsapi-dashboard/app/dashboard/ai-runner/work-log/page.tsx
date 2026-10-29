'use client';

/**
 * Work log (docs/AI_RUNNER_WEB_TERMINAL.md §11): every web terminal session — who, when, how long, what they asked the
 * AI, its tokens and cost — with a screen replay on each session's page. People with "Web terminal work logs" see
 * everyone (and a per-person summary); everyone else sees their own.
 */
import React, { useMemo, useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { ClipboardList, RefreshCw } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { Badge, Button, Card, Input, Pagination, Select, Table } from '@/components/ui';
import { ErrorNote } from '@/components/property-deals/ui';
import { AiRunnerPage, BASE, PRODUCT, compact, cost, elapsed, useAiData, when } from '@/components/ai-runner/ui';
import { aiRunner, type WorkLogPerson, type WorkLogTab } from '@/services/ai-runner.service';

const PER_PAGE = 50;

export default function WorkLogPage() {
  return (
    <AiRunnerPage module={['ai_runs', 'ai_terminal_worklogs']} action="read">
      <WorkLog />
    </AiRunnerPage>
  );
}

const day = (d: Date) => d.toISOString().slice(0, 10);
const who = (t: Pick<WorkLogTab, 'person_name' | 'person_email' | 'terminal_user'>) =>
  t.person_name || t.person_email || (t.terminal_user ? `${t.terminal_user} (terminal user)` : 'Someone');
const tokens = (t: Pick<WorkLogTab, 'input_tokens' | 'output_tokens' | 'cache_read_tokens' | 'cache_write_tokens'>) =>
  t.input_tokens + t.output_tokens + t.cache_read_tokens + t.cache_write_tokens;

function ending(t: WorkLogTab): string {
  if (t.open) return 'Open';
  return t.end_reason ? `Ended: ${t.end_reason}` : 'Ended';
}

const tabColumns = [
  {
    key: 'when', header: 'Started', render: (t: WorkLogTab) => <span className="whitespace-nowrap">{when(t.opened_at)}</span>,
  },
  { key: 'who', header: 'Person', render: (t: WorkLogTab) => <span className="whitespace-nowrap font-medium">{who(t)}</span> },
  {
    key: 'task', header: 'Task', render: (t: WorkLogTab) => t.task_uuid
      ? <span className="block max-w-[12rem] truncate" title={t.task_title || ''}>#{t.task_number} {t.task_title}</span>
      : <span className="text-secondary-400">—</span>,
  },
  {
    key: 'where', header: 'Folder', render: (t: WorkLogTab) => (
      <span className="block max-w-[10rem] truncate font-mono text-xs" title={t.cwd || ''}>{t.cwd || '—'}</span>
    ),
  },
  {
    key: 'time', header: 'Time', render: (t: WorkLogTab) => (
      <span className="whitespace-nowrap" title={`${elapsed(t.duration_secs)} open`}>{elapsed(t.active_secs)} active</span>
    ),
  },
  { key: 'prompts', header: 'Prompts', render: (t: WorkLogTab) => t.prompts },
  { key: 'tokens', header: 'Tokens', render: (t: WorkLogTab) => compact(tokens(t)) },
  { key: 'cost', header: 'Cost', render: (t: WorkLogTab) => cost(t.cost_usd) },
  {
    key: 'state', header: '', render: (t: WorkLogTab) => (
      <Badge size="sm" variant={t.open ? 'success' : 'secondary'}>{ending(t)}</Badge>
    ),
  },
];

const personColumns = [
  {
    key: 'who', header: 'Person', render: (p: WorkLogPerson) => (
      <span className="font-medium">{p.person_name || p.person_email || `${p.terminal_user || '?'} (terminal user)`}</span>
    ),
  },
  { key: 'tabs', header: 'Sessions', render: (p: WorkLogPerson) => p.tabs },
  { key: 'active', header: 'Active', render: (p: WorkLogPerson) => elapsed(p.active_secs) },
  { key: 'prompts', header: 'Prompts', render: (p: WorkLogPerson) => p.prompts },
  { key: 'tokens', header: 'Tokens', render: (p: WorkLogPerson) => compact(p.input_tokens + p.output_tokens) },
  { key: 'cost', header: 'Cost', render: (p: WorkLogPerson) => cost(p.cost_usd) },
  {
    key: 'code', header: 'Code', render: (p: WorkLogPerson) => (
      <span className="whitespace-nowrap">+{p.lines_added} −{p.lines_removed} · {p.commits} commits · {p.pull_requests} PRs</span>
    ),
  },
  { key: 'seen', header: 'Last active', render: (p: WorkLogPerson) => <span className="whitespace-nowrap">{when(p.last_seen)}</span> },
];

function WorkLog() {
  const router = useRouter();
  const [from, setFrom] = useState(() => day(new Date(Date.now() - 6 * 86400000)));
  const [to, setTo] = useState(() => day(new Date()));
  const [person, setPerson] = useState('');
  const [page, setPage] = useState(1);
  const tabs = useAiData(
    () => aiRunner.workLog({ from, to, user_uuid: person || undefined, page, per_page: PER_PAGE }),
    [from, to, person, page],
  );
  const everyone = tabs.data?.seesEveryone === true;
  const people = useAiData(() => (everyone ? aiRunner.workLogPeople({ from, to }) : Promise.resolve([])), [everyone, from, to]);
  const personOptions = useMemo(() => [
    { value: '', label: 'Everyone' },
    ...(people.data || []).filter((p) => p.user_uuid).map((p) => ({
      value: p.user_uuid as string, label: p.person_name || p.person_email || (p.user_uuid as string),
    })),
  ], [people.data]);
  const totals = (people.data || []).reduce(
    (acc, p) => ({ cost: acc.cost + p.cost_usd, active: acc.active + p.active_secs, prompts: acc.prompts + p.prompts }),
    { cost: 0, active: 0, prompts: 0 },
  );

  return (
    <div className="space-y-5">
      <PageHeader
        title="Work log"
        description={everyone
          ? 'Everything done in your web terminals: who worked when, what they asked the AI, its tokens and cost, and a replay of each session.'
          : 'What is recorded about your web terminal work: your sessions, what you asked the AI, its tokens and cost, and a replay of your screen.'}
        icon={<ClipboardList className="h-5 w-5" />}
        actions={
          <Button variant="ghost" size="sm" onClick={() => { tabs.refresh(); people.refresh(); }} aria-label="Refresh">
            <RefreshCw className="h-4 w-4" />
          </Button>
        }
      />
      <p className="text-xs text-secondary-500">
        Prompts and commands are kept for 90 days and screen replays for 30. Everyone can see their own work log.
      </p>

      <Card className="flex flex-wrap items-end gap-3" data-testid="air-worklog-filters">
        <div className="w-44">
          <Input id="air-wl-from" type="date" label="From" value={from} max={to} onChange={(e) => { setFrom(e.target.value); setPage(1); }} />
        </div>
        <div className="w-44">
          <Input id="air-wl-to" type="date" label="To" value={to} min={from} onChange={(e) => { setTo(e.target.value); setPage(1); }} />
        </div>
        {everyone && (
          <div className="min-w-[14rem]">
            <Select id="air-wl-person" label="Person" value={person} onChange={(e) => { setPerson(e.target.value); setPage(1); }}>
              {personOptions.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
            </Select>
          </div>
        )}
      </Card>

      {everyone && (
        <section aria-labelledby="air-wl-people" className="space-y-2">
          <div className="flex flex-wrap items-baseline justify-between gap-2">
            <h2 id="air-wl-people" className="font-semibold text-secondary-900">People</h2>
            <p className="text-sm text-secondary-500">
              {elapsed(totals.active)} active · {totals.prompts} prompt{totals.prompts === 1 ? '' : 's'} · {cost(totals.cost)} in this period
            </p>
          </div>
          <ErrorNote error={people.error} product={PRODUCT} />
          <Card padding="none">
            <Table
              columns={personColumns}
              data={people.data || []}
              keyExtractor={(p) => p.user_uuid || `terminal:${p.terminal_user}`}
              onRowClick={(p) => { if (p.user_uuid) { setPerson(p.user_uuid); setPage(1); } }}
              isLoading={people.loading}
              emptyMessage="No one used a web terminal in this period."
            />
          </Card>
        </section>
      )}

      <section aria-labelledby="air-wl-sessions" className="space-y-2" data-testid="air-worklog-sessions">
        <h2 id="air-wl-sessions" className="font-semibold text-secondary-900">Sessions</h2>
        <ErrorNote error={tabs.error} product={PRODUCT} />
        <Card padding="none">
          <Table
            columns={tabColumns}
            data={tabs.data?.items || []}
            keyExtractor={(t) => t.uuid}
            onRowClick={(t) => router.push(`${BASE}/work-log/${t.uuid}`)}
            isLoading={tabs.loading}
            emptyMessage="No web terminal sessions in this period."
          />
        </Card>
        {(tabs.data?.totalPages || 0) > 1 && (
          <Pagination
            currentPage={tabs.data?.page || 1}
            totalPages={tabs.data?.totalPages || 1}
            totalItems={tabs.data?.total || 0}
            perPage={PER_PAGE}
            onPageChange={setPage}
          />
        )}
        <p className="text-xs text-secondary-500">
          Open a session for its timeline and screen replay. Sessions started from a task also show on the task&apos;s{' '}
          <Link href="/dashboard/my-tasks" className="underline">AI work panel</Link>.
        </p>
      </section>
    </div>
  );
}

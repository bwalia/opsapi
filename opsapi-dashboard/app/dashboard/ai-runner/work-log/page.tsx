'use client';

/**
 * Work log (docs/AI_RUNNER_WEB_TERMINAL.md §11): who is working in a web terminal right now, and every session —
 * who, when, how long, what they asked the AI, its tokens and cost — with a screen replay on each session's page.
 * People with "Web terminal work logs" see everyone (and a per-person summary); everyone else sees their own.
 * Managers of AI runners can sign someone out from "Now" (Suspend; they resume them under Machines → People).
 */
import React, { useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import toast from 'react-hot-toast';
import { ClipboardList, PauseCircle, RefreshCw, X } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { Badge, Button, Card, Input, Pagination, Select, Table, confirmDialog } from '@/components/ui';
import { ErrorNote } from '@/components/property-deals/ui';
import { AiRunnerPage, BASE, PRODUCT, compact, cost, elapsed, toDate, useAiData, when } from '@/components/ai-runner/ui';
import {
  aiRunner, aiErrorText, type WorkLogLive, type WorkLogPerson, type WorkLogTab,
} from '@/services/ai-runner.service';

const PER_PAGE = 50;
const LIVE_EVERY_MS = 15_000;

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

/** "Typing now", "Idle 5 min", or nothing typed yet. */
function typing(r: WorkLogLive): { text: string; busy: boolean } {
  if (r.idle_secs == null) return { text: 'Nothing typed yet', busy: false };
  if (r.idle_secs < 60) return { text: 'Typing now', busy: true };
  const m = Math.round(r.idle_secs / 60);
  return { text: m < 60 ? `Idle ${m} min` : `Idle ${elapsed(r.idle_secs)}`, busy: false };
}

const sinceOpened = (v?: string | null) => {
  const d = toDate(v);
  return d ? elapsed((Date.now() - d.getTime()) / 1000) : '—';
};

/** Who is working in a terminal right now: refreshed every 15 seconds while the page is visible. */
function LiveNow() {
  const live = useAiData(() => aiRunner.workLogLive(), [], LIVE_EVERY_MS);
  const items = live.data?.items || [];
  const everyone = live.data?.seesEveryone === true;
  const canSuspend = live.data?.canSuspend === true;

  async function suspend(r: WorkLogLive) {
    if (!r.terminal_uuid || !r.key_uuid) return;
    const name = who(r);
    const terminal = r.terminal_name || 'the terminal';
    const ok = await confirmDialog({
      title: `Sign ${name} out of ${terminal} now?`,
      message: 'They can’t sign in again until you resume them (Machines → Web terminals → People).',
      confirmText: 'Suspend',
      danger: true,
    });
    if (!ok) return;
    try {
      await aiRunner.suspendTerminalKey(r.terminal_uuid, r.key_uuid);
      toast.success(`${name} is signed out of ${terminal}. Their terminal closes within a minute.`);
      live.refresh();
    } catch (e) {
      toast.error(aiErrorText(e));
    }
  }

  return (
    <section aria-labelledby="air-wl-now" className="space-y-2" data-testid="air-worklog-now">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 id="air-wl-now" className="font-semibold text-secondary-900">Now</h2>
        <p className="text-xs text-secondary-500">Updates every 15 seconds.</p>
      </div>
      <ErrorNote error={live.error} product={PRODUCT} />
      <Card padding="none">
        {live.loading && !live.data ? (
          <p className="p-4 text-sm text-secondary-500">Looking for open terminals…</p>
        ) : items.length === 0 ? (
          <p className="p-4 text-sm text-secondary-500">
            {everyone ? 'Nobody is working in a terminal right now.' : 'You aren’t working in a terminal right now.'}
          </p>
        ) : (
          <ul className="divide-y divide-secondary-100" data-testid="air-worklog-now-list">
            {items.map((r) => {
              const t = typing(r);
              return (
                <li key={r.uuid} className="flex flex-wrap items-center justify-between gap-3 p-3">
                  <div className="min-w-0 space-y-0.5 text-sm">
                    <p className="flex flex-wrap items-center gap-2">
                      <span className="font-medium text-secondary-900">{who(r)}</span>
                      <span className="text-secondary-500">in {r.terminal_name || 'a web terminal'}</span>
                      <Badge size="sm" variant={t.busy ? 'success' : 'secondary'}>{t.text}</Badge>
                      {r.attached === false && <Badge size="sm" variant="info">Running with nobody watching</Badge>}
                    </p>
                    <p className="text-xs text-secondary-600">
                      {r.task_uuid ? (
                        r.project_uuid ? (
                          <Link href={`/dashboard/projects/${r.project_uuid}/tasks/${r.task_uuid}`} className="underline">
                            #{r.task_number} {r.task_title}
                          </Link>
                        ) : <span>#{r.task_number} {r.task_title}</span>
                      ) : <span>No task</span>}
                      {r.agent ? ` · ${r.agent}` : ''}
                      {` · open for ${sinceOpened(r.opened_at)}`}
                    </p>
                    {r.cwd && (
                      <p className="max-w-[28rem] truncate font-mono text-[11px] text-secondary-500" title={r.cwd}>{r.cwd}</p>
                    )}
                  </div>
                  <div className="flex gap-1">
                    <Link href={`${BASE}/work-log/${r.uuid}`} className="rounded-md px-2 py-1 text-sm text-primary-600 hover:underline">
                      Details
                    </Link>
                    {canSuspend && r.key_uuid && r.terminal_uuid && (
                      <Button size="sm" variant="ghost" leftIcon={<PauseCircle className="h-4 w-4" aria-hidden />}
                        onClick={() => void suspend(r)} data-testid="air-worklog-now-suspend">
                        Suspend
                      </Button>
                    )}
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </Card>
    </section>
  );
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
  const [terminal, setTerminal] = useState('');
  const [state, setState] = useState<'' | 'open' | 'closed'>('');
  const [agent, setAgent] = useState('');
  const [search, setSearch] = useState('');
  const [q, setQ] = useState('');
  // A task's sessions: /dashboard/ai-runner/work-log?task_uuid=… (read once; "Show all" clears it). This only renders
  // in the browser (AiRunnerPage waits for the permissions and the plugin probe first).
  const [task, setTask] = useState(() => (typeof window === 'undefined'
    ? '' : new URLSearchParams(window.location.search).get('task_uuid') || ''));
  const [page, setPage] = useState(1);

  // Search as they type, once they pause.
  useEffect(() => {
    const id = setTimeout(() => { setQ(search.trim()); setPage(1); }, 400);
    return () => clearTimeout(id);
  }, [search]);

  const options = useAiData(() => aiRunner.workLogOptions(), []);
  const tabs = useAiData(
    () => aiRunner.workLog({
      from, to, user_uuid: person || undefined, terminal_uuid: terminal || undefined, state: state || undefined,
      agent: agent || undefined, q: q || undefined, task_uuid: task || undefined, page, per_page: PER_PAGE,
    }),
    [from, to, person, terminal, state, agent, q, task, page],
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
  const taskRow = task ? (tabs.data?.items || []).find((t) => t.task_uuid === task) : undefined;
  const filtered = !!(person || terminal || state || agent || q || task);
  const reset = (fn: () => void) => { fn(); setPage(1); };

  return (
    <div className="space-y-5">
      <PageHeader
        title="Work log"
        description={everyone
          ? 'Who is working in your web terminals now, and everything done in them: who worked when, what they asked the AI, its tokens and cost, and a replay of each session.'
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

      <LiveNow />

      <Card className="flex flex-wrap items-end gap-3" data-testid="air-worklog-filters">
        <div className="w-44">
          <Input id="air-wl-from" type="date" label="From" value={from} max={to} onChange={(e) => reset(() => setFrom(e.target.value))} />
        </div>
        <div className="w-44">
          <Input id="air-wl-to" type="date" label="To" value={to} min={from} onChange={(e) => reset(() => setTo(e.target.value))} />
        </div>
        {everyone && (
          <div className="min-w-[14rem]">
            <Select id="air-wl-person" label="Person" value={person} onChange={(e) => reset(() => setPerson(e.target.value))}>
              {personOptions.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
            </Select>
          </div>
        )}
        {(options.data?.terminals.length || 0) > 1 && (
          <div className="min-w-[12rem]">
            <Select id="air-wl-terminal" label="Terminal" value={terminal} onChange={(e) => reset(() => setTerminal(e.target.value))}>
              <option value="">All terminals</option>
              {(options.data?.terminals || []).map((t) => <option key={t.uuid} value={t.uuid}>{t.name}</option>)}
            </Select>
          </div>
        )}
        <div className="w-40">
          <Select id="air-wl-state" label="Sessions" value={state}
            onChange={(e) => reset(() => setState(e.target.value as '' | 'open' | 'closed'))}>
            <option value="">Open and ended</option>
            <option value="open">Still open</option>
            <option value="closed">Ended</option>
          </Select>
        </div>
        {(options.data?.agents.length || 0) > 0 && (
          <div className="min-w-[11rem]">
            <Select id="air-wl-agent" label="Started" value={agent} onChange={(e) => reset(() => setAgent(e.target.value))}>
              <option value="">Any assistant</option>
              {(options.data?.agents || []).map((a) => <option key={a.id} value={a.id}>{a.label}</option>)}
            </Select>
          </div>
        )}
        <div className="min-w-[14rem] flex-1">
          <Input id="air-wl-search" type="search" label="Search" value={search} onChange={(e) => setSearch(e.target.value)}
            placeholder={everyone ? 'Person, folder or task' : 'Folder or task'} />
        </div>
        {filtered && (
          <Button variant="ghost" size="sm" onClick={() => {
            setPerson(''); setTerminal(''); setState(''); setAgent(''); setSearch(''); setQ(''); setTask(''); setPage(1);
          }}>
            Clear filters
          </Button>
        )}
      </Card>
      {task && (
        <p className="flex flex-wrap items-center gap-2 text-sm text-secondary-700" data-testid="air-worklog-task-filter">
          Only the sessions of {taskRow ? `task #${taskRow.task_number} ${taskRow.task_title || ''}` : 'one task'}.
          <Button variant="ghost" size="sm" leftIcon={<X className="h-3.5 w-3.5" aria-hidden />} onClick={() => reset(() => setTask(''))}>
            Show all
          </Button>
        </p>
      )}

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
              onRowClick={(p) => { if (p.user_uuid) reset(() => setPerson(p.user_uuid as string)); }}
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
            emptyMessage={filtered ? 'No sessions match these filters in this period.' : 'No web terminal sessions in this period.'}
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
        {tabs.data?.totalCapped && (
          <p className="text-xs text-secondary-500" data-testid="air-worklog-capped">
            More than {tabs.data.total.toLocaleString('en-GB')} sessions match. Pick fewer days or a filter to see them all.
          </p>
        )}
        <p className="text-xs text-secondary-500">
          Open a session for its timeline and screen replay. Sessions started from a task also show on the task&apos;s{' '}
          <Link href="/dashboard/my-tasks" className="underline">AI work panel</Link>.
        </p>
      </section>
    </div>
  );
}

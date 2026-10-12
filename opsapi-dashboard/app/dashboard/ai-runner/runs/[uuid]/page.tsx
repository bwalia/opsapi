'use client';

/**
 * One AI run: header (status, task, runner, profile, folder, branch, output, result, timings), the prompt,
 * and the live log. Polls every 3 s until the run ends. Cancel / Retry for the requester or ai_runs.manage.
 * Phase 3 (§23.5): the start approval banner, permission requests to decide and their history, the
 * conversation with the agent (its question, follow-ups) and usage totals. The server says who may act
 * (can_approve / can_decide / can_message) and checks it again on every call.
 * §25: nobody approves their own run; "Allow for this run" is exact and not offered when the server says the
 * request isn't rememberable; requests too large to review are denied automatically.
 */
import React, { useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import { useParams, useRouter } from 'next/navigation';
import { ArrowLeft, Bot, Copy, MessageSquare, RotateCcw, Send, ShieldAlert, ShieldCheck, XCircle } from 'lucide-react';
import toast from 'react-hot-toast';
import { Badge, Button, Card, ConfirmDialog, Input, Table, Textarea } from '@/components/ui';
import { ErrorNote, Spinner } from '@/components/property-deals/ui';
import {
  AiRunnerPage, BASE, PRODUCT, RequestWants, RunResult, RunStatusBadge, compact, cost, duration, outputModeLabel,
  requestTarget, runView, useAiData, when,
} from '@/components/ai-runner/ui';
import { usePermissions } from '@/contexts/PermissionsContext';
import { useAuthStore } from '@/store/auth.store';
import {
  aiRunner, aiErrorText, TERMINAL, type RequestStatus, type RunEvent, type RunRequest, type RunTurn, type Usage,
} from '@/services/ai-runner.service';

export default function RunDetailPage() {
  const { uuid } = useParams<{ uuid: string }>();
  return (
    <AiRunnerPage>
      <RunDetail key={uuid} uuid={uuid} />
    </AiRunnerPage>
  );
}

function eventText(e: RunEvent): string {
  if (e.text) return e.text;
  const d = e.data as { text?: unknown; message?: unknown } | null | undefined;
  if (d && typeof d.text === 'string') return d.text;
  if (d && typeof d.message === 'string') return d.message;
  return d === undefined || d === null ? '' : JSON.stringify(d);
}

const REQUEST_STATUS: Record<RequestStatus, { label: string; variant: 'warning' | 'success' | 'error' | 'secondary' }> = {
  pending: { label: 'Pending', variant: 'warning' },
  allowed: { label: 'Allowed', variant: 'success' },
  denied: { label: 'Denied', variant: 'error' },
  expired: { label: 'Expired', variant: 'secondary' },
};

/** Run something that changes the run, with a toast either way; true when it worked. */
async function act(fn: () => Promise<unknown>, ok: string, setBusy: (b: string | null) => void, key: string) {
  setBusy(key);
  try {
    await fn();
    toast.success(ok);
    return true;
  } catch (e) {
    toast.error(aiErrorText(e));
    return false;
  } finally {
    setBusy(null);
  }
}

/**
 * pending_approval: a manager approves (→ queued) or rejects (→ cancelled) the run before any runner sees it.
 * Never the person who asked for it (`mine`), even when they are a manager.
 */
function ApprovalBanner({ uuid, canApprove, mine, onDone }: { uuid: string; canApprove: boolean; mine: boolean; onDone: () => void }) {
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  return (
    <section aria-labelledby="air-approval-title" className="space-y-3 rounded-xl border border-warning-300 bg-warning-500/10 p-4">
      <h2 id="air-approval-title" className="flex items-center gap-2 font-semibold text-warning-800">
        <ShieldAlert className="h-5 w-5 shrink-0" aria-hidden /> This run needs a manager&apos;s approval before it starts
      </h2>
      {canApprove && !mine ? (
        <>
          <div className="max-w-xl">
            <Input id="air-reject-reason" label="Reason, if you reject it (optional)" value={reason} maxLength={500}
              onChange={(e) => setReason(e.target.value)} />
          </div>
          <div className="flex flex-wrap gap-2">
            <Button size="sm" isLoading={busy === 'approve'} disabled={!!busy} leftIcon={<ShieldCheck className="h-4 w-4" aria-hidden />}
              onClick={() => act(() => aiRunner.approve(uuid), 'Approved: the run is queued', setBusy, 'approve').then((ok) => ok && onDone())}>
              Approve
            </Button>
            <Button size="sm" variant="danger" isLoading={busy === 'reject'} disabled={!!busy} leftIcon={<XCircle className="h-4 w-4" aria-hidden />}
              onClick={() => act(() => aiRunner.reject(uuid, reason.trim() || undefined), 'Rejected: the run is cancelled', setBusy, 'reject').then((ok) => ok && onDone())}>
              Reject
            </Button>
          </div>
        </>
      ) : (
        <p className="text-sm text-warning-800">
          {mine ? 'Another manager must approve it, since you asked for it.' : 'A manager has to approve it.'}
          {' '}Until then no runner picks it up; after 3 days without a decision it is cancelled.
        </p>
      )}
    </section>
  );
}

const EDIT_TOOLS = ['Edit', 'Write', 'MultiEdit', 'NotebookEdit'];
/** What "Allow for this run" allows again: exactly this (§25.2). */
const rememberWhat = (tool: string) => tool === 'Bash' ? 'this exact command' : EDIT_TOOLS.includes(tool) ? 'edits to this file' : 'this exact request';

/** One pending permission request with Allow / Allow for this run (unless the server says no) / Deny (+ an optional reason). */
function DecisionCard({ runUuid, r, onDone }: { runUuid: string; r: RunRequest; onDone: () => void }) {
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const decide = (kind: 'allow' | 'remember' | 'deny') => act(
    () => aiRunner.decide(runUuid, r.uuid, kind === 'deny' ? 'deny' : 'allow', {
      reason: reason.trim() || undefined,
      remember: kind === 'remember' ? true : undefined,
    }),
    kind === 'deny' ? 'Denied: the agent is told and carries on' : 'Allowed: the agent carries on',
    setBusy, kind,
  ).then((ok) => ok && onDone());
  const hint = `air-remember-${r.uuid}`;
  const rememberable = r.rememberable !== false;
  return (
    <div role="group" aria-label={`${r.tool} request`} className="space-y-3 rounded-lg border border-secondary-200 bg-surface p-3">
      <RequestWants r={r} />
      {r.expires_at && <p className="text-xs text-secondary-500">Denied automatically if nobody answers by {when(r.expires_at)}.</p>}
      <div className="max-w-xl">
        <Input id={`air-reason-${r.uuid}`} label="Reason (optional)" value={reason} maxLength={500} onChange={(e) => setReason(e.target.value)}
          helperText="If you deny, the agent is told this reason." />
      </div>
      <div className="flex flex-wrap gap-2">
        <Button size="sm" isLoading={busy === 'allow'} disabled={!!busy} onClick={() => decide('allow')}>Allow</Button>
        {rememberable && (
          <Button size="sm" variant="outline" isLoading={busy === 'remember'} disabled={!!busy} onClick={() => decide('remember')} aria-describedby={hint}>
            Allow for this run
          </Button>
        )}
        <Button size="sm" variant="danger" isLoading={busy === 'deny'} disabled={!!busy} onClick={() => decide('deny')}>Deny</Button>
      </div>
      <p id={hint} className="text-xs text-secondary-500">
        {rememberable
          ? `Allow for this run also allows ${rememberWhat(r.tool)} again later in this run, without asking.`
          : r.tool === 'Bash'
            ? 'This command chains, substitutes or redirects other commands, so it can only be allowed once.'
            : 'This can only be allowed once.'}
      </p>
    </div>
  );
}

function PendingRequests({ runUuid, requests, canDecide, onDone }: {
  runUuid: string; requests: RunRequest[]; canDecide: boolean; onDone: () => void;
}) {
  return (
    <section aria-labelledby="air-decide-title" className="space-y-3 rounded-xl border border-warning-300 bg-warning-500/10 p-4">
      <h2 id="air-decide-title" className="flex items-center gap-2 font-semibold text-warning-800">
        <ShieldAlert className="h-5 w-5 shrink-0" aria-hidden />
        {canDecide ? 'Needs your decision' : 'Waiting for a decision'}
      </h2>
      <div aria-live="polite" className="space-y-3">
        {canDecide
          ? requests.map((r) => <DecisionCard key={r.uuid} runUuid={runUuid} r={r} onDone={onDone} />)
          : requests.map((r) => (
            <div key={r.uuid} className="space-y-2 rounded-lg border border-secondary-200 bg-surface p-3">
              <RequestWants r={r} />
              <p className="text-xs text-secondary-500">The agent is waiting until someone allowed to decide answers{r.expires_at ? ` (by ${when(r.expires_at)})` : ''}.</p>
            </div>
          ))}
      </div>
    </section>
  );
}

function RequestHistory({ requests }: { requests: RunRequest[] }) {
  return (
    <section aria-labelledby="air-requests-title">
      <h2 id="air-requests-title" className="mb-2 text-sm font-semibold text-secondary-800">
        Permission requests <span className="font-normal text-secondary-500">({requests.length})</span>
      </h2>
      <Table<RunRequest>
        caption="Permission requests"
        data={requests}
        keyExtractor={(r) => r.uuid}
        columns={[
          {
            key: 'what', header: 'Request', render: (r) => {
              const t = requestTarget(r);
              return (
                <span className="block min-w-0 max-w-[32rem]">
                  <span className="font-medium">{r.tool}</span>
                  {t && <code className="block truncate font-mono text-xs text-secondary-600" title={t.value}>{t.value}</code>}
                </span>
              );
            },
          },
          {
            key: 'decision', header: 'Decision', render: (r) => {
              const st = REQUEST_STATUS[r.status] || { label: r.status, variant: 'secondary' as const };
              const auto = r.status === 'denied' && !r.decided_by;
              return (
                <span className="block">
                  <Badge size="sm" variant={st.variant}>{st.label}</Badge>
                  {r.remember && r.status === 'allowed' && <span className="ml-1 text-xs text-secondary-500">for this run</span>}
                  {r.reason && <span className={`mt-0.5 block text-xs ${auto ? 'font-medium text-error-700' : 'text-secondary-600'}`}>{r.reason}</span>}
                  {/* §25.4: too big to show a decider in full, so nobody was asked. */}
                  {auto && /too large to review/i.test(r.reason || '') && (
                    <span className="block text-xs text-secondary-600">Too big to show in full, so it was denied without asking anyone.</span>
                  )}
                </span>
              );
            },
          },
          {
            key: 'by', header: 'Decided by', render: (r) => r.decided_by_name
              || (r.status === 'expired' ? 'Nobody answered' : r.status === 'denied' && !r.decided_by ? 'Denied automatically' : '—'),
          },
          { key: 'at', header: 'When', render: (r) => when(r.decided_at || r.created_at) },
        ]}
      />
    </section>
  );
}

const turnTokens = (t: RunTurn) =>
  `${compact(t.tokens_in)} in · ${compact(t.tokens_out)} out${Number(t.cache_read) ? ` · ${compact(t.cache_read)} cache read` : ''}`;

/** The agent's turns and people's messages, the open question, and the message box. */
function Conversation({ runUuid, turns, question, needsInput, canMessage, onSent }: {
  runUuid: string; turns: RunTurn[]; question?: string | null; needsInput: boolean; canMessage: boolean; onSent: () => void;
}) {
  const [text, setText] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  async function send(e: React.FormEvent) {
    e.preventDefault();
    const msg = text.trim();
    if (!msg) return;
    const ok = await act(() => aiRunner.sendMessage(runUuid, msg),
      needsInput ? 'Answer sent to the agent' : 'Sent: the agent gets it after its current turn', setBusy, 'send');
    if (ok) { setText(''); onSent(); }
  }
  return (
    <section aria-labelledby="air-conv-title" className="space-y-3">
      <h2 id="air-conv-title" className="flex items-center gap-2 text-sm font-semibold text-secondary-800">
        <MessageSquare className="h-4 w-4" aria-hidden /> Conversation <span className="font-normal text-secondary-500">({turns.length} {turns.length === 1 ? 'message' : 'messages'})</span>
      </h2>
      {question && (
        <div role="alert" className="rounded-lg border-2 border-warning-400 bg-warning-500/10 p-3">
          <p className="text-xs font-semibold uppercase tracking-wide text-warning-800">The agent asks</p>
          <p className="mt-1 whitespace-pre-wrap text-sm text-secondary-900">{question}</p>
          {canMessage && <p className="mt-1 text-xs text-secondary-600">Answer in the box below; the run waits until you do.</p>}
        </div>
      )}
      {turns.length > 0 && (
        <ol aria-label="Conversation turns" tabIndex={0} className="max-h-[60vh] space-y-2 overflow-auto rounded-xl border border-secondary-200 bg-surface p-3">
          {turns.map((t) => {
            const agent = t.role === 'assistant';
            return (
              <li key={t.uuid || t.seq}
                className={`rounded-lg p-3 text-sm ${agent ? 'bg-secondary-50' : 'border border-primary-200 bg-primary-500/5'} ${t.needs_input ? 'ring-2 ring-warning-400' : ''}`}>
                <div className="mb-1 flex flex-wrap items-center gap-x-2 gap-y-0.5 text-xs text-secondary-500">
                  <span className="font-semibold text-secondary-800">{agent ? 'Agent' : t.author_name || 'Someone'}</span>
                  <span>{when(t.at || t.created_at)}</span>
                  {agent && <span>{turnTokens(t)}</span>}
                  {t.needs_input && <Badge size="sm" variant="warning">Asks a question</Badge>}
                  {!agent && t.status === 'queued' && <Badge size="sm" variant="default">Not yet sent to the agent</Badge>}
                </div>
                <p className="whitespace-pre-wrap break-words text-secondary-900">{t.text || '—'}</p>
              </li>
            );
          })}
        </ol>
      )}
      {canMessage && (
        <form onSubmit={send} className="space-y-2">
          <Textarea id="air-message" label={question ? 'Your answer' : 'Message the agent'} rows={3} maxLength={8000} value={text}
            onChange={(e) => setText(e.target.value)}
            helperText={question ? 'Sent to the agent as its next message.' : 'A follow-up for the agent; it gets it after its current turn.'} />
          <div className="flex justify-end">
            <Button type="submit" size="sm" isLoading={busy === 'send'} disabled={!text.trim() || !!busy} leftIcon={<Send className="h-4 w-4" aria-hidden />}>
              Send
            </Button>
          </div>
        </form>
      )}
    </section>
  );
}

function UsageTotals({ usage }: { usage: Usage }) {
  const items: [string, number, string][] = [
    ['Tokens in', usage.tokens_in, compact(usage.tokens_in)],
    ['Tokens out', usage.tokens_out, compact(usage.tokens_out)],
    ['Cache read', usage.cache_read, compact(usage.cache_read)],
    ['Cache write', usage.cache_write, compact(usage.cache_write)],
    ['Cost estimate', usage.cost_estimate, cost(usage.cost_estimate)],
    ['Turns', usage.turns, String(usage.turns)],
  ];
  return (
    <Card padding="sm">
      <h2 id="air-usage-title" className="mb-2 text-sm font-semibold text-secondary-800">Usage</h2>
      <dl aria-labelledby="air-usage-title" className="grid grid-cols-2 gap-x-6 gap-y-3 text-sm sm:grid-cols-3 lg:grid-cols-6">
        {items.map(([k, n, label]) => (
          <div key={k}>
            <dt className="text-xs font-medium uppercase tracking-wide text-secondary-500">{k}</dt>
            <dd className="mt-0.5 text-secondary-900" title={k === 'Cost estimate' ? 'Estimated by the agent; on a subscription nothing is billed per token' : n.toLocaleString('en-GB')}>{label}</dd>
          </div>
        ))}
      </dl>
    </Card>
  );
}

function RunDetail({ uuid }: { uuid: string }) {
  const router = useRouter();
  const { hasPermission } = usePermissions();
  const me = useAuthStore((s) => s.user?.uuid);
  const [ended, setEnded] = useState(false);
  const detail = useAiData(() => aiRunner.getRun(uuid), [uuid, ended], ended ? undefined : 3000);
  const run = detail.data?.run;
  const events = detail.data?.events || [];
  const requests = detail.data?.requests || [];
  const pending = requests.filter((r) => r.status === 'pending');
  const decided = requests.filter((r) => r.status !== 'pending');
  const turns = detail.data?.turns || [];
  const usage = detail.data?.usage;
  const terminal = !!run && TERMINAL.includes(run.status);
  useEffect(() => { if (terminal) setEnded(true); }, [terminal]);

  const [confirmCancel, setConfirmCancel] = useState(false);
  const [busy, setBusy] = useState<'cancel' | 'retry' | null>(null);
  const [stick, setStick] = useState(true);
  const logRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (stick && logRef.current) logRef.current.scrollTop = logRef.current.scrollHeight;
  }, [events.length, stick]);

  if (detail.loading && !run) return <Spinner />;
  if (!run) return <div className="mt-6"><ErrorNote error={detail.error} product={PRODUCT} /></div>;

  const v = runView(run);
  const mine = !!me && v.requesterUuid === me;
  const mayAct = hasPermission('ai_runs', 'manage') || mine;
  const canCancel = mayAct && !terminal && run.status !== 'cancelling';
  const canRetry = mayAct && terminal && run.status !== 'succeeded';

  async function cancel() {
    setBusy('cancel');
    try {
      await aiRunner.cancel(uuid);
      toast.success('Cancel sent');
      setConfirmCancel(false);
      detail.refresh();
    } catch (e) {
      toast.error(aiErrorText(e));
    } finally {
      setBusy(null);
    }
  }
  async function retry() {
    setBusy('retry');
    try {
      const next = await aiRunner.retry(uuid);
      toast.success('A new attempt is queued');
      router.push(`${BASE}/runs/${next.uuid}`);
    } catch (e) {
      toast.error(aiErrorText(e));
    } finally {
      setBusy(null);
    }
  }

  const facts: [string, React.ReactNode][] = [
    ['Task', v.taskHref ? <Link href={v.taskHref} className="text-primary-600 hover:underline">{v.taskLabel}</Link> : v.taskLabel],
    ['Requested by', v.requester],
    ['Runner', v.runner],
    ['Profile', v.profile],
    ['Folder', <span key="f" className="break-all font-mono text-xs">{run.repo_path}</span>],
    ['Branch', <span key="b" className="break-all font-mono text-xs">{run.work_branch || '—'}{run.base_branch ? ` (from ${run.base_branch})` : ''}</span>],
    ['Output', outputModeLabel(run.output_mode)],
    ['Result', <RunResult key="r" run={run} />],
    ['Commit', run.commit_sha ? <span key="c" className="break-all font-mono text-xs">{run.commit_sha}</span> : '—'],
    ['Queued', when(run.created_at)],
    ['Started', when(run.started_at)],
    ['Finished', when(run.finished_at)],
    ['Duration', duration(run)],
    ['Attempt', run.attempt ?? 1],
  ];

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center gap-3">
        <Link href={`${BASE}/runs`} className="inline-flex h-8 w-8 items-center justify-center rounded-lg border border-secondary-200 text-secondary-500 hover:text-secondary-800" aria-label="Back to AI Runs">
          <ArrowLeft className="h-4 w-4" aria-hidden />
        </Link>
        <Bot className="h-6 w-6 text-primary-500" aria-hidden />
        <h1 className="text-2xl font-bold tracking-tight text-secondary-900">{v.taskLabel}</h1>
        <RunStatusBadge status={run.status} />
        <div className="ml-auto flex gap-2">
          {canCancel && (
            <Button variant="danger" size="sm" leftIcon={<XCircle className="h-4 w-4" aria-hidden />} onClick={() => setConfirmCancel(true)}>Cancel run</Button>
          )}
          {canRetry && (
            <Button variant="outline" size="sm" isLoading={busy === 'retry'} leftIcon={<RotateCcw className="h-4 w-4" aria-hidden />} onClick={retry}>Retry</Button>
          )}
        </div>
      </div>

      {detail.error && <ErrorNote error={detail.error} product={PRODUCT} />}
      {run.status === 'pending_approval' && <ApprovalBanner uuid={uuid} canApprove={!!detail.data?.can_approve} mine={mine} onDone={detail.refresh} />}
      {pending.length > 0 && !terminal && (
        <PendingRequests runUuid={uuid} requests={pending} canDecide={!!detail.data?.can_decide} onDone={detail.refresh} />
      )}
      {(run.error || run.error_category) && (
        <div className="rounded-lg bg-error-500/10 p-3 text-sm text-error-700" role="alert">
          <span className="font-semibold">The run failed{run.error_category ? ` (${run.error_category.replace(/_/g, ' ')})` : ''}.</span>
          {run.error && <span className="block whitespace-pre-wrap">{run.error}</span>}
        </div>
      )}
      {run.summary && (
        <Card padding="sm">
          <h2 className="mb-1 text-sm font-semibold text-secondary-800">Summary</h2>
          <p className="whitespace-pre-wrap text-sm text-secondary-700">{run.summary}</p>
        </Card>
      )}

      <Card padding="sm">
        <dl className="grid gap-x-6 gap-y-3 text-sm sm:grid-cols-2 lg:grid-cols-4">
          {facts.map(([k, val]) => (
            <div key={k} className="min-w-0">
              <dt className="text-xs font-medium uppercase tracking-wide text-secondary-500">{k}</dt>
              <dd className="mt-0.5 text-secondary-900">{val}</dd>
            </div>
          ))}
        </dl>
      </Card>

      {usage && (usage.turns > 0 || usage.tokens_in + usage.tokens_out > 0) && <UsageTotals usage={usage} />}

      {(turns.length > 0 || (run.question && !terminal) || detail.data?.can_message) && (
        <Conversation runUuid={uuid} turns={turns} question={terminal ? null : run.question} needsInput={run.status === 'needs_input'}
          canMessage={!!detail.data?.can_message && !terminal} onSent={detail.refresh} />
      )}

      {decided.length > 0 && <RequestHistory requests={decided} />}

      <details className="rounded-xl border border-secondary-200 bg-surface">
        <summary className="cursor-pointer select-none px-4 py-3 text-sm font-semibold text-secondary-800 focus:outline-none focus-visible:ring-2 focus-visible:ring-primary-500">
          Prompt{run.template_version ? ` (template v${run.template_version})` : ''}
        </summary>
        <div className="border-t border-secondary-200 p-4">
          <div className="mb-2 flex justify-end">
            <Button variant="ghost" size="sm" leftIcon={<Copy className="h-4 w-4" aria-hidden />}
              onClick={() => navigator.clipboard.writeText(run.prompt || '').then(() => toast.success('Prompt copied'), () => toast.error('Could not copy'))}>
              Copy prompt
            </Button>
          </div>
          <pre className="max-h-[50vh] overflow-auto whitespace-pre-wrap font-mono text-xs text-secondary-800">{run.prompt || '—'}</pre>
        </div>
      </details>

      <section aria-labelledby="run-log-title">
        <div className="mb-2 flex items-center justify-between">
          <h2 id="run-log-title" className="text-sm font-semibold text-secondary-800">
            Log <span className="font-normal text-secondary-500">({events.length} {events.length === 1 ? 'line' : 'lines'}{terminal ? '' : ', live'})</span>
          </h2>
          <label className="flex items-center gap-2 text-sm text-secondary-600">
            <input type="checkbox" checked={stick} onChange={(e) => setStick(e.target.checked)} /> Stick to bottom
          </label>
        </div>
        <div ref={logRef} role="log" aria-labelledby="run-log-title" tabIndex={0}
          className="max-h-[60vh] min-h-[12rem] overflow-auto rounded-xl bg-secondary-900 p-3 font-mono text-xs leading-relaxed text-secondary-100">
          {events.length === 0 ? (
            <p className="text-secondary-400">{terminal ? 'No log lines.' : 'Waiting for the runner…'}</p>
          ) : (
            events.map((e) => (
              <div key={e.seq} className="whitespace-pre-wrap break-words">
                {e.type !== 'log' && <span className="mr-2 text-secondary-400">[{e.type}]</span>}
                {eventText(e)}
              </div>
            ))
          )}
        </div>
      </section>

      <ConfirmDialog
        isOpen={confirmCancel}
        onClose={() => setConfirmCancel(false)}
        onConfirm={cancel}
        title="Cancel this run?"
        message={run.status === 'queued' ? 'It has not started yet; it will be cancelled now.' : 'The runner stops the agent at its next check-in, within about 15 seconds.'}
        confirmText="Cancel run"
        cancelText="Keep running"
        isLoading={busy === 'cancel'}
      />
    </div>
  );
}

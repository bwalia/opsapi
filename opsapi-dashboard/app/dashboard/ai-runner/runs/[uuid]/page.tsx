'use client';

/**
 * One AI run: header (status, task, runner, profile, folder, branch, output, result, timings), the prompt,
 * and the live log. Polls every 3 s until the run ends. Cancel / Retry for the requester or ai_runs.manage.
 */
import React, { useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import { useParams, useRouter } from 'next/navigation';
import { ArrowLeft, Bot, Copy, RotateCcw, XCircle } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Card, ConfirmDialog } from '@/components/ui';
import { ErrorNote, Spinner } from '@/components/property-deals/ui';
import {
  AiRunnerPage, BASE, PRODUCT, RunResult, RunStatusBadge, duration, outputModeLabel, runView, useAiData, when,
} from '@/components/ai-runner/ui';
import { usePermissions } from '@/contexts/PermissionsContext';
import { useAuthStore } from '@/store/auth.store';
import { aiRunner, aiErrorText, TERMINAL, type RunEvent } from '@/services/ai-runner.service';

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

function RunDetail({ uuid }: { uuid: string }) {
  const router = useRouter();
  const { hasPermission } = usePermissions();
  const me = useAuthStore((s) => s.user?.uuid);
  const [ended, setEnded] = useState(false);
  const detail = useAiData(() => aiRunner.getRun(uuid), [uuid, ended], ended ? undefined : 3000);
  const run = detail.data?.run;
  const events = detail.data?.events || [];
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
  const mayAct = hasPermission('ai_runs', 'manage') || (!!me && v.requesterUuid === me);
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
    ['Commit', run.commit_sha ? <span key="c" className="font-mono text-xs">{run.commit_sha}</span> : '—'],
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

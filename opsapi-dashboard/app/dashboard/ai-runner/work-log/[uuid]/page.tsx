'use client';

/**
 * One web terminal session in the work log (docs/AI_RUNNER_WEB_TERMINAL.md §11): who, where, when; totals (prompts,
 * AI requests, tokens, cost, actions, code); a replay of the screen; and the timeline of what was asked and done.
 */
import React, { useState } from 'react';
import Link from 'next/link';
import { useParams } from 'next/navigation';
import { AlertTriangle, ArrowLeft, Bot, Check, ClipboardList, GitCommit, GitPullRequest, MessageSquare, Wrench, X } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { Badge, Card } from '@/components/ui';
import { ErrorNote } from '@/components/property-deals/ui';
import { AiRunnerPage, BASE, PRODUCT, compact, cost, elapsed, useAiData, when } from '@/components/ai-runner/ui';
import { ScreenReplay } from '@/components/ai-runner/ScreenReplay';
import { aiRunner, type WorkLogDetail, type WorkLogEvent } from '@/services/ai-runner.service';

export default function WorkLogSessionPage() {
  return (
    <AiRunnerPage module="ai_runs" action="read">
      <Session />
    </AiRunnerPage>
  );
}

const FILTERS = [
  { key: 'all', label: 'Everything' },
  { key: 'user_prompt', label: 'Prompts' },
  { key: 'tool_result', label: 'Actions' },
  { key: 'api_request', label: 'AI requests' },
] as const;

function Stat({ label, value, hint }: { label: string; value: React.ReactNode; hint?: string }) {
  return (
    <div className="rounded-lg border border-secondary-200 bg-surface p-3">
      <p className="text-xs text-secondary-500">{label}</p>
      <p className="text-lg font-semibold text-secondary-900">{value}</p>
      {hint && <p className="text-xs text-secondary-500">{hint}</p>}
    </div>
  );
}

function clock(at: string) {
  return when(at);
}

/** What a tool was given, readably: the command it ran or the file it touched; otherwise the raw details. */
function toolDetails(text: string): { main: string; note?: string } {
  try {
    const p = JSON.parse(text) as Record<string, unknown>;
    const main = p.full_command ?? p.command ?? p.file_path ?? p.path ?? p.url ?? p.pattern;
    if (typeof main === 'string') return { main, note: typeof p.description === 'string' ? p.description : undefined };
  } catch {
    // not JSON: show it as it came
  }
  return { main: text };
}

/** One line of the timeline: an icon, what happened, and the words (prompt, command, error) when kept. */
function EventRow({ e, textDays }: { e: WorkLogEvent; textDays: number }) {
  const a = e.attrs || {};
  const removed = <span className="italic text-secondary-400">(removed after {textDays} days)</span>;
  let icon = <Bot className="h-4 w-4 text-secondary-500" aria-hidden />;
  let title: React.ReactNode = e.type;
  let body: React.ReactNode = null;
  if (e.type === 'user_prompt') {
    icon = <MessageSquare className="h-4 w-4 text-primary-600" aria-hidden />;
    title = <span className="font-medium text-secondary-900">Asked the AI</span>;
    body = <p className="whitespace-pre-wrap break-words text-sm text-secondary-800">{e.text ?? removed}</p>;
  } else if (e.type === 'api_request') {
    title = (
      <span>
        AI request · {e.model || 'model'} · {compact((e.input_tokens || 0) + (e.cache_read_tokens || 0) + (e.cache_write_tokens || 0))} in /{' '}
        {compact(e.output_tokens)} out · {cost(e.cost_usd)}
        {e.duration_ms != null ? ` · ${(e.duration_ms / 1000).toFixed(1)} s` : ''}
      </span>
    );
  } else if (e.type === 'tool_result') {
    icon = e.success === false
      ? <X className="h-4 w-4 text-error-600" aria-hidden />
      : <Wrench className="h-4 w-4 text-secondary-600" aria-hidden />;
    title = (
      <span className="font-medium text-secondary-900">
        {e.success === false ? 'Failed: ' : ''}{e.tool_name || 'Tool'}
        {e.duration_ms != null && <span className="font-normal text-secondary-500"> · {(e.duration_ms / 1000).toFixed(1)} s</span>}
      </span>
    );
    const d = e.text ? toolDetails(e.text) : null;
    body = d ? (
      <div className="space-y-1">
        <pre className="overflow-x-auto whitespace-pre-wrap break-words rounded bg-secondary-50 p-2 font-mono text-xs text-secondary-800">{d.main}</pre>
        {d.note && <p className="text-xs text-secondary-500">{d.note}</p>}
      </div>
    ) : removed;
  } else if (e.type === 'tool_decision') {
    const ok = String(a.decision || '').startsWith('accept');
    icon = ok ? <Check className="h-4 w-4 text-success-600" aria-hidden /> : <X className="h-4 w-4 text-warning-600" aria-hidden />;
    title = <span>{e.tool_name || 'Tool'}: {ok ? 'allowed' : 'refused'}{a.source ? ` (${a.source})` : ''}</span>;
  } else if (e.type === 'api_error') {
    icon = <AlertTriangle className="h-4 w-4 text-error-600" aria-hidden />;
    title = <span className="text-error-700">AI error{e.model ? ` · ${e.model}` : ''}</span>;
    body = <p className="text-sm text-secondary-700">{e.text ?? removed}</p>;
  } else if (e.type === 'metric') {
    const n = Number(a.value) || 0;
    if (a.name === 'claude_code.commit.count') {
      icon = <GitCommit className="h-4 w-4 text-secondary-600" aria-hidden />;
      title = `${n} commit${n === 1 ? '' : 's'}`;
    } else if (a.name === 'claude_code.pull_request.count') {
      icon = <GitPullRequest className="h-4 w-4 text-secondary-600" aria-hidden />;
      title = `${n} pull request${n === 1 ? '' : 's'}`;
    } else if (a.name === 'claude_code.lines_of_code.count') {
      title = `${a.type === 'removed' ? '−' : '+'}${n} lines ${a.type === 'removed' ? 'removed' : 'added'}`;
    } else {
      return null;
    }
  }
  return (
    <li className="flex gap-3 py-2">
      <span className="mt-0.5 shrink-0">{icon}</span>
      <div className="min-w-0 flex-1 space-y-1">
        <p className="flex flex-wrap items-baseline justify-between gap-2 text-sm text-secondary-700">
          {title}
          <span className="whitespace-nowrap text-xs text-secondary-400">{clock(e.at)}</span>
        </p>
        {body}
      </div>
    </li>
  );
}

function Session() {
  const params = useParams<{ uuid: string }>();
  const data = useAiData(() => aiRunner.workLogTab(params.uuid), [params.uuid]);
  const [filter, setFilter] = useState<(typeof FILTERS)[number]['key']>('all');
  const t: WorkLogDetail | undefined = data.data;
  const person = t ? (t.person_name || t.person_email || (t.terminal_user ? `${t.terminal_user} (terminal user)` : 'Someone')) : '';
  const events = (t?.events || []).filter((e) => filter === 'all' || e.type === filter);

  return (
    <div className="space-y-5">
      <Link href={`${BASE}/work-log`} className="inline-flex items-center gap-1 text-sm text-secondary-600 hover:underline">
        <ArrowLeft className="h-4 w-4" aria-hidden /> Work log
      </Link>
      <ErrorNote error={data.error} product={PRODUCT} />
      {t && (
        <>
          <PageHeader
            title={`${person} · ${t.terminal_name || 'web terminal'}`}
            description={`${when(t.opened_at)} → ${t.open ? 'still open' : when(t.closed_at)} · ${elapsed(t.active_secs)} active of ${elapsed(t.duration_secs)}`}
            icon={<ClipboardList className="h-5 w-5" />}
          />
          <Card className="space-y-1 text-sm text-secondary-700" data-testid="air-worklog-session">
            <p className="flex flex-wrap items-center gap-2">
              <Badge size="sm" variant={t.open ? 'success' : 'secondary'}>{t.open ? 'Open' : (t.end_reason ? `Ended: ${t.end_reason}` : 'Ended')}</Badge>
              {t.exit_code != null && <span className="text-xs text-secondary-500">exit code {t.exit_code}</span>}
            </p>
            {t.task_uuid && <p>Task: #{t.task_number} {t.task_title}</p>}
            <p>Folder: <span className="font-mono text-xs">{t.cwd || '—'}</span>{t.agent ? ` · started ${t.agent}` : ''}</p>
            <p>
              Signed in as <span className="font-mono text-xs">{t.terminal_user || '?'}</span>{' '}
              {t.via === 'opsapi_launch' ? 'by OpsAPI (Start with AI)' : 'with their key'}
              {t.ip ? ` from ${t.ip}` : ''}
            </p>
          </Card>

          <div className="grid grid-cols-2 gap-3 sm:grid-cols-4" data-testid="air-worklog-totals">
            <Stat label="Prompts" value={t.prompts} />
            <Stat label="AI requests" value={t.requests} hint={`${t.tool_calls} action${t.tool_calls === 1 ? '' : 's'}`} />
            <Stat
              label="Tokens"
              value={compact(t.input_tokens + t.output_tokens + t.cache_read_tokens + t.cache_write_tokens)}
              hint={`${compact(t.output_tokens)} out · ${compact(t.cache_read_tokens)} from cache`}
            />
            <Stat label="Cost (estimate)" value={cost(t.cost_usd)} />
            <Stat label="Code" value={`+${t.lines_added} −${t.lines_removed}`} hint={`${t.commits} commits · ${t.pull_requests} PRs`} />
            <Stat label="Typed / shown" value={`${compact(t.input_bytes)} / ${compact(t.output_bytes)}`} hint="bytes" />
          </div>

          <section aria-labelledby="air-wl-replay" className="space-y-2">
            <h2 id="air-wl-replay" className="font-semibold text-secondary-900">Screen replay</h2>
            {t.recording.length > 0 ? (
              <ScreenReplay uuid={t.uuid} parts={t.recording.map((r) => r.part)} />
            ) : (
              <p className="text-sm text-secondary-500">No screen recording for this session (recordings are kept for {t.recording_days} days).</p>
            )}
            <p className="text-xs text-secondary-500">Shows what appeared on the screen. What was typed (for example passwords) is never recorded.</p>
          </section>

          <section aria-labelledby="air-wl-timeline" className="space-y-2" data-testid="air-worklog-timeline">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <h2 id="air-wl-timeline" className="font-semibold text-secondary-900">What happened</h2>
              <div role="group" aria-label="Show" className="inline-flex rounded-lg border border-secondary-200 bg-surface p-1">
                {FILTERS.map((f) => (
                  <button
                    key={f.key}
                    type="button"
                    onClick={() => setFilter(f.key)}
                    aria-pressed={filter === f.key}
                    className={`rounded-md px-3 py-1 text-sm ${filter === f.key ? 'bg-primary-500 text-white' : 'text-secondary-600 hover:bg-secondary-100'}`}
                  >
                    {f.label}
                  </button>
                ))}
              </div>
            </div>
            <Card>
              {events.length === 0 ? (
                <p className="text-sm text-secondary-500">
                  {t.events.length === 0
                    ? 'Nothing from an AI agent in this session (plain terminal work shows in the replay).'
                    : 'Nothing of this kind.'}
                </p>
              ) : (
                <ul className="divide-y divide-secondary-100">
                  {events.map((e) => <EventRow key={e.id} e={e} textDays={t.text_days} />)}
                </ul>
              )}
            </Card>
          </section>
        </>
      )}
    </div>
  );
}

'use client';

/**
 * Hiring › Review an interview — /dashboard/ats/interviews/[uuid]
 *
 * Left: the transcript; each evidence quote links to the turn it came from
 * and is highlighted there. Right: one card per competency with the quotes,
 * the AI's suggestion (labelled as such, with a low-agreement badge when its
 * two runs disagreed) and the reviewer's own level. The decision is the
 * reviewer's; declining sends nothing to the candidate.
 *
 * All candidate text is untrusted and rendered as text (React escapes it).
 */

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import { useParams } from 'next/navigation';
import toast from 'react-hot-toast';
import { AlertTriangle, Bot, RefreshCw } from 'lucide-react';
import { Badge, Button, Card, Select, Textarea } from '@/components/ui';
import { AtsShell } from '@/components/ats/AtsShell';
import { apiError } from '@/components/field-service/shared';
import { atsService, when, type Decision, type InterviewDetail, type Quote } from '@/services/ats.service';

const FLAG_LABEL: Record<string, string> = {
  adjustment: 'Adjustment requested', human_requested: 'Asked for a person', distress: 'Seemed distressed',
  protected_info_volunteered: 'Shared personal information (hidden from the assessment)',
  injection_attempt: 'Tried to instruct the AI', technical: 'Technical problem', off_topic: 'Off topic',
  pasted: 'Answer pasted in (information only)', time_up: 'Ran out of time', other: 'Note',
};

function Highlighted({ text, quotes }: { text: string; quotes: string[] }) {
  // Marks each quote's first occurrence (case-insensitive) as plain text segments.
  const parts = useMemo(() => {
    const ranges: [number, number][] = [];
    const lower = text.toLowerCase();
    for (const q of quotes) {
      const i = lower.indexOf(q.toLowerCase().trim());
      if (i >= 0) ranges.push([i, i + q.trim().length]);
    }
    ranges.sort((a, b) => a[0] - b[0]);
    const out: { t: string; mark: boolean }[] = [];
    let at = 0;
    for (const [a, b] of ranges) {
      if (a < at) continue;
      if (a > at) out.push({ t: text.slice(at, a), mark: false });
      out.push({ t: text.slice(a, b), mark: true });
      at = b;
    }
    if (at < text.length) out.push({ t: text.slice(at), mark: false });
    return out;
  }, [text, quotes]);
  return <>{parts.map((p, i) => (p.mark ? <mark key={i} className="rounded bg-amber-100 px-0.5">{p.t}</mark> : <React.Fragment key={i}>{p.t}</React.Fragment>))}</>;
}

export default function ReviewPage() {
  const { uuid } = useParams<{ uuid: string }>();
  const [d, setD] = useState<InterviewDetail | null>(null);
  const [levels, setLevels] = useState<Record<string, number>>({});
  const [decision, setDecision] = useState<Decision | ''>('');
  const [reason, setReason] = useState('');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => {
    atsService.interview(uuid).then((x) => {
      setD(x);
      setLevels(x.review?.levels ?? {});
      setDecision(x.review?.decision ?? '');
      setReason(x.review?.reason ?? '');
      setNote(x.review?.note ?? '');
    }).catch((e) => toast.error(apiError(e, 'Could not load the interview')));
  }, [uuid]);
  useEffect(load, [load]);

  // Poll while the evaluator runs.
  useEffect(() => {
    if (d?.evaluation_status !== 'running') return;
    const t = setInterval(load, 5000);
    return () => clearInterval(t);
  }, [d?.evaluation_status, load]);

  const quotesByTurn = useMemo(() => {
    const m: Record<string, string[]> = {};
    for (const c of d?.evaluation?.competencies ?? []) for (const q of c.evidence) (m[q.turn] ??= []).push(q.quote);
    return m;
  }, [d]);

  const save = async () => {
    setBusy(true);
    try {
      const x = await atsService.review(uuid, { levels, decision: decision || undefined, reason, note });
      setD(x);
      toast.success(decision ? 'Decision recorded. Nothing was sent to the candidate.' : 'Review saved');
    } catch (e) {
      toast.error(apiError(e, 'Could not save the review'));
    } finally {
      setBusy(false);
    }
  };

  const evaluate = async () => {
    try {
      await atsService.evaluate(uuid);
      toast.success('The assessment is running');
      load();
    } catch (e) {
      toast.error(apiError(e, 'Could not start the assessment'));
    }
  };

  const jump = (q: Quote) => document.getElementById(`turn-${q.turn}`)?.scrollIntoView({ behavior: 'smooth', block: 'center' });

  if (!d) return <AtsShell title="Interview" module="ats_interviews"><p className="text-secondary-500">Loading…</p></AtsShell>;
  const finished = ['completed', 'human_requested', 'withdrawn', 'abandoned', 'expired'].includes(d.state);

  return (
    <AtsShell title={`${d.candidate_name} · ${d.job_title}`} module="ats_interviews"
      description={`${d.source === 'hosted' ? 'Online interview' : 'Interview run in Snazzy Pro'} · kit v${d.kit_version} · ${d.state.replace('_', ' ')}${d.ended_at ? ` · ended ${when(d.ended_at)}` : ''}`}
      actions={<Link href={`/dashboard/ats/candidates/${d.candidate_uuid}`} className="text-sm font-medium text-primary-600 hover:underline">Candidate profile</Link>}>
      <div className="grid gap-6 xl:grid-cols-[minmax(0,1fr)_420px]">
        <div className="space-y-4">
          {d.flags.length > 0 && (
            <Card>
              <h2 className="mb-2 font-semibold">Flags</h2>
              <ul className="space-y-1 text-sm">
                {d.flags.map((f, i) => (
                  <li key={i} className="flex gap-2">
                    <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-amber-600" />
                    <span>{FLAG_LABEL[f.kind] ?? f.kind}{f.kind !== 'protected_info_volunteered' && f.detail ? `: ${f.detail}` : ''}
                      {f.turn && <a className="ml-1 text-primary-600 underline" href={`#turn-${f.turn}`}>({f.turn})</a>}</span>
                  </li>
                ))}
              </ul>
            </Card>
          )}
          {d.eligibility.length > 0 && (
            <Card>
              <h2 className="mb-2 font-semibold">Eligibility answers (as given)</h2>
              <ul className="space-y-1 text-sm">
                {d.eligibility.map((e) => (
                  <li key={e.id} className="flex flex-wrap justify-between gap-2">
                    <span className="text-secondary-600">{e.text}</span>
                    <span className="font-medium">{e.answer ?? '—'}{e.meets === false && <Badge className="ml-2" variant="warning">Doesn&apos;t meet the stated requirement</Badge>}</span>
                  </li>
                ))}
              </ul>
            </Card>
          )}
          <Card>
            <h2 className="mb-3 font-semibold">Transcript</h2>
            <ol className="space-y-3">
              {d.turns.filter((t) => t.role !== 'system').map((t) => (
                <li key={t.id} id={`turn-${t.id}`} className={`rounded-lg p-3 text-sm ${t.role === 'candidate' ? 'ml-6 bg-primary-50' : 'mr-6 bg-secondary-50'}`}>
                  <p className="mb-1 text-xs font-semibold uppercase tracking-wide text-secondary-500">
                    {t.role === 'candidate' ? 'Candidate' : 'Interviewer'} · {t.id}{t.input === 'pasted' ? ' · pasted' : t.input === 'spoken' ? ' · spoken' : ''}
                  </p>
                  <p className="whitespace-pre-wrap text-secondary-900">
                    {t.role === 'candidate' ? <Highlighted text={t.text} quotes={quotesByTurn[t.id] ?? []} /> : t.text}
                  </p>
                </li>
              ))}
            </ol>
            {d.forwarded_questions.length > 0 && (
              <div className="mt-4 rounded-lg border border-secondary-200 p-3 text-sm">
                <p className="font-semibold">Questions the candidate asked that the AI passed to you</p>
                <ul className="mt-1 list-disc pl-5">{d.forwarded_questions.map((q, i) => <li key={i}>{q}</li>)}</ul>
              </div>
            )}
          </Card>
        </div>

        <div className="space-y-4 xl:sticky xl:top-4 xl:self-start">
          <Card>
            <div className="flex items-center justify-between">
              <h2 className="flex items-center gap-2 font-semibold"><Bot className="h-4 w-4" /> Evidence by competency</h2>
              {finished && <Button size="sm" variant="ghost" leftIcon={<RefreshCw className="h-4 w-4" />} onClick={evaluate}
                disabled={d.evaluation_status === 'running'}>{d.evaluation ? 'Re-run' : 'Run'}</Button>}
            </div>
            <p className="mt-1 text-xs text-secondary-500">
              AI suggestions are advice: check the quotes, then set your own level. {d.evaluation?.model ? `Model: ${d.evaluation.model}.` : ''}
            </p>
            {d.evaluation_status === 'running' && <p className="mt-3 text-sm text-secondary-600">The assessment is running…</p>}
            {d.evaluation_status === 'failed' && <p className="mt-3 text-sm text-red-700">The assessment failed. Run it again.</p>}
            {d.evaluation?.notes_for_reviewer && <p className="mt-3 rounded bg-secondary-50 p-2 text-sm">{d.evaluation.notes_for_reviewer}</p>}
            <div className="mt-3 space-y-4">
              {d.kit.competencies.map((c) => {
                const r = d.evaluation?.competencies.find((x) => x.id === c.id);
                return (
                  <section key={c.id} className="rounded-lg border border-secondary-200 p-3">
                    <h3 className="font-medium text-secondary-900">{c.name}</h3>
                    {r && r.evidence.length > 0 ? (
                      <ul className="mt-2 space-y-1">
                        {r.evidence.map((q, i) => (
                          <li key={i}>
                            <button className="text-left text-sm text-secondary-700 hover:text-primary-700" onClick={() => jump(q)}>
                              “{q.quote}” <span className="text-xs text-primary-600">({q.turn})</span>
                            </button>
                          </li>
                        ))}
                      </ul>
                    ) : <p className="mt-2 text-sm text-secondary-500">{r ? 'No evidence in the answers.' : 'Not assessed yet.'}</p>}
                    {r && (
                      <div className="mt-2 flex flex-wrap items-center gap-2 text-xs">
                        <Badge variant="info">AI suggestion: {r.level ? `level ${r.level}` : d.kit.settings.ratings_enabled ? 'not enough evidence' : 'ratings off'}</Badge>
                        {!r.agreed && <Badge variant="warning">Low agreement (second run: {r.second_level ?? 'not enough evidence'})</Badge>}
                      </div>
                    )}
                    {r?.reason && <p className="mt-1 text-xs text-secondary-600">{r.reason}</p>}
                    {r?.probe_next && <p className="mt-1 text-xs text-secondary-500">Ask next round: {r.probe_next}</p>}
                    <details className="mt-2 text-xs text-secondary-500">
                      <summary className="cursor-pointer">Rubric</summary>
                      <p>1: {c.anchors['1']}</p><p>3: {c.anchors['3']}</p><p>5: {c.anchors['5']}</p>
                    </details>
                    <Select className="mt-2" label="Your level" value={String(levels[c.id] ?? '')}
                      onChange={(e) => setLevels((l) => { const n = { ...l }; if (e.target.value === '') delete n[c.id]; else n[c.id] = Number(e.target.value); return n; })}>
                      <option value="">Not set</option>
                      <option value="0">Not enough evidence</option>
                      {[1, 2, 3, 4, 5].map((n) => <option key={n} value={n}>{n}</option>)}
                    </Select>
                  </section>
                );
              })}
            </div>
          </Card>

          <Card>
            <h2 className="mb-2 font-semibold">Your decision</h2>
            {d.review?.decision && (
              <p className="mb-2 text-sm text-secondary-600">Recorded: <strong>{d.review.decision}</strong> by {d.review.reviewer} on {when(d.review.at)}</p>
            )}
            <div role="radiogroup" aria-label="Decision" className="flex gap-2">
              {(['advance', 'hold', 'decline'] as const).map((x) => (
                <button key={x} role="radio" aria-checked={decision === x} onClick={() => setDecision(x)}
                  className={`flex-1 rounded-lg border px-3 py-2 text-sm font-medium ${decision === x
                    ? x === 'decline' ? 'border-red-500 bg-red-50 text-red-800' : 'border-primary-500 bg-primary-50 text-primary-800'
                    : 'border-secondary-200 text-secondary-700'}`}>
                  {x === 'advance' ? 'Advance' : x === 'hold' ? 'Hold' : 'Decline'}
                </button>
              ))}
            </div>
            {decision === 'decline' && (
              <Select className="mt-3" label="Reason" value={reason} onChange={(e) => setReason(e.target.value)}>
                <option value="">Choose a reason</option>
                {d.settings.decline_reasons.map((r) => <option key={r}>{r}</option>)}
              </Select>
            )}
            <Textarea className="mt-3" label="Note for the team" rows={3} value={note} onChange={(e) => setNote(e.target.value)} />
            <Button className="mt-3 w-full" onClick={save} isLoading={busy} disabled={decision === 'decline' && !reason}>
              {decision ? 'Record decision' : 'Save review'}
            </Button>
            <p className="mt-2 text-xs text-secondary-500">Recording a decision doesn&apos;t contact the candidate.</p>
          </Card>
        </div>
      </div>
    </AtsShell>
  );
}

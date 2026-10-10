'use client';

/**
 * Property Deals — Approvals inbox (SPEC §3.8 #7): every draft waiting for a person.
 * Shows the agent, model, cost, JobShout, the tools it used, the draft (editable, with a diff
 * against the original) and approve / edit & approve / reject with a note. Decisions carry the
 * payload version shown, so a draft that changed meanwhile is refused (409) instead of approved.
 */
import React, { useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import { CheckSquare, Check, X, Pencil, RefreshCw, Bot, User } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, Card, Input, Textarea, Badge } from '@/components/ui';
import { pdService, pdError, pdErrorText, type Approval } from '@/services/property-deals.service';
import { PdPage, Spinner, ErrorNote, Empty, BASE, label, dateText } from '@/components/property-deals/ui';
import { usePdData, usePdMe } from '@/components/property-deals/usePd';
import { cn } from '@/lib/utils';

export default function ApprovalsPage() {
  return (
    <PdPage module="approvals">
      <Inbox />
    </PdPage>
  );
}

function Inbox() {
  const [all, setAll] = useState(false);
  const inbox = usePdData(async () => (await pdService.inbox(all)).data, [all], 30_000);
  const [selected, setSelected] = useState<string | null>(null);
  const items = useMemo(() => inbox.data || [], [inbox.data]);
  const current = items.find((a) => a.uuid === selected) || items[0];

  return (
    <div className="space-y-6">
      <PageHeader
        title="Approvals"
        description="Nothing leaves the system without a person. Check each draft, edit it if needed, then approve or reject."
        icon={<CheckSquare className="h-6 w-6" />}
        actions={
          <>
            <label className="flex items-center gap-2 text-sm text-secondary-600">
              <input type="checkbox" checked={all} onChange={(e) => setAll(e.target.checked)} /> Show ones I can&apos;t decide
            </label>
            <Button variant="outline" leftIcon={<RefreshCw className="h-4 w-4" />} onClick={inbox.refresh}>Refresh</Button>
          </>
        }
      />
      <ErrorNote error={inbox.error} />
      {inbox.loading && !inbox.data ? (
        <Spinner />
      ) : items.length === 0 ? (
        <Empty title="Inbox zero">No drafts are waiting for you.</Empty>
      ) : (
        <div className="grid gap-6 lg:grid-cols-[22rem_1fr]">
          <Card padding="none" data-tour="approvals-list">
            <ul className="max-h-[70vh] divide-y divide-secondary-100 overflow-y-auto" role="listbox" aria-label="Approvals waiting">
              {items.map((a) => (
                <li key={a.uuid}>
                  <button
                    type="button"
                    role="option"
                    aria-selected={current?.uuid === a.uuid}
                    onClick={() => setSelected(a.uuid)}
                    className={cn('w-full p-4 text-left text-sm hover:bg-secondary-50 focus:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-primary-500', current?.uuid === a.uuid && 'bg-primary-500/5')}
                  >
                    <div className="font-medium text-secondary-900">{a.title}</div>
                    <div className="mt-1 flex flex-wrap items-center gap-2 text-xs text-secondary-500">
                      {a.agent_key ? <span className="inline-flex items-center gap-1"><Bot className="h-3 w-3" aria-hidden />{label(a.agent_key)}</span> : <span className="inline-flex items-center gap-1"><User className="h-3 w-3" aria-hidden />person</span>}
                      {a.from_jobshout && <Badge size="sm" variant="info">JobShout</Badge>}
                      <Badge size="sm" variant={a.rule === 'manager' ? 'warning' : 'default'}>{label(a.rule)}</Badge>
                      {a.can_decide === false && <Badge size="sm" variant="secondary">not yours</Badge>}
                    </div>
                  </button>
                </li>
              ))}
            </ul>
          </Card>
          {current && <Detail key={current.uuid + ':' + current.payload_version} a={current} onDone={() => { setSelected(null); inbox.refresh(); }} />}
        </div>
      )}
    </div>
  );
}

/** Line diff (LCS) between two texts for the "what did I change" view. */
function lineDiff(a: string, b: string): { t: 'same' | 'add' | 'del'; s: string }[] {
  const x = a.split('\n');
  const y = b.split('\n');
  const n = x.length;
  const m = y.length;
  const dp: number[][] = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) dp[i][j] = x[i] === y[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
  const out: { t: 'same' | 'add' | 'del'; s: string }[] = [];
  let i = 0;
  let j = 0;
  while (i < n && j < m) {
    if (x[i] === y[j]) { out.push({ t: 'same', s: x[i] }); i++; j++; }
    else if (dp[i + 1][j] >= dp[i][j + 1]) out.push({ t: 'del', s: x[i++] });
    else out.push({ t: 'add', s: y[j++] });
  }
  while (i < n) out.push({ t: 'del', s: x[i++] });
  while (j < m) out.push({ t: 'add', s: y[j++] });
  return out;
}

function asObj(v: unknown): Record<string, unknown> {
  if (typeof v === 'string') { try { return JSON.parse(v); } catch { return {}; } }
  return (v as Record<string, unknown>) || {};
}

function Detail({ a, onDone }: { a: Approval; onDone: () => void }) {
  const { can } = usePdMe();
  const payload = useMemo(() => asObj(a.payload), [a.payload]);
  const isEmail = typeof payload.body === 'string';
  const [draft, setDraft] = useState<Record<string, unknown>>(payload);
  const [json, setJson] = useState(JSON.stringify(payload, null, 2));
  const [editing, setEditing] = useState(false);
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const steps = (Array.isArray(a.run_steps) ? a.run_steps : asObj(a.run_steps)) as { tool?: string; refused?: boolean; reason?: string; round?: number }[] | Record<string, never>;
  const stepList = Array.isArray(steps) ? steps.filter((s) => s.tool) : [];
  const original = asObj(a.original_payload);

  useEffect(() => { setDraft(payload); setJson(JSON.stringify(payload, null, 2)); }, [payload]);

  const edited = isEmail ? JSON.stringify(draft) !== JSON.stringify(payload) : json !== JSON.stringify(payload, null, 2);

  async function decide(decision: 'approve' | 'reject') {
    setBusy(decision);
    try {
      let editedPayload: unknown;
      if (decision === 'approve' && edited) editedPayload = isEmail ? draft : JSON.parse(json);
      const res = await pdService.decide(a.uuid, {
        decision,
        note: note || undefined,
        payload: editedPayload,
        payload_version: a.payload_version,
      } as never);
      const s = res.data.status;
      toast.success(decision === 'reject' ? 'Rejected — the task is back with a person' : s === 'executed' ? 'Approved and done' : s === 'failed' ? 'Approved, but it couldn’t run (see the reason)' : res.data.waiting_for ? 'Approved — needs a second person' : 'Approved');
      if (s === 'failed') toast.error(String(asObj(res.data.execution_result).error || 'Execution failed'));
      // WhatsApp (and SMS without a gateway): open the click-to-send link with the approved text.
      const link = asObj(res.data.execution_result).manual_link;
      if (s === 'executed' && typeof link === 'string' && /^(https:\/\/wa\.me\/|sms:)/.test(link)) {
        window.open(link, '_blank', 'noopener,noreferrer');
        toast.success('Opened — press send, then mark the follow-up task done');
      }
      onDone();
    } catch (e) {
      const err = pdError(e);
      toast.error(err.status === 409 && /changed/.test(err.message) ? 'The draft changed since you opened it — reloading' : pdErrorText(e));
      if (err.status === 409) onDone();
    } finally {
      setBusy(null);
    }
  }

  const before = String((original.body ?? payload.body ?? '') as string);
  const after = String((draft.body ?? '') as string);

  return (
    <Card data-tour="approval-editor">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-lg font-semibold text-secondary-900">{a.title}</h2>
          <div className="mt-1 flex flex-wrap gap-x-3 text-sm text-secondary-500">
            <span>{label(a.subject_type)} · {label(a.action)}</span>
            {a.deal_uuid && <Link className="text-primary-600 hover:underline" href={`${BASE}/deals/${a.deal_uuid}`}>{a.deal_name || 'Deal'}</Link>}
            {a.task_title && <span>Task: {a.task_title}</span>}
            <span>Asked {dateText(a.created_at, true)}</span>
          </div>
        </div>
        <div className="text-right text-xs text-secondary-500">
          {a.agent_key ? (
            <>
              <div>Agent: <b className="text-secondary-800">{label(a.agent_key)}</b>{a.from_jobshout ? ' (JobShout)' : ''}</div>
              {a.model && <div>Model: {a.model}</div>}
              <div>Cost: ${Number(a.cost_usd || 0).toFixed(4)} · {a.tokens_in ?? 0}+{a.tokens_out ?? 0} tokens</div>
            </>
          ) : (
            <div>Asked by a person</div>
          )}
          <div>Version {a.payload_version} · {label(a.rule)}</div>
        </div>
      </div>

      {stepList.length > 0 && (
        <details className="mt-4 rounded-lg bg-secondary-50 p-3 text-sm">
          <summary className="cursor-pointer font-medium text-secondary-700">Sources: what the agent looked at ({stepList.length})</summary>
          <ul className="mt-2 space-y-1 text-secondary-600">
            {stepList.map((s, i) => (
              <li key={i} className={cn(s.refused && 'text-error-600')}>
                {s.refused ? `Refused: ${s.tool} (${s.reason})` : `Read ${label(s.tool)}`}
              </li>
            ))}
          </ul>
        </details>
      )}

      <div className="mt-4 space-y-3">
        {isEmail ? (
          <>
            {a.action === 'send_lead_followup' && (
              <div className="rounded-lg bg-secondary-50 p-3 text-sm text-secondary-700">
                <div>Personal follow-up by <b>{label(String(payload.channel || 'email'))}</b>{payload.signal_title ? <> · opens with: <i>{String(payload.signal_title)}</i></> : null}</div>
                {payload.why ? <div className="mt-0.5 text-xs text-secondary-500">Why it’s personal: {String(payload.why)}</div> : null}
                {payload.channel === 'whatsapp' && <div className="mt-0.5 text-xs text-secondary-500">Approving opens WhatsApp with this text ready to send (no paid API).</div>}
              </div>
            )}
            <div className="grid gap-3 sm:grid-cols-2">
              <Input label="To" value={String(draft.to ?? '')} disabled={!editing} onChange={(e) => setDraft({ ...draft, to: e.target.value })} />
              {(a.action !== 'send_lead_followup' || (payload.channel ?? 'email') === 'email') && (
                <Input label="Subject" value={String(draft.subject ?? '')} disabled={!editing} onChange={(e) => setDraft({ ...draft, subject: e.target.value })} />
              )}
            </div>
            <Textarea label="Message" rows={10} value={after} disabled={!editing} onChange={(e) => setDraft({ ...draft, body: e.target.value })} />
            {Array.isArray(payload.enquiry_updates) && (payload.enquiry_updates as unknown[]).length > 0 && (
              <div className="rounded-lg bg-info-500/10 p-3 text-sm text-info-700">
                Also proposed: {(payload.enquiry_updates as { title?: string; action?: string }[]).map((u) => `${u.action} “${u.title}”`).join('; ')}
              </div>
            )}
          </>
        ) : (
          <Textarea label="Draft (JSON)" rows={12} value={json} disabled={!editing} onChange={(e) => setJson(e.target.value)} className="font-mono text-xs" />
        )}
        {(edited || Boolean(a.original_payload)) && isEmail && before !== after && (
          <div className="rounded-lg border border-secondary-200 p-3" aria-label="Changes">
            <div className="mb-1 text-xs font-medium text-secondary-500">Changes vs the {a.original_payload ? 'original' : 'agent’s'} draft</div>
            <pre className="whitespace-pre-wrap text-xs">
              {lineDiff(before, after).map((l, i) => (
                <div key={i} className={cn(l.t === 'add' && 'bg-success-500/10 text-success-700', l.t === 'del' && 'bg-error-500/10 text-error-700 line-through')}>
                  {l.t === 'add' ? '+ ' : l.t === 'del' ? '− ' : '  '}{l.s}
                </div>
              ))}
            </pre>
          </div>
        )}
        <Input label="Note (required to reject; the agent redrafts with it)" value={note} onChange={(e) => setNote(e.target.value)} />
      </div>

      {a.can_decide !== false && can('approvals', 'update') ? (
        <div className="mt-5 flex flex-wrap justify-end gap-2">
          <Button variant="danger" leftIcon={<X className="h-4 w-4" />} disabled={!note} isLoading={busy === 'reject'} onClick={() => decide('reject')}>
            Reject
          </Button>
          {!editing ? (
            <Button variant="outline" leftIcon={<Pencil className="h-4 w-4" />} onClick={() => setEditing(true)}>Edit</Button>
          ) : null}
          <Button leftIcon={<Check className="h-4 w-4" />} isLoading={busy === 'approve'} onClick={() => decide('approve')}>
            {edited ? 'Approve edited version' : 'Approve'}
          </Button>
        </div>
      ) : (
        <p className="mt-4 text-sm text-secondary-500">
          {a.rule === 'manager' ? 'This needs a manager.' : 'You can’t decide this one (your own request, or already approved by you).'}
        </p>
      )}
    </Card>
  );
}

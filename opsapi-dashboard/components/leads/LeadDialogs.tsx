'use client';

/**
 * The lead page's actions, one dialog each: log a call, plan a step, book or
 * move a meeting, qualify, convert to a deal, pass to a partner, record a
 * meeting's outcome. Each shows the server's message next to the field it
 * is about, and never closes on an error.
 */
import React, { useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import toast from 'react-hot-toast';
import { Button, Modal } from '@/components/ui';
import { cn } from '@/lib/utils';
import {
  leadError, leadsService, type CallOutcome, type Lead, type Meeting, type Partner, type SettingsBundle,
} from '@/services/leads.service';
import { FieldError, fullName, inHours, isoToLocal, localToIso, money } from './ui';

const field = 'w-full rounded-lg border border-secondary-300 px-3 py-2 text-sm focus:border-primary-500 focus:outline-none focus:ring-2 focus:ring-primary-500/20';
const labelCls = 'block text-sm font-medium text-secondary-700';

function useForm<T>() {
  const [busy, setBusy] = useState(false);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const run = async (fn: () => Promise<T>, ok: (v: T) => void) => {
    setBusy(true); setErrors({});
    try {
      ok(await fn());
    } catch (e) {
      const err = leadError(e);
      setErrors(err.fields ?? {});
      toast.error(err.message);
    } finally {
      setBusy(false);
    }
  };
  return { busy, errors, run };
}

// ---------------------------------------------------------------------------
// Log a call
// ---------------------------------------------------------------------------

const OUTCOME_ORDER: CallOutcome[] = ['connected', 'no_answer', 'voicemail', 'callback', 'wrong_number', 'not_interested'];

const OUTCOME_HELP: Record<CallOutcome, string> = {
  connected: 'You talked to them.',
  no_answer: 'We plan the next try for you.',
  voicemail: 'We plan the next try for you.',
  wrong_number: 'We flag the number so nobody calls it again.',
  callback: 'Pick when they asked you to call back.',
  not_interested: 'The lead moves to Lost.',
};

export function LogCallDialog({ lead, outcomes, onClose, onDone }: {
  lead: Lead; outcomes: Record<CallOutcome, string>; onClose: () => void; onDone: (l: Lead, note?: string) => void;
}) {
  const [outcome, setOutcome] = useState<CallOutcome | ''>('');
  const [notes, setNotes] = useState('');
  const [minutes, setMinutes] = useState('');
  const [nextAt, setNextAt] = useState('');
  const f = useForm<Awaited<ReturnType<typeof leadsService.logCall>>>();
  const needsTime = outcome === 'callback';
  return (
    <Modal isOpen onClose={onClose} size="lg" title={`How did the call with ${fullName(lead)} go?`}
      footer={<>
        <Button variant="ghost" onClick={onClose} disabled={f.busy}>Cancel</Button>
        <Button disabled={!outcome || (needsTime && !nextAt)} isLoading={f.busy} onClick={() => outcome && f.run(
          () => leadsService.logCall(lead.uuid, { outcome, notes: notes.trim() || undefined,
            duration_minutes: minutes ? Number(minutes) : undefined, next_at: nextAt ? localToIso(nextAt) : undefined }),
          (r) => { toast.success('Call logged'); onDone(r.lead, r.suggestion?.message); })}>Save call</Button>
      </>}>
      <div className="space-y-4">
        <fieldset>
          <legend className={labelCls}>Outcome</legend>
          <div className="mt-2 grid grid-cols-2 gap-2 sm:grid-cols-3">
            {OUTCOME_ORDER.filter((o) => outcomes[o]).map((o) => (
              <button key={o} type="button" onClick={() => setOutcome(o)} aria-pressed={outcome === o}
                className={cn('rounded-lg border px-3 py-2 text-left text-sm transition',
                  outcome === o ? 'border-primary-500 bg-primary-50 text-primary-800 ring-2 ring-primary-500/20' : 'border-secondary-200 hover:border-secondary-300')}>
                <span className="font-medium">{outcomes[o]}</span>
                <span className="mt-0.5 block text-[11px] text-secondary-500">{OUTCOME_HELP[o]}</span>
              </button>
            ))}
          </div>
          <FieldError message={f.errors.outcome} />
        </fieldset>
        {(needsTime || outcome === 'connected') && (
          <div>
            <label className={labelCls} htmlFor="call-next">{needsTime ? 'Call them back at' : 'Next call (optional)'}</label>
            <input id="call-next" type="datetime-local" className={cn(field, 'mt-1')} value={nextAt} min={inHours(0)}
              onChange={(e) => setNextAt(e.target.value)} />
            <FieldError message={f.errors.next_at} />
          </div>
        )}
        <div>
          <label className={labelCls} htmlFor="call-notes">What did you learn?</label>
          <textarea id="call-notes" rows={4} className={cn(field, 'mt-1')} value={notes} onChange={(e) => setNotes(e.target.value)}
            maxLength={4000} placeholder="Budget, timing, who decides… The AI uses these notes to update its analysis." />
        </div>
        <div className="w-40">
          <label className={labelCls} htmlFor="call-min">Length (minutes)</label>
          <input id="call-min" type="number" min={0} max={600} className={cn(field, 'mt-1')} value={minutes}
            onChange={(e) => setMinutes(e.target.value)} />
          <FieldError message={f.errors.duration_minutes} />
        </div>
      </div>
    </Modal>
  );
}

// ---------------------------------------------------------------------------
// Plan a step
// ---------------------------------------------------------------------------

export function PlanStepDialog({ lead, onClose, onDone }: { lead: Lead; onClose: () => void; onDone: (l: Lead) => void }) {
  const [type, setType] = useState('call');
  const [due, setDue] = useState(inHours(24));
  const [note, setNote] = useState('');
  const f = useForm<Lead>();
  return (
    <Modal isOpen onClose={onClose} size="sm" title="Plan the next step"
      description="It shows in the owner's next steps, and they're reminded before it's due."
      footer={<>
        <Button variant="ghost" onClick={onClose} disabled={f.busy}>Cancel</Button>
        <Button isLoading={f.busy} onClick={() => f.run(() => leadsService.planStep(lead.uuid, { type, due_at: localToIso(due) ?? '',
          note: note.trim() || undefined }), (l) => { toast.success('Step planned'); onDone(l); })}>Plan it</Button>
      </>}>
      <div className="space-y-3">
        <div>
          <label className={labelCls} htmlFor="step-type">What</label>
          <select id="step-type" className={cn(field, 'mt-1')} value={type} onChange={(e) => setType(e.target.value)}>
            <option value="call">Call</option><option value="email">Email</option>
            <option value="follow_up">Follow up</option><option value="task">Other task</option>
          </select>
          <FieldError message={f.errors.type} />
        </div>
        <div>
          <label className={labelCls} htmlFor="step-due">When</label>
          <input id="step-due" type="datetime-local" className={cn(field, 'mt-1')} value={due} onChange={(e) => setDue(e.target.value)} />
          <FieldError message={f.errors.due_at} />
        </div>
        <div>
          <label className={labelCls} htmlFor="step-note">Note (optional)</label>
          <input id="step-note" className={cn(field, 'mt-1')} value={note} maxLength={2000} onChange={(e) => setNote(e.target.value)} />
        </div>
      </div>
    </Modal>
  );
}

// ---------------------------------------------------------------------------
// Book or move a meeting
// ---------------------------------------------------------------------------

export function MeetingDialog({ lead, meeting, settings, onClose, onDone }: {
  lead: Lead; meeting?: Meeting | null; settings: SettingsBundle | null; onClose: () => void; onDone: () => void;
}) {
  const types = settings?.meeting_types ?? { video: 'Video call', phone: 'Phone call', in_person: 'In person', viewing: 'Viewing' };
  const [type, setType] = useState<string>(meeting?.type ?? 'video');
  const [starts, setStarts] = useState(meeting ? isoToLocal(meeting.starts_at) : inHours(48).slice(0, 11) + '10:00');
  const [minutes, setMinutes] = useState(String(meeting?.duration_minutes ?? settings?.settings.meeting.default_minutes ?? 30));
  const [link, setLink] = useState(meeting?.meeting_url ?? settings?.settings.meeting.default_link ?? '');
  const [location, setLocation] = useState(meeting?.location ?? '');
  const [notes, setNotes] = useState(meeting?.description ?? '');
  const [guests, setGuests] = useState('');
  const [sendInvite, setSendInvite] = useState(settings?.settings.meeting.send_invites ?? true);
  const f = useForm<Meeting>();
  const physical = type === 'in_person' || type === 'viewing';
  const submit = () => {
    const body: Record<string, unknown> = {
      type, starts_at: localToIso(starts), duration_minutes: Number(minutes) || 30,
      meeting_url: physical ? null : (link.trim() || null), location: physical ? location.trim() : (location.trim() || null),
      notes: notes.trim() || null,
    };
    if (!meeting) {
      body.send_invite = sendInvite;
      const g = guests.split(/[\s,;]+/).map((x) => x.trim()).filter(Boolean);
      if (g.length) body.guests = g.map((email) => ({ email }));
    }
    f.run(() => (meeting ? leadsService.updateMeeting(meeting.uuid, body) : leadsService.bookMeeting(lead.uuid, body)),
      () => {
        toast.success(meeting ? 'Meeting moved. Everyone gets the updated invite.'
          : sendInvite && lead.email ? `Meeting booked. ${fullName(lead)} gets a calendar invite by email.` : 'Meeting booked');
        onDone();
      });
  };
  return (
    <Modal isOpen onClose={onClose} size="lg" title={meeting ? 'Move the meeting' : `Book a meeting with ${fullName(lead)}`}
      footer={<>
        <Button variant="ghost" onClick={onClose} disabled={f.busy}>Cancel</Button>
        <Button isLoading={f.busy} onClick={submit}>{meeting ? 'Save and send update' : 'Book meeting'}</Button>
      </>}>
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <div>
          <label className={labelCls} htmlFor="m-type">Kind of meeting</label>
          <select id="m-type" className={cn(field, 'mt-1')} value={type} onChange={(e) => setType(e.target.value)}>
            {Object.entries(types).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
          </select>
          <FieldError message={f.errors.type} />
        </div>
        <div>
          <label className={labelCls} htmlFor="m-len">Length (minutes)</label>
          <input id="m-len" type="number" min={5} max={480} step={5} className={cn(field, 'mt-1')} value={minutes}
            onChange={(e) => setMinutes(e.target.value)} />
          <FieldError message={f.errors.duration_minutes} />
        </div>
        <div className="sm:col-span-2">
          <label className={labelCls} htmlFor="m-start">Date and time</label>
          <input id="m-start" type="datetime-local" className={cn(field, 'mt-1')} value={starts} min={inHours(0)}
            onChange={(e) => setStarts(e.target.value)} />
          <p className="mt-1 text-xs text-secondary-500">In your time zone. Invites show it in each person’s own time.</p>
          <FieldError message={f.errors.starts_at} />
        </div>
        {physical ? (
          <div className="sm:col-span-2">
            <label className={labelCls} htmlFor="m-loc">Where</label>
            <input id="m-loc" className={cn(field, 'mt-1')} value={location} maxLength={300} onChange={(e) => setLocation(e.target.value)}
              placeholder="Address or meeting place" />
            <FieldError message={f.errors.location} />
          </div>
        ) : (
          <div className="sm:col-span-2">
            <label className={labelCls} htmlFor="m-link">Meeting link</label>
            <input id="m-link" className={cn(field, 'mt-1')} value={link} onChange={(e) => setLink(e.target.value)}
              placeholder="https://teams.microsoft.com/… or Zoom / Google Meet link" />
            <FieldError message={f.errors.meeting_url} />
          </div>
        )}
        <div className="sm:col-span-2">
          <label className={labelCls} htmlFor="m-notes">Agenda (optional, shown in the invite)</label>
          <textarea id="m-notes" rows={3} className={cn(field, 'mt-1')} value={notes} maxLength={2000} onChange={(e) => setNotes(e.target.value)} />
        </div>
        {!meeting && (
          <>
            <div className="sm:col-span-2">
              <label className={labelCls} htmlFor="m-guests">Other guests (optional)</label>
              <input id="m-guests" className={cn(field, 'mt-1')} value={guests} onChange={(e) => setGuests(e.target.value)}
                placeholder="Emails, separated by commas" />
              <FieldError message={f.errors.guests} />
            </div>
            <label className="flex items-start gap-2 text-sm text-secondary-700 sm:col-span-2">
              <input type="checkbox" className="mt-0.5 h-4 w-4 rounded border-secondary-300" checked={sendInvite}
                onChange={(e) => setSendInvite(e.target.checked)} />
              <span>Email everyone a calendar invite{lead.email ? '' : ' (this lead has no email, so only staff and guests get one)'}.
                They get a reminder before it starts.</span>
            </label>
          </>
        )}
      </div>
    </Modal>
  );
}

export function MeetingOutcomeDialog({ meeting, onClose, onDone }: { meeting: Meeting; onClose: () => void; onDone: () => void }) {
  const [outcome, setOutcome] = useState<'held' | 'no_show'>('held');
  const [notes, setNotes] = useState('');
  const f = useForm<Meeting>();
  return (
    <Modal isOpen onClose={onClose} size="md" title="How did the meeting go?"
      footer={<>
        <Button variant="ghost" onClick={onClose} disabled={f.busy}>Cancel</Button>
        <Button isLoading={f.busy} onClick={() => f.run(() => leadsService.meetingOutcome(meeting.uuid, outcome, notes.trim() || undefined),
          () => { toast.success(outcome === 'held' ? 'Saved. The AI is updating its analysis.' : 'Saved. A call to rebook is planned.'); onDone(); })}>
          Save</Button>
      </>}>
      <div className="space-y-4">
        <div className="grid grid-cols-2 gap-2">
          {([['held', 'It happened'], ['no_show', "They didn't come"]] as const).map(([k, v]) => (
            <button key={k} type="button" aria-pressed={outcome === k} onClick={() => setOutcome(k)}
              className={cn('rounded-lg border px-3 py-2 text-sm font-medium',
                outcome === k ? 'border-primary-500 bg-primary-50 text-primary-800' : 'border-secondary-200')}>{v}</button>
          ))}
        </div>
        <div>
          <label className={labelCls} htmlFor="mo-notes">{outcome === 'held' ? 'What did you agree?' : 'Notes (optional)'}</label>
          <textarea id="mo-notes" rows={4} className={cn(field, 'mt-1')} value={notes} maxLength={4000} onChange={(e) => setNotes(e.target.value)} />
          <FieldError message={f.errors.outcome} />
        </div>
      </div>
    </Modal>
  );
}

// ---------------------------------------------------------------------------
// Qualify
// ---------------------------------------------------------------------------

export function QualifyDialog({ lead, settings, onClose, onDone }: {
  lead: Lead; settings: SettingsBundle | null; onClose: () => void; onDone: (l: Lead) => void;
}) {
  const questions = settings?.settings.qualification_questions ?? [];
  const [answers, setAnswers] = useState<Record<string, string>>(() => ({ ...(lead.qualification ?? {}) }));
  const [value, setValue] = useState(lead.estimated_value ? String(lead.estimated_value) : '');
  const [currency, setCurrency] = useState(lead.currency || settings?.settings.currency || 'GBP');
  const [close, setClose] = useState(lead.expected_close_date ?? '');
  const [move, setMove] = useState(['new', 'contacting'].includes(lead.stage));
  const f = useForm<Lead>();
  const aiValue = lead.analysis?.result?.estimated_value;
  return (
    <Modal isOpen onClose={onClose} size="lg" title="Qualify the lead"
      description="Record what you know. The value and close date carry over to the deal."
      footer={<>
        <Button variant="ghost" onClick={onClose} disabled={f.busy}>Cancel</Button>
        <Button isLoading={f.busy} onClick={() => f.run(() => leadsService.qualify(lead.uuid, {
          answers: Object.fromEntries(questions.map((q) => [q.key, answers[q.key]?.trim() ? answers[q.key].trim() : null])),
          estimated_value: value === '' ? null : Number(value), currency, expected_close_date: close || null, move,
        }), (l) => { toast.success(move ? 'Qualified' : 'Saved'); onDone(l); })}>Save</Button>
      </>}>
      <div className="space-y-4">
        {questions.map((q) => (
          <div key={q.key}>
            <label className={labelCls} htmlFor={`q-${q.key}`}>{q.label}</label>
            <input id={`q-${q.key}`} className={cn(field, 'mt-1')} value={answers[q.key] ?? ''} maxLength={1000}
              onChange={(e) => setAnswers((a) => ({ ...a, [q.key]: e.target.value }))} />
            <FieldError message={f.errors[`answers.${q.key}`]} />
          </div>
        ))}
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <div className="sm:col-span-2">
            <label className={labelCls} htmlFor="q-value">Estimated value</label>
            <input id="q-value" type="number" min={0} step="0.01" className={cn(field, 'mt-1')} value={value}
              onChange={(e) => setValue(e.target.value)} placeholder={aiValue ? `AI estimate: ${money(aiValue, currency)}` : ''} />
            <FieldError message={f.errors.estimated_value} />
          </div>
          <div>
            <label className={labelCls} htmlFor="q-cur">Currency</label>
            <input id="q-cur" className={cn(field, 'mt-1 uppercase')} maxLength={3} value={currency} onChange={(e) => setCurrency(e.target.value.toUpperCase())} />
            <FieldError message={f.errors.currency} />
          </div>
          <div className="sm:col-span-2">
            <label className={labelCls} htmlFor="q-close">Expected to close</label>
            <input id="q-close" type="date" className={cn(field, 'mt-1')} value={close} onChange={(e) => setClose(e.target.value)} />
            <FieldError message={f.errors.expected_close_date} />
          </div>
        </div>
        {['new', 'contacting'].includes(lead.stage) && (
          <label className="flex items-center gap-2 text-sm text-secondary-700">
            <input type="checkbox" className="h-4 w-4 rounded border-secondary-300" checked={move} onChange={(e) => setMove(e.target.checked)} />
            Move the lead to Qualified
          </label>
        )}
      </div>
    </Modal>
  );
}

// ---------------------------------------------------------------------------
// Convert
// ---------------------------------------------------------------------------

export function ConvertDialog({ lead, settings, onClose, onDone }: {
  lead: Lead; settings: SettingsBundle | null; onClose: () => void; onDone: (dealUuid: string) => void;
}) {
  const ai = lead.analysis?.result;
  const [name, setName] = useState('');
  const [value, setValue] = useState(lead.estimated_value ? String(lead.estimated_value) : ai?.estimated_value ? String(ai.estimated_value) : '');
  const [close, setClose] = useState(lead.expected_close_date ?? '');
  const f = useForm<Awaited<ReturnType<typeof leadsService.convert>>>();
  const currency = lead.currency || settings?.settings.currency || 'GBP';
  return (
    <Modal isOpen onClose={onClose} size="md" title={`Convert ${fullName(lead)} to a deal`}
      description="Creates the contact (and the company), and a deal owned by the lead's owner. Calls, meetings and referrals move to the deal."
      footer={<>
        <Button variant="ghost" onClick={onClose} disabled={f.busy}>Cancel</Button>
        <Button isLoading={f.busy} onClick={() => f.run(() => leadsService.convert(lead.uuid, {
          name: name.trim() || undefined, value: value === '' ? undefined : Number(value), currency,
          expected_close_date: close || undefined }), (r) => { toast.success(`Deal created: ${r.deal_name}`); onDone(r.deal_uuid); })}>
          Convert to deal</Button>
      </>}>
      <div className="space-y-4">
        <div>
          <label className={labelCls} htmlFor="c-name">Deal name (optional)</label>
          <input id="c-name" className={cn(field, 'mt-1')} value={name} maxLength={200} onChange={(e) => setName(e.target.value)}
            placeholder={`${lead.company_name || fullName(lead)}${ai?.wants ? ` — ${ai.wants}` : ''}`} />
        </div>
        <div>
          <label className={labelCls} htmlFor="c-value">Deal value ({currency})</label>
          <input id="c-value" type="number" min={0} step="0.01" className={cn(field, 'mt-1')} value={value} onChange={(e) => setValue(e.target.value)} />
          {lead.metadata?.value_from === 'ai' && <p className="mt-1 text-xs text-secondary-500">This is the AI’s estimate. Change it if you know better.</p>}
          <FieldError message={f.errors.value} />
        </div>
        <div>
          <label className={labelCls} htmlFor="c-close">Expected to close (optional)</label>
          <input id="c-close" type="date" className={cn(field, 'mt-1')} value={close} onChange={(e) => setClose(e.target.value)} />
          <FieldError message={f.errors.expected_close_date} />
        </div>
      </div>
    </Modal>
  );
}

// ---------------------------------------------------------------------------
// Pass to a partner
// ---------------------------------------------------------------------------

export function ReferDialog({ lead, preselect, onClose, onDone }: {
  lead: Lead; preselect?: string | null; onClose: () => void; onDone: () => void;
}) {
  const [partners, setPartners] = useState<Partner[] | null>(null);
  const [partnerUuid, setPartnerUuid] = useState(preselect ?? '');
  const [value, setValue] = useState(lead.estimated_value ? String(lead.estimated_value) : '');
  const [kind, setKind] = useState<'percent' | 'fixed'>('percent');
  const [rate, setRate] = useState('');
  const [message, setMessage] = useState('');
  const [share, setShare] = useState(false);
  const [consent, setConsent] = useState(false);
  const f = useForm<unknown>();
  const suggestions = useMemo(() => lead.analysis?.result?.partner_suggestions ?? [], [lead]);

  // Picking a partner fills in its usual commission.
  const choose = (uuid: string, list: Partner[] | null = partners) => {
    setPartnerUuid(uuid);
    const p = list?.find((x) => x.uuid === uuid);
    if (p) { setKind(p.commission_type); setRate(String(Number(p.commission_value))); }
  };
  useEffect(() => {
    let alive = true;
    leadsService.partners().then((list) => {
      if (!alive) return;
      setPartners(list);
      if (preselect) choose(preselect, list);
    }).catch((e) => { if (alive) { toast.error(leadError(e).message); setPartners([]); } });
    return () => { alive = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- load once; `choose` only sets state
  }, []);

  const ordered = useMemo(() => {
    if (!partners) return [];
    const fit = new Map(suggestions.map((s) => [s.partner_uuid, s]));
    return [...partners].sort((a, b) => (fit.get(b.uuid)?.fit ?? -1) - (fit.get(a.uuid)?.fit ?? -1));
  }, [partners, suggestions]);
  const chosen = partners?.find((p) => p.uuid === partnerUuid);
  const commission = kind === 'fixed' ? Number(rate || 0) : (Number(value || 0) * Number(rate || 0)) / 100;
  const reason = suggestions.find((s) => s.partner_uuid === partnerUuid)?.reason ?? undefined;

  return (
    <Modal isOpen onClose={onClose} size="lg" title="Pass to a partner"
      description="A partner fulfils the work and you earn a commission. They get a private link to accept or decline."
      footer={<>
        <Button variant="ghost" onClick={onClose} disabled={f.busy}>Cancel</Button>
        <Button disabled={!partnerUuid || (share && !consent)} isLoading={f.busy} onClick={() => f.run(() => leadsService.refer({
          lead_uuid: lead.converted_deal_uuid ? undefined : lead.uuid, deal_uuid: lead.converted_deal_uuid ?? undefined,
          partner_uuid: partnerUuid, deal_value: value === '' ? undefined : Number(value), commission_type: kind,
          commission_value: rate === '' ? undefined : Number(rate), message: message.trim() || undefined, share_contact: share,
          consent_confirmed: share ? consent : undefined, ai_reason: reason,
        }), () => { toast.success(`Sent to ${chosen?.name ?? 'the partner'}`); onDone(); })}>Send to partner</Button>
      </>}>
      {partners === null ? <p className="text-sm text-secondary-500">Loading partners…</p> : partners.length === 0 ? (
        <p className="text-sm text-secondary-600">You have no partners yet. Add the companies you pass work to under <Link className="font-medium text-primary-600 underline" href="/dashboard/leads/partners">Partners</Link>.</p>
      ) : (
        <div className="space-y-4">
          <fieldset>
            <legend className={labelCls}>Partner</legend>
            <div className="mt-2 max-h-56 space-y-2 overflow-y-auto pr-1">
              {ordered.map((p) => {
                const s = suggestions.find((x) => x.partner_uuid === p.uuid);
                return (
                  <label key={p.uuid} className={cn('flex cursor-pointer items-start gap-3 rounded-lg border p-3',
                    partnerUuid === p.uuid ? 'border-primary-500 bg-primary-50/60' : 'border-secondary-200 hover:border-secondary-300')}>
                    <input type="radio" name="partner" className="mt-1" checked={partnerUuid === p.uuid} onChange={() => choose(p.uuid)} />
                    <span className="min-w-0 flex-1">
                      <span className="flex items-center gap-2 text-sm font-medium text-secondary-900">{p.name}
                        {s && <span className="rounded bg-primary-500/10 px-1.5 py-0.5 text-[11px] font-semibold text-primary-700">AI fit {s.fit ?? '—'}</span>}
                      </span>
                      <span className="block text-xs text-secondary-500">{p.offering || p.categories.join(', ') || 'No description'}</span>
                      {s?.reason && <span className="mt-0.5 block text-xs text-primary-700">{s.reason}</span>}
                    </span>
                  </label>
                );
              })}
            </div>
            <FieldError message={f.errors.partner_uuid || f.errors.referral_email} />
          </fieldset>
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
            <div>
              <label className={labelCls} htmlFor="r-value">Deal value</label>
              <input id="r-value" type="number" min={0} className={cn(field, 'mt-1')} value={value} onChange={(e) => setValue(e.target.value)} />
              <FieldError message={f.errors.deal_value} />
            </div>
            <div>
              <label className={labelCls} htmlFor="r-kind">Commission</label>
              <select id="r-kind" className={cn(field, 'mt-1')} value={kind} onChange={(e) => setKind(e.target.value as 'percent' | 'fixed')}>
                <option value="percent">% of the deal</option><option value="fixed">Fixed fee</option>
              </select>
            </div>
            <div>
              <label className={labelCls} htmlFor="r-rate">{kind === 'percent' ? 'Percent' : 'Amount'}</label>
              <input id="r-rate" type="number" min={0} step="0.01" className={cn(field, 'mt-1')} value={rate} onChange={(e) => setRate(e.target.value)} />
              <FieldError message={f.errors.commission_value} />
            </div>
          </div>
          <p className="text-sm text-secondary-600">Your commission: <strong>{money(commission, lead.currency || 'GBP')}</strong></p>
          <div>
            <label className={labelCls} htmlFor="r-msg">Message to the partner (optional)</label>
            <textarea id="r-msg" rows={3} className={cn(field, 'mt-1')} value={message} maxLength={3000} onChange={(e) => setMessage(e.target.value)} />
          </div>
          <div className="rounded-lg border border-secondary-200 bg-secondary-50 p-3">
            <label className="flex items-start gap-2 text-sm text-secondary-800">
              <input type="checkbox" className="mt-0.5 h-4 w-4 rounded border-secondary-300" checked={share} onChange={(e) => setShare(e.target.checked)} />
              <span>Share the customer’s name and contact details with the partner</span>
            </label>
            {share && (
              <label className="mt-2 flex items-start gap-2 pl-6 text-sm text-secondary-800">
                <input type="checkbox" className="mt-0.5 h-4 w-4 rounded border-secondary-300" checked={consent} onChange={(e) => setConsent(e.target.checked)} />
                <span>The customer agreed to us sharing their details with {chosen?.name ?? 'this partner'}.</span>
              </label>
            )}
            {!share && <p className="mt-1 pl-6 text-xs text-secondary-500">The partner sees what is wanted and its size, not who it’s for. You introduce them once they accept.</p>}
            <FieldError message={f.errors.consent_confirmed} />
          </div>
        </div>
      )}
    </Modal>
  );
}

'use client';

/**
 * One lead, end to end: where it stands (stage track), who owns it, the next
 * step, what the AI made of it, and every action — call, email, WhatsApp,
 * book a meeting, qualify, pass to a partner, convert, nurture, lost — with
 * its meetings, referrals and full timeline.
 */
import React, { useCallback, useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import { useParams, useRouter } from 'next/navigation';
import toast from 'react-hot-toast';
import {
  ArrowLeft, Briefcase, CalendarPlus, CheckCircle2, ChevronRight, CircleSlash, ClipboardCheck, Clock, Handshake, Mail,
  MessageCircle, Phone, PhoneCall, Repeat, Sprout, Trash2, UserRound, Video, XCircle,
} from 'lucide-react';
import { Button, confirmDialog, promptDialog } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import PropertyDealsLeadPanel from '@/components/property-deals/LeadPanel';
import RecordFormResponses from '@/components/forms/RecordFormResponses';
import { AiCard, type AiAction } from '@/components/leads/AiCard';
import { ShopPanel } from '@/components/leads/ShopPanel';
import { VipBadge } from '@/components/shop/VipBadge';
import { useVipFor } from '@/hooks/useVipStatus';
import {
  ConvertDialog, LogCallDialog, MeetingDialog, MeetingOutcomeDialog, PlanStepDialog, QualifyDialog, ReferDialog,
} from '@/components/leads/LeadDialogs';
import { StageModal } from '@/components/leads/StageModal';
import {
  Avatar, dateOnly, dateTime, dueText, fullName, money, Section, StageBadge, STAGE_STYLE, STEP_LABEL,
} from '@/components/leads/ui';
import { cn } from '@/lib/utils';
import { useAuthStore } from '@/store/auth.store';
import {
  leadError, leadsService, type Lead, type LeadStage, type Meeting, type Referral, type SettingsBundle,
  type TeamMember, type TimelineItem,
} from '@/services/leads.service';

type Dialog =
  | { kind: 'call' } | { kind: 'step' } | { kind: 'meeting'; meeting?: Meeting } | { kind: 'outcome'; meeting: Meeting }
  | { kind: 'qualify' } | { kind: 'convert' } | { kind: 'refer'; partner?: string | null }
  | { kind: 'stage'; target: LeadStage } | null;

const FUNNEL: LeadStage[] = ['new', 'contacting', 'qualified', 'meeting', 'converted'];

function StageTrack({ lead, labels }: { lead: Lead; labels: Record<string, string> }) {
  const current = FUNNEL.indexOf(lead.stage);
  const parked = lead.stage === 'nurture' || lead.stage === 'lost';
  return (
    <ol className="flex flex-wrap items-center gap-1" aria-label="Pipeline stage">
      {FUNNEL.map((s, i) => {
        const done = !parked && current >= 0 && i < current;
        const now = s === lead.stage;
        return (
          <li key={s} className="flex items-center gap-1">
            <span aria-current={now ? 'step' : undefined}
              className={cn('inline-flex items-center gap-1.5 rounded-full px-3 py-1 text-xs font-medium',
                now ? cn(STAGE_STYLE[s].chip, 'ring-1 ring-inset') : done ? 'bg-secondary-100 text-secondary-700' : 'text-secondary-400')}>
              {done && <CheckCircle2 className="h-3.5 w-3.5 text-emerald-500" aria-hidden="true" />}
              {labels[s] ?? s}
            </span>
            {i < FUNNEL.length - 1 && <ChevronRight className="h-3.5 w-3.5 text-secondary-300" aria-hidden="true" />}
          </li>
        );
      })}
      {parked && <li className="ml-2"><StageBadge stage={lead.stage} label={labels[lead.stage]} /></li>}
    </ol>
  );
}

function LeadContent() {
  const { uuid } = useParams<{ uuid: string }>();
  const router = useRouter();
  const [lead, setLead] = useState<Lead | null>(null);
  const vip = useVipFor(lead?.email);
  const [timeline, setTimeline] = useState<TimelineItem[]>([]);
  const [settings, setSettings] = useState<SettingsBundle | null>(null);
  const [team, setTeam] = useState<TeamMember[]>([]);
  const [error, setError] = useState<{ status: number; message: string } | null>(null);
  const [dialog, setDialog] = useState<Dialog>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const myUuid = useAuthStore((st) => st.user?.uuid ?? null);

  const load = useCallback(async () => {
    try {
      const [l, t] = await Promise.all([leadsService.get(uuid), leadsService.timeline(uuid)]);
      setLead(l); setTimeline(t); setError(null);
    } catch (e) {
      const err = leadError(e);
      setError({ status: err.status, message: err.message });
    }
  }, [uuid]);

  useEffect(() => { load(); }, [load]);
  useEffect(() => {
    leadsService.settings().then(setSettings).catch(() => undefined);
    leadsService.team().then(setTeam).catch(() => undefined);
  }, []);
  // While the AI works, check back every few seconds.
  useEffect(() => {
    const s = lead?.analysis?.status;
    if (s !== 'pending' && s !== 'running') return;
    const t = setTimeout(load, 4000);
    return () => clearTimeout(t);
  }, [lead, load]);

  const labels = useMemo(() => settings?.stage_labels ?? {
    new: 'New', contacting: 'Contacting', qualified: 'Qualified', meeting: 'Meeting', converted: 'Converted', nurture: 'Nurture', lost: 'Lost',
  }, [settings]);

  if (error) {
    return (
      <div className="mx-auto max-w-lg rounded-xl border border-secondary-200 bg-white p-8 text-center">
        <p className="text-sm text-secondary-700">{error.status === 404 ? "This lead doesn't exist, or it isn't yours to see." : error.message}</p>
        <Link href="/dashboard/leads" className="mt-4 inline-flex text-sm font-medium text-primary-600 hover:underline">Back to leads</Link>
      </div>
    );
  }
  if (!lead) return <div className="p-10 text-sm text-secondary-500">Loading the lead…</div>;

  const canWork = lead.permissions?.can_work ?? false;
  const isManager = lead.permissions?.is_manager ?? false;
  const open = lead.is_open;
  const due = dueText(lead.next_action_at);
  const outcomes = lead.call_outcomes ?? settings?.call_outcomes ?? {
    connected: 'Spoke to them', no_answer: 'No answer', voicemail: 'Left a message', wrong_number: 'Wrong number',
    callback: 'Call back later', not_interested: 'Not interested' };
  const phoneDigits = (lead.phone ?? '').replace(/[^\d+]/g, '');
  const wa = phoneDigits.replace(/^\+/, '').length >= 7 ? `https://wa.me/${phoneDigits.replace(/^\+/, '')}` : null;

  const done = (l?: Lead, note?: string) => {
    setDialog(null);
    if (l) setLead(l);
    if (note) toast(note, { duration: 6000 });
    load();
  };

  const onAi = (action: AiAction, partnerUuid?: string) => {
    switch (action) {
      case 'call_now': case 'call':
        if (lead.phone) window.location.href = `tel:${phoneDigits}`;
        setDialog({ kind: 'call' }); break;
      case 'email': {
        const r = lead.analysis?.result?.first_reply;
        if (lead.email) window.location.href = `mailto:${lead.email}?subject=${encodeURIComponent(r?.subject ?? '')}&body=${encodeURIComponent(r?.body ?? '')}`;
        else toast.error('This lead has no email address');
        break;
      }
      case 'book_meeting': setDialog({ kind: 'meeting' }); break;
      case 'qualify': setDialog({ kind: 'qualify' }); break;
      case 'send_quote': setDialog({ kind: 'convert' }); break;
      case 'refer_to_partner': setDialog({ kind: 'refer', partner: partnerUuid }); break;
      case 'nurture': setDialog({ kind: 'stage', target: 'nurture' }); break;
      case 'disqualify': setDialog({ kind: 'stage', target: 'lost' }); break;
    }
  };

  const assign = async (owner: string | null) => {
    setBusy('assign');
    try {
      setLead(await leadsService.assign(lead.uuid, owner));
      toast.success(owner ? 'Owner changed' : 'Back in the queue');
      load();
    } catch (e) { toast.error(leadError(e).message); } finally { setBusy(null); }
  };

  const reopen = async () => {
    setBusy('reopen');
    try { setLead(await leadsService.move(lead.uuid, 'contacting')); toast.success('Reopened. A call is planned.'); load(); }
    catch (e) { toast.error(leadError(e).message); } finally { setBusy(null); }
  };

  const remove = async () => {
    if (!(await confirmDialog({ title: `Delete ${fullName(lead)}?`, message: 'The lead and its planned steps are removed. This can’t be undone from here.',
      confirmText: 'Delete lead', danger: true }))) return;
    try { await leadsService.remove(lead.uuid); toast.success('Lead deleted'); router.push('/dashboard/leads'); }
    catch (e) { toast.error(leadError(e).message); }
  };

  const cancelMeeting = async (m: Meeting) => {
    const reason = await promptDialog({ title: 'Cancel the meeting?', label: 'Reason (optional, included in the cancellation)',
      placeholder: 'e.g. they asked to move it', confirmText: 'Cancel meeting' });
    if (reason === null) return;
    try { await leadsService.cancelMeeting(m.uuid, reason || undefined); toast.success('Meeting cancelled. Everyone invited is told.'); load(); }
    catch (e) { toast.error(leadError(e).message); }
  };

  const moveReferral = async (r: Referral, status: Referral['status']) => {
    let deal_value: number | undefined;
    if (status === 'won') {
      const v = await promptDialog({ title: `${r.partner_name} won it`, label: 'Final deal value (for the commission)',
        defaultValue: r.deal_value ? String(r.deal_value) : '', inputType: 'number', confirmText: 'Save' });
      if (v === null) return;
      deal_value = v === '' ? undefined : Number(v);
    }
    try { await leadsService.moveReferral(r.uuid, { status, deal_value }); toast.success('Referral updated'); load(); }
    catch (e) { toast.error(leadError(e).message); }
  };

  const billCommission = async (r: Referral) => {
    const tax = await promptDialog({ title: `Invoice ${r.partner_name} for the commission`,
      label: 'VAT rate % (0 if none)', defaultValue: '20', inputType: 'number', confirmText: 'Create invoice' });
    if (tax === null) return;
    try {
      const res = await leadsService.invoiceReferral(r.uuid, { tax_rate: Number(tax) || 0 });
      toast.success('Commission invoice created as a draft');
      router.push(`/dashboard/invoices/${res.invoice_uuid}`);
    } catch (e) { toast.error(leadError(e).message); }
  };

  const meetings = lead.meetings ?? [];
  const referrals = lead.referrals ?? [];
  const questions = settings?.settings.qualification_questions ?? [];

  return (
    <div className="space-y-6">
      <div>
        <Link href="/dashboard/leads" className="inline-flex items-center gap-1 text-sm text-secondary-500 hover:text-secondary-800">
          <ArrowLeft className="h-4 w-4" aria-hidden="true" />Leads
        </Link>
        <div className="mt-2 flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div className="min-w-0">
            <div className="flex min-w-0 flex-wrap items-center gap-3">
              <h1 className="truncate text-2xl font-bold tracking-tight text-secondary-900">{fullName(lead)}</h1>
              <VipBadge vip={vip} size="md" />
            </div>
            <p className="mt-0.5 text-sm text-secondary-500">
              {[lead.job_title, lead.company_name].filter(Boolean).join(' at ') || 'No company given'}
              {lead.source ? ` · came from ${lead.source.replace(/_/g, ' ')}` : ''} · {dateOnly(lead.created_at)}
            </p>
            <div className="mt-3"><StageTrack lead={lead} labels={labels} /></div>
          </div>
          <div className="flex shrink-0 items-center gap-3 rounded-xl border border-secondary-200 bg-white px-4 py-3">
            <Avatar name={lead.owner_name} className="h-9 w-9 text-xs" />
            <div className="min-w-[10rem]">
              <p className="text-xs text-secondary-500">Owner</p>
              {isManager && open ? (
                <select aria-label="Owner" value={lead.owner_user_uuid ?? ''} disabled={busy === 'assign'}
                  onChange={(e) => assign(e.target.value || null)}
                  className="mt-0.5 w-full rounded-md border border-secondary-200 px-2 py-1 text-sm">
                  <option value="">No owner (queue)</option>
                  {team.map((t) => <option key={t.uuid} value={t.uuid}>{t.name}</option>)}
                </select>
              ) : (
                <div className="flex items-center gap-2">
                  <p className="text-sm font-medium text-secondary-900">{lead.owner_name ?? 'Nobody yet'}</p>
                  {canWork && open && !lead.owner_user_uuid && (
                    <Button size="sm" variant="outline" isLoading={busy === 'assign'} disabled={!myUuid}
                      onClick={() => myUuid && assign(myUuid)}>Take it</Button>
                  )}
                </div>
              )}
            </div>
          </div>
        </div>
      </div>

      {canWork && (
        <div className="flex flex-wrap gap-2" role="toolbar" aria-label="Lead actions">
          {open && lead.phone && (
            <a href={`tel:${phoneDigits}`} onClick={() => setTimeout(() => setDialog({ kind: 'call' }), 300)}
              className="inline-flex h-10 items-center gap-2 rounded-lg bg-primary-500 px-4 text-sm font-medium text-white shadow-sm hover:bg-primary-600">
              <Phone className="h-4 w-4" aria-hidden="true" />Call {lead.phone}
            </a>
          )}
          {lead.stage !== 'converted' && (
            <Button variant={lead.phone ? 'ghost' : 'primary'} onClick={() => setDialog({ kind: 'call' })} leftIcon={<PhoneCall className="h-4 w-4" />}>Log a call</Button>
          )}
          {lead.email && <a href={`mailto:${lead.email}`} className="inline-flex h-10 items-center gap-2 rounded-lg px-4 text-sm font-medium text-secondary-700 hover:bg-secondary-100">
            <Mail className="h-4 w-4" aria-hidden="true" />Email</a>}
          {wa && <a href={wa} target="_blank" rel="noopener noreferrer" className="inline-flex h-10 items-center gap-2 rounded-lg px-4 text-sm font-medium text-secondary-700 hover:bg-secondary-100">
            <MessageCircle className="h-4 w-4" aria-hidden="true" />WhatsApp</a>}
          {open && <Button variant="ghost" onClick={() => setDialog({ kind: 'meeting' })} leftIcon={<CalendarPlus className="h-4 w-4" />}>Book meeting</Button>}
          {open && <Button variant="ghost" onClick={() => setDialog({ kind: 'qualify' })} leftIcon={<ClipboardCheck className="h-4 w-4" />}>Qualify</Button>}
          <Button variant="ghost" onClick={() => setDialog({ kind: 'refer' })} leftIcon={<Handshake className="h-4 w-4" />}>Pass to partner</Button>
          {lead.stage !== 'converted' && lead.permissions?.can_convert && (
            <Button variant="secondary" onClick={() => setDialog({ kind: 'convert' })} leftIcon={<Briefcase className="h-4 w-4" />}>Convert to deal</Button>
          )}
          {open && <Button variant="ghost" onClick={() => setDialog({ kind: 'stage', target: 'nurture' })} leftIcon={<Sprout className="h-4 w-4" />}>Nurture</Button>}
          {open && <Button variant="ghost" onClick={() => setDialog({ kind: 'stage', target: 'lost' })} leftIcon={<XCircle className="h-4 w-4" />}>Lost</Button>}
          {(lead.stage === 'lost' || lead.stage === 'nurture') && (
            <Button variant="outline" isLoading={busy === 'reopen'} onClick={reopen} leftIcon={<Repeat className="h-4 w-4" />}>Reopen</Button>
          )}
        </div>
      )}

      {lead.stage === 'converted' && lead.converted_deal_uuid && (
        <div className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-emerald-200 bg-emerald-50 px-5 py-4">
          <p className="text-sm text-emerald-900">
            Converted to the deal <strong>{lead.converted_deal_name}</strong>
            {lead.converted_deal_value ? ` (${money(lead.converted_deal_value, lead.currency || settings?.settings.currency)})` : ''}. Work continues there.
          </p>
          <Link href="/dashboard/crm?tab=deals" className="text-sm font-medium text-emerald-800 underline">Open deals</Link>
        </div>
      )}
      {lead.stage === 'lost' && lead.lost_reason && (
        <p className="flex items-center gap-2 rounded-xl border border-secondary-200 bg-secondary-50 px-5 py-3 text-sm text-secondary-700">
          <CircleSlash className="h-4 w-4" aria-hidden="true" />Lost: {lead.lost_reason}
        </p>
      )}
      {lead.stage === 'nurture' && lead.nurture_until && (
        <p className="flex items-center gap-2 rounded-xl border border-teal-200 bg-teal-50 px-5 py-3 text-sm text-teal-900">
          <Sprout className="h-4 w-4" aria-hidden="true" />Comes back on {dateOnly(lead.nurture_until)} with a call planned.
        </p>
      )}
      {typeof lead.metadata?.duplicate_of === 'string' && (
        <p className="rounded-xl border border-amber-200 bg-amber-50 px-5 py-3 text-sm text-amber-900">
          Another open lead has the same email or phone.{' '}
          <Link className="font-medium underline" href={`/dashboard/leads/${lead.metadata.duplicate_of as string}`}>Look at it</Link>
          {' '}before calling, so they aren’t contacted twice.
        </p>
      )}

      <div className="grid grid-cols-1 gap-6 xl:grid-cols-3">
        <div className="space-y-6 xl:col-span-2">
          <AiCard lead={lead} canWork={canWork} onAction={onAi} onRefresh={load} />

          <Section title="Meetings" action={canWork && open ? (
            <Button size="sm" variant="ghost" onClick={() => setDialog({ kind: 'meeting' })} leftIcon={<CalendarPlus className="h-3.5 w-3.5" />}>Book</Button>) : undefined}>
            {meetings.length === 0 ? <p className="text-sm text-secondary-500">No meetings yet.</p> : (
              <ul className="space-y-3">
                {meetings.map((m) => {
                  const past = new Date(m.starts_at).getTime() < Date.now() + 15 * 60000;
                  return (
                    <li key={m.uuid} className={cn('rounded-lg border p-3', m.status === 'cancelled' ? 'border-secondary-200 opacity-60' : 'border-secondary-200')}>
                      <div className="flex flex-wrap items-start justify-between gap-2">
                        <div>
                          <p className="flex items-center gap-2 text-sm font-medium text-secondary-900">
                            <Video className="h-4 w-4 text-secondary-400" aria-hidden="true" />{m.subject}
                          </p>
                          <p className="text-xs text-secondary-500">{dateTime(m.starts_at)} · {m.duration_minutes} min · {m.type_label}</p>
                          {m.meeting_url && <a href={m.meeting_url} target="_blank" rel="noopener noreferrer" className="text-xs text-primary-600 hover:underline">{m.meeting_url}</a>}
                          {m.location && <p className="text-xs text-secondary-600">{m.location}</p>}
                          <p className="mt-1 text-[11px] text-secondary-500">
                            {m.status === 'planned' ? (!m.invite.enabled ? 'No invites sent' : m.invite.error ? `Invite not sent yet: ${m.invite.error}`
                              : m.invite.up_to_date ? `Invite sent to ${m.attendees.length}` : 'Sending the invite…')
                              : m.status === 'completed' ? (m.outcome === 'held' ? 'It happened' : "They didn't come") : 'Cancelled'}
                          </p>
                        </div>
                        {canWork && m.status === 'planned' && (
                          <div className="flex flex-wrap gap-1">
                            {past && <Button size="sm" onClick={() => setDialog({ kind: 'outcome', meeting: m })}>How did it go?</Button>}
                            <Button size="sm" variant="ghost" onClick={() => setDialog({ kind: 'meeting', meeting: m })}>Move</Button>
                            <Button size="sm" variant="ghost" onClick={() => cancelMeeting(m)}>Cancel</Button>
                          </div>
                        )}
                      </div>
                    </li>
                  );
                })}
              </ul>
            )}
          </Section>

          {referrals.length > 0 && (
            <Section title="Passed to partners">
              <ul className="space-y-3">
                {referrals.map((r) => (
                  <li key={r.uuid} className="rounded-lg border border-secondary-200 p-3">
                    <div className="flex flex-wrap items-start justify-between gap-2">
                      <div>
                        <p className="text-sm font-medium text-secondary-900">{r.partner_name}</p>
                        <p className="text-xs text-secondary-500">{r.status_label}
                          {r.commission_amount !== null ? ` · commission ${money(r.commission_amount, r.currency || 'GBP')}` : ''}
                          {r.invoice_number ? ` · invoice ${r.invoice_number}` : ''}</p>
                        {r.partner_notes && <p className="mt-1 whitespace-pre-wrap text-xs text-secondary-600">{r.partner_notes}</p>}
                      </div>
                      {canWork && (
                        <div className="flex flex-wrap gap-1">
                          {r.status === 'sent' && <>
                            <Button size="sm" variant="ghost" onClick={() => moveReferral(r, 'accepted')}>They accepted</Button>
                            <Button size="sm" variant="ghost" onClick={() => moveReferral(r, 'declined')}>They declined</Button>
                            <Button size="sm" variant="ghost" onClick={async () => { try { await leadsService.resendReferral(r.uuid); toast.success('Sent again'); } catch (e) { toast.error(leadError(e).message); } }}>Send again</Button>
                          </>}
                          {r.status === 'accepted' && <>
                            <Button size="sm" onClick={() => moveReferral(r, 'won')}>They won it</Button>
                            <Button size="sm" variant="ghost" onClick={() => moveReferral(r, 'lost')}>They lost it</Button>
                          </>}
                          {r.status === 'won' && <Button size="sm" onClick={() => billCommission(r)}>Invoice the commission</Button>}
                          {r.invoice_uuid && <Link href={`/dashboard/invoices/${r.invoice_uuid}`} className="inline-flex h-8 items-center rounded-lg px-3 text-sm font-medium text-primary-600 hover:bg-primary-50">Open invoice</Link>}
                        </div>
                      )}
                    </div>
                  </li>
                ))}
              </ul>
            </Section>
          )}

          <Section title="Timeline">
            {timeline.length === 0 ? <p className="text-sm text-secondary-500">Nothing yet.</p> : (
              <ol className="relative ml-2 space-y-4 border-l border-secondary-200 pl-5">
                {timeline.map((t, i) => (
                  <li key={`${t.kind}-${t.at}-${i}`} className="relative">
                    <span className={cn('absolute -left-[27px] top-1 h-3 w-3 rounded-full border-2 border-white',
                      t.kind === 'stage' ? 'bg-indigo-500' : t.kind === 'analysis' ? 'bg-primary-500' : t.kind === 'converted' ? 'bg-emerald-500'
                        : t.status === 'planned' ? 'bg-amber-400' : 'bg-secondary-400')} aria-hidden="true" />
                    <p className="text-sm font-medium text-secondary-900">{t.title}
                      {t.outcome_label && <span className="ml-2 rounded bg-secondary-100 px-1.5 py-0.5 text-[11px] font-medium text-secondary-600">{t.outcome_label}</span>}
                      {t.status === 'planned' && <span className="ml-2 rounded bg-amber-50 px-1.5 py-0.5 text-[11px] font-medium text-amber-700">planned</span>}
                      {t.status === 'cancelled' && <span className="ml-2 rounded bg-secondary-100 px-1.5 py-0.5 text-[11px] text-secondary-500">cancelled</span>}
                    </p>
                    <p className="text-xs text-secondary-500">{dateTime(t.at)}{t.by ? ` · ${t.by}` : ''}</p>
                    {t.detail && <p className="mt-1 whitespace-pre-wrap text-sm text-secondary-700">{t.detail}</p>}
                  </li>
                ))}
              </ol>
            )}
          </Section>
        </div>

        <div className="space-y-6">
          <Section title="Next step" action={canWork && open ? (
            <Button size="sm" variant="ghost" onClick={() => setDialog({ kind: 'step' })}>Plan one</Button>) : undefined}>
            {lead.next_action_at ? (
              <div className={cn('rounded-lg border p-3', due.overdue ? 'border-error-200 bg-error-50' : due.soon ? 'border-amber-200 bg-amber-50' : 'border-secondary-200')}>
                <p className="flex items-center gap-2 text-sm font-medium text-secondary-900">
                  <Clock className="h-4 w-4" aria-hidden="true" />{lead.next_action_note || STEP_LABEL[lead.next_action_type ?? ''] || 'Follow up'}
                </p>
                <p className={cn('mt-0.5 text-xs', due.overdue ? 'font-semibold text-error-700' : 'text-secondary-600')}>{due.overdue || due.soon ? `${due.text} · ${dateTime(lead.next_action_at)}` : due.text}</p>
              </div>
            ) : (
              <p className="text-sm text-secondary-500">{open ? 'Nothing planned. Plan the next step so this lead doesn’t go cold.' : 'None — the lead isn’t open.'}</p>
            )}
            <p className="mt-3 text-xs text-secondary-500">
              {lead.contact_attempts} call{lead.contact_attempts === 1 ? '' : 's'} so far
              {lead.first_contacted_at ? ` · first contact ${dateTime(lead.first_contacted_at)}` : ' · not contacted yet'}
            </p>
          </Section>

          <Section title="Details">
            <dl className="space-y-2 text-sm">
              {[['Email', lead.email], ['Phone', lead.phone], ['Company', lead.company_name], ['Job title', lead.job_title],
                ['Campaign', lead.campaign], ['Priority', lead.priority]].map(([k, v]) => v ? (
                <div key={k as string} className="flex justify-between gap-3"><dt className="text-secondary-500">{k}</dt>
                  <dd className="truncate text-right text-secondary-900">{v}</dd></div>) : null)}
              <div className="flex justify-between gap-3"><dt className="text-secondary-500">Value</dt>
                <dd className="text-right font-medium text-secondary-900">{lead.estimated_value ? money(lead.estimated_value, lead.currency || settings?.settings.currency) : '—'}
                  {lead.metadata?.value_from === 'ai' && <span className="ml-1 text-[11px] font-normal text-secondary-500">(AI)</span>}</dd></div>
              {lead.expected_close_date && <div className="flex justify-between gap-3"><dt className="text-secondary-500">Expected close</dt>
                <dd className="text-secondary-900">{dateOnly(lead.expected_close_date)}</dd></div>}
            </dl>
            {lead.notes && (
              <div className="mt-4 rounded-lg bg-secondary-50 p-3">
                <p className="text-xs font-medium text-secondary-500">Their message</p>
                <p className="mt-1 whitespace-pre-wrap break-words text-sm text-secondary-800">{lead.notes}</p>
              </div>
            )}
          </Section>

          {questions.length > 0 && (
            <Section title="Qualification" action={canWork && open ? <Button size="sm" variant="ghost" onClick={() => setDialog({ kind: 'qualify' })}>Edit</Button> : undefined}>
              <dl className="space-y-2 text-sm">
                {questions.map((q) => (
                  <div key={q.key}><dt className="text-xs text-secondary-500">{q.label}</dt>
                    <dd className="text-secondary-900">{lead.qualification?.[q.key] || <span className="text-secondary-400">Not known</span>}</dd></div>
                ))}
              </dl>
            </Section>
          )}

          <ShopPanel metadata={lead.metadata} />
          <RecordFormResponses entityType="lead" entityUuid={lead.uuid} />
          <PropertyDealsLeadPanel leadUuid={lead.uuid} />

          {canWork && lead.stage !== 'converted' && (
            <button type="button" onClick={remove} className="inline-flex items-center gap-2 text-sm text-secondary-500 hover:text-error-600">
              <Trash2 className="h-4 w-4" aria-hidden="true" />Delete this lead
            </button>
          )}
          {!canWork && (
            <p className="flex items-start gap-2 rounded-lg bg-secondary-50 p-3 text-xs text-secondary-600">
              <UserRound className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />You can see this lead but not work on it. Ask a manager to give it to you.
            </p>
          )}
        </div>
      </div>

      {dialog?.kind === 'call' && <LogCallDialog lead={lead} outcomes={outcomes} onClose={() => setDialog(null)} onDone={done} />}
      {dialog?.kind === 'step' && <PlanStepDialog lead={lead} onClose={() => setDialog(null)} onDone={(l) => done(l)} />}
      {dialog?.kind === 'meeting' && <MeetingDialog lead={lead} meeting={dialog.meeting} settings={settings} onClose={() => setDialog(null)} onDone={() => done()} />}
      {dialog?.kind === 'outcome' && <MeetingOutcomeDialog meeting={dialog.meeting} onClose={() => setDialog(null)} onDone={() => done()} />}
      {dialog?.kind === 'qualify' && <QualifyDialog lead={lead} settings={settings} onClose={() => setDialog(null)} onDone={(l) => done(l)} />}
      {dialog?.kind === 'convert' && <ConvertDialog lead={lead} settings={settings} onClose={() => setDialog(null)} onDone={() => done()} />}
      {dialog?.kind === 'refer' && <ReferDialog lead={lead} preselect={dialog.partner} onClose={() => setDialog(null)} onDone={() => done()} />}
      {dialog?.kind === 'stage' && (
        <StageModal lead={lead} target={dialog.target} lostReasons={settings?.settings.lost_reasons ?? ['Not interested', 'Other']}
          onClose={() => setDialog(null)} onDone={(l) => done(l)} />
      )}
    </div>
  );
}

export default function LeadPage() {
  return (
    <ProtectedPage module="crm_leads" title="Lead">
      <LeadContent />
    </ProtectedPage>
  );
}

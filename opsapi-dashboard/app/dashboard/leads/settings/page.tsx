'use client';

/**
 * Lead pipeline settings (managers): how fast leads must be called, working
 * hours, the call plan, escalation, who gets new leads (auto-assign, round
 * robin, rules), the AI (on/off, provider, daily budget, "hot" score),
 * qualification questions, lost reasons, stage names, meetings and the
 * website form's bot check. Field errors from the server show in place.
 */
import React, { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import toast from 'react-hot-toast';
import { ArrowLeft, Plus, Save, Trash2, X } from 'lucide-react';
import { Button, confirmDialog } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { cn } from '@/lib/utils';
import {
  ALL_STAGES, leadError, leadsService, type AssignmentRule, type LeadSettings, type SettingsBundle, type TeamMember,
} from '@/services/leads.service';
import { FieldError } from '@/components/leads/ui';

const input = 'w-full rounded-lg border border-secondary-300 px-3 py-2 text-sm focus:border-primary-500 focus:outline-none focus:ring-2 focus:ring-primary-500/20';
const DAYS = [[1, 'Mon'], [2, 'Tue'], [3, 'Wed'], [4, 'Thu'], [5, 'Fri'], [6, 'Sat'], [7, 'Sun']] as const;

function Card({ title, help, children }: { title: string; help?: string; children: React.ReactNode }) {
  return (
    <section className="rounded-xl border border-secondary-200 bg-white p-5">
      <h2 className="text-sm font-semibold text-secondary-900">{title}</h2>
      {help && <p className="mt-0.5 text-xs text-secondary-500">{help}</p>}
      <div className="mt-4 space-y-4">{children}</div>
    </section>
  );
}

function Label({ htmlFor, children }: { htmlFor?: string; children: React.ReactNode }) {
  return <label htmlFor={htmlFor} className="block text-sm font-medium text-secondary-700">{children}</label>;
}

function SettingsContent() {
  const [bundle, setBundle] = useState<SettingsBundle | null>(null);
  const [s, setS] = useState<LeadSettings | null>(null);
  const [team, setTeam] = useState<TeamMember[]>([]);
  const [rules, setRules] = useState<AssignmentRule[]>([]);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [saving, setSaving] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [newRule, setNewRule] = useState<{ name: string; sources: string; keywords: string; assignee: string }>({ name: '', sources: '', keywords: '', assignee: '' });

  const load = useCallback(async () => {
    try {
      const [b, t, r] = await Promise.all([leadsService.settings(), leadsService.team(), leadsService.rules()]);
      setBundle(b); setS(b.settings); setTeam(t); setRules(r);
    } catch (e) {
      setLoadError(leadError(e).message);
    }
  }, []);
  useEffect(() => { load(); }, [load]);

  if (loadError) return <p className="rounded-lg border border-error-200 bg-error-50 p-4 text-sm text-error-700">{loadError}</p>;
  if (!s || !bundle) return <p className="p-10 text-sm text-secondary-500">Loading settings…</p>;
  const canEdit = bundle.can_edit;
  const set = <K extends keyof LeadSettings>(k: K, v: LeadSettings[K]) => setS((cur) => (cur ? { ...cur, [k]: v } : cur));
  const labels = (Array.isArray(s.stage_labels) ? {} : s.stage_labels) as Record<string, string>;

  const save = async () => {
    setSaving(true); setErrors({});
    try {
      const saved = await leadsService.saveSettings(s);
      setS(saved);
      toast.success('Settings saved');
    } catch (e) {
      const err = leadError(e);
      setErrors(err.fields ?? {});
      toast.error(err.message);
    } finally {
      setSaving(false);
    }
  };

  const addRule = async () => {
    try {
      await leadsService.createRule({
        name: newRule.name.trim(), position: rules.length,
        conditions: {
          sources: newRule.sources.split(',').map((x) => x.trim()).filter(Boolean),
          keywords: newRule.keywords.split(',').map((x) => x.trim()).filter(Boolean),
        },
        assignee_user_uuid: newRule.assignee || null, pool: [], enabled: true,
      });
      setNewRule({ name: '', sources: '', keywords: '', assignee: '' });
      toast.success('Rule added');
      setRules(await leadsService.rules());
    } catch (e) {
      const err = leadError(e);
      toast.error(Object.values(err.fields ?? {})[0] ?? err.message);
    }
  };

  const removeRule = async (r: AssignmentRule) => {
    if (!(await confirmDialog({ title: `Delete the rule “${r.name}”?`, confirmText: 'Delete', danger: true }))) return;
    try { await leadsService.deleteRule(r.uuid); setRules(await leadsService.rules()); toast.success('Rule deleted'); }
    catch (e) { toast.error(leadError(e).message); }
  };

  const nameOf = (uuid: string | null) => team.find((t) => t.uuid === uuid)?.name ?? 'Someone who left';

  return (
    <div className="mx-auto max-w-4xl space-y-6">
      <div>
        <Link href="/dashboard/leads" className="inline-flex items-center gap-1 text-sm text-secondary-500 hover:text-secondary-800">
          <ArrowLeft className="h-4 w-4" aria-hidden="true" />Leads
        </Link>
        <div className="mt-2 flex flex-wrap items-center justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold tracking-tight text-secondary-900">Lead settings</h1>
            <p className="text-sm text-secondary-500">How new leads are handled in this workspace.</p>
          </div>
          {canEdit && <Button onClick={save} isLoading={saving} leftIcon={<Save className="h-4 w-4" />}>Save settings</Button>}
        </div>
        {!canEdit && <p className="mt-3 rounded-lg bg-secondary-50 p-3 text-sm text-secondary-600">Only lead managers can change these.</p>}
      </div>

      <fieldset disabled={!canEdit} className="space-y-6">
        <Card title="Speed to lead" help="A new lead gets a call planned for its owner within this many working minutes.">
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
            <div>
              <Label htmlFor="frm">Call within (minutes)</Label>
              <input id="frm" type="number" min={1} className={cn(input, 'mt-1')} value={s.first_response_minutes}
                onChange={(e) => set('first_response_minutes', Number(e.target.value))} />
              <FieldError message={errors.first_response_minutes} />
            </div>
            <div>
              <Label htmlFor="esc">Tell managers when late by (minutes)</Label>
              <input id="esc" type="number" min={5} className={cn(input, 'mt-1')} value={s.escalate_after_minutes}
                onChange={(e) => set('escalate_after_minutes', Number(e.target.value))} />
              <FieldError message={errors.escalate_after_minutes} />
            </div>
            <div>
              <Label htmlFor="cur">Currency</Label>
              <input id="cur" className={cn(input, 'mt-1 uppercase')} maxLength={3} value={s.currency}
                onChange={(e) => set('currency', e.target.value.toUpperCase())} />
              <FieldError message={errors.currency} />
            </div>
          </div>
          <div>
            <Label>Working hours</Label>
            <div className="mt-1 flex flex-wrap items-center gap-2">
              <input aria-label="Opens at" type="time" className={cn(input, 'w-32')} value={s.working_hours.start}
                onChange={(e) => set('working_hours', { ...s.working_hours, start: e.target.value })} />
              <span className="text-sm text-secondary-500">to</span>
              <input aria-label="Closes at" type="time" className={cn(input, 'w-32')} value={s.working_hours.end}
                onChange={(e) => set('working_hours', { ...s.working_hours, end: e.target.value })} />
              <input aria-label="Time zone" className={cn(input, 'w-52')} value={s.working_hours.timezone}
                onChange={(e) => set('working_hours', { ...s.working_hours, timezone: e.target.value })} placeholder="Europe/London" />
            </div>
            <div className="mt-2 flex flex-wrap gap-1.5" role="group" aria-label="Working days">
              {DAYS.map(([d, l]) => {
                const on = s.working_hours.days.includes(d);
                return (
                  <button key={d} type="button" aria-pressed={on}
                    onClick={() => set('working_hours', { ...s.working_hours,
                      days: on ? s.working_hours.days.filter((x) => x !== d) : [...s.working_hours.days, d].sort() })}
                    className={cn('rounded-md px-3 py-1.5 text-sm font-medium', on ? 'bg-primary-500 text-white' : 'bg-secondary-100 text-secondary-600')}>
                    {l}
                  </button>
                );
              })}
            </div>
            <FieldError message={errors.working_hours} />
          </div>
          <div>
            <Label htmlFor="plan">If they don’t answer, try again after (hours, comma-separated)</Label>
            <input id="plan" className={cn(input, 'mt-1')} defaultValue={s.attempt_plan_hours.join(', ')}
              onBlur={(e) => set('attempt_plan_hours', e.target.value.split(',').map((x) => Number(x.trim())).filter((x) => !Number.isNaN(x) && x > 0))} />
            <p className="mt-1 text-xs text-secondary-500">With 4, 24, 72 there are four tries: now, 4 h later, a day later, three days later. Then we suggest Nurture.</p>
            <FieldError message={errors.attempt_plan_hours} />
          </div>
        </Card>

        <Card title="Who gets new leads" help="Rules are checked top to bottom; if none matches, leads go round-robin.">
          <label className="flex items-center gap-2 text-sm text-secondary-700">
            <input type="checkbox" className="h-4 w-4 rounded border-secondary-300" checked={s.auto_assign}
              onChange={(e) => set('auto_assign', e.target.checked)} />
            Give every new lead an owner automatically
          </label>
          <div>
            <Label>Round-robin between</Label>
            <div className="mt-2 flex flex-wrap gap-2">
              {team.map((t) => {
                const on = s.round_robin_user_uuids.includes(t.uuid);
                return (
                  <button key={t.uuid} type="button" aria-pressed={on}
                    onClick={() => set('round_robin_user_uuids', on ? s.round_robin_user_uuids.filter((u) => u !== t.uuid) : [...s.round_robin_user_uuids, t.uuid])}
                    className={cn('rounded-full border px-3 py-1 text-sm', on ? 'border-primary-500 bg-primary-50 text-primary-800' : 'border-secondary-200 text-secondary-600')}>
                    {t.name}
                  </button>
                );
              })}
            </div>
            <p className="mt-1 text-xs text-secondary-500">Pick nobody to share leads between everyone who can work leads.</p>
            <FieldError message={errors.round_robin_user_uuids} />
          </div>
          <div>
            <Label>Rules</Label>
            {rules.length === 0 ? <p className="mt-1 text-sm text-secondary-500">No rules yet.</p> : (
              <ul className="mt-2 divide-y divide-secondary-100 rounded-lg border border-secondary-200">
                {rules.map((r) => (
                  <li key={r.uuid} className="flex items-center justify-between gap-2 px-3 py-2 text-sm">
                    <span><strong>{r.name}</strong>
                      <span className="ml-2 text-secondary-500">
                        {[r.conditions.sources?.length ? `source: ${r.conditions.sources.join(', ')}` : '',
                          r.conditions.keywords?.length ? `mentions: ${r.conditions.keywords.join(', ')}` : ''].filter(Boolean).join(' · ') || 'every lead'}
                        {' → '}{r.assignee_user_uuid ? nameOf(r.assignee_user_uuid) : `round-robin of ${r.pool.length}`}
                      </span></span>
                    {canEdit && <button type="button" onClick={() => removeRule(r)} aria-label={`Delete rule ${r.name}`}
                      className="rounded p-1 text-secondary-400 hover:bg-error-50 hover:text-error-600"><Trash2 className="h-4 w-4" /></button>}
                  </li>
                ))}
              </ul>
            )}
            {canEdit && (
              <div className="mt-3 grid grid-cols-1 gap-2 rounded-lg bg-secondary-50 p-3 sm:grid-cols-4">
                <input aria-label="Rule name" className={input} placeholder="Name, e.g. Website laptops" value={newRule.name}
                  onChange={(e) => setNewRule({ ...newRule, name: e.target.value })} />
                <input aria-label="Sources" className={input} placeholder="Sources (comma-separated)" value={newRule.sources}
                  onChange={(e) => setNewRule({ ...newRule, sources: e.target.value })} />
                <input aria-label="Words in the message" className={input} placeholder="Words in the message" value={newRule.keywords}
                  onChange={(e) => setNewRule({ ...newRule, keywords: e.target.value })} />
                <div className="flex gap-2">
                  <select aria-label="Give to" className={input} value={newRule.assignee} onChange={(e) => setNewRule({ ...newRule, assignee: e.target.value })}>
                    <option value="">Give to…</option>
                    {team.map((t) => <option key={t.uuid} value={t.uuid}>{t.name}</option>)}
                  </select>
                  <Button size="md" onClick={addRule} disabled={!newRule.name.trim() || !newRule.assignee} aria-label="Add rule"><Plus className="h-4 w-4" /></Button>
                </div>
              </div>
            )}
          </div>
        </Card>

        <Card title="AI" help="The AI reads every new lead, sizes the deal, suggests the next step and partners, and drafts a first reply. It never contacts anyone.">
          <label className="flex items-center gap-2 text-sm text-secondary-700">
            <input type="checkbox" className="h-4 w-4 rounded border-secondary-300" checked={s.ai_enabled} onChange={(e) => set('ai_enabled', e.target.checked)} />
            Analyse new leads automatically
          </label>
          {bundle.ai_providers.length === 0 ? (
            <p className="rounded-lg bg-amber-50 p-3 text-sm text-amber-900">
              No AI model is set up for this workspace yet, so leads aren’t analysed.{' '}
              <Link href="/dashboard/namespace/ai" className="font-medium underline">Set up AI models</Link>
            </p>
          ) : (
            <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
              <div>
                <Label htmlFor="prov">Model</Label>
                <select id="prov" className={cn(input, 'mt-1')} value={s.ai_provider_uuid ?? ''}
                  onChange={(e) => set('ai_provider_uuid', e.target.value || null)}>
                  <option value="">Any enabled (self-hosted first)</option>
                  {bundle.ai_providers.map((p) => <option key={p.uuid} value={p.uuid} disabled={!p.enabled}>{p.name}{p.is_local ? ' (self-hosted)' : ''}</option>)}
                </select>
                <FieldError message={errors.ai_provider_uuid} />
              </div>
              <div>
                <Label htmlFor="budget">Daily budget (US$)</Label>
                <input id="budget" type="number" min={0} step="0.5" className={cn(input, 'mt-1')} value={s.ai_daily_cost_usd}
                  onChange={(e) => set('ai_daily_cost_usd', Number(e.target.value))} />
                <FieldError message={errors.ai_daily_cost_usd} />
              </div>
              <div>
                <Label htmlFor="hot">“Hot lead” from score</Label>
                <input id="hot" type="number" min={1} max={100} className={cn(input, 'mt-1')} value={s.ai_hot_score}
                  onChange={(e) => set('ai_hot_score', Number(e.target.value))} />
                <FieldError message={errors.ai_hot_score} />
              </div>
            </div>
          )}
          <p className="text-xs text-secondary-500">
            {bundle.web_research ? 'Deal sizes come from a web price search (Google Gemini). Only a description of what is wanted is searched, never who wants it.'
              : 'Add a Google Gemini provider to size deals from a web price search; until then the AI estimates from what it knows.'}
          </p>
        </Card>

        <Card title="Qualifying and losing" help="The questions your team answers on a call, and the reasons a lead can be lost.">
          <div>
            <Label>Qualification questions</Label>
            <ul className="mt-2 space-y-2">
              {s.qualification_questions.map((q, i) => (
                <li key={`${q.key}-${i}`} className="flex gap-2">
                  <input aria-label={`Question ${i + 1}`} className={input} value={q.label} onChange={(e) => {
                    const next = [...s.qualification_questions]; next[i] = { ...q, label: e.target.value }; set('qualification_questions', next);
                  }} />
                  <button type="button" aria-label="Remove question" className="rounded-lg px-2 text-secondary-400 hover:bg-secondary-100"
                    onClick={() => set('qualification_questions', s.qualification_questions.filter((_, j) => j !== i))}><X className="h-4 w-4" /></button>
                </li>
              ))}
            </ul>
            <Button variant="ghost" size="sm" className="mt-2" leftIcon={<Plus className="h-4 w-4" />}
              onClick={() => set('qualification_questions', [...s.qualification_questions, { key: '', label: '' }])}>Add question</Button>
            <FieldError message={errors.qualification_questions} />
          </div>
          <div>
            <Label htmlFor="lost">Lost reasons (one per line)</Label>
            <textarea id="lost" rows={5} className={cn(input, 'mt-1')} defaultValue={s.lost_reasons.join('\n')}
              onBlur={(e) => set('lost_reasons', e.target.value.split('\n').map((x) => x.trim()).filter(Boolean))} />
            <FieldError message={errors.lost_reasons} />
          </div>
          <div>
            <Label>Stage names</Label>
            <div className="mt-2 grid grid-cols-2 gap-2 sm:grid-cols-4">
              {ALL_STAGES.map((st) => (
                <input key={st} aria-label={`Name for ${st}`} className={input} placeholder={bundle.stage_labels[st]}
                  value={labels[st] ?? ''} onChange={(e) => set('stage_labels', { ...labels, [st]: e.target.value })} />
              ))}
            </div>
            <FieldError message={errors.stage_labels} />
          </div>
        </Card>

        <Card title="Meetings" help="Invites are sent from your workspace email, with a calendar file that works in Google, Outlook and Apple calendars.">
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div>
              <Label htmlFor="mlen">Default length (minutes)</Label>
              <input id="mlen" type="number" min={5} max={480} className={cn(input, 'mt-1')} value={s.meeting.default_minutes}
                onChange={(e) => set('meeting', { ...s.meeting, default_minutes: Number(e.target.value) })} />
              <FieldError message={errors['meeting.default_minutes']} />
            </div>
            <div>
              <Label htmlFor="mlink">Default video link</Label>
              <input id="mlink" className={cn(input, 'mt-1')} value={s.meeting.default_link} placeholder="https://…"
                onChange={(e) => set('meeting', { ...s.meeting, default_link: e.target.value })} />
              <FieldError message={errors['meeting.default_link']} />
            </div>
            <div>
              <Label htmlFor="mlr">Remind the lead (hours before, 0 = never)</Label>
              <input id="mlr" type="number" min={0} max={168} className={cn(input, 'mt-1')} value={s.meeting.lead_reminder_hours}
                onChange={(e) => set('meeting', { ...s.meeting, lead_reminder_hours: Number(e.target.value) })} />
              <FieldError message={errors['meeting.lead_reminder_hours']} />
            </div>
            <div>
              <Label htmlFor="msr">Remind staff (minutes before, 0 = never)</Label>
              <input id="msr" type="number" min={0} max={1440} className={cn(input, 'mt-1')} value={s.meeting.staff_reminder_minutes}
                onChange={(e) => set('meeting', { ...s.meeting, staff_reminder_minutes: Number(e.target.value) })} />
              <FieldError message={errors['meeting.staff_reminder_minutes']} />
            </div>
          </div>
          <label className="flex items-center gap-2 text-sm text-secondary-700">
            <input type="checkbox" className="h-4 w-4 rounded border-secondary-300" checked={s.meeting.send_invites}
              onChange={(e) => set('meeting', { ...s.meeting, send_invites: e.target.checked })} />
            Send calendar invites when a meeting is booked
          </label>
        </Card>

        <Card title="Website form" help="Leads sent to your public lead address from your website.">
          <label className="flex items-start gap-2 text-sm text-secondary-700">
            <input type="checkbox" className="mt-0.5 h-4 w-4 rounded border-secondary-300" checked={s.public_captcha}
              onChange={(e) => set('public_captcha', e.target.checked)} />
            <span>Require the “I’m not a robot” check (Cloudflare Turnstile, using the key in Forms settings). Turn this on only once your website sends it.</span>
          </label>
        </Card>
      </fieldset>

      {canEdit && (
        <div className="sticky bottom-4 flex justify-end">
          <Button onClick={save} isLoading={saving} leftIcon={<Save className="h-4 w-4" />} className="shadow-lg">Save settings</Button>
        </div>
      )}
    </div>
  );
}

export default function LeadSettingsPage() {
  return (
    <ProtectedPage module="crm_leads" title="Lead settings">
      <SettingsContent />
    </ProtectedPage>
  );
}

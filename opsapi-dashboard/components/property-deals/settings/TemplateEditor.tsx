'use client';

/**
 * Workflow template editor (docs/property-deals/template-format.md): stages, tasks, deadlines,
 * gates, owners, the AI-eligible flag and the approval rule — as a form or as JSON. Saving
 * publishes a new version (deals keep the version they started with); older versions can be
 * made active again. JSON import / export.
 */
import React, { useEffect, useMemo, useState } from 'react';
import { ArrowDown, ArrowUp, Download, Plus, Trash2, Upload } from 'lucide-react';
import toast from 'react-hot-toast';
import { Badge, Button, Card, Input, Modal, Select, Textarea } from '@/components/ui';
import { pdService, pdError, pdErrorText } from '@/services/property-deals.service';
import { ErrorNote, Spinner, Tabs, dateText } from '../ui';
import { usePdData } from '../usePd';

type Due = { from?: string; minutes?: number; hours?: number; working_days?: number };
type TaskDef = {
  key: string; title: string; owner?: string; sla_minutes?: number; due?: Due; blocking?: boolean; compliance?: boolean;
  depends_on?: string[]; agent?: { eligible?: boolean; agent_key?: string; auto?: boolean }; approval?: string; description?: string;
  [k: string]: unknown;
};
type StageDef = { key: string; name: string; expected_working_days?: number; parallel?: boolean; optional?: boolean; entry_gate?: unknown; tasks: TaskDef[]; [k: string]: unknown };
type Definition = { key: string; name: string; description?: string; stages: StageDef[]; [k: string]: unknown };

const OWNERS = ['operator', 'manager', 'compliance', 'agent'];
const DUE_FROM = ['stage_entry', 'deal_created', 'task_done', 'target_exchange', 'target_completion'];
const AGENTS = ['lead_triage', 'property_enrichment', 'offer_reasoning', 'buyer_matcher', 'legal_chaser', 'booking_agent', 'document_checker', 'compliance_assistant', 'investor_update'];
const RULES = ['none', 'any_operator', 'manager', 'two_person'];

const slug = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '').slice(0, 60) || 'item';

function dueAmount(d?: Due): { unit: string; n: string } {
  if (!d) return { unit: 'hours', n: '' };
  if (d.minutes !== undefined) return { unit: 'minutes', n: String(d.minutes) };
  if (d.working_days !== undefined) return { unit: 'working_days', n: String(d.working_days) };
  return { unit: 'hours', n: d.hours !== undefined ? String(d.hours) : '' };
}

export default function TemplateEditor({ canEdit }: { canEdit: boolean }) {
  const list = usePdData(async () => (await pdService.templates()).data, []);
  const [id, setId] = useState<string>('');
  const current = id || list.data?.[0]?.uuid || '';
  const tpl = usePdData(async () => (current ? (await pdService.template(current)).data : undefined), [current]);
  const versions = usePdData(async () => (current ? (await pdService.templateVersions(current)).data : []), [current]);
  const [def, setDef] = useState<Definition | null>(null);
  const [json, setJson] = useState('');
  const [mode, setMode] = useState<'form' | 'json'>('form');
  const [notes, setNotes] = useState('');
  const [errors, setErrors] = useState<string[]>([]);
  const [importing, setImporting] = useState(false);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    const d = tpl.data?.definition as Definition | undefined;
    if (d) { setDef(JSON.parse(JSON.stringify(d))); setJson(JSON.stringify(d, null, 2)); setErrors([]); }
  }, [tpl.data]);

  const dirty = useMemo(() => (def ? JSON.stringify(def) !== JSON.stringify(tpl.data?.definition) : false), [def, tpl.data]);

  function update(fn: (d: Definition) => void) {
    if (!def) return;
    const d = JSON.parse(JSON.stringify(def)) as Definition;
    fn(d);
    setDef(d);
    setJson(JSON.stringify(d, null, 2));
  }

  async function publish() {
    let d: unknown = def;
    if (mode === 'json') {
      try { d = JSON.parse(json); } catch { setErrors(['The JSON does not parse']); return; }
    }
    setBusy(true);
    try {
      const v = (await pdService.publishVersion(current, d, notes || undefined)).data;
      toast.success(`Version ${v.version} published and active`);
      setNotes('');
      setErrors([]);
      tpl.refresh(); versions.refresh(); list.refresh();
    } catch (e) {
      const err = pdError(e);
      setErrors(Array.isArray(err.details) ? (err.details as string[]) : [pdErrorText(e)]);
    } finally { setBusy(false); }
  }

  if (list.loading && !list.data) return <Spinner />;
  return (
    <div className="space-y-5">
      <Card>
        <div className="flex flex-wrap items-end justify-between gap-3">
          <Select label="Template" value={current} onChange={(e) => setId(e.target.value)}>
            {list.data?.map((t) => <option key={t.uuid} value={t.uuid}>{t.name} (v{t.active_version}{t.active_deals ? `, ${t.active_deals} active deals` : ''})</option>)}
          </Select>
          <div className="flex flex-wrap gap-2">
            <Button variant="outline" size="sm" leftIcon={<Download className="h-4 w-4" />} onClick={async () => {
              const d = (await pdService.exportTemplate(current)).data;
              const blob = new Blob([JSON.stringify(d, null, 2)], { type: 'application/json' });
              const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = `${tpl.data?.key || 'template'}.json`; a.click();
            }}>Export JSON</Button>
            {canEdit && <Button variant="outline" size="sm" leftIcon={<Upload className="h-4 w-4" />} onClick={() => setImporting(true)}>Import JSON</Button>}
          </div>
        </div>
        <p className="mt-2 text-xs text-secondary-500">Deals stay on the version they started with. Publishing makes a new version for new deals.</p>
      </Card>
      <ErrorNote error={tpl.error} />
      {def && (
        <>
          <Tabs value={mode} onChange={(m) => { if (m === 'form') { try { setDef(JSON.parse(json)); } catch { toast.error('Fix the JSON first'); return; } } setMode(m); }} tabs={[{ key: 'form', label: 'Stages and tasks' }, { key: 'json', label: 'JSON' }]} />
          {mode === 'json' ? (
            <Textarea rows={28} value={json} onChange={(e) => setJson(e.target.value)} className="font-mono text-xs" disabled={!canEdit} aria-label="Template JSON" />
          ) : (
            <div className="space-y-4">
              <div className="grid gap-3 sm:grid-cols-2">
                <Input label="Name" value={def.name} disabled={!canEdit} onChange={(e) => update((d) => { d.name = e.target.value; })} />
                <Input label="Description" value={def.description || ''} disabled={!canEdit} onChange={(e) => update((d) => { d.description = e.target.value; })} />
              </div>
              {def.stages.map((st, si) => (
                <Card key={si} padding="sm">
                  <div className="flex flex-wrap items-end gap-2">
                    <Input label={`Stage ${si + 1}`} value={st.name} disabled={!canEdit} onChange={(e) => update((d) => { d.stages[si].name = e.target.value; })} />
                    <Input label="Key" value={st.key} disabled={!canEdit} onChange={(e) => update((d) => { d.stages[si].key = slug(e.target.value); })} className="w-40" />
                    <Input label="Expected working days" type="number" min={0} value={st.expected_working_days ?? ''} disabled={!canEdit} onChange={(e) => update((d) => { d.stages[si].expected_working_days = e.target.value === '' ? undefined : Number(e.target.value); })} className="w-40" />
                    <label className="flex h-10 items-center gap-1.5 text-sm"><input type="checkbox" checked={!!st.parallel} disabled={!canEdit} onChange={(e) => update((d) => { d.stages[si].parallel = e.target.checked; })} /> Parallel</label>
                    <label className="flex h-10 items-center gap-1.5 text-sm"><input type="checkbox" checked={!!st.optional} disabled={!canEdit} onChange={(e) => update((d) => { d.stages[si].optional = e.target.checked; })} /> Optional</label>
                    {canEdit && (
                      <div className="ml-auto flex">
                        <Button size="sm" variant="ghost" aria-label="Move stage up" disabled={si === 0} onClick={() => update((d) => { [d.stages[si - 1], d.stages[si]] = [d.stages[si], d.stages[si - 1]]; })}><ArrowUp className="h-4 w-4" /></Button>
                        <Button size="sm" variant="ghost" aria-label="Move stage down" disabled={si === def.stages.length - 1} onClick={() => update((d) => { [d.stages[si + 1], d.stages[si]] = [d.stages[si], d.stages[si + 1]]; })}><ArrowDown className="h-4 w-4" /></Button>
                        <Button size="sm" variant="ghost" aria-label="Remove stage" onClick={() => window.confirm(`Remove stage ${st.name}?`) && update((d) => { d.stages.splice(si, 1); })}><Trash2 className="h-4 w-4" /></Button>
                      </div>
                    )}
                  </div>
                  <details className="mt-2 text-sm">
                    <summary className="cursor-pointer text-secondary-600">Entry gate {st.entry_gate ? '(set)' : '(none)'}</summary>
                    <Textarea rows={4} className="mt-2 font-mono text-xs" disabled={!canEdit} defaultValue={st.entry_gate ? JSON.stringify(st.entry_gate, null, 2) : ''} placeholder='{"tasks": ["order_searches"], "compliance": ["aml_cdd_buyer"], "documents": ["title"], "fields": ["agreed_price"], "no_open_blocking_enquiries": true}'
                      onBlur={(e) => { const v = e.target.value.trim(); try { update((d) => { d.stages[si].entry_gate = v ? JSON.parse(v) : undefined; }); } catch { toast.error('The gate JSON does not parse'); } }} aria-label={`Entry gate for ${st.name}`} />
                  </details>
                  <div className="mt-3 overflow-x-auto">
                    <table className="w-full min-w-[56rem] text-sm">
                      <thead className="text-left text-xs text-secondary-500">
                        <tr><th className="py-1">Task</th><th>Owner</th><th>Due from</th><th>Within</th><th>Blocking</th><th>Compliance</th><th>AI agent</th><th>Approval</th><th /></tr>
                      </thead>
                      <tbody>
                        {st.tasks.map((t, ti) => {
                          const amt = dueAmount(t.due);
                          const setT = (fn: (x: TaskDef) => void) => update((d) => fn(d.stages[si].tasks[ti]));
                          return (
                            <tr key={ti} className="border-t border-secondary-100 align-top">
                              <td className="py-1.5 pr-2"><Input value={t.title} disabled={!canEdit} aria-label="Task title" onChange={(e) => setT((x) => { x.title = e.target.value; if (!x.key) x.key = slug(e.target.value); })} /></td>
                              <td className="pr-2"><Select value={t.owner || 'operator'} disabled={!canEdit} aria-label="Owner" onChange={(e) => setT((x) => { x.owner = e.target.value; })}>{OWNERS.map((o) => <option key={o} value={o}>{o}</option>)}</Select></td>
                              <td className="pr-2"><Select value={t.due?.from || 'stage_entry'} disabled={!canEdit} aria-label="Due from" onChange={(e) => setT((x) => { x.due = { ...(x.due || {}), from: e.target.value }; })}>{DUE_FROM.map((o) => <option key={o} value={o}>{o.replace(/_/g, ' ')}</option>)}</Select></td>
                              <td className="pr-2">
                                <div className="flex gap-1">
                                  <Input type="number" className="w-20" value={amt.n} disabled={!canEdit} aria-label="Amount" onChange={(e) => setT((x) => { const due: Due = { from: x.due?.from || 'stage_entry' }; if (e.target.value !== '') (due as Record<string, unknown>)[amt.unit] = Number(e.target.value); x.due = due; })} />
                                  <Select value={amt.unit} disabled={!canEdit} aria-label="Unit" onChange={(e) => setT((x) => { const due: Due = { from: x.due?.from || 'stage_entry' }; if (amt.n !== '') (due as Record<string, unknown>)[e.target.value] = Number(amt.n); x.due = due; })}>
                                    <option value="minutes">minutes</option><option value="hours">hours</option><option value="working_days">working days</option>
                                  </Select>
                                </div>
                              </td>
                              <td className="pr-2 pt-3"><input type="checkbox" aria-label="Blocking" checked={!!t.blocking} disabled={!canEdit} onChange={(e) => setT((x) => { x.blocking = e.target.checked; })} /></td>
                              <td className="pr-2 pt-3"><input type="checkbox" aria-label="Compliance" checked={!!t.compliance} disabled={!canEdit} onChange={(e) => setT((x) => { x.compliance = e.target.checked; })} /></td>
                              <td className="pr-2">
                                <Select value={t.agent?.eligible ? t.agent.agent_key || '' : ''} disabled={!canEdit} aria-label="AI agent" onChange={(e) => setT((x) => { x.agent = e.target.value ? { ...(x.agent || {}), eligible: true, agent_key: e.target.value } : undefined; })}>
                                  <option value="">None</option>
                                  {AGENTS.map((a) => <option key={a} value={a}>{a.replace(/_/g, ' ')}</option>)}
                                </Select>
                              </td>
                              <td className="pr-2"><Select value={t.approval || 'any_operator'} disabled={!canEdit} aria-label="Approval rule" onChange={(e) => setT((x) => { x.approval = e.target.value; })}>{RULES.map((o) => <option key={o} value={o}>{o.replace(/_/g, ' ')}</option>)}</Select></td>
                              <td>{canEdit && <Button size="sm" variant="ghost" aria-label="Remove task" onClick={() => update((d) => { d.stages[si].tasks.splice(ti, 1); })}><Trash2 className="h-4 w-4" /></Button>}</td>
                            </tr>
                          );
                        })}
                      </tbody>
                    </table>
                  </div>
                  {canEdit && <Button className="mt-2" size="sm" variant="ghost" leftIcon={<Plus className="h-4 w-4" />} onClick={() => update((d) => { d.stages[si].tasks.push({ key: `task_${d.stages[si].tasks.length + 1}`, title: 'New task', owner: 'operator', due: { from: 'stage_entry', hours: 24 } }); })}>Add task</Button>}
                </Card>
              ))}
              {canEdit && <Button variant="outline" leftIcon={<Plus className="h-4 w-4" />} onClick={() => update((d) => { d.stages.push({ key: `stage_${d.stages.length + 1}`, name: 'New stage', tasks: [] }); })}>Add stage</Button>}
            </div>
          )}
          {errors.length > 0 && (
            <div className="rounded-lg bg-error-500/10 p-3 text-sm text-error-700" role="alert">
              <div className="font-medium">The template has problems:</div>
              <ul className="mt-1 list-disc pl-5">{errors.slice(0, 20).map((e) => <li key={e}>{e}</li>)}</ul>
            </div>
          )}
          {canEdit && (
            <Card padding="sm">
              <div className="flex flex-wrap items-end gap-3">
                <div className="min-w-[16rem] flex-1"><Input label="What changed (version notes)" value={notes} onChange={(e) => setNotes(e.target.value)} /></div>
                <Button isLoading={busy} disabled={mode === 'form' && !dirty && !notes} onClick={publish}>Publish new version</Button>
              </div>
            </Card>
          )}
        </>
      )}
      <Card>
        <h3 className="font-semibold text-secondary-900">Versions</h3>
        <ul className="mt-3 divide-y divide-secondary-100 text-sm">
          {(versions.data || []).map((v) => (
            <li key={v.uuid} className="flex flex-wrap items-center justify-between gap-2 py-2">
              <span>v{v.version} · {dateText(v.created_at, true)}{v.notes ? ` · ${v.notes}` : ''} {v.is_active && <Badge size="sm" variant="success">active</Badge>}</span>
              {canEdit && !v.is_active && <Button size="sm" variant="ghost" onClick={async () => {
                try { await pdService.updateTemplate(current, { active_version_uuid: v.uuid }); toast.success(`v${v.version} is active again`); tpl.refresh(); versions.refresh(); } catch (e) { toast.error(pdErrorText(e)); }
              }}>Make active</Button>}
            </li>
          ))}
        </ul>
      </Card>
      {importing && <ImportModal onClose={() => setImporting(false)} onDone={() => { setImporting(false); list.refresh(); tpl.refresh(); versions.refresh(); }} />}
    </div>
  );
}

function ImportModal({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const [text, setText] = useState('');
  const [errs, setErrs] = useState<string[]>([]);
  return (
    <Modal isOpen onClose={onClose} title="Import a template" description="Paste exported JSON. Same key = a new version of that template; a new key = a new template." size="xl">
      <Textarea rows={16} className="font-mono text-xs" value={text} onChange={(e) => setText(e.target.value)} aria-label="Template JSON" />
      {errs.length > 0 && <ul className="mt-2 list-disc pl-5 text-sm text-error-700">{errs.slice(0, 20).map((e) => <li key={e}>{e}</li>)}</ul>}
      <div className="mt-4 flex justify-end gap-2">
        <Button variant="ghost" onClick={onClose}>Cancel</Button>
        <Button onClick={async () => {
          let d: unknown;
          try { d = JSON.parse(text); } catch { setErrs(['The JSON does not parse']); return; }
          try { await pdService.importTemplate(d); toast.success('Imported'); onDone(); } catch (e) { const err = pdError(e); setErrs(Array.isArray(err.details) ? (err.details as string[]) : [pdErrorText(e)]); }
        }}>Import</Button>
      </div>
    </Modal>
  );
}

'use client';

/**
 * Property Deals — the deal page (SPEC §3.8 #3): header with stage, health and why, target
 * dates, money at risk and the slip forecast; tabs for Tasks, Enquiries & blockers, Chase log,
 * Documents, Compliance, Buyers/matches and Timeline. One call fills the page
 * (GET /deals/{id}/overview); tabs load their own lists.
 */
import React, { useState } from 'react';
import Link from 'next/link';
import { useParams } from 'next/navigation';
import { ArrowLeft, ArrowRight, CheckCircle2, Circle, CircleDot, FileUp, Plus, AlertTriangle, Download } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Card, Input, Modal, Select, Textarea } from '@/components/ui';
import { pdService, pdErrorText, type DealOverview, type Gate } from '@/services/property-deals.service';
import {
  PdPage, HealthBadge, Tabs, gbp, dateText, dueText, Spinner, ErrorNote, Empty, UrgencyScore, TaskStatusBadge, BASE, label,
} from '@/components/property-deals/ui';
import TaskActions from '@/components/property-deals/TaskActions';
import MatchRow from '@/components/property-deals/MatchRow';
import { usePdData, usePdMe } from '@/components/property-deals/usePd';
import { cn } from '@/lib/utils';

type TabKey = 'tasks' | 'enquiries' | 'chases' | 'documents' | 'compliance' | 'buyers' | 'timeline';
const PARTIES = ['seller_solicitor', 'buyer_solicitor', 'seller', 'buyer', 'lender', 'freeholder', 'managing_agent', 'council', 'other'];

export default function DealPage() {
  return (
    <PdPage module="deals">
      <Deal />
    </PdPage>
  );
}

function Deal() {
  const { id } = useParams<{ id: string }>();
  const { can } = usePdMe();
  const [tab, setTab] = useState<TabKey>('tasks');
  const ov = usePdData(async () => (await pdService.overview(id)).data, [id], 60_000);
  const [gate, setGate] = useState<Gate | null>(null);
  const [gateFor, setGateFor] = useState<string | undefined>(undefined);
  const [pick, setPick] = useState('');
  const [moving, setMoving] = useState(false);

  if (ov.loading && !ov.data) return <Spinner />;
  if (ov.error) return <ErrorNote error={ov.error} />;
  const o = ov.data as DealOverview;
  const d = o.deal;
  const next = o.stage.next;

  async function moveTo(to?: string) {
    if (!to) return;
    setMoving(true);
    try {
      const g = (await pdService.gate(id, to)).data;
      if (!g.ok) {
        setGateFor(to);
        setGate(g);
        return;
      }
      await pdService.moveStage(id, to);
      toast.success(`Moved to ${label(to)}`);
      ov.refresh();
    } catch (e) {
      toast.error(pdErrorText(e));
    } finally {
      setMoving(false);
    }
  }

  return (
    <div className="space-y-5">
      <Link href={`${BASE}/deals`} className="inline-flex items-center gap-1 text-sm text-secondary-500 hover:text-secondary-800">
        <ArrowLeft className="h-4 w-4" /> Deals
      </Link>

      <Card data-tour="deal-header">
        <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div>
            <div className="flex flex-wrap items-center gap-3">
              <h1 className="text-2xl font-bold text-secondary-900">{d.name}</h1>
              <HealthBadge health={o.health.health} reasons={o.health.reasons} />
              <span className="rounded-full bg-secondary-100 px-2.5 py-0.5 text-xs font-medium text-secondary-700">{label(d.stage_key)}</span>
            </div>
            <p className="mt-1 text-sm text-secondary-500">
              {label(d.deal_type)} · {[d.address_line1, d.town, d.postcode].filter(Boolean).join(', ') || 'No property yet'}
            </p>
            {o.health.reasons && o.health.reasons.length > 0 && (
              <ul className="mt-3 space-y-1 text-sm text-secondary-700">
                {o.health.reasons.map((r) => (
                  <li key={r} className="flex items-start gap-2"><AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-warning-500" aria-hidden />{r}</li>
                ))}
              </ul>
            )}
          </div>
          <dl className="grid shrink-0 grid-cols-2 gap-x-6 gap-y-2 text-sm sm:grid-cols-4 lg:grid-cols-2">
            <div><dt className="text-secondary-500">Target exchange</dt><dd className="font-medium text-secondary-900">{dateText(d.target_exchange_date)}</dd></div>
            <div><dt className="text-secondary-500">Target completion</dt><dd className="font-medium text-secondary-900">{dateText(d.target_completion_date)}</dd></div>
            <div>
              <dt className="text-secondary-500">Forecast completion</dt>
              <dd className={cn('font-medium', o.health.predicted_completion_date && d.target_completion_date && o.health.predicted_completion_date > d.target_completion_date ? 'text-error-600' : 'text-secondary-900')}>
                {dateText(o.health.predicted_completion_date)}
              </dd>
            </div>
            <div><dt className="text-secondary-500">Money at risk</dt><dd className={cn('font-semibold', (o.health.money_at_risk ?? 0) > 0 ? 'text-error-600' : 'text-secondary-900')}>{gbp(o.health.money_at_risk)}</dd></div>
            <div><dt className="text-secondary-500">Offer / agreed</dt><dd className="font-medium text-secondary-900">{gbp(d.agreed_price ?? d.offer_amount)}</dd></div>
            <div><dt className="text-secondary-500">Working days left</dt><dd className="font-medium text-secondary-900">{o.health.working_days_left ?? '—'}</dd></div>
          </dl>
        </div>
      </Card>

      <Card padding="sm" data-tour="stage-track">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <ol className="flex flex-wrap items-center gap-1 text-xs" aria-label="Stages">
            {o.stage.stages?.map((s) => (
              <li key={s.key} className={cn('flex items-center gap-1 rounded-full px-2 py-1', s.state === 'current' ? 'bg-primary-500 text-white' : s.state === 'done' ? 'bg-success-500/10 text-success-700' : s.state === 'skipped' ? 'text-secondary-400 line-through' : 'bg-secondary-100 text-secondary-600')}>
                {s.state === 'done' ? <CheckCircle2 className="h-3.5 w-3.5" aria-hidden /> : s.state === 'current' ? <CircleDot className="h-3.5 w-3.5" aria-hidden /> : <Circle className="h-3.5 w-3.5" aria-hidden />}
                {s.name}
                <span className="sr-only">({s.state})</span>
              </li>
            ))}
          </ol>
          {can('deals', 'update') && (
            <div className="flex flex-wrap items-center gap-2">
              <Select aria-label="Move to stage" value={pick} onChange={(e) => setPick(e.target.value)} data-testid="stage-picker">
                <option value="">Move to…</option>
                {o.stage.stages?.filter((s) => s.key !== d.stage_key).map((s) => <option key={s.key} value={s.key}>{s.name}</option>)}
              </Select>
              <Button size="sm" variant="outline" disabled={!pick} isLoading={moving && !!pick} onClick={() => moveTo(pick)}>Move</Button>
              {next && (
                <Button size="sm" rightIcon={<ArrowRight className="h-4 w-4" />} onClick={() => moveTo(next)} isLoading={moving && !pick}>
                  Next: {label(next)}
                </Button>
              )}
            </div>
          )}
        </div>
        {o.stage.next_gate && !o.stage.next_gate.ok && (
          <p className="mt-2 text-xs text-secondary-500">Before {label(next)}: {o.stage.next_gate.missing.slice(0, 3).map((m) => m.message).join(' · ')}{o.stage.next_gate.missing.length > 3 ? ` · +${o.stage.next_gate.missing.length - 3} more` : ''}</p>
        )}
      </Card>

      <Tabs<TabKey>
        value={tab}
        onChange={setTab}
        tabs={[
          { key: 'tasks', label: 'Tasks', count: o.tasks.open?.length },
          { key: 'enquiries', label: 'Enquiries & blockers', count: o.enquiries?.filter((e) => e.status === 'open').length },
          { key: 'chases', label: 'Chase log' },
          { key: 'documents', label: 'Documents', count: o.documents?.reduce((a, x) => a + (x.count || 0), 0) },
          { key: 'compliance', label: 'Compliance' },
          { key: 'buyers', label: 'Buyers' },
          { key: 'timeline', label: 'Timeline' },
        ]}
      />
      <div role="tabpanel">
        {tab === 'tasks' && <TasksTab dealId={id} onChanged={ov.refresh} />}
        {tab === 'enquiries' && <EnquiriesTab dealId={id} onChanged={ov.refresh} />}
        {tab === 'chases' && <ChasesTab dealId={id} />}
        {tab === 'documents' && <DocumentsTab dealId={id} propertyId={d.property_uuid} />}
        {tab === 'compliance' && <ComplianceTab dealId={id} items={o.compliance || []} onChanged={ov.refresh} />}
        {tab === 'buyers' && <BuyersTab propertyId={d.property_uuid} />}
        {tab === 'timeline' && <TimelineTab dealId={id} />}
      </div>

      <Modal isOpen={!!gate} onClose={() => setGate(null)} title={`Not ready for ${label(gateFor)} yet`} description="These are missing:">
        <ul className="list-disc space-y-1 pl-5 text-sm text-secondary-700">
          {gate?.missing.map((m) => <li key={`${m.type}:${m.key}`}>{m.message}</li>)}
        </ul>
        <div className="mt-4 flex justify-end"><Button onClick={() => setGate(null)}>OK</Button></div>
      </Modal>
    </div>
  );
}

function TasksTab({ dealId, onChanged }: { dealId: string; onChanged: () => void }) {
  const { can } = usePdMe();
  const [showDone, setShowDone] = useState(false);
  const [adding, setAdding] = useState(false);
  const [title, setTitle] = useState('');
  const tasks = usePdData(async () => (await pdService.tasks({ deal_uuid: dealId, per_page: 100, ...(showDone ? {} : { open: 'true' }) })).data, [dealId, showDone]);
  const refresh = () => { tasks.refresh(); onChanged(); };
  return (
    <Card padding="none">
      <div className="flex flex-wrap items-center justify-between gap-2 border-b border-secondary-200 p-3">
        <label className="flex items-center gap-2 text-sm text-secondary-600">
          <input type="checkbox" checked={showDone} onChange={(e) => setShowDone(e.target.checked)} /> Show done
        </label>
        {can('tasks', 'create') && <Button size="sm" leftIcon={<Plus className="h-4 w-4" />} onClick={() => setAdding(true)}>Add task</Button>}
      </div>
      <ErrorNote error={tasks.error} />
      {!tasks.data?.length ? (
        <div className="p-6"><Empty title={tasks.loading ? 'Loading…' : 'No open tasks'} /></div>
      ) : (
        <ul className="divide-y divide-secondary-100">
          {tasks.data.map((t) => {
            const due = dueText(t.due_at);
            const waiting = (t.metadata as { waiting_on?: string[] } | undefined)?.waiting_on;
            return (
              <li key={t.task_uuid} className="flex flex-col gap-2 p-4 sm:flex-row sm:items-start">
                <UrgencyScore score={t.urgency_score} why={t.urgency_why} />
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="font-medium text-secondary-900">{t.title}</span>
                    <TaskStatusBadge status={t.pd_status} />
                    {t.blocking && <span className="rounded bg-secondary-100 px-1.5 text-xs text-secondary-600">blocking</span>}
                    {t.compliance && <span className="rounded bg-info-500/10 px-1.5 text-xs text-info-600">compliance</span>}
                    {t.agent_eligible && <span className="rounded bg-primary-500/10 px-1.5 text-xs text-primary-600">AI can help</span>}
                  </div>
                  <div className="mt-0.5 flex flex-wrap gap-x-3 text-sm text-secondary-500">
                    <span>{label(t.stage_key)}</span>
                    {waiting?.length ? <span>waits for {waiting.join(', ').replace(/_/g, ' ')}</span> : <span className={cn(due.overdue && 'font-semibold text-error-600')}>{due.text}</span>}
                    {t.snoozed_until && <span>snoozed to {dateText(t.snoozed_until, true)} — {t.snooze_reason}</span>}
                  </div>
                  <div className="mt-2"><TaskActions task={t} onChanged={refresh} /></div>
                </div>
              </li>
            );
          })}
        </ul>
      )}
      <Modal isOpen={adding} onClose={() => setAdding(false)} title="Add a task to this deal">
        <Input label="Title" value={title} onChange={(e) => setTitle(e.target.value)} />
        <div className="mt-4 flex justify-end gap-2">
          <Button variant="ghost" onClick={() => setAdding(false)}>Cancel</Button>
          <Button disabled={!title} onClick={async () => {
            try { await pdService.createTask({ deal_uuid: dealId, title }); toast.success('Task added'); setAdding(false); setTitle(''); refresh(); } catch (e) { toast.error(pdErrorText(e)); }
          }}>Add</Button>
        </div>
      </Modal>
    </Card>
  );
}

function EnquiriesTab({ dealId, onChanged }: { dealId: string; onChanged: () => void }) {
  const { can } = usePdMe();
  const list = usePdData(async () => (await pdService.enquiries(dealId)).data, [dealId]);
  const [f, setF] = useState<Record<string, string>>({ owner_party: 'seller_solicitor' });
  const [open, setOpen] = useState(false);
  const refresh = () => { list.refresh(); onChanged(); };
  return (
    <Card padding="none">
      <div className="flex justify-end border-b border-secondary-200 p-3">
        {can('tasks', 'create') && <Button size="sm" leftIcon={<Plus className="h-4 w-4" />} onClick={() => setOpen(true)}>Raise enquiry</Button>}
      </div>
      {!list.data?.length ? (
        <div className="p-6"><Empty title="No enquiries">Open legal questions and missing items show here.</Empty></div>
      ) : (
        <ul className="divide-y divide-secondary-100">
          {list.data.map((e) => (
            <li key={e.uuid} className="flex flex-wrap items-start justify-between gap-3 p-4">
              <div>
                <div className="flex flex-wrap items-center gap-2">
                  <span className={cn('font-medium', e.status === 'open' ? 'text-secondary-900' : 'text-secondary-400 line-through')}>{e.title}</span>
                  {e.blocking && e.status === 'open' && <span className="rounded bg-error-500/10 px-1.5 text-xs text-error-600">blocking</span>}
                  {e.source === 'agent' && <span className="rounded bg-primary-500/10 px-1.5 text-xs text-primary-600">from AI review</span>}
                </div>
                <div className="text-sm text-secondary-500">Waiting on {label(e.owner_party)} · raised {dateText(e.raised_at)}{e.resolved_at ? ` · resolved ${dateText(e.resolved_at)}` : ''}</div>
                {e.detail && <p className="mt-1 text-sm text-secondary-600">{e.detail}</p>}
                {e.resolution && <p className="mt-1 text-sm text-success-700">{e.resolution}</p>}
              </div>
              {e.status === 'open' && can('tasks', 'update') && (
                <Button size="sm" variant="outline" onClick={async () => {
                  const note = window.prompt('How was it resolved?');
                  if (!note) return;
                  try { await pdService.updateEnquiry(e.uuid, { status: 'resolved', resolution: note, resolved_at: new Date().toISOString() }); toast.success('Resolved'); refresh(); } catch (err) { toast.error(pdErrorText(err)); }
                }}>Resolve</Button>
              )}
            </li>
          ))}
        </ul>
      )}
      <Modal isOpen={open} onClose={() => setOpen(false)} title="Raise an enquiry">
        <div className="space-y-3">
          <Input label="Title" value={f.title || ''} onChange={(e) => setF({ ...f, title: e.target.value })} />
          <Select label="Waiting on" value={f.owner_party} onChange={(e) => setF({ ...f, owner_party: e.target.value })}>
            {PARTIES.map((p) => <option key={p} value={p}>{label(p)}</option>)}
          </Select>
          <Textarea label="Detail" rows={3} value={f.detail || ''} onChange={(e) => setF({ ...f, detail: e.target.value })} />
          <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={f.blocking !== 'no'} onChange={(e) => setF({ ...f, blocking: e.target.checked ? 'yes' : 'no' })} /> Blocks exchange</label>
        </div>
        <div className="mt-4 flex justify-end gap-2">
          <Button variant="ghost" onClick={() => setOpen(false)}>Cancel</Button>
          <Button disabled={!f.title} onClick={async () => {
            try { await pdService.createEnquiry({ deal_uuid: dealId, title: f.title, owner_party: f.owner_party, detail: f.detail, blocking: f.blocking !== 'no' }); toast.success('Raised'); setOpen(false); setF({ owner_party: 'seller_solicitor' }); refresh(); } catch (e) { toast.error(pdErrorText(e)); }
          }}>Raise</Button>
        </div>
      </Modal>
    </Card>
  );
}

function ChasesTab({ dealId }: { dealId: string }) {
  const list = usePdData(async () => (await pdService.chases({ deal_uuid: dealId })).data, [dealId]);
  return (
    <Card padding="none">
      {!list.data?.length ? (
        <div className="p-6"><Empty title="No chases yet">Emails the system sent (after approval), calls and messages you logged, and replies.</Empty></div>
      ) : (
        <ul className="divide-y divide-secondary-100">
          {list.data.map((c) => (
            <li key={c.uuid} className="p-4 text-sm">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <span className="font-medium text-secondary-900">{c.subject || label(c.channel)} <span className="font-normal text-secondary-500">→ {label(c.to_party)}{c.to_name ? ` (${c.to_name})` : ''}</span></span>
                <span className={cn('rounded-full px-2 py-0.5 text-xs', c.status === 'replied' ? 'bg-success-500/10 text-success-700' : 'bg-secondary-100 text-secondary-600')}>{label(c.status)}</span>
              </div>
              <div className="mt-0.5 text-secondary-500">
                {label(c.channel)} · sent {dateText(c.sent_at, true)}{c.reply_at ? ` · replied ${dateText(c.reply_at, true)}` : ''}{c.outcome ? ` · ${label(c.outcome)}` : ''}{(c as { approval_uuid?: string }).approval_uuid ? ' · approved draft' : ''}
              </div>
              {c.body && <p className="mt-2 whitespace-pre-wrap text-secondary-700">{c.body}</p>}
            </li>
          ))}
        </ul>
      )}
    </Card>
  );
}

function DocumentsTab({ dealId, propertyId }: { dealId: string; propertyId?: string }) {
  const { can } = usePdMe();
  const docs = usePdData(async () => (await pdService.documents({ deal_uuid: dealId, per_page: 100 })).data, [dealId]);
  const [category, setCategory] = useState('other');
  const [uploading, setUploading] = useState(false);
  async function upload(file: File) {
    const form = new FormData();
    form.append('deal_uuid', dealId);
    if (propertyId) form.append('property_uuid', propertyId);
    form.append('category', category);
    form.append('file', file);
    setUploading(true);
    try { await pdService.uploadDocument(form); toast.success('Uploaded'); docs.refresh(); } catch (e) { toast.error(pdErrorText(e)); } finally { setUploading(false); }
  }
  return (
    <Card padding="none">
      {can('properties', 'create') && (
        <div className="flex flex-wrap items-end gap-3 border-b border-secondary-200 p-3">
          <Select label="Category" value={category} onChange={(e) => setCategory(e.target.value)}>
            {['title', 'lease', 'survey', 'valuation', 'epc', 'searches', 'id', 'proof_of_funds', 'aml', 'contract', 'completion_statement', 'photo', 'correspondence', 'other'].map((c) => <option key={c} value={c}>{label(c)}</option>)}
          </Select>
          <label className={cn('inline-flex h-10 cursor-pointer items-center gap-2 rounded-lg bg-primary-500 px-4 text-sm font-medium text-white hover:bg-primary-600 focus-within:ring-2 focus-within:ring-primary-500', uploading && 'opacity-60')}>
            <FileUp className="h-4 w-4" aria-hidden /> {uploading ? 'Uploading…' : 'Upload a file'}
            <input type="file" className="sr-only" disabled={uploading} onChange={(e) => e.target.files?.[0] && upload(e.target.files[0])} />
          </label>
          <span className="text-xs text-secondary-500">Up to 25 MB. Stored privately; links last 5 minutes.</span>
        </div>
      )}
      {!docs.data?.length ? (
        <div className="p-6"><Empty title="No documents">Title, lease, searches, ID, photos…</Empty></div>
      ) : (
        <ul className="divide-y divide-secondary-100">
          {docs.data.map((doc) => (
            <li key={doc.uuid} className="flex items-center justify-between gap-3 p-4 text-sm">
              <div>
                <div className="font-medium text-secondary-900">{doc.filename}</div>
                <div className="text-secondary-500">{label(doc.category)} · {doc.size_bytes ? `${Math.round(doc.size_bytes / 1024)} KB` : ''} · {dateText(doc.created_at)}</div>
              </div>
              <Button size="sm" variant="ghost" leftIcon={<Download className="h-4 w-4" />} onClick={async () => {
                try { const d = (await pdService.document(doc.uuid)).data; if (d.download_url) window.open(d.download_url, '_blank', 'noopener'); } catch (e) { toast.error(pdErrorText(e)); }
              }}>Open</Button>
            </li>
          ))}
        </ul>
      )}
    </Card>
  );
}

function ComplianceTab({ dealId, items, onChanged }: { dealId: string; items: NonNullable<DealOverview['compliance']>; onChanged: () => void }) {
  const { can } = usePdMe();
  return (
    <Card padding="none">
      {!items.length ? (
        <div className="p-6"><Empty title="No compliance items for this template" /></div>
      ) : (
        <ul className="divide-y divide-secondary-100">
          {items.map((c) => {
            const check = c.check as { uuid?: string; status?: string; expires_at?: string; checked_at?: string } | undefined;
            return (
              <li key={`${c.key}:${c.party_role || ''}`} className="flex flex-wrap items-center justify-between gap-3 p-4 text-sm">
                <div>
                  <div className={cn('font-medium', c.applies === false ? 'text-secondary-400' : 'text-secondary-900')}>{c.name || label(c.key)}{c.party_role ? ` — ${label(c.party_role)}` : ''}</div>
                  <div className="text-secondary-500">
                    {c.applies === false ? 'Not needed for this deal' : label(check?.status || c.status || 'not_started')}
                    {check?.expires_at ? ` · expires ${dateText(check.expires_at)}` : ''}
                  </div>
                </div>
                {c.applies !== false && !check && can('compliance', 'create') && (
                  <Button size="sm" variant="outline" onClick={async () => {
                    try { await pdService.createCheck({ check_type: c.key, subject_type: 'deal', deal_uuid: dealId, party_role: c.party_role, status: 'in_progress' }); toast.success('Started'); onChanged(); } catch (e) { toast.error(pdErrorText(e)); }
                  }}>Start</Button>
                )}
                {check?.uuid && <Link className="text-primary-600 hover:underline" href={`${BASE}/compliance?check=${check.uuid}`}>Open</Link>}
              </li>
            );
          })}
        </ul>
      )}
    </Card>
  );
}

function BuyersTab({ propertyId }: { propertyId?: string }) {
  const { can } = usePdMe();
  const matches = usePdData(async () => (propertyId ? (await pdService.propertyMatches(propertyId)).data : []), [propertyId]);
  if (!propertyId) return <Empty title="No property on this deal" />;
  return (
    <Card padding="none">
      {!matches.data?.length ? (
        <div className="p-6"><Empty title="No matching buyers yet">Add buyer profiles on the Buyers page; scores update by themselves.</Empty></div>
      ) : (
        <ul className="divide-y divide-secondary-100">
          {matches.data.map((m) => <MatchRow key={m.uuid} m={m} canSend={can('buyers', 'update')} onChanged={matches.refresh} />)}
        </ul>
      )}
    </Card>
  );
}

function TimelineTab({ dealId }: { dealId: string }) {
  const tl = usePdData(async () => (await pdService.timeline(dealId)).data, [dealId]);
  return (
    <Card padding="none">
      {!tl.data?.length ? (
        <div className="p-6"><Empty title={tl.loading ? 'Loading…' : 'Nothing recorded yet'}>Every change on the deal, its tasks, enquiries, chases, approvals and documents — who and when.</Empty></div>
      ) : (
        <ol className="divide-y divide-secondary-100">
          {tl.data.map((e) => (
            <li key={e.uuid} className="flex gap-3 p-3 text-sm">
              <span className="w-32 shrink-0 text-secondary-500">{dateText(e.created_at, true)}</span>
              <span className="text-secondary-800">{label(e.event_type)} <span className="text-secondary-500">{label(e.entity_type)}</span></span>
            </li>
          ))}
        </ol>
      )}
    </Card>
  );
}

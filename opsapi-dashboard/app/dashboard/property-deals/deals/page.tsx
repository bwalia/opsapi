'use client';

/**
 * Property Deals — Deals (SPEC §3.8 #3): Kanban by stage plus a list view.
 * Dragging a deal checks the stage gate first; if anything is missing the move is refused
 * and the exact reasons are shown. Gated columns show a lock.
 */
import React, { useMemo, useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { DndContext, PointerSensor, KeyboardSensor, useDraggable, useDroppable, useSensor, useSensors, type DragEndEvent } from '@dnd-kit/core';
import { Kanban, List, Plus, Lock, Search } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, Card, Input, Modal, Select, Table } from '@/components/ui';
import { pdService, pdErrorText, type DealBoard, type Deal, type Gate } from '@/services/property-deals.service';
import { PdPage, HealthBadge, gbp, dateText, Spinner, ErrorNote, Empty, BASE, label } from '@/components/property-deals/ui';
import { usePdData, usePdMe } from '@/components/property-deals/usePd';
import type { TableColumn } from '@/types';
import { cn } from '@/lib/utils';

type BoardDeal = NonNullable<NonNullable<DealBoard['columns']>[number]['deals']>[number];

export default function DealsPage() {
  return (
    <PdPage module="deals">
      <Deals />
    </PdPage>
  );
}

function Deals() {
  const { can } = usePdMe();
  const [view, setView] = useState<'board' | 'list'>('board');
  const [template, setTemplate] = useState<string>('');
  const [creating, setCreating] = useState(false);
  const templates = usePdData(async () => (await pdService.templates()).data, []);
  const board = usePdData(async () => (await pdService.board(template || undefined)).data, [template], 60_000);

  return (
    <div className="space-y-6">
      <PageHeader
        title="Deals"
        description={board.data?.template ? `${board.data.template.name} · version ${board.data.template.version}` : 'Your pipeline by stage'}
        icon={<Kanban className="h-6 w-6" />}
        actions={
          <>
            <div className="flex rounded-lg border border-secondary-200 p-0.5" role="group" aria-label="View" data-tour="deals-view">
              <Button size="sm" variant={view === 'board' ? 'secondary' : 'ghost'} onClick={() => setView('board')} leftIcon={<Kanban className="h-4 w-4" />} aria-pressed={view === 'board'}>
                Board
              </Button>
              <Button size="sm" variant={view === 'list' ? 'secondary' : 'ghost'} onClick={() => setView('list')} leftIcon={<List className="h-4 w-4" />} aria-pressed={view === 'list'}>
                List
              </Button>
            </div>
            {can('deals', 'create') && (
              <Button leftIcon={<Plus className="h-4 w-4" />} onClick={() => setCreating(true)} data-tour="new-deal">
                New deal
              </Button>
            )}
          </>
        }
      />
      {view === 'board' && (templates.data?.length ?? 0) > 1 && (
        <div className="max-w-xs">
          <Select label="Workflow template" value={template || board.data?.template?.key || ''} onChange={(e) => setTemplate(e.target.value)}>
            {templates.data?.map((t) => (
              <option key={t.uuid} value={t.key}>{t.name}{t.active_deals !== undefined ? ` (${t.active_deals} active)` : ''}</option>
            ))}
          </Select>
        </div>
      )}
      <ErrorNote error={board.error} />
      {view === 'board' ? (
        board.loading && !board.data ? <Spinner /> : board.data ? <Board board={board.data} onMoved={board.refresh} canMove={can('deals', 'update')} /> : null
      ) : (
        <DealList />
      )}
      {creating && (
        <NewDealModal
          templates={templates.data || []}
          onClose={() => setCreating(false)}
          onCreated={() => {
            setCreating(false);
            board.refresh();
          }}
        />
      )}
    </div>
  );
}

function DealCard({ deal, draggable }: { deal: BoardDeal; draggable: boolean }) {
  const { attributes, listeners, setNodeRef, transform, isDragging } = useDraggable({ id: deal.uuid!, data: deal, disabled: !draggable });
  const style = transform ? { transform: `translate3d(${transform.x}px, ${transform.y}px, 0)` } : undefined;
  return (
    <div
      ref={setNodeRef}
      style={style}
      {...attributes}
      {...listeners}
      className={cn(
        'rounded-lg border border-secondary-200 bg-surface p-3 text-sm shadow-sm outline-none focus-visible:ring-2 focus-visible:ring-primary-500',
        draggable && 'cursor-grab',
        isDragging && 'z-20 opacity-80 shadow-lg',
      )}
      aria-label={`${deal.name}. ${draggable ? 'Press space to pick up and move to another stage.' : ''}`}
    >
      <div className="flex items-start justify-between gap-2">
        <Link href={`${BASE}/deals/${deal.uuid}`} className="font-medium text-secondary-900 hover:text-primary-600 hover:underline" onPointerDown={(e) => e.stopPropagation()}>
          {deal.name}
        </Link>
        <HealthBadge health={deal.health} />
      </div>
      {deal.postcode && <div className="mt-0.5 text-xs text-secondary-500">{deal.address_line1} · {deal.postcode}</div>}
      <div className="mt-2 flex flex-wrap gap-x-3 text-xs text-secondary-500">
        <span>{deal.open_tasks ?? 0} open</span>
        {(deal.overdue_tasks ?? 0) > 0 && <span className="font-semibold text-error-600">{deal.overdue_tasks} overdue</span>}
        {(deal.money_at_risk ?? 0) > 0 && <span className="text-error-600">{gbp(deal.money_at_risk)} at risk</span>}
        {deal.target_completion_date && <span>Target {dateText(deal.target_completion_date)}</span>}
      </div>
    </div>
  );
}

function Column({ col, children }: { col: NonNullable<DealBoard['columns']>[number]; children: React.ReactNode }) {
  const { setNodeRef, isOver } = useDroppable({ id: col.key! });
  const g = col.gate_summary;
  const gateText = g ? [g.tasks && `${g.tasks} task(s)`, g.compliance && `${g.compliance} check(s)`, g.documents && `${g.documents} document(s)`, g.fields && `${g.fields} field(s)`, g.no_open_blocking_enquiries && 'no open blockers'].filter(Boolean).join(', ') : '';
  return (
    <section
      ref={setNodeRef}
      aria-label={`${col.name} stage`}
      className={cn('flex w-72 shrink-0 flex-col rounded-xl bg-secondary-50 p-2 transition-colors', isOver && 'bg-primary-500/10 ring-2 ring-primary-500/40')}
    >
      <header className="mb-2 flex items-center justify-between px-1">
        <h3 className="flex items-center gap-1.5 text-sm font-semibold text-secondary-800">
          {col.has_gate && <Lock className="h-3.5 w-3.5 text-secondary-400" aria-label={`Gate: needs ${gateText}`} />}
          {col.name}
          {col.parallel && <span className="text-xs font-normal text-secondary-400">(parallel)</span>}
        </h3>
        <span className="rounded-full bg-secondary-200 px-2 text-xs text-secondary-700">{col.deals?.length ?? 0}</span>
      </header>
      {col.has_gate && gateText && <p className="mb-2 px-1 text-xs text-secondary-500">Gate: {gateText}</p>}
      <div className="flex min-h-[4rem] flex-col gap-2">{children}</div>
    </section>
  );
}

function Board({ board, onMoved, canMove }: { board: DealBoard; onMoved: () => void; canMove: boolean }) {
  const sensors = useSensors(useSensor(PointerSensor, { activationConstraint: { distance: 6 } }), useSensor(KeyboardSensor));
  const [blocked, setBlocked] = useState<{ deal: string; stage: string; gate: Gate } | null>(null);
  const columns = useMemo(() => board.columns || [], [board.columns]);
  const names = useMemo(() => Object.fromEntries(columns.map((c) => [c.key, c.name])), [columns]);

  async function onDragEnd(e: DragEndEvent) {
    const deal = e.active.data.current as BoardDeal | undefined;
    const to = e.over?.id as string | undefined;
    if (!deal?.uuid || !to || to === deal.stage_key) return;
    try {
      const gate = (await pdService.gate(deal.uuid, to)).data;
      if (!gate.ok) {
        setBlocked({ deal: deal.name || 'This deal', stage: names[to] || to, gate });
        return;
      }
      await pdService.moveStage(deal.uuid, to);
      toast.success(`${deal.name} moved to ${names[to] || to}`);
      onMoved();
    } catch (err) {
      toast.error(pdErrorText(err));
    }
  }

  if (columns.length === 0) return <Empty title="No stages">This template has no stages.</Empty>;
  return (
    <>
      <DndContext sensors={sensors} onDragEnd={onDragEnd}>
        <div className="flex gap-3 overflow-x-auto pb-4" data-tour="deals-board">
          {columns.map((col) => (
            <Column key={col.key} col={col}>
              {(col.deals || []).map((d) => (
                <DealCard key={d.uuid} deal={d} draggable={canMove} />
              ))}
            </Column>
          ))}
        </div>
      </DndContext>
      <Modal isOpen={!!blocked} onClose={() => setBlocked(null)} title={`Can't move to ${blocked?.stage}`} description={`${blocked?.deal} doesn't meet the gate yet:`}>
        <ul className="list-disc space-y-1 pl-5 text-sm text-secondary-700">
          {blocked?.gate.missing.map((m) => (
            <li key={`${m.type}:${m.key}`}>{m.message}</li>
          ))}
        </ul>
        <div className="mt-4 flex justify-end">
          <Button onClick={() => setBlocked(null)}>OK</Button>
        </div>
      </Modal>
    </>
  );
}

function DealList() {
  const router = useRouter();
  const [q, setQ] = useState('');
  const [sort, setSort] = useState('money_at_risk');
  const [page, setPage] = useState(1);
  const list = usePdData(async () => pdService.deals({ q, sort, page, per_page: 25 }), [q, sort, page]);
  const cols: TableColumn<Deal>[] = [
    { key: 'name', header: 'Deal', render: (d) => <span className="font-medium text-secondary-900">{d.name}</span> },
    { key: 'stage_key', header: 'Stage', render: (d) => label(d.stage_key) },
    { key: 'health', header: 'Health', render: (d) => <HealthBadge health={d.health} reasons={d.health_reasons} /> },
    { key: 'money_at_risk', header: 'At risk', render: (d) => gbp(d.money_at_risk) },
    { key: 'target_completion_date', header: 'Target completion', render: (d) => dateText(d.target_completion_date) },
    { key: 'predicted_completion_date', header: 'Forecast', render: (d) => dateText(d.predicted_completion_date) },
    { key: 'postcode', header: 'Postcode' },
  ];
  return (
    <Card padding="none">
      <div className="flex flex-wrap items-end gap-3 border-b border-secondary-200 p-4">
        <div className="min-w-[16rem] flex-1">
          <Input leftIcon={<Search className="h-4 w-4" />} placeholder="Name, address or postcode" value={q} onChange={(e) => { setQ(e.target.value); setPage(1); }} aria-label="Search deals" />
        </div>
        <Select value={sort} onChange={(e) => setSort(e.target.value)} aria-label="Sort by">
          <option value="money_at_risk">Most at risk</option>
          <option value="target_completion">Target date</option>
          <option value="health">Health</option>
          <option value="created">Newest</option>
        </Select>
      </div>
      <ErrorNote error={list.error} />
      <Table columns={cols} data={list.data?.data || []} keyExtractor={(d) => d.uuid} onRowClick={(d) => router.push(`${BASE}/deals/${d.uuid}`)} isLoading={list.loading} emptyMessage="No deals yet" />
      <div className="flex items-center justify-between p-3 text-sm text-secondary-500">
        <span>{list.data?.meta?.total ?? 0} deals</span>
        <div className="flex gap-2">
          <Button size="sm" variant="ghost" disabled={page <= 1} onClick={() => setPage(page - 1)}>Previous</Button>
          <Button size="sm" variant="ghost" disabled={page >= (list.data?.meta?.total_pages ?? 1)} onClick={() => setPage(page + 1)}>Next</Button>
        </div>
      </div>
    </Card>
  );
}

function NewDealModal({ templates, onClose, onCreated }: { templates: { key: string; name: string }[]; onClose: () => void; onCreated: () => void }) {
  const router = useRouter();
  const [f, setF] = useState<Record<string, string>>({ deal_type: 'buy' });
  const [busy, setBusy] = useState(false);
  const set = (k: string) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setF({ ...f, [k]: e.target.value });
  async function create() {
    setBusy(true);
    try {
      const prop = (await pdService.createProperty({ address_line1: f.address, postcode: f.postcode || undefined, town: f.town || undefined, tenure: f.tenure || 'unknown' })).data;
      const deal = (
        await pdService.createDeal({
          property_uuid: prop.uuid,
          deal_type: f.deal_type as 'buy',
          template: f.template || undefined,
          name: f.name || undefined,
          offer_amount: f.offer ? Number(f.offer) : undefined,
          target_completion_date: f.target || undefined,
          late_penalty_per_day: f.penalty ? Number(f.penalty) : undefined,
          late_penalty_cap_days: f.cap ? Number(f.cap) : undefined,
        })
      ).data;
      toast.success('Deal created — its first tasks are ready');
      onCreated();
      router.push(`${BASE}/deals/${deal.uuid}`);
    } catch (e) {
      toast.error(pdErrorText(e));
    } finally {
      setBusy(false);
    }
  }
  return (
    <Modal isOpen onClose={onClose} title="New deal" description="To start from a lead, open it on the Leads page and use “Create deal”." size="lg">
      <div className="grid gap-3 sm:grid-cols-2">
        <Input label="Address" value={f.address || ''} onChange={set('address')} required />
        <Input label="Postcode" value={f.postcode || ''} onChange={set('postcode')} />
        <Input label="Town" value={f.town || ''} onChange={set('town')} />
        <Select label="Tenure" value={f.tenure || ''} onChange={set('tenure')}>
          <option value="">Unknown</option>
          <option value="freehold">Freehold</option>
          <option value="leasehold">Leasehold</option>
          <option value="share_of_freehold">Share of freehold</option>
        </Select>
        <Select label="Deal type" value={f.deal_type} onChange={set('deal_type')}>
          {['buy', 'sell', 'buy_and_assign', 'sourcing'].map((t) => (
            <option key={t} value={t}>{label(t)}</option>
          ))}
        </Select>
        <Select label="Workflow template" value={f.template || ''} onChange={set('template')}>
          <option value="">Default for the deal type</option>
          {templates.map((t) => (
            <option key={t.key} value={t.key}>{t.name}</option>
          ))}
        </Select>
        <Input label="Deal name (optional)" value={f.name || ''} onChange={set('name')} />
        <Input label="Offer (£)" type="number" min={0} value={f.offer || ''} onChange={set('offer')} />
        <Input label="Target completion" type="date" value={f.target || ''} onChange={set('target')} />
        <Input label="Late penalty per day (£)" type="number" min={0} value={f.penalty || ''} onChange={set('penalty')} />
        <Input label="Penalty cap (days)" type="number" min={0} value={f.cap || ''} onChange={set('cap')} />
      </div>
      <div className="mt-5 flex justify-end gap-2">
        <Button variant="ghost" onClick={onClose}>Cancel</Button>
        <Button onClick={create} isLoading={busy} disabled={!f.address}>Create deal</Button>
      </div>
    </Modal>
  );
}

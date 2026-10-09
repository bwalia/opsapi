'use client';

/**
 * Property Deals — Suppliers (SPEC §3.8 #6): the directory with type filters, measured
 * turnaround and on-time %, and "book nearest": the nearest suitable suppliers for a property,
 * then a booking task on its deal that the booking agent can work on.
 */
import React, { useState } from 'react';
import { Wrench, Plus, Navigation } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, Card, Input, Modal, Select, Table } from '@/components/ui';
import { pdService, pdErrorText, type Supplier } from '@/services/property-deals.service';
import { PdPage, ErrorNote, label } from '@/components/property-deals/ui';
import { usePdData, usePdMe } from '@/components/property-deals/usePd';
import type { TableColumn } from '@/types';

const KINDS = ['epc_assessor', 'surveyor', 'solicitor', 'broker', 'bridging_lender', 'builder', 'letting_agent', 'auction_house', 'managing_agent', 'searches_provider'];
const SERVICE_TASK: Record<string, string> = { epc_assessor: 'Book an EPC assessor', surveyor: 'Book survey or lender valuation' };

export default function SuppliersPage() {
  return (
    <PdPage module="suppliers">
      <Suppliers />
    </PdPage>
  );
}

function Suppliers() {
  const { can } = usePdMe();
  const [kind, setKind] = useState('');
  const [q, setQ] = useState('');
  const [sort, setSort] = useState('name');
  const list = usePdData(async () => (await pdService.suppliers({ kind: kind || undefined, q: q || undefined, sort, per_page: 100 })).data, [kind, q, sort]);
  const [adding, setAdding] = useState(false);
  const [nearest, setNearest] = useState(false);
  const cols: TableColumn<Supplier>[] = [
    { key: 'name', header: 'Supplier', render: (s) => <span className="font-medium text-secondary-900">{s.name}</span> },
    { key: 'kinds', header: 'Does', render: (s) => (s.kinds || []).map(label).join(', ') },
    { key: 'avg_turnaround_hours', header: 'Avg turnaround', render: (s) => (s.avg_turnaround_hours ? `${Math.round(Number(s.avg_turnaround_hours))} h` : '—') },
    { key: 'on_time_pct', header: 'On time', render: (s) => (s.on_time_pct !== undefined && s.on_time_pct !== null ? `${Math.round(Number(s.on_time_pct))}%` : '—') },
    { key: 'jobs_measured', header: 'Jobs', render: (s) => s.jobs_measured ?? 0 },
    { key: 'radius_miles', header: 'Covers', render: (s) => (s.radius_miles ? `${s.radius_miles} miles` : '—') },
    { key: 'email', header: 'Email' },
    { key: 'active', header: 'Active', render: (s) => (s.active === false ? 'No' : 'Yes') },
  ];
  return (
    <div className="space-y-6">
      <PageHeader title="Suppliers" description="EPC assessors, surveyors, solicitors and more — with how fast they really are." icon={<Wrench className="h-6 w-6" />}
        actions={<>
          <Button variant="outline" leftIcon={<Navigation className="h-4 w-4" />} onClick={() => setNearest(true)} data-tour="book-nearest">Book nearest</Button>
          {can('suppliers', 'create') && <Button leftIcon={<Plus className="h-4 w-4" />} onClick={() => setAdding(true)}>Add supplier</Button>}
        </>} />
      <Card padding="none" data-tour="suppliers-list">
        <div className="flex flex-wrap items-end gap-3 border-b border-secondary-200 p-4">
          <Select label="Type" value={kind} onChange={(e) => setKind(e.target.value)}>
            <option value="">All</option>{KINDS.map((k) => <option key={k} value={k}>{label(k)}</option>)}
          </Select>
          <Input label="Search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Name" />
          <Select label="Sort" value={sort} onChange={(e) => setSort(e.target.value)}>
            <option value="name">Name</option><option value="speed">Fastest</option><option value="on_time">Most on time</option><option value="rating">Rating</option>
          </Select>
        </div>
        <ErrorNote error={list.error} />
        <Table columns={cols} data={list.data || []} keyExtractor={(s) => s.uuid} isLoading={list.loading} emptyMessage="No suppliers yet" />
      </Card>
      {adding && <AddSupplier onClose={() => setAdding(false)} onSaved={() => { setAdding(false); list.refresh(); }} />}
      {nearest && <BookNearest onClose={() => setNearest(false)} />}
    </div>
  );
}

function AddSupplier({ onClose, onSaved }: { onClose: () => void; onSaved: () => void }) {
  const [f, setF] = useState<Record<string, string>>({ kind: 'epc_assessor' });
  const s = (k: string) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setF({ ...f, [k]: e.target.value });
  return (
    <Modal isOpen onClose={onClose} title="Add a supplier" description="Creates the CRM company too." size="lg">
      <div className="grid gap-3 sm:grid-cols-2">
        <Input label="Company name" value={f.name || ''} onChange={s('name')} />
        <Select label="Type" value={f.kind} onChange={s('kind')}>{KINDS.map((k) => <option key={k} value={k}>{label(k)}</option>)}</Select>
        <Input label="Email (booking requests go here)" type="email" value={f.email || ''} onChange={s('email')} />
        <Input label="Phone" value={f.phone || ''} onChange={s('phone')} />
        <Input label="Base location (lat,lng)" placeholder="53.96,-1.08" value={f.base || ''} onChange={s('base')} />
        <Input label="Covers (miles)" type="number" value={f.radius || ''} onChange={s('radius')} />
      </div>
      <div className="mt-5 flex justify-end gap-2">
        <Button variant="ghost" onClick={onClose}>Cancel</Button>
        <Button disabled={!f.name} onClick={async () => {
          const [lat, lng] = (f.base || '').split(',').map((x) => Number(x.trim()));
          try {
            await pdService.createSupplier({ name: f.name, email: f.email || undefined, phone: f.phone || undefined, kinds: [f.kind],
              base_lat: Number.isFinite(lat) && f.base ? lat : undefined, base_lng: Number.isFinite(lng) && f.base ? lng : undefined,
              radius_miles: f.radius ? Number(f.radius) : undefined });
            toast.success('Supplier added'); onSaved();
          } catch (e) { toast.error(pdErrorText(e)); }
        }}>Add</Button>
      </div>
    </Modal>
  );
}

function BookNearest({ onClose }: { onClose: () => void }) {
  const deals = usePdData(async () => (await pdService.deals({ per_page: 100, status: 'active' })).data, []);
  const [dealId, setDealId] = useState('');
  const [kind, setKind] = useState('epc_assessor');
  const [rows, setRows] = useState<Record<string, unknown>[] | null>(null);
  const deal = (deals.data || []).find((d) => d.uuid === dealId);
  return (
    <Modal isOpen onClose={onClose} title="Book the nearest supplier" description="Pick a deal and a service. We list the nearest active suppliers; then create a booking task the booking agent can work on." size="lg">
      <div className="grid gap-3 sm:grid-cols-2">
        <Select label="Deal" value={dealId} onChange={(e) => { setDealId(e.target.value); setRows(null); }}>
          <option value="">Choose…</option>{(deals.data || []).map((d) => <option key={d.uuid} value={d.uuid}>{d.name}</option>)}
        </Select>
        <Select label="Service" value={kind} onChange={(e) => { setKind(e.target.value); setRows(null); }}>{KINDS.map((k) => <option key={k} value={k}>{label(k)}</option>)}</Select>
      </div>
      <Button className="mt-3" variant="outline" disabled={!deal?.property_uuid} onClick={async () => {
        try { setRows((await pdService.nearest({ kind, property_uuid: deal!.property_uuid, limit: 5 })).data); } catch (e) { toast.error(pdErrorText(e)); }
      }}>Find nearest</Button>
      {rows && (
        <ul className="mt-3 divide-y divide-secondary-100 rounded-lg border border-secondary-200 text-sm">
          {rows.length === 0 && <li className="p-3 text-secondary-500">No active {label(kind)} in the directory.</li>}
          {rows.map((r) => (
            <li key={String(r.supplier_uuid)} className="flex justify-between p-3">
              <span className="font-medium">{String(r.name)}</span>
              <span className="text-secondary-500">{r.distance_miles !== undefined ? `${Number(r.distance_miles).toFixed(1)} mi` : 'no base set'}{r.on_time_pct !== undefined ? ` · ${Math.round(Number(r.on_time_pct))}% on time` : ''}</span>
            </li>
          ))}
        </ul>
      )}
      <div className="mt-5 flex justify-end gap-2">
        <Button variant="ghost" onClick={onClose}>Close</Button>
        <Button disabled={!deal || !rows?.length} onClick={async () => {
          try {
            await pdService.createTask({ deal_uuid: dealId, property_uuid: deal?.property_uuid, title: SERVICE_TASK[kind] || `Book ${label(kind)}`, agent_eligible: true, agent_key: 'booking_agent', approval_rule: 'any_operator', blocking: true });
            toast.success('Booking task created — use “Let AI do it” on the deal to request slots');
            onClose();
          } catch (e) { toast.error(pdErrorText(e)); }
        }}>Create booking task</Button>
      </div>
    </Modal>
  );
}

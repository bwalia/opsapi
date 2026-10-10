'use client';

/**
 * Property Deals — Renovations. Each renovation is a kanban project whose board
 * columns are the build stages (survey → strip-out → … → snagging), so builders
 * and site managers work it on the normal Projects board. This page lists them
 * with progress and starts new ones from a deal.
 */
import React, { useState } from 'react';
import Link from 'next/link';
import { Hammer, Plus, ExternalLink } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, Card, Input, Modal, Select } from '@/components/ui';
import { pdService, pdErrorText, type Renovation } from '@/services/property-deals.service';
import { namespaceService } from '@/services/namespace.service';
import { PdPage, ErrorNote, Empty, Spinner, gbp, dateText, BASE } from '@/components/property-deals/ui';
import { usePdData, usePdMe } from '@/components/property-deals/usePd';
import { cn } from '@/lib/utils';

export default function RenovationsPage() {
  return (
    <PdPage module="deals">
      <Renovations />
    </PdPage>
  );
}

function Renovations() {
  const { can } = usePdMe();
  const [status, setStatus] = useState<'active' | 'completed' | 'all'>('active');
  const [creating, setCreating] = useState(false);
  const { data, error, loading, refresh } = usePdData(async () => (await pdService.renovations({ status })).data, [status]);

  return (
    <div className="space-y-6">
      <PageHeader
        title="Renovations"
        description="Build projects on kanban boards: one column per stage, one card per job. Builders work them under Projects."
        icon={<Hammer className="h-6 w-6" />}
        actions={
          can('deals', 'create') && (
            <Button leftIcon={<Plus className="h-4 w-4" />} onClick={() => setCreating(true)}>
              Start a renovation
            </Button>
          )
        }
      />
      <div className="flex gap-1" role="group" aria-label="Filter renovations">
        {(['active', 'completed', 'all'] as const).map((s) => (
          <Button key={s} size="sm" variant={status === s ? 'secondary' : 'ghost'} onClick={() => setStatus(s)} aria-pressed={status === s}>
            {s === 'active' ? 'In progress' : s === 'completed' ? 'Completed' : 'All'}
          </Button>
        ))}
      </div>
      <ErrorNote error={error} />
      {loading && !data ? (
        <Spinner />
      ) : !data?.length ? (
        <Card>
          <Empty title="No renovations yet">Start one from a deal: you get a board with the standard build stages and dated jobs.</Empty>
        </Card>
      ) : (
        <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
          {data.map((r) => (
            <RenovationCard key={r.uuid} r={r} />
          ))}
        </div>
      )}
      {creating && (
        <StartRenovation
          onClose={() => setCreating(false)}
          onCreated={() => {
            setCreating(false);
            refresh();
          }}
        />
      )}
    </div>
  );
}

function RenovationCard({ r }: { r: Renovation }) {
  const pct = r.jobs_total ? Math.round((r.jobs_done / r.jobs_total) * 100) : 0;
  const spent = Number(r.budget_spent || 0);
  const budget = Number(r.budget || 0);
  return (
    <Card className="flex flex-col gap-3">
      <div>
        <Link href={`/dashboard/projects/${r.project_uuid}`} className="font-semibold text-secondary-900 hover:text-primary-600">
          {r.name}
        </Link>
        <div className="text-sm text-secondary-500">
          {r.address ? `${r.address}${r.postcode ? `, ${r.postcode}` : ''}` : 'No property linked'}
        </div>
        {r.deal_uuid && (
          <Link href={`${BASE}/deals/${r.deal_uuid}`} className="text-sm text-primary-600 hover:underline">
            {r.deal_name || 'Deal'}
          </Link>
        )}
      </div>
      <div>
        <div className="mb-1 flex justify-between text-xs text-secondary-600">
          <span>{r.jobs_done} of {r.jobs_total} jobs done</span>
          <span>{pct}%</span>
        </div>
        <div className="h-2 overflow-hidden rounded-full bg-secondary-100" role="progressbar" aria-valuenow={pct} aria-valuemin={0} aria-valuemax={100}>
          <div className="h-full bg-primary-500" style={{ width: `${pct}%` }} />
        </div>
      </div>
      <dl className="grid grid-cols-2 gap-2 text-sm">
        <div>
          <dt className="text-xs text-secondary-500">Finish by</dt>
          <dd>{dateText(r.due_date)}</dd>
        </div>
        <div>
          <dt className="text-xs text-secondary-500">Overdue jobs</dt>
          <dd className={cn(r.jobs_overdue > 0 && 'font-semibold text-error-600')}>{r.jobs_overdue}</dd>
        </div>
        <div>
          <dt className="text-xs text-secondary-500">Budget</dt>
          <dd>{budget ? gbp(budget) : '—'}</dd>
        </div>
        <div>
          <dt className="text-xs text-secondary-500">Spent</dt>
          <dd className={cn(budget > 0 && spent > budget && 'font-semibold text-error-600')}>{spent ? gbp(spent) : '—'}</dd>
        </div>
      </dl>
      <div className="mt-auto flex flex-wrap gap-2">
        <Link href={`/dashboard/projects/${r.project_uuid}`}>
          <Button size="sm" leftIcon={<ExternalLink className="h-4 w-4" />}>Open board</Button>
        </Link>
        <Link href={`/dashboard/purchase-orders?project_uuid=${r.project_uuid}`}>
          <Button size="sm" variant="outline">Purchase orders</Button>
        </Link>
      </div>
    </Card>
  );
}

function StartRenovation({ onClose, onCreated }: { onClose: () => void; onCreated: () => void }) {
  const deals = usePdData(async () => (await pdService.deals({ per_page: 100 })).data, []);
  const members = usePdData(async () => (await namespaceService.getMembers({ perPage: 100, status: 'active' })).data || [], []);
  const [f, setF] = useState({ deal_uuid: '', name: '', budget: '', start_date: '', target_end_date: '' });
  const [builders, setBuilders] = useState<string[]>([]);
  const [saving, setSaving] = useState(false);
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setF({ ...f, [k]: e.target.value });

  const submit = async () => {
    setSaving(true);
    try {
      const r = (
        await pdService.createRenovation({
          deal_uuid: f.deal_uuid || undefined,
          name: f.name || undefined,
          budget: f.budget ? Number(f.budget) : undefined,
          start_date: f.start_date || undefined,
          target_end_date: f.target_end_date || undefined,
          builder_user_uuids: builders.length ? builders : undefined,
        })
      ).data;
      toast.success(`Board created with ${r.jobs_total} jobs`);
      onCreated();
    } catch (e) {
      toast.error(pdErrorText(e));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal isOpen onClose={onClose} title="Start a renovation" description="Creates a project board with the standard build stages and dated jobs. Change anything on the board afterwards." size="lg">
      <div className="grid gap-3 sm:grid-cols-2">
        <Select label="Deal" value={f.deal_uuid} onChange={set('deal_uuid')}>
          <option value="">No deal (standalone)</option>
          {(deals.data || []).map((d) => (
            <option key={d.uuid} value={d.uuid}>{d.name}</option>
          ))}
        </Select>
        <Input label="Name (optional)" placeholder="Renovation — 14 Elm Grove" value={f.name} onChange={set('name')} />
        <Input label="Budget (£)" type="number" min={0} value={f.budget} onChange={set('budget')} />
        <div />
        <Input label="Start" type="date" value={f.start_date} onChange={set('start_date')} />
        <Input label="Finish by" type="date" value={f.target_end_date} onChange={set('target_end_date')} />
      </div>
      <fieldset className="mt-4">
        <legend className="mb-1 text-sm font-medium text-secondary-700">Builders and site managers on the board</legend>
        {members.error ? (
          <p className="text-sm text-secondary-500">Couldn&apos;t load the team. Add people later from the project&apos;s Members tab.</p>
        ) : (
          <div className="grid max-h-40 gap-1 overflow-y-auto rounded-lg border border-secondary-200 p-2 sm:grid-cols-2">
            {(members.data || []).map((m) => {
              const uuid = m.user?.uuid;
              if (!uuid) return null;
              const name = `${m.user?.first_name || ''} ${m.user?.last_name || ''}`.trim() || m.user?.email;
              return (
                <label key={uuid} className="flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    checked={builders.includes(uuid)}
                    onChange={(e) => setBuilders((b) => (e.target.checked ? [...b, uuid] : b.filter((x) => x !== uuid)))}
                  />
                  {name}
                </label>
              );
            })}
          </div>
        )}
      </fieldset>
      <div className="mt-5 flex justify-end gap-2">
        <Button variant="ghost" onClick={onClose}>Cancel</Button>
        <Button onClick={submit} isLoading={saving}>Create board</Button>
      </div>
    </Modal>
  );
}

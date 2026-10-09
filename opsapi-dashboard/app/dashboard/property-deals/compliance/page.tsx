'use client';

/**
 * Property Deals — Compliance (SPEC §3.8 #8): every check across deals, its status, evidence,
 * who signed it off and when it expires. Passing or waiving records the named person and time
 * (server-side); waiving needs a note. AI agents can't sign off.
 */
import React, { Suspense, useEffect, useState } from 'react';
import Link from 'next/link';
import { useSearchParams } from 'next/navigation';
import { Shield } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, Card, Input, Modal, Select, Textarea, Table, Badge } from '@/components/ui';
import { pdService, pdErrorText, type ComplianceCheck } from '@/services/property-deals.service';
import { PdPage, ErrorNote, BASE, label, dateText, Spinner } from '@/components/property-deals/ui';
import { usePdData, usePdMe } from '@/components/property-deals/usePd';
import type { TableColumn } from '@/types';

const STATUSES = ['not_started', 'in_progress', 'passed', 'failed', 'waived', 'expired'];
const VARIANT: Record<string, 'default' | 'success' | 'warning' | 'error' | 'info' | 'secondary'> = {
  not_started: 'default', in_progress: 'info', passed: 'success', failed: 'error', waived: 'warning', expired: 'error',
};

export default function CompliancePage() {
  return (
    <PdPage module="compliance">
      <Suspense fallback={<Spinner />}>
        <Compliance />
      </Suspense>
    </PdPage>
  );
}

function Compliance() {
  const { can } = usePdMe();
  const params = useSearchParams();
  const [status, setStatus] = useState('');
  const [expiring, setExpiring] = useState(false);
  const [page, setPage] = useState(1);
  const list = usePdData(
    async () => pdService.compliance({ status: status || undefined, expiring_within_days: expiring ? 30 : undefined, page, per_page: 25, sort: 'expires_at' }),
    [status, expiring, page],
  );
  const [edit, setEdit] = useState<ComplianceCheck | null>(null);

  useEffect(() => {
    const id = params.get('check');
    if (id && list.data?.data) {
      const c = list.data.data.find((x) => x.uuid === id);
      if (c) {
        const t = setTimeout(() => setEdit(c), 0);
        return () => clearTimeout(t);
      }
    }
  }, [params, list.data]);

  const cols: TableColumn<ComplianceCheck>[] = [
    { key: 'check_type', header: 'Check', render: (c) => <span className="font-medium text-secondary-900">{label(c.check_type)}{c.party_role ? ` — ${label(c.party_role)}` : ''}</span> },
    { key: 'status', header: 'Status', render: (c) => <Badge size="sm" variant={VARIANT[c.status] || 'default'}>{label(c.status)}</Badge> },
    { key: 'deal_uuid', header: 'Deal', render: (c) => (c.deal_uuid ? <Link className="text-primary-600 hover:underline" href={`${BASE}/deals/${c.deal_uuid}`} onClick={(e) => e.stopPropagation()}>Open deal</Link> : label(c.subject_type)) },
    { key: 'risk_rating', header: 'Risk', render: (c) => label(c.risk_rating) },
    { key: 'checked_at', header: 'Signed off', render: (c) => (c.checked_at ? dateText(c.checked_at) : '—') },
    { key: 'expires_at', header: 'Expires', render: (c) => <span className={c.expires_at && new Date(c.expires_at) < new Date(Date.now() + 30 * 864e5) ? 'font-medium text-warning-600' : ''}>{dateText(c.expires_at)}</span> },
    { key: 'evidence_document_uuid', header: 'Evidence', render: (c) => (c.evidence_document_uuid ? 'Document' : c.notes ? 'Note' : '—') },
  ];

  return (
    <div className="space-y-6">
      <PageHeader title="Compliance" description="AML, ID, source of funds and the other checks on your deals. A named person signs off every check." icon={<Shield className="h-6 w-6" />} />
      <p className="rounded-lg bg-secondary-50 p-3 text-xs text-secondary-500">
        The checklists are editable templates, not legal advice: your own solicitor or compliance lead should review them.
      </p>
      <Card padding="none" data-tour="compliance-list">
        <div className="flex flex-wrap items-end gap-3 border-b border-secondary-200 p-4">
          <Select label="Status" value={status} onChange={(e) => { setStatus(e.target.value); setPage(1); }}>
            <option value="">All</option>
            {STATUSES.map((s) => <option key={s} value={s}>{label(s)}</option>)}
          </Select>
          <label className="flex h-10 items-center gap-2 text-sm text-secondary-700">
            <input type="checkbox" checked={expiring} onChange={(e) => { setExpiring(e.target.checked); setPage(1); }} /> Expiring in 30 days
          </label>
        </div>
        <ErrorNote error={list.error} />
        <Table columns={cols} data={list.data?.data || []} keyExtractor={(c) => c.uuid} isLoading={list.loading} emptyMessage="No checks match" onRowClick={(c) => can('compliance', 'update') && setEdit(c)} />
        <div className="flex items-center justify-between p-3 text-sm text-secondary-500">
          <span>{list.data?.meta?.total ?? 0} checks</span>
          <div className="flex gap-2">
            <Button size="sm" variant="ghost" disabled={page <= 1} onClick={() => setPage(page - 1)}>Previous</Button>
            <Button size="sm" variant="ghost" disabled={page >= (list.data?.meta?.total_pages ?? 1)} onClick={() => setPage(page + 1)}>Next</Button>
          </div>
        </div>
      </Card>
      {edit && <SignOff check={edit} onClose={() => setEdit(null)} onSaved={() => { setEdit(null); list.refresh(); }} />}
    </div>
  );
}

function SignOff({ check, onClose, onSaved }: { check: ComplianceCheck; onClose: () => void; onSaved: () => void }) {
  const [f, setF] = useState<Record<string, string>>({
    status: check.status, notes: check.notes || '', risk_rating: check.risk_rating || '',
    expires_at: check.expires_at ? check.expires_at.slice(0, 10) : '', evidence_document_uuid: check.evidence_document_uuid || '',
  });
  const [busy, setBusy] = useState(false);
  const notes = ((check.data as { assistant_notes?: string[] } | undefined)?.assistant_notes) || [];
  return (
    <Modal isOpen onClose={onClose} title={`${label(check.check_type)}${check.party_role ? ` — ${label(check.party_role)}` : ''}`} description={check.checked_at ? `Signed off ${dateText(check.checked_at)}` : 'Not signed off yet'} size="lg">
      <div className="grid gap-3 sm:grid-cols-2">
        <Select label="Status" value={f.status} onChange={(e) => setF({ ...f, status: e.target.value })}>
          {STATUSES.map((s) => <option key={s} value={s}>{label(s)}</option>)}
        </Select>
        <Select label="Risk" value={f.risk_rating} onChange={(e) => setF({ ...f, risk_rating: e.target.value })}>
          <option value="">—</option>
          {['low', 'medium', 'high'].map((s) => <option key={s} value={s}>{label(s)}</option>)}
        </Select>
        <Input label="Expires" type="date" value={f.expires_at} onChange={(e) => setF({ ...f, expires_at: e.target.value })} />
        <Input label="Evidence document id (from the deal's Documents)" value={f.evidence_document_uuid} onChange={(e) => setF({ ...f, evidence_document_uuid: e.target.value })} />
      </div>
      <Textarea className="mt-3" label={f.status === 'waived' ? 'Why it is waived (required)' : 'Notes'} rows={3} value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} />
      {notes.length > 0 && (
        <div className="mt-3 rounded-lg bg-info-500/10 p-3 text-sm text-info-700">
          <div className="font-medium">Compliance assistant notes</div>
          <ul className="mt-1 list-disc pl-5">{notes.map((n, i) => <li key={i}>{n}</li>)}</ul>
        </div>
      )}
      <div className="mt-5 flex justify-end gap-2">
        <Button variant="ghost" onClick={onClose}>Cancel</Button>
        <Button isLoading={busy} disabled={f.status === 'waived' && !f.notes} onClick={async () => {
          setBusy(true);
          try {
            await pdService.updateCheck(check.uuid, {
              status: f.status, notes: f.notes || undefined, risk_rating: f.risk_rating || undefined,
              expires_at: f.expires_at ? `${f.expires_at}T23:59:59Z` : undefined, evidence_document_uuid: f.evidence_document_uuid || undefined,
            });
            toast.success(f.status === 'passed' || f.status === 'waived' ? 'Signed off in your name' : 'Saved');
            onSaved();
          } catch (e) {
            toast.error(pdErrorText(e));
          } finally {
            setBusy(false);
          }
        }}>Save</Button>
      </div>
    </Modal>
  );
}

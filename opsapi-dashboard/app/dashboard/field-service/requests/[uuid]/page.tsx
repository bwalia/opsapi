'use client';

/**
 * Service Request detail — /dashboard/field-service/requests/[uuid]
 *
 * The complaint workspace: triage/assign, convert to a job, and see every job
 * (and its visits / hours / billing) spawned from this request.
 */

import React, { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import { useParams, useRouter } from 'next/navigation';
import toast from 'react-hot-toast';
import {
  ArrowLeft, Pencil, Trash2, Building2, Package, MapPin, User, Phone, Mail, UserPlus, Wrench, Briefcase,
} from 'lucide-react';
import { Button, Card, Modal, SearchableSelect, ConfirmDialog } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import {
  fieldService,
  formatFsDate,
  formatFsDateTime,
  type FsConvertResult,
  type FsEngineer,
  type FsServiceRequestDetail,
  type RequestStatus,
} from '@/services/field-service.service';
import {
  SectionCard,
  RequestStatusPill,
  JobPriorityPill,
  JobStatusPill,
  REQUEST_TRANSITION_LABELS,
  CHANNEL_LABELS,
  apiError,
  apiStatus,
  hours,
  money,
} from '@/components/field-service/shared';
import RequestFormModal from '@/components/field-service/RequestFormModal';
import ConvertToJobModal from '@/components/field-service/ConvertToJobModal';

const NEEDS_NOTES: RequestStatus[] = ['resolved', 'rejected', 'duplicate'];

function InfoRow({ icon, label, children }: { icon: React.ReactNode; label: string; children: React.ReactNode }) {
  return (
    <div className="flex items-start gap-2.5">
      <span className="text-secondary-400 mt-0.5 shrink-0">{icon}</span>
      <div className="min-w-0">
        <p className="text-xs text-secondary-500">{label}</p>
        <div className="text-sm text-secondary-800">{children}</div>
      </div>
    </div>
  );
}

function AssignModal({
  isOpen,
  request,
  onClose,
  onAssigned,
}: {
  isOpen: boolean;
  request: FsServiceRequestDetail;
  onClose: () => void;
  onAssigned: (r: FsServiceRequestDetail) => void;
}) {
  const [members, setMembers] = useState<FsEngineer[]>([]);
  const [uuid, setUuid] = useState(request.assigned_manager_uuid || '');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (isOpen) fieldService.getEngineers().then(setMembers).catch(() => setMembers([]));
  }, [isOpen]);

  const submit = async () => {
    if (!uuid) {
      toast.error('Pick a manager');
      return;
    }
    setSaving(true);
    try {
      const r = await fieldService.assignRequest(request.uuid, uuid);
      toast.success('Assigned');
      onAssigned(r);
      onClose();
    } catch (err) {
      toast.error(apiError(err, 'Failed to assign'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Assign manager" size="sm">
      {isOpen && (
        <div className="space-y-4">
          <SearchableSelect
            label="Manager"
            options={members.map((m) => ({ value: m.uuid, label: m.name || m.email, hint: m.email }))}
            value={uuid}
            onChange={setUuid}
            placeholder="Select a manager"
          />
          <div className="flex justify-end gap-2">
            <Button variant="ghost" onClick={onClose}>
              Cancel
            </Button>
            <Button onClick={submit} isLoading={saving}>
              Assign
            </Button>
          </div>
        </div>
      )}
    </Modal>
  );
}

function NotesModal({
  status,
  onClose,
  onSubmit,
}: {
  status: RequestStatus | null;
  onClose: () => void;
  onSubmit: (notes: string) => void;
}) {
  const [notes, setNotes] = useState('');
  useEffect(() => {
    if (status) setNotes('');
  }, [status]);
  const label = status ? REQUEST_TRANSITION_LABELS[status] : '';
  return (
    <Modal isOpen={!!status} onClose={onClose} title={label} size="sm">
      {!!status && (
        <div className="space-y-4">
          <label className="block">
            <span className="text-sm font-medium text-secondary-700">Notes (optional)</span>
            <textarea
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
              rows={3}
              className="mt-1 w-full rounded-lg border border-secondary-300 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
              placeholder="What was done / why?"
            />
          </label>
          <div className="flex justify-end gap-2">
            <Button variant="ghost" onClick={onClose}>
              Cancel
            </Button>
            <Button onClick={() => onSubmit(notes.trim())}>{label}</Button>
          </div>
        </div>
      )}
    </Modal>
  );
}

function RequestDetailContent() {
  const params = useParams();
  const uuid = String(params?.uuid || '');
  const router = useRouter();
  const { canUpdate, canDelete, canCreate } = usePermissions();

  const [req, setReq] = useState<FsServiceRequestDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [notFound, setNotFound] = useState(false);
  const [loadError, setLoadError] = useState(false);
  const [busy, setBusy] = useState(false);
  const [formOpen, setFormOpen] = useState(false);
  const [assignOpen, setAssignOpen] = useState(false);
  const [convertOpen, setConvertOpen] = useState(false);
  const [notesFor, setNotesFor] = useState<RequestStatus | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [deleting, setDeleting] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setNotFound(false);
    setLoadError(false);
    try {
      setReq(await fieldService.getRequest(uuid));
    } catch (err) {
      if (apiStatus(err) === 404) setNotFound(true);
      else {
        setLoadError(true);
        toast.error(apiError(err, 'Failed to load request'));
      }
    } finally {
      setLoading(false);
    }
  }, [uuid]);

  useEffect(() => {
    if (uuid) load();
  }, [uuid, load]);

  const transition = async (status: RequestStatus, notes?: string) => {
    setBusy(true);
    try {
      setReq(await fieldService.setRequestStatus(uuid, status, notes ? { resolution_notes: notes } : {}));
      toast.success('Status updated');
    } catch (err) {
      toast.error(apiError(err, 'Could not update status'));
    } finally {
      setBusy(false);
    }
  };

  const onTransition = (status: RequestStatus) => {
    if (NEEDS_NOTES.includes(status)) setNotesFor(status);
    else transition(status);
  };

  const remove = async () => {
    setDeleting(true);
    try {
      await fieldService.deleteRequest(uuid);
      toast.success('Service request deleted');
      router.push('/dashboard/field-service/requests');
    } catch (err) {
      toast.error(apiError(err, 'Could not delete request'));
      setDeleting(false);
    }
  };

  const onConverted = (result: FsConvertResult) => {
    router.push(`/dashboard/field-service/jobs/${result.job_uuid}`);
  };

  if (loading) {
    return <div className="py-24 text-center text-secondary-500">Loading…</div>;
  }

  if (notFound || (!req && !loadError)) {
    return (
      <div className="py-24 text-center">
        <p className="text-secondary-600">Service request not found.</p>
        <Link href="/dashboard/field-service/requests" className="text-primary-600 hover:underline text-sm mt-2 inline-block">
          Back to requests
        </Link>
      </div>
    );
  }

  if (loadError || !req) {
    return (
      <div className="py-24 text-center space-y-3">
        <p className="text-secondary-600">Couldn&apos;t load this request.</p>
        <Button variant="secondary" onClick={load}>
          Try again
        </Button>
      </div>
    );
  }

  const totals = req.totals || { job_count: 0, open_jobs: 0, visit_count: 0, labour_hours: 0, invoiced_total: 0 };
  const jobs = req.jobs || [];
  const transitions = req.allowed_transitions || [];
  const canManage = canUpdate('fs_service_requests');

  return (
    <div className="space-y-6">
      <div>
        <Link
          href="/dashboard/field-service/requests"
          className="inline-flex items-center gap-1 text-sm text-secondary-500 hover:text-secondary-800"
        >
          <ArrowLeft className="w-4 h-4" /> Service requests
        </Link>
      </div>

      {/* Header */}
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="min-w-0">
          <div className="flex items-center gap-2 flex-wrap">
            <h1 className="text-xl font-bold text-secondary-900">{req.title}</h1>
            <RequestStatusPill status={req.status} />
            <JobPriorityPill priority={req.priority} />
          </div>
          <p className="text-sm font-mono text-secondary-500 mt-1">
            {req.request_number} · Logged {formatFsDate(req.created_at)}
            {req.channel ? ` · via ${CHANNEL_LABELS[req.channel] ?? req.channel}` : ''}
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          {canManage && (
            <Button variant="secondary" onClick={() => setFormOpen(true)}>
              <Pencil className="w-4 h-4 mr-1.5" /> Edit
            </Button>
          )}
          {canDelete('fs_service_requests') && (
            <Button variant="danger" onClick={() => setConfirmDelete(true)}>
              <Trash2 className="w-4 h-4" />
            </Button>
          )}
        </div>
      </div>

      {/* Actions */}
      {canManage && (
        <Card padding="md">
          <div className="flex flex-wrap items-center gap-2">
            {canCreate('fs_jobs') && req.status !== 'closed' && req.status !== 'rejected' && req.status !== 'duplicate' && (
              <Button onClick={() => setConvertOpen(true)} disabled={busy}>
                <Briefcase className="w-4 h-4 mr-1.5" /> Convert to job
              </Button>
            )}
            <Button variant="secondary" onClick={() => setAssignOpen(true)} disabled={busy}>
              <UserPlus className="w-4 h-4 mr-1.5" /> {req.assigned_manager_uuid ? 'Reassign' : 'Assign'}
            </Button>
            <span className="w-px h-6 bg-secondary-200 mx-1" />
            {transitions.length === 0 ? (
              <span className="text-sm text-secondary-400">No further status changes</span>
            ) : (
              transitions.map((s) => (
                <Button key={s} variant="ghost" onClick={() => onTransition(s)} disabled={busy}>
                  {REQUEST_TRANSITION_LABELS[s] ?? s}
                </Button>
              ))
            )}
          </div>
        </Card>
      )}

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Left: details + jobs */}
        <div className="lg:col-span-2 space-y-6">
          <SectionCard title="Details">
            {req.description ? (
              <p className="text-sm text-secondary-700 whitespace-pre-wrap mb-4">{req.description}</p>
            ) : (
              <p className="text-sm text-secondary-400 mb-4">No description.</p>
            )}
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <InfoRow icon={<Building2 className="w-4 h-4" />} label="Customer">
                {req.account_name || '—'}
              </InfoRow>
              <InfoRow icon={<User className="w-4 h-4" />} label="Reported by">
                {req.contact_name || req.reported_by || '—'}
                {req.contact_phone && (
                  <a href={`tel:${req.contact_phone}`} className="ml-2 text-primary-600 hover:underline">
                    <Phone className="w-3 h-3 inline" /> {req.contact_phone}
                  </a>
                )}
                {req.contact_email && (
                  <a href={`mailto:${req.contact_email}`} className="ml-2 text-primary-600 hover:underline">
                    <Mail className="w-3 h-3 inline" />
                  </a>
                )}
              </InfoRow>
              <InfoRow icon={<MapPin className="w-4 h-4" />} label="Site">
                {req.site_name || '—'}
              </InfoRow>
              <InfoRow icon={<Package className="w-4 h-4" />} label="Faulty asset">
                {req.asset_name ? (
                  <>
                    {req.asset_name}
                    {req.asset_serial && <span className="text-secondary-500"> · {req.asset_serial}</span>}
                  </>
                ) : (
                  '—'
                )}
              </InfoRow>
              <InfoRow icon={<Wrench className="w-4 h-4" />} label="Fault category">
                {req.fault_category || '—'}
              </InfoRow>
              <InfoRow icon={<User className="w-4 h-4" />} label="Assigned manager">
                {req.assigned_manager_name || <span className="text-secondary-400">Unassigned</span>}
              </InfoRow>
              {req.sla_response_due_at && (
                <InfoRow icon={<Phone className="w-4 h-4" />} label="Respond by">
                  {formatFsDateTime(req.sla_response_due_at)}
                </InfoRow>
              )}
              {req.sla_resolve_due_at && (
                <InfoRow icon={<Wrench className="w-4 h-4" />} label="Resolve by">
                  {formatFsDateTime(req.sla_resolve_due_at)}
                </InfoRow>
              )}
            </div>
            {req.resolution_notes && (
              <div className="mt-4 rounded-lg bg-secondary-50 border border-secondary-200 p-3">
                <p className="text-xs text-secondary-500 mb-1">Resolution</p>
                <p className="text-sm text-secondary-700 whitespace-pre-wrap">{req.resolution_notes}</p>
              </div>
            )}
          </SectionCard>

          <SectionCard title={`Jobs (${jobs.length})`}>
            {jobs.length === 0 ? (
              <p className="text-sm text-secondary-400">
                No jobs yet. Use <span className="font-medium">Convert to job</span> to dispatch an engineer.
              </p>
            ) : (
              <ul className="divide-y divide-secondary-100 -my-2">
                {jobs.map((j) => (
                  <li key={j.uuid} className="py-3 flex items-center justify-between gap-3">
                    <div className="min-w-0">
                      <Link
                        href={`/dashboard/field-service/jobs/${j.uuid}`}
                        className="font-medium text-primary-600 hover:underline"
                      >
                        {j.job_number}
                      </Link>
                      <p className="text-sm text-secondary-700 truncate">{j.title}</p>
                    </div>
                    <div className="flex items-center gap-3 shrink-0">
                      <span className="text-xs text-secondary-500">{j.visit_count} visit(s)</span>
                      {j.invoice_number && <span className="text-xs text-secondary-500">{j.invoice_number}</span>}
                      <JobStatusPill status={j.status} />
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </SectionCard>
        </div>

        {/* Right: rollup */}
        <div className="space-y-6">
          <SectionCard title="Summary">
            <dl className="space-y-3 text-sm">
              <div className="flex justify-between">
                <dt className="text-secondary-500">Jobs</dt>
                <dd className="font-medium text-secondary-900">{totals.job_count}</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-secondary-500">Open jobs</dt>
                <dd className="font-medium text-secondary-900">{totals.open_jobs}</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-secondary-500">Visits</dt>
                <dd className="font-medium text-secondary-900">{totals.visit_count}</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-secondary-500">Labour logged</dt>
                <dd className="font-medium text-secondary-900">{hours(totals.labour_hours)}</dd>
              </div>
              <div className="flex justify-between border-t border-secondary-200 pt-3">
                <dt className="text-secondary-500">Invoiced</dt>
                <dd className="font-semibold text-secondary-900">{money(totals.invoiced_total)}</dd>
              </div>
            </dl>
          </SectionCard>
          <SectionCard title="Timeline">
            <dl className="space-y-2 text-sm">
              <div className="flex justify-between">
                <dt className="text-secondary-500">First response</dt>
                <dd className="text-secondary-800">{req.first_response_at ? formatFsDateTime(req.first_response_at) : '—'}</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-secondary-500">Resolved</dt>
                <dd className="text-secondary-800">{req.resolved_at ? formatFsDateTime(req.resolved_at) : '—'}</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-secondary-500">Closed</dt>
                <dd className="text-secondary-800">{req.closed_at ? formatFsDateTime(req.closed_at) : '—'}</dd>
              </div>
            </dl>
          </SectionCard>
        </div>
      </div>

      <RequestFormModal isOpen={formOpen} request={req} onClose={() => setFormOpen(false)} onSaved={() => load()} />
      <AssignModal isOpen={assignOpen} request={req} onClose={() => setAssignOpen(false)} onAssigned={setReq} />
      <ConvertToJobModal isOpen={convertOpen} request={req} onClose={() => setConvertOpen(false)} onConverted={onConverted} />
      <NotesModal
        status={notesFor}
        onClose={() => setNotesFor(null)}
        onSubmit={(notes) => {
          const s = notesFor;
          setNotesFor(null);
          if (s) transition(s, notes || undefined);
        }}
      />
      <ConfirmDialog
        isOpen={confirmDelete}
        onClose={() => setConfirmDelete(false)}
        onConfirm={remove}
        title="Delete service request"
        message={`Delete "${req.request_number}"? Jobs already created keep their history.`}
        confirmText="Delete"
        variant="danger"
        isLoading={deleting}
      />
    </div>
  );
}

export default function FieldServiceRequestDetailPage() {
  return (
    <ProtectedPage module="fs_service_requests" title="Service Request">
      <RequestDetailContent />
    </ProtectedPage>
  );
}

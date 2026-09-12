'use client';

/**
 * Service Job — /dashboard/field-service/jobs/[uuid]
 *
 * One job end to end: details + status workflow, its phases (checklists,
 * sign-off), engineer site visits, parts & materials, billing (invoice via
 * the invoicing module) and the activity trail.
 */

import React, { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import { useParams, useRouter } from 'next/navigation';
import toast from 'react-hot-toast';
import { ArrowLeft, Building2, Loader2, MapPin, Pencil, Phone, Trash2, User, Wrench, Mail, CalendarDays, Hash } from 'lucide-react';
import { Button, ConfirmDialog } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import { fieldService, formatFsDate, type FsJobDetail, type JobStatus } from '@/services/field-service.service';
import {
  FieldServiceNav,
  JobPriorityPill,
  JobStatusPill,
  JOB_TRANSITION_LABELS,
  PromptDialog,
  apiError,
  apiStatus,
  mapsUrl,
  siteAddressFromJob,
} from '@/components/field-service/shared';
import JobFormModal from '@/components/field-service/JobFormModal';
import PhasesPanel from '@/components/field-service/PhasesPanel';
import VisitsPanel from '@/components/field-service/VisitsPanel';
import ItemsPanel from '@/components/field-service/ItemsPanel';
import BillingPanel from '@/components/field-service/BillingPanel';
import ActivityFeed from '@/components/field-service/ActivityFeed';

// Order the workflow buttons left→right the way a job usually progresses.
const TRANSITION_ORDER: JobStatus[] = ['scheduled', 'in_progress', 'completed', 'on_hold', 'draft', 'cancelled'];

function JobDetailContent() {
  const params = useParams<{ uuid: string }>();
  const uuid = params?.uuid as string;
  const router = useRouter();
  const { canUpdate, canDelete, canCreate } = usePermissions();

  const [job, setJob] = useState<FsJobDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [notFound, setNotFound] = useState(false);
  const [editOpen, setEditOpen] = useState(false);
  const [cancelOpen, setCancelOpen] = useState(false);
  const [forceMessage, setForceMessage] = useState<string | null>(null);
  const [deleteOpen, setDeleteOpen] = useState(false);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      setJob(await fieldService.getJob(uuid));
      setNotFound(false);
    } catch (err) {
      if (apiStatus(err) === 404) setNotFound(true);
      else toast.error(apiError(err, 'Failed to load job'));
    } finally {
      setLoading(false);
    }
  }, [uuid]);

  useEffect(() => {
    load();
  }, [load]);

  const setStatus = async (status: JobStatus, opts: { reason?: string; force?: boolean } = {}) => {
    if (!job) return;
    setBusy(true);
    try {
      setJob(await fieldService.setJobStatus(job.uuid, status, opts));
      toast.success(`Job ${JOB_TRANSITION_LABELS[status].toLowerCase()}`);
    } catch (err) {
      const msg = apiError(err, 'Could not change status');
      if (status === 'completed' && apiStatus(err) === 422 && /force/i.test(msg)) setForceMessage(msg);
      else toast.error(msg);
    } finally {
      setBusy(false);
    }
  };

  const handleTransition = (status: JobStatus) => {
    if (status === 'cancelled') setCancelOpen(true);
    else setStatus(status);
  };

  const deleteJob = async () => {
    if (!job) return;
    setBusy(true);
    try {
      await fieldService.deleteJob(job.uuid);
      toast.success('Job deleted');
      router.push('/dashboard/field-service');
    } catch (err) {
      toast.error(apiError(err, 'Could not delete job'));
      setBusy(false);
    }
  };

  if (loading) {
    return (
      <div className="flex items-center justify-center py-24 text-secondary-500">
        <Loader2 className="w-6 h-6 animate-spin mr-2" /> Loading job…
      </div>
    );
  }

  if (notFound || !job) {
    return (
      <div className="space-y-4">
        <FieldServiceNav />
        <div className="text-center py-16">
          <p className="text-lg font-medium text-secondary-900">Job not found</p>
          <Link href="/dashboard/field-service" className="text-primary-600 hover:underline text-sm">
            Back to jobs
          </Link>
        </div>
      </div>
    );
  }

  const canManage = canUpdate('fs_jobs');
  const editable = job.status !== 'completed' && job.status !== 'cancelled';
  const address = siteAddressFromJob(job);
  const maps = mapsUrl(address, job.site_latitude, job.site_longitude);
  const transitions = TRANSITION_ORDER.filter((s) => job.allowed_transitions.includes(s));

  return (
    <div className="space-y-6">
      <FieldServiceNav />

      <div>
        <Link href="/dashboard/field-service" className="inline-flex items-center gap-1 text-sm text-secondary-500 hover:text-secondary-800">
          <ArrowLeft className="w-4 h-4" /> All jobs
        </Link>
      </div>

      {/* Header */}
      <section className="bg-surface rounded-xl border border-secondary-200 shadow-sm p-5 space-y-4">
        <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div className="flex items-start gap-3.5 min-w-0">
            <span
              className="mt-0.5 flex h-11 w-11 shrink-0 items-center justify-center rounded-xl bg-primary-500/10 text-primary-500"
              style={job.job_type_color ? { backgroundColor: `${job.job_type_color}1a`, color: job.job_type_color } : undefined}
            >
              <Wrench className="w-5 h-5" />
            </span>
            <div className="min-w-0">
              <p className="text-sm text-secondary-500">
                {job.job_number}
                {job.job_type_name ? ` · ${job.job_type_name}` : ''}
              </p>
              <h1 className="text-2xl font-bold tracking-tight text-secondary-900">{job.title}</h1>
              <div className="mt-2 flex flex-wrap items-center gap-2">
                <JobStatusPill status={job.status} />
                <JobPriorityPill priority={job.priority} />
                {job.invoice_number && <span className="text-xs text-secondary-500">Invoiced · {job.invoice_number}</span>}
              </div>
            </div>
          </div>
          {canManage && (
            <div className="flex flex-wrap items-center gap-2">
              {transitions.map((s) => (
                <Button
                  key={s}
                  size="sm"
                  variant={s === 'completed' || (s === 'in_progress' && job.status !== 'completed') ? 'primary' : s === 'cancelled' ? 'danger' : 'ghost'}
                  onClick={() => handleTransition(s)}
                  disabled={busy}
                >
                  {JOB_TRANSITION_LABELS[s]}
                </Button>
              ))}
              <Button size="sm" variant="ghost" onClick={() => setEditOpen(true)} title="Edit details">
                <Pencil className="w-4 h-4" />
              </Button>
              {canDelete('fs_jobs') && !job.invoice_uuid && (
                <Button size="sm" variant="ghost" onClick={() => setDeleteOpen(true)} title="Delete job">
                  <Trash2 className="w-4 h-4 text-error-500" />
                </Button>
              )}
            </div>
          )}
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4 text-sm">
          <div>
            <p className="text-xs font-medium uppercase tracking-wide text-secondary-500 mb-1">Customer</p>
            <p className="flex items-center gap-1.5 text-secondary-900">
              <Building2 className="w-4 h-4 text-secondary-400" /> {job.account_name || '—'}
            </p>
            {job.contact_name && (
              <p className="flex items-center gap-1.5 text-secondary-600 mt-1">
                <User className="w-4 h-4 text-secondary-400" /> {job.contact_name}
              </p>
            )}
            {(job.contact_phone || job.account_phone) && (
              <a href={`tel:${job.contact_phone || job.account_phone}`} className="flex items-center gap-1.5 text-primary-600 mt-1 hover:underline">
                <Phone className="w-4 h-4" /> {job.contact_phone || job.account_phone}
              </a>
            )}
            {(job.contact_email || job.account_email) && (
              <a href={`mailto:${job.contact_email || job.account_email}`} className="flex items-center gap-1.5 text-primary-600 mt-1 hover:underline break-all">
                <Mail className="w-4 h-4 shrink-0" /> {job.contact_email || job.account_email}
              </a>
            )}
          </div>
          <div>
            <p className="text-xs font-medium uppercase tracking-wide text-secondary-500 mb-1">Site</p>
            {job.site_name || address ? (
              <>
                <p className="text-secondary-900">{job.site_name}</p>
                {address &&
                  (maps ? (
                    <a href={maps} target="_blank" rel="noopener noreferrer" className="flex items-start gap-1.5 text-primary-600 hover:underline mt-1">
                      <MapPin className="w-4 h-4 mt-0.5 shrink-0" /> {address}
                    </a>
                  ) : (
                    <p className="text-secondary-600">{address}</p>
                  ))}
                {job.site_access_notes && <p className="text-xs text-secondary-500 mt-1">Access: {job.site_access_notes}</p>}
              </>
            ) : (
              <p className="text-secondary-400">No site</p>
            )}
          </div>
          <div>
            <p className="text-xs font-medium uppercase tracking-wide text-secondary-500 mb-1">Service manager</p>
            <p className="text-secondary-900">{job.service_manager_name || '—'}</p>
            {job.customer_reference && (
              <p className="flex items-center gap-1.5 text-secondary-600 mt-1">
                <Hash className="w-4 h-4 text-secondary-400" /> Ref {job.customer_reference}
              </p>
            )}
          </div>
          <div>
            <p className="text-xs font-medium uppercase tracking-wide text-secondary-500 mb-1">Schedule</p>
            <p className="flex items-center gap-1.5 text-secondary-900">
              <CalendarDays className="w-4 h-4 text-secondary-400" /> Due {job.due_date ? formatFsDate(String(job.due_date).slice(0, 10)) : '—'}
            </p>
            {job.estimated_hours != null && <p className="text-secondary-600 mt-1">Estimate {job.estimated_hours} h</p>}
            {job.hourly_rate != null && <p className="text-secondary-600 mt-1">Rate {job.hourly_rate}/h</p>}
          </div>
        </div>

        {job.description && <p className="text-sm text-secondary-700 whitespace-pre-line border-t border-secondary-100 pt-4">{job.description}</p>}
        {job.notes && <p className="text-xs text-secondary-500 whitespace-pre-line">Notes: {job.notes}</p>}
        {job.status === 'cancelled' && job.cancelled_reason && <p className="text-sm text-red-600">Cancelled: {job.cancelled_reason}</p>}
      </section>

      <div className="grid grid-cols-1 xl:grid-cols-3 gap-6">
        <div className="xl:col-span-2 space-y-6">
          <PhasesPanel jobUuid={job.uuid} phases={job.phases} editable={editable} canManage={canManage} onChanged={load} />
          <VisitsPanel
            jobUuid={job.uuid}
            visits={job.visits}
            phases={job.phases}
            editable={editable}
            canManage={canManage || canCreate('fs_visits')}
            onChanged={load}
          />
          <ItemsPanel
            jobUuid={job.uuid}
            items={job.items}
            phases={job.phases}
            currency={job.currency}
            canEdit={canManage && job.status !== 'cancelled'}
            onChanged={load}
          />
        </div>
        <div className="space-y-6">
          <BillingPanel job={job} canInvoice={canManage && canCreate('invoices')} onChanged={load} />
          <ActivityFeed activity={job.activity} />
        </div>
      </div>

      <JobFormModal isOpen={editOpen} job={job} onClose={() => setEditOpen(false)} onSaved={(j) => setJob(j)} />
      <PromptDialog
        isOpen={cancelOpen}
        title="Cancel job"
        message="Booked visits that haven't started will be cancelled too."
        label="Reason"
        multiline
        confirmText="Cancel job"
        variant="danger"
        onClose={() => setCancelOpen(false)}
        onSubmit={async (reason) => {
          setCancelOpen(false);
          await setStatus('cancelled', { reason: reason || undefined });
        }}
      />
      <ConfirmDialog
        isOpen={!!forceMessage}
        onClose={() => setForceMessage(null)}
        onConfirm={() => {
          setForceMessage(null);
          setStatus('completed', { force: true });
        }}
        title="Complete anyway?"
        message={forceMessage || ''}
        confirmText="Complete anyway"
        variant="warning"
      />
      <ConfirmDialog
        isOpen={deleteOpen}
        onClose={() => setDeleteOpen(false)}
        onConfirm={deleteJob}
        title="Delete job"
        message={`Delete ${job.job_number}? Its visits are removed too. Cancel the job instead if you need to keep a record.`}
        confirmText="Delete"
        variant="danger"
        isLoading={busy}
      />
    </div>
  );
}

export default function FieldServiceJobPage() {
  return (
    <ProtectedPage module="fs_jobs" title="Service Job">
      <JobDetailContent />
    </ProtectedPage>
  );
}

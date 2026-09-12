'use client';

/**
 * Site Visit — /dashboard/field-service/visits/[uuid]
 *
 * The engineer's on-site view (built to work on a phone): where to go, who to
 * ask for, what to do, then En route → Check in → work the phase checklist →
 * log parts → Check out with the work report.
 */

import React, { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import toast from 'react-hot-toast';
import { useParams } from 'next/navigation';
import {
  ArrowLeft,
  Car,
  CheckCircle2,
  ClipboardList,
  DoorClosed,
  KeyRound,
  Loader2,
  LogIn,
  LogOut,
  MapPin,
  Phone,
  Plus,
  User,
  Clock,
  FileClock,
  XCircle,
} from 'lucide-react';
import { Button } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import { useAuthStore } from '@/store/auth.store';
import { fieldService, formatFsDateTime, formatFsTime, type FsVisitDetail } from '@/services/field-service.service';
import {
  FieldServiceNav,
  JobPriorityPill,
  PhaseStatusPill,
  PromptDialog,
  SectionCard,
  VisitStatusPill,
  apiError,
  apiStatus,
  hours,
  mapsUrl,
  siteAddressFromJob,
} from '@/components/field-service/shared';
import { PhaseChecklist, usePhaseStatus } from '@/components/field-service/PhasesPanel';
import { ItemFormModal, ItemsTable, useItemActions } from '@/components/field-service/ItemsPanel';
import CheckOutModal, { getPosition } from '@/components/field-service/CheckOutModal';
import type { FsJobItem } from '@/services/field-service.service';

function VisitDetailContent() {
  const params = useParams<{ uuid: string }>();
  const uuid = params?.uuid as string;
  const { canUpdate, canRead } = usePermissions();
  const currentUser = useAuthStore((s) => s.user);

  const [visit, setVisit] = useState<FsVisitDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [notFound, setNotFound] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [checkOutOpen, setCheckOutOpen] = useState(false);
  const [noAccessOpen, setNoAccessOpen] = useState(false);
  const [cancelOpen, setCancelOpen] = useState(false);
  const [itemOpen, setItemOpen] = useState(false);
  const [editingItem, setEditingItem] = useState<FsJobItem | null>(null);

  const load = useCallback(async () => {
    try {
      setVisit(await fieldService.getVisit(uuid));
      setNotFound(false);
    } catch (err) {
      if (apiStatus(err) === 404) setNotFound(true);
      else toast.error(apiError(err, 'Failed to load visit'));
    } finally {
      setLoading(false);
    }
  }, [uuid]);

  useEffect(() => {
    load();
  }, [load]);

  const { change: changePhase, dialogs: phaseDialogs } = usePhaseStatus(() => load());
  const { requestDelete, confirm: itemConfirm } = useItemActions(load);

  const act = async (key: string, fn: () => Promise<FsVisitDetail>, success: string) => {
    setBusy(key);
    try {
      setVisit(await fn());
      toast.success(success);
    } catch (err) {
      toast.error(apiError(err, 'Action failed'));
    } finally {
      setBusy(null);
    }
  };

  if (loading) {
    return (
      <div className="flex items-center justify-center py-24 text-secondary-500">
        <Loader2 className="w-6 h-6 animate-spin mr-2" /> Loading visit…
      </div>
    );
  }

  if (notFound || !visit) {
    return (
      <div className="space-y-4">
        <FieldServiceNav />
        <div className="text-center py-16">
          <p className="text-lg font-medium text-secondary-900">Visit not found</p>
          <Link href="/dashboard/field-service/visits" className="text-primary-600 hover:underline text-sm">
            Back to visits
          </Link>
        </div>
      </div>
    );
  }

  const isAssigned = !!currentUser?.uuid && visit.engineer_user_uuid === currentUser.uuid;
  const canWork = isAssigned || canUpdate('fs_visits');
  const jobOpen = visit.job_status !== 'completed' && visit.job_status !== 'cancelled';
  const address = siteAddressFromJob(visit);
  const maps = mapsUrl(address, visit.site_latitude, visit.site_longitude);
  const s = visit.status;

  return (
    <div className="space-y-5 max-w-4xl">
      <FieldServiceNav />
      <Link href="/dashboard/field-service/visits" className="inline-flex items-center gap-1 text-sm text-secondary-500 hover:text-secondary-800">
        <ArrowLeft className="w-4 h-4" /> Site visits
      </Link>

      {/* Header */}
      <section className="bg-surface rounded-xl border border-secondary-200 shadow-sm p-5 space-y-3">
        <div className="flex flex-wrap items-center gap-2">
          <VisitStatusPill status={s} />
          {(visit.job_priority === 'high' || visit.job_priority === 'urgent') && <JobPriorityPill priority={visit.job_priority} />}
          {visit.follow_up_required && <span className="text-xs font-medium text-amber-600">Follow-up required</span>}
        </div>
        <div>
          <p className="text-2xl font-bold text-secondary-900">
            {formatFsDateTime(visit.scheduled_start, { weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}
            {visit.scheduled_end ? ` – ${formatFsTime(visit.scheduled_end)}` : ''}
          </p>
          <p className="text-secondary-700 mt-0.5">
            {canRead('fs_jobs') ? (
              <Link href={`/dashboard/field-service/jobs/${visit.job_uuid}`} className="text-primary-600 hover:underline">
                {visit.job_number} · {visit.job_title}
              </Link>
            ) : (
              <>
                {visit.job_number} · {visit.job_title}
              </>
            )}
          </p>
          <p className="text-sm text-secondary-500 flex items-center gap-1.5 mt-1">
            <User className="w-4 h-4" /> {visit.engineer_name || 'Unassigned'}
            {visit.phase_name && <span>· Phase: {visit.phase_name}</span>}
          </p>
        </div>

        {/* Workflow actions */}
        {canWork && (
          <div className="flex flex-wrap gap-2 pt-1">
            {s === 'scheduled' && (
              <Button
                variant="ghost"
                isLoading={busy === 'enroute'}
                onClick={() => act('enroute', () => fieldService.markEnRoute(visit.uuid), 'Marked en route')}
              >
                <Car className="w-4 h-4 mr-1.5" /> En route
              </Button>
            )}
            {(s === 'scheduled' || s === 'en_route') && (
              <Button
                isLoading={busy === 'checkin'}
                onClick={() =>
                  act(
                    'checkin',
                    async () => fieldService.checkIn(visit.uuid, await getPosition()),
                    'Checked in on site'
                  )
                }
              >
                <LogIn className="w-4 h-4 mr-1.5" /> Check in
              </Button>
            )}
            {(s === 'scheduled' || s === 'en_route' || s === 'on_site') && (
              <>
                <Button onClick={() => setCheckOutOpen(true)} variant={s === 'on_site' ? 'primary' : 'ghost'}>
                  <LogOut className="w-4 h-4 mr-1.5" /> Check out
                </Button>
                <Button variant="ghost" onClick={() => setNoAccessOpen(true)}>
                  <DoorClosed className="w-4 h-4 mr-1.5" /> No access
                </Button>
              </>
            )}
            {(s === 'scheduled' || s === 'en_route') && canUpdate('fs_visits') && (
              <Button variant="ghost" onClick={() => setCancelOpen(true)}>
                <XCircle className="w-4 h-4 mr-1.5 text-error-500" /> Cancel visit
              </Button>
            )}
            {s === 'completed' && !visit.timesheet_uuid && Number(visit.labour_hours) > 0 && visit.engineer_user_uuid && (
              <Button
                variant="ghost"
                isLoading={busy === 'timesheet'}
                onClick={async () => {
                  setBusy('timesheet');
                  try {
                    const r = await fieldService.logTimesheet(visit.uuid);
                    toast.success(`${hours(r.hours)} logged to timesheet`);
                    load();
                  } catch (err) {
                    toast.error(apiError(err, 'Could not log timesheet'));
                  } finally {
                    setBusy(null);
                  }
                }}
              >
                <FileClock className="w-4 h-4 mr-1.5" /> Log to timesheet
              </Button>
            )}
          </div>
        )}
      </section>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-5">
        <SectionCard title="Site">
          <div className="space-y-2 text-sm">
            <p className="font-medium text-secondary-900">{visit.account_name || 'No customer'}</p>
            {visit.site_name && <p className="text-secondary-700">{visit.site_name}</p>}
            {address ? (
              maps ? (
                <a href={maps} target="_blank" rel="noopener noreferrer" className="flex items-start gap-1.5 text-primary-600 hover:underline">
                  <MapPin className="w-4 h-4 mt-0.5 shrink-0" /> {address}
                </a>
              ) : (
                <p>{address}</p>
              )
            ) : (
              <p className="text-secondary-400">No site address</p>
            )}
            {(visit.site_contact_name || visit.site_contact_phone) && (
              <p className="flex items-center gap-1.5 text-secondary-700">
                <User className="w-4 h-4 text-secondary-400" /> {visit.site_contact_name}
                {visit.site_contact_phone && (
                  <a href={`tel:${visit.site_contact_phone}`} className="ml-1 inline-flex items-center gap-1 text-primary-600 hover:underline">
                    <Phone className="w-3.5 h-3.5" /> {visit.site_contact_phone}
                  </a>
                )}
              </p>
            )}
            {visit.site_access_notes && (
              <p className="flex items-start gap-1.5 rounded-lg bg-amber-50 text-amber-800 p-2.5">
                <KeyRound className="w-4 h-4 mt-0.5 shrink-0" /> {visit.site_access_notes}
              </p>
            )}
          </div>
        </SectionCard>

        <SectionCard title="Instructions & report">
          <div className="space-y-3 text-sm">
            <div>
              <p className="text-xs font-medium uppercase tracking-wide text-secondary-500 mb-1">Instructions</p>
              <p className="text-secondary-800 whitespace-pre-line">{visit.instructions || '—'}</p>
            </div>
            {(visit.checked_in_at || visit.checked_out_at) && (
              <p className="flex items-center gap-1.5 text-secondary-600">
                <Clock className="w-4 h-4 text-secondary-400" />
                {visit.checked_in_at ? `In ${formatFsTime(visit.checked_in_at)}` : 'Not checked in'}
                {visit.checked_out_at ? ` · Out ${formatFsTime(visit.checked_out_at)}` : ''}
                {visit.labour_hours != null && ` · ${hours(visit.labour_hours)}`}
              </p>
            )}
            {visit.work_summary && (
              <div>
                <p className="text-xs font-medium uppercase tracking-wide text-secondary-500 mb-1">Work carried out</p>
                <p className="text-secondary-800 whitespace-pre-line">{visit.work_summary}</p>
              </div>
            )}
            {visit.customer_signoff_name && (
              <p className="flex items-center gap-1.5 text-green-700">
                <CheckCircle2 className="w-4 h-4" /> Signed off by {visit.customer_signoff_name}
                {visit.customer_signed_at && ` · ${formatFsDateTime(visit.customer_signed_at)}`}
              </p>
            )}
            {visit.follow_up_notes && (
              <p className="rounded-lg bg-amber-50 text-amber-800 p-2.5">
                {s === 'no_access' ? 'No access: ' : 'Follow-up: '}
                {visit.follow_up_notes}
              </p>
            )}
            {visit.cancelled_reason && <p className="text-red-600">Cancelled: {visit.cancelled_reason}</p>}
            {visit.timesheet_uuid && <p className="text-xs text-secondary-500">Logged to timesheet.</p>}
          </div>
        </SectionCard>
      </div>

      {visit.phase && (
        <SectionCard
          title={`Phase: ${visit.phase.name}`}
          actions={
            <>
              <PhaseStatusPill status={visit.phase.status} />
              {canWork && jobOpen && visit.phase.status !== 'completed' && visit.phase.status !== 'skipped' && (
                <Button size="sm" variant="ghost" onClick={() => visit.phase && changePhase(visit.phase, 'completed')}>
                  <CheckCircle2 className="w-4 h-4 mr-1" /> Complete phase
                </Button>
              )}
            </>
          }
        >
          {visit.phase.description && <p className="text-sm text-secondary-600">{visit.phase.description}</p>}
          {visit.phase.checklist.length === 0 ? (
            <p className="text-sm text-secondary-500 flex items-center gap-1.5 mt-1">
              <ClipboardList className="w-4 h-4" /> No checklist for this phase.
            </p>
          ) : (
            <PhaseChecklist phase={visit.phase} disabled={!canWork || !jobOpen} onChanged={() => load()} />
          )}
        </SectionCard>
      )}

      <SectionCard
        title="Parts used on this visit"
        actions={
          canWork &&
          visit.job_status !== 'cancelled' && (
            <Button
              size="sm"
              variant="ghost"
              onClick={() => {
                setEditingItem(null);
                setItemOpen(true);
              }}
            >
              <Plus className="w-4 h-4 mr-1" /> Log part
            </Button>
          )
        }
      >
        <ItemsTable
          items={visit.items}
          currency={visit.job_currency || 'GBP'}
          canEdit={(it) => canUpdate('fs_jobs') || (canWork && it.created_by_uuid === currentUser?.uuid)}
          onEdit={(it) => {
            setEditingItem(it);
            setItemOpen(true);
          }}
          onDelete={requestDelete}
        />
      </SectionCard>

      <CheckOutModal isOpen={checkOutOpen} visit={visit} onClose={() => setCheckOutOpen(false)} onDone={(v) => setVisit(v)} />
      <PromptDialog
        isOpen={noAccessOpen}
        title="No access"
        message="The visit is closed and flagged for a follow-up."
        label="What happened?"
        multiline
        required
        confirmText="Mark no access"
        variant="danger"
        onClose={() => setNoAccessOpen(false)}
        onSubmit={async (reason) => {
          setNoAccessOpen(false);
          await act('noaccess', () => fieldService.markNoAccess(visit.uuid, reason), 'Marked as no access');
        }}
      />
      <PromptDialog
        isOpen={cancelOpen}
        title="Cancel visit"
        label="Reason (optional)"
        confirmText="Cancel visit"
        variant="danger"
        onClose={() => setCancelOpen(false)}
        onSubmit={async (reason) => {
          setCancelOpen(false);
          await act('cancel', () => fieldService.cancelVisit(visit.uuid, reason || undefined), 'Visit cancelled');
        }}
      />
      <ItemFormModal
        isOpen={itemOpen}
        jobUuid={visit.job_uuid}
        item={editingItem}
        visitUuid={visit.uuid}
        onClose={() => setItemOpen(false)}
        onSaved={load}
      />
      {itemConfirm}
      {phaseDialogs}
    </div>
  );
}

export default function FieldServiceVisitPage() {
  return (
    <ProtectedPage module="fs_visits" title="Site Visit">
      <VisitDetailContent />
    </ProtectedPage>
  );
}

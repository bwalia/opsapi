'use client';

import React, { useState } from 'react';
import Link from 'next/link';
import toast from 'react-hot-toast';
import { CalendarPlus, CalendarClock, ExternalLink, Pencil, Trash2, XCircle, AlertTriangle } from 'lucide-react';
import { Button, ConfirmDialog } from '@/components/ui';
import { fieldService, formatFsDateTime, formatFsTime, type FsPhase, type FsVisit } from '@/services/field-service.service';
import { PromptDialog, SectionCard, VisitStatusPill, apiError, hours } from './shared';
import VisitFormModal from './VisitFormModal';

interface VisitsPanelProps {
  jobUuid: string;
  visits: FsVisit[];
  phases: FsPhase[];
  editable: boolean;
  canManage: boolean;
  onChanged: () => void;
}

export function VisitsPanel({ jobUuid, visits, phases, editable, canManage, onChanged }: VisitsPanelProps) {
  const [formOpen, setFormOpen] = useState(false);
  const [editing, setEditing] = useState<FsVisit | null>(null);
  const [cancelTarget, setCancelTarget] = useState<FsVisit | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<FsVisit | null>(null);
  const [busy, setBusy] = useState(false);

  const remove = async () => {
    if (!deleteTarget) return;
    setBusy(true);
    try {
      await fieldService.deleteVisit(deleteTarget.uuid);
      toast.success('Visit deleted');
      setDeleteTarget(null);
      onChanged();
    } catch (err) {
      toast.error(apiError(err, 'Could not delete visit'));
    } finally {
      setBusy(false);
    }
  };

  return (
    <SectionCard
      title={`Site visits (${visits.length})`}
      actions={
        editable &&
        canManage && (
          <Button
            size="sm"
            variant="ghost"
            onClick={() => {
              setEditing(null);
              setFormOpen(true);
            }}
          >
            <CalendarPlus className="w-4 h-4 mr-1" /> Book visit
          </Button>
        )
      }
    >
      {visits.length === 0 ? (
        <p className="text-sm text-secondary-500">No visits booked yet.</p>
      ) : (
        <ul className="divide-y divide-secondary-100">
          {visits.map((v) => {
            const preStart = v.status === 'scheduled' || v.status === 'en_route';
            return (
              <li key={v.uuid} className="py-3 flex flex-wrap items-start justify-between gap-3">
                <div className="flex items-start gap-3 min-w-0">
                  <div className="w-10 h-10 rounded-lg bg-blue-50 text-blue-600 flex items-center justify-center shrink-0">
                    <CalendarClock className="w-5 h-5" />
                  </div>
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <Link href={`/dashboard/field-service/visits/${v.uuid}`} className="font-medium text-secondary-900 hover:text-primary-600">
                        {formatFsDateTime(v.scheduled_start, { weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}
                        {v.scheduled_end ? ` – ${formatFsTime(v.scheduled_end)}` : ''}
                      </Link>
                      <VisitStatusPill status={v.status} />
                      {v.follow_up_required && (
                        <span className="inline-flex items-center gap-1 text-xs text-amber-600">
                          <AlertTriangle className="w-3 h-3" /> follow-up
                        </span>
                      )}
                    </div>
                    <p className="text-sm text-secondary-600">
                      {v.engineer_name || <span className="text-amber-600">Unassigned</span>}
                      {v.phase_name ? ` · ${v.phase_name}` : ''}
                    </p>
                    <p className="text-xs text-secondary-500">
                      {v.status === 'completed' && `${hours(v.labour_hours)} on site${v.is_billable ? '' : ' (non-billable)'}`}
                      {v.status === 'completed' && v.timesheet_uuid && ' · on timesheet'}
                      {v.invoiced && ' · invoiced'}
                      {v.status === 'cancelled' && v.cancelled_reason && `Cancelled: ${v.cancelled_reason}`}
                      {v.status === 'no_access' && v.follow_up_notes && `No access: ${v.follow_up_notes}`}
                    </p>
                    {v.work_summary && <p className="text-sm text-secondary-700 mt-1 line-clamp-2">{v.work_summary}</p>}
                  </div>
                </div>
                <div className="flex items-center gap-1">
                  <Link
                    href={`/dashboard/field-service/visits/${v.uuid}`}
                    title="Open visit"
                    aria-label="Open visit"
                    className="inline-flex h-8 items-center px-3 rounded-lg text-secondary-600 hover:bg-secondary-100 hover:text-secondary-900"
                  >
                    <ExternalLink className="w-4 h-4" />
                  </Link>
                  {canManage && preStart && editable && (
                    <>
                      <Button
                        size="sm"
                        variant="ghost"
                        title="Reschedule / reassign"
                        onClick={() => {
                          setEditing(v);
                          setFormOpen(true);
                        }}
                      >
                        <Pencil className="w-4 h-4" />
                      </Button>
                      <Button size="sm" variant="ghost" title="Cancel visit" onClick={() => setCancelTarget(v)}>
                        <XCircle className="w-4 h-4 text-amber-600" />
                      </Button>
                    </>
                  )}
                  {canManage && !v.invoiced && !v.timesheet_uuid && v.status !== 'on_site' && (
                    <Button size="sm" variant="ghost" title="Delete visit" onClick={() => setDeleteTarget(v)}>
                      <Trash2 className="w-4 h-4 text-error-500" />
                    </Button>
                  )}
                </div>
              </li>
            );
          })}
        </ul>
      )}

      <VisitFormModal
        isOpen={formOpen}
        jobUuid={jobUuid}
        phases={phases}
        visit={editing}
        onClose={() => setFormOpen(false)}
        onSaved={onChanged}
      />
      <PromptDialog
        isOpen={!!cancelTarget}
        title="Cancel visit"
        label="Reason (optional)"
        confirmText="Cancel visit"
        variant="danger"
        onClose={() => setCancelTarget(null)}
        onSubmit={async (reason) => {
          if (!cancelTarget) return;
          try {
            await fieldService.cancelVisit(cancelTarget.uuid, reason || undefined);
            toast.success('Visit cancelled');
            setCancelTarget(null);
            onChanged();
          } catch (err) {
            toast.error(apiError(err, 'Could not cancel visit'));
          }
        }}
      />
      <ConfirmDialog
        isOpen={!!deleteTarget}
        onClose={() => setDeleteTarget(null)}
        onConfirm={remove}
        title="Delete visit"
        message="Delete this visit? Prefer cancelling if the customer should see it was called off."
        confirmText="Delete"
        variant="danger"
        isLoading={busy}
      />
    </SectionCard>
  );
}

export default VisitsPanel;

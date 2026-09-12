'use client';

/**
 * Engineer check-out: work report, labour hours (prefilled from the
 * check-in time), customer sign-off, follow-up flag, and whether to complete
 * the linked phase and log the time to the engineer's timesheet.
 */

import React, { useState } from 'react';
import toast from 'react-hot-toast';
import { Modal, Button, Input, Textarea } from '@/components/ui';
import { fieldService, parseFsDate, type FsVisitDetail } from '@/services/field-service.service';
import { CheckboxField, apiError } from './shared';

interface CheckOutModalProps {
  isOpen: boolean;
  visit: FsVisitDetail;
  onClose: () => void;
  onDone: (visit: FsVisitDetail) => void;
}

export function CheckOutModal(props: CheckOutModalProps) {
  return (
    <Modal isOpen={props.isOpen} onClose={props.onClose} title="Check out & work report" size="lg">
      {props.isOpen && <CheckOutForm {...props} />}
    </Modal>
  );
}

function elapsedHours(checkedIn?: string | null): string {
  const start = parseFsDate(checkedIn);
  if (!start) return '';
  const h = (Date.now() - start.getTime()) / 3600000;
  if (h <= 0) return '0';
  return String(Math.round(h * 4) / 4); // nearest quarter hour
}

/** Best-effort device location; resolves undefined when unavailable or denied. */
export function getPosition(): Promise<{ latitude: number; longitude: number } | undefined> {
  return new Promise((resolve) => {
    if (typeof navigator === 'undefined' || !navigator.geolocation) return resolve(undefined);
    navigator.geolocation.getCurrentPosition(
      (pos) => resolve({ latitude: pos.coords.latitude, longitude: pos.coords.longitude }),
      () => resolve(undefined),
      { enableHighAccuracy: true, timeout: 8000, maximumAge: 60000 }
    );
  });
}

function CheckOutForm({ visit, onClose, onDone }: CheckOutModalProps) {
  const phaseOpen = !!visit.phase && visit.phase.status !== 'completed' && visit.phase.status !== 'skipped';
  const [summary, setSummary] = useState(visit.work_summary || '');
  const [labour, setLabour] = useState(() => elapsedHours(visit.checked_in_at));
  const [signoff, setSignoff] = useState(visit.customer_signoff_name || '');
  const [followUp, setFollowUp] = useState(false);
  const [followUpNotes, setFollowUpNotes] = useState('');
  const [completePhase, setCompletePhase] = useState(phaseOpen);
  const [logTimesheet, setLogTimesheet] = useState(true);
  const [useLocation, setUseLocation] = useState(true);
  const [saving, setSaving] = useState(false);

  const needsHours = !visit.checked_in_at;
  const signoffNeeded = completePhase && visit.phase?.requires_signoff && !visit.phase?.signed_off_at;
  const openChecklist = visit.phase ? visit.phase.checklist.filter((c) => !c.done).length : 0;

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!summary.trim()) {
      toast.error('Add a short work summary');
      return;
    }
    if (needsHours && !labour.trim()) {
      toast.error('Enter the labour hours (the visit was not checked in)');
      return;
    }
    if (signoffNeeded && !signoff.trim()) {
      toast.error('This phase needs the customer’s sign-off name');
      return;
    }
    setSaving(true);
    try {
      const coords = useLocation ? await getPosition() : undefined;
      const result = await fieldService.checkOut(visit.uuid, {
        work_summary: summary.trim(),
        labour_hours: labour.trim() === '' ? undefined : Number(labour),
        customer_signoff_name: signoff.trim() || undefined,
        follow_up_required: followUp,
        follow_up_notes: followUp ? followUpNotes.trim() || undefined : undefined,
        complete_phase: completePhase,
        log_timesheet: logTimesheet,
        ...(coords ?? {}),
      });
      toast.success('Checked out — visit completed');
      result.warnings?.forEach((w) => toast(w, { icon: '⚠️', duration: 7000 }));
      onDone(result.visit);
      onClose();
    } catch (err) {
      toast.error(apiError(err, 'Check-out failed'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <form onSubmit={submit} className="space-y-4">
      <Textarea
        label="Work carried out *"
        value={summary}
        onChange={(e) => setSummary(e.target.value)}
        rows={4}
        placeholder="What was done, readings taken, parts fitted…"
        autoFocus
      />
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <Input
          label={needsHours ? 'Labour hours *' : 'Labour hours'}
          value={labour}
          onChange={(e) => setLabour(e.target.value)}
          inputMode="decimal"
          helperText={needsHours ? 'Not checked in — enter the time spent.' : 'Prefilled from your check-in time.'}
        />
        <Input
          label={signoffNeeded ? 'Customer sign-off name *' : 'Customer sign-off name'}
          value={signoff}
          onChange={(e) => setSignoff(e.target.value)}
          placeholder="Name of the person who signed off"
        />
      </div>

      <div className="space-y-3 rounded-lg border border-secondary-200 p-4">
        {phaseOpen && visit.phase && (
          <CheckboxField
            label={`Complete phase “${visit.phase.name}”`}
            checked={completePhase}
            onChange={setCompletePhase}
            hint={openChecklist > 0 ? `${openChecklist} checklist item(s) still unticked — the phase stays open until they are done.` : undefined}
          />
        )}
        <CheckboxField label="Log hours to my timesheet" checked={logTimesheet} onChange={setLogTimesheet} />
        <CheckboxField label="Follow-up visit required" checked={followUp} onChange={setFollowUp} />
        {followUp && (
          <Textarea label="Follow-up notes" value={followUpNotes} onChange={(e) => setFollowUpNotes(e.target.value)} rows={2} placeholder="What still needs doing?" />
        )}
        <CheckboxField label="Record my location" checked={useLocation} onChange={setUseLocation} />
      </div>

      <div className="flex justify-end gap-2">
        <Button type="button" variant="ghost" onClick={onClose}>
          Cancel
        </Button>
        <Button type="submit" isLoading={saving}>
          Complete visit
        </Button>
      </div>
    </form>
  );
}

export default CheckOutModal;

'use client';

/**
 * Book (or reschedule / reassign) an engineer site visit on a job.
 * Double-bookings are allowed but reported back as `conflicts`, which are
 * surfaced as a warning toast.
 */

import React, { useEffect, useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { Modal, Button, Input, Textarea, SearchableSelect, Select } from '@/components/ui';
import {
  fieldService,
  formatFsDateTime,
  toApiDateTime,
  toLocalInputValue,
  type FsConflict,
  type FsEngineer,
  type FsPhase,
  type FsVisit,
} from '@/services/field-service.service';
import { CheckboxField, apiError, optionalNumber } from './shared';

interface VisitFormModalProps {
  isOpen: boolean;
  jobUuid: string;
  phases: FsPhase[];
  /** Existing visit to edit; omit to book a new one. */
  visit?: FsVisit | null;
  defaultPhaseUuid?: string;
  onClose: () => void;
  onSaved: () => void;
}

export function warnConflicts(conflicts: FsConflict[] | undefined) {
  if (!conflicts || conflicts.length === 0) return;
  const list = conflicts
    .slice(0, 3)
    .map((c) => `${c.job_number} (${formatFsDateTime(c.scheduled_start, { dateStyle: 'short', timeStyle: 'short' })})`)
    .join(', ');
  toast(`Engineer is double-booked: ${list}${conflicts.length > 3 ? '…' : ''}`, { icon: '⚠️', duration: 6000 });
}

export function VisitFormModal(props: VisitFormModalProps) {
  return (
    <Modal isOpen={props.isOpen} onClose={props.onClose} title={props.visit ? 'Reschedule visit' : 'Book site visit'} size="lg">
      {props.isOpen && <VisitForm {...props} />}
    </Modal>
  );
}

function defaultStart(): string {
  const d = new Date();
  d.setDate(d.getDate() + 1);
  d.setHours(9, 0, 0, 0);
  return toLocalInputValue(d.toISOString());
}

function plusHours(localValue: string, h: number): string {
  const d = new Date(localValue);
  if (isNaN(d.getTime())) return '';
  d.setMinutes(d.getMinutes() + h * 60);
  return toLocalInputValue(d.toISOString());
}

function VisitForm({ jobUuid, phases, visit, defaultPhaseUuid, onClose, onSaved }: VisitFormModalProps) {
  const initialStart = visit ? toLocalInputValue(visit.scheduled_start) : defaultStart();
  const [engineer, setEngineer] = useState(visit?.engineer_user_uuid || '');
  const [phaseUuid, setPhaseUuid] = useState(visit?.phase_uuid || defaultPhaseUuid || '');
  const [start, setStart] = useState(initialStart);
  const [end, setEnd] = useState(visit ? toLocalInputValue(visit.scheduled_end) : plusHours(initialStart, 2));
  const [instructions, setInstructions] = useState(visit?.instructions || '');
  const [billable, setBillable] = useState(visit?.is_billable ?? true);
  const [rate, setRate] = useState(visit?.hourly_rate != null ? String(visit.hourly_rate) : '');
  const [engineers, setEngineers] = useState<FsEngineer[]>([]);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    fieldService.getEngineers().then(setEngineers).catch(() => setEngineers([]));
  }, []);

  const engineerOptions = useMemo(
    () =>
      engineers.map((e) => ({
        value: e.uuid,
        label: e.name || e.email,
        hint: `${e.open_visits} open visit(s)`,
      })),
    [engineers]
  );

  const openPhases = phases.filter((p) => p.status !== 'completed' && p.status !== 'skipped');

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    const startIso = toApiDateTime(start);
    if (!startIso) {
      toast.error('Start time is required');
      return;
    }
    const endIso = toApiDateTime(end);
    if (endIso && new Date(endIso) <= new Date(startIso)) {
      toast.error('End must be after start');
      return;
    }
    const payload: Record<string, unknown> = {
      scheduled_start: startIso,
      scheduled_end: visit ? endIso ?? '' : endIso,
      engineer_user_uuid: visit ? engineer : engineer || undefined,
      phase_uuid: visit ? phaseUuid : phaseUuid || undefined,
      instructions: visit ? instructions.trim() : instructions.trim() || undefined,
      is_billable: billable,
      hourly_rate: visit ? rate.trim() : optionalNumber(rate),
    };
    setSaving(true);
    try {
      const result = visit ? await fieldService.updateVisit(visit.uuid, payload) : await fieldService.createVisit(jobUuid, payload);
      toast.success(visit ? 'Visit updated' : 'Visit booked');
      warnConflicts(result.conflicts);
      result.warnings?.forEach((w) => toast(w, { icon: '⚠️' }));
      onSaved();
      onClose();
    } catch (err) {
      toast.error(apiError(err, 'Failed to save visit'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <form onSubmit={submit} className="space-y-4">
      <SearchableSelect
        label="Engineer"
        options={engineerOptions}
        value={engineer}
        onChange={setEngineer}
        placeholder="Unassigned"
        clearable
      />
      <Select label="Phase" value={phaseUuid} onChange={(e) => setPhaseUuid(e.target.value)}>
        <option value="">No specific phase</option>
        {(visit ? phases : openPhases).map((p) => (
          <option key={p.uuid} value={p.uuid}>
            {p.sort_order}. {p.name}
          </option>
        ))}
      </Select>
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <Input
          label="Start *"
          type="datetime-local"
          value={start}
          onChange={(e) => {
            const next = e.target.value;
            // Keep the slot length when moving the start.
            if (start && end) {
              const len = (new Date(end).getTime() - new Date(start).getTime()) / 3600000;
              if (len > 0) setEnd(plusHours(next, len));
            }
            setStart(next);
          }}
        />
        <Input label="End" type="datetime-local" value={end} onChange={(e) => setEnd(e.target.value)} />
      </div>
      <Textarea
        label="Instructions for the engineer"
        value={instructions}
        onChange={(e) => setInstructions(e.target.value)}
        rows={3}
        placeholder="Parts to bring, who to ask for, what to check…"
      />
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4 items-end">
        <CheckboxField label="Billable labour" checked={billable} onChange={setBillable} />
        <Input
          label="Hourly rate override"
          value={rate}
          onChange={(e) => setRate(e.target.value)}
          inputMode="decimal"
          placeholder="Job rate"
          disabled={visit?.invoiced}
        />
      </div>
      <div className="flex justify-end gap-2">
        <Button type="button" variant="ghost" onClick={onClose}>
          Cancel
        </Button>
        <Button type="submit" isLoading={saving}>
          {visit ? 'Save visit' : 'Book visit'}
        </Button>
      </div>
    </form>
  );
}

export default VisitFormModal;

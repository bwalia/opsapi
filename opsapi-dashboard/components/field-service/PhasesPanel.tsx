'use client';

/**
 * Job phases: ordered list with status actions, checklists (tick to toggle),
 * sign-off capture, add / edit / reorder / delete. Also exports the
 * PhaseChecklist used on the engineer's visit page.
 */

import React, { useState } from 'react';
import toast from 'react-hot-toast';
import {
  ArrowDown,
  ArrowUp,
  CheckCircle2,
  Circle,
  Pencil,
  Play,
  Plus,
  RotateCcw,
  Ban,
  SkipForward,
  Trash2,
  PenLine,
} from 'lucide-react';
import { Modal, Button, Input, Textarea, ConfirmDialog } from '@/components/ui';
import { fieldService, formatFsDateTime, type FsPhase, type PhaseStatus } from '@/services/field-service.service';
import { CheckboxField, PhaseStatusPill, PromptDialog, SectionCard, apiError, apiStatus, hours, optionalNumber } from './shared';

// ============================================================
// Checklist (shared with the visit page)
// ============================================================

export function PhaseChecklist({
  phase,
  disabled,
  onChanged,
}: {
  phase: FsPhase;
  disabled?: boolean;
  onChanged: (phase: FsPhase) => void;
}) {
  const [busyIndex, setBusyIndex] = useState<number | null>(null);
  if (!phase.checklist.length) return null;

  const toggle = async (index: number, done: boolean) => {
    setBusyIndex(index);
    try {
      onChanged(await fieldService.setChecklistItem(phase.uuid, index, done));
    } catch (err) {
      toast.error(apiError(err, 'Could not update checklist'));
    } finally {
      setBusyIndex(null);
    }
  };

  const doneCount = phase.checklist.filter((c) => c.done).length;
  return (
    <div className="mt-3">
      <p className="text-xs font-medium text-secondary-500 mb-1.5">
        Checklist {doneCount}/{phase.checklist.length}
      </p>
      <ul className="space-y-1">
        {phase.checklist.map((item, index) => (
          <li key={`${index}-${item.label}`}>
            <button
              type="button"
              disabled={disabled || busyIndex !== null}
              onClick={() => toggle(index, !item.done)}
              className="flex items-start gap-2 text-left text-sm w-full rounded-md px-1.5 py-1 hover:bg-secondary-50 disabled:cursor-not-allowed disabled:hover:bg-transparent"
            >
              {item.done ? (
                <CheckCircle2 className="w-4 h-4 mt-0.5 text-green-600 shrink-0" />
              ) : (
                <Circle className="w-4 h-4 mt-0.5 text-secondary-400 shrink-0" />
              )}
              <span className={item.done ? 'text-secondary-500 line-through' : 'text-secondary-800'}>{item.label}</span>
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}

// ============================================================
// Phase status changes (with sign-off / force follow-ups)
// ============================================================

/**
 * Hook that moves a phase to a status, prompting for the customer's sign-off
 * name when the phase requires it and offering to force completion when the
 * checklist is incomplete. Render `dialogs` somewhere in the tree.
 */
export function usePhaseStatus(onChanged: (phase: FsPhase) => void) {
  const [signoffFor, setSignoffFor] = useState<FsPhase | null>(null);
  const [forceFor, setForceFor] = useState<{ phase: FsPhase; message: string; signoff?: string } | null>(null);

  const run = async (phase: FsPhase, status: PhaseStatus, opts: { signoff_name?: string; force?: boolean } = {}) => {
    try {
      const updated = await fieldService.setPhaseStatus(phase.uuid, status, opts);
      onChanged(updated);
      toast.success(`${phase.name}: ${status.replace('_', ' ')}`);
      return true;
    } catch (err) {
      const msg = apiError(err, 'Could not update phase');
      if (status === 'completed' && apiStatus(err) === 422 && /force/i.test(msg)) {
        setForceFor({ phase, message: msg, signoff: opts.signoff_name });
      } else {
        toast.error(msg);
      }
      return false;
    }
  };

  const change = (phase: FsPhase, status: PhaseStatus) => {
    if (status === 'completed' && phase.requires_signoff && !phase.signed_off_at) {
      setSignoffFor(phase);
      return;
    }
    run(phase, status);
  };

  const dialogs = (
    <>
      <PromptDialog
        isOpen={!!signoffFor}
        title="Customer sign-off"
        message={signoffFor ? `"${signoffFor.name}" needs the customer's sign-off before it can be completed.` : ''}
        label="Signed off by (name)"
        required
        confirmText="Complete phase"
        onClose={() => setSignoffFor(null)}
        onSubmit={async (name) => {
          if (!signoffFor) return;
          const phase = signoffFor;
          setSignoffFor(null);
          await run(phase, 'completed', { signoff_name: name });
        }}
      />
      <ConfirmDialog
        isOpen={!!forceFor}
        onClose={() => setForceFor(null)}
        onConfirm={async () => {
          if (!forceFor) return;
          const { phase, signoff } = forceFor;
          setForceFor(null);
          await run(phase, 'completed', { force: true, signoff_name: signoff });
        }}
        title="Complete anyway?"
        message={`${forceFor?.message || ''}`}
        confirmText="Complete anyway"
        variant="warning"
      />
    </>
  );

  return { change, dialogs };
}

// ============================================================
// Phase form modal
// ============================================================

function PhaseFormModal({
  isOpen,
  jobUuid,
  phase,
  onClose,
  onSaved,
}: {
  isOpen: boolean;
  jobUuid: string;
  phase: FsPhase | null;
  onClose: () => void;
  onSaved: () => void;
}) {
  return (
    <Modal isOpen={isOpen} onClose={onClose} title={phase ? 'Edit phase' : 'Add phase'} size="lg">
      {isOpen && <PhaseForm jobUuid={jobUuid} phase={phase} onClose={onClose} onSaved={onSaved} />}
    </Modal>
  );
}

function PhaseForm({
  jobUuid,
  phase,
  onClose,
  onSaved,
}: {
  jobUuid: string;
  phase: FsPhase | null;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [name, setName] = useState(phase?.name || '');
  const [description, setDescription] = useState(phase?.description || '');
  const [estimated, setEstimated] = useState(phase?.estimated_hours != null ? String(phase.estimated_hours) : '');
  const [requiresVisit, setRequiresVisit] = useState(phase?.requires_visit ?? true);
  const [requiresSignoff, setRequiresSignoff] = useState(phase?.requires_signoff ?? false);
  const [checklist, setChecklist] = useState((phase?.checklist || []).map((c) => c.label).join('\n'));
  const [notes, setNotes] = useState(phase?.notes || '');
  const [saving, setSaving] = useState(false);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!name.trim()) {
      toast.error('Phase name is required');
      return;
    }
    // Keep the tick state of items whose label is unchanged.
    const previous = new Map((phase?.checklist || []).map((c) => [c.label, c]));
    const items = checklist
      .split('\n')
      .map((l) => l.trim())
      .filter(Boolean)
      .map((label) => previous.get(label) ?? { label, done: false });

    const payload: Record<string, unknown> = {
      name: name.trim(),
      description: description.trim(),
      estimated_hours: phase ? estimated.trim() : optionalNumber(estimated),
      requires_visit: requiresVisit,
      requires_signoff: requiresSignoff,
      checklist: items,
    };
    if (phase) payload.notes = notes.trim();
    setSaving(true);
    try {
      if (phase) await fieldService.updatePhase(phase.uuid, payload);
      else await fieldService.addPhase(jobUuid, payload);
      toast.success(phase ? 'Phase updated' : 'Phase added');
      onSaved();
      onClose();
    } catch (err) {
      toast.error(apiError(err, 'Failed to save phase'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <form onSubmit={submit} className="space-y-4">
      <Input label="Name *" value={name} onChange={(e) => setName(e.target.value)} autoFocus />
      <Textarea label="Description" value={description} onChange={(e) => setDescription(e.target.value)} rows={2} />
      <Input label="Estimated hours" value={estimated} onChange={(e) => setEstimated(e.target.value)} inputMode="decimal" />
      <div className="flex flex-wrap gap-6">
        <CheckboxField label="Requires a site visit" checked={requiresVisit} onChange={setRequiresVisit} />
        <CheckboxField label="Requires customer sign-off" checked={requiresSignoff} onChange={setRequiresSignoff} />
      </div>
      <Textarea
        label="Checklist (one item per line)"
        value={checklist}
        onChange={(e) => setChecklist(e.target.value)}
        rows={5}
        placeholder={'Isolate supply\nCheck flue\nPressure test'}
      />
      {phase && <Textarea label="Notes" value={notes} onChange={(e) => setNotes(e.target.value)} rows={2} />}
      <div className="flex justify-end gap-2">
        <Button type="button" variant="ghost" onClick={onClose}>
          Cancel
        </Button>
        <Button type="submit" isLoading={saving}>
          {phase ? 'Save phase' : 'Add phase'}
        </Button>
      </div>
    </form>
  );
}

// ============================================================
// Panel
// ============================================================

interface PhasesPanelProps {
  jobUuid: string;
  phases: FsPhase[];
  /** Job is open (not completed / cancelled). */
  editable: boolean;
  canManage: boolean;
  onChanged: () => void;
}

export function PhasesPanel({ jobUuid, phases, editable, canManage, onChanged }: PhasesPanelProps) {
  const [formOpen, setFormOpen] = useState(false);
  const [editing, setEditing] = useState<FsPhase | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<FsPhase | null>(null);
  const [busy, setBusy] = useState(false);
  const { change, dialogs } = usePhaseStatus(() => onChanged());

  const move = async (index: number, delta: number) => {
    const order = phases.map((p) => p.uuid);
    const target = index + delta;
    if (target < 0 || target >= order.length) return;
    [order[index], order[target]] = [order[target], order[index]];
    setBusy(true);
    try {
      await fieldService.reorderPhases(jobUuid, order);
      onChanged();
    } catch (err) {
      toast.error(apiError(err, 'Could not reorder phases'));
    } finally {
      setBusy(false);
    }
  };

  const remove = async () => {
    if (!deleteTarget) return;
    setBusy(true);
    try {
      await fieldService.deletePhase(deleteTarget.uuid);
      toast.success('Phase removed');
      setDeleteTarget(null);
      onChanged();
    } catch (err) {
      toast.error(apiError(err, 'Could not remove phase'));
    } finally {
      setBusy(false);
    }
  };

  const done = phases.filter((p) => p.status === 'completed' || p.status === 'skipped').length;

  return (
    <SectionCard
      title={`Phases (${done}/${phases.length})`}
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
            <Plus className="w-4 h-4 mr-1" /> Add phase
          </Button>
        )
      }
    >
      {phases.length === 0 ? (
        <p className="text-sm text-secondary-500">No phases yet. Add phases to break the job into stages.</p>
      ) : (
        <ol className="space-y-3">
          {phases.map((phase, index) => {
            const finished = phase.status === 'completed' || phase.status === 'skipped';
            return (
              <li key={phase.uuid} className="rounded-lg border border-secondary-200 p-4">
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div className="flex items-start gap-3 min-w-0">
                    <span className="mt-0.5 inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-secondary-100 text-xs font-semibold text-secondary-700">
                      {index + 1}
                    </span>
                    <div className="min-w-0">
                      <div className="flex flex-wrap items-center gap-2">
                        <p className="font-medium text-secondary-900">{phase.name}</p>
                        <PhaseStatusPill status={phase.status} />
                        {phase.requires_signoff && (
                          <span className="inline-flex items-center gap-1 text-xs text-secondary-500">
                            <PenLine className="w-3 h-3" /> sign-off
                          </span>
                        )}
                      </div>
                      {phase.description && <p className="text-sm text-secondary-600 mt-0.5">{phase.description}</p>}
                      <p className="text-xs text-secondary-500 mt-1">
                        {phase.visit_count} visit(s) · {hours(phase.logged_hours)} logged
                        {phase.estimated_hours ? ` of ${hours(phase.estimated_hours)} est.` : ''}
                        {phase.completed_at &&
                          ` · ${phase.status === 'skipped' ? 'skipped' : 'completed'} ${formatFsDateTime(phase.completed_at)}${
                            phase.completed_by_name ? ` by ${phase.completed_by_name}` : ''
                          }`}
                        {phase.signoff_name && ` · signed off by ${phase.signoff_name}`}
                      </p>
                      {phase.notes && <p className="text-xs text-secondary-600 mt-1 italic">{phase.notes}</p>}
                    </div>
                  </div>

                  {editable && (
                    <div className="flex flex-wrap items-center gap-1">
                      {(phase.status === 'pending' || phase.status === 'blocked') && (
                        <Button size="sm" variant="ghost" onClick={() => change(phase, 'in_progress')} title="Start">
                          <Play className="w-4 h-4 mr-1" /> Start
                        </Button>
                      )}
                      {!finished && (
                        <Button size="sm" variant="ghost" onClick={() => change(phase, 'completed')} title="Complete">
                          <CheckCircle2 className="w-4 h-4 mr-1" /> Complete
                        </Button>
                      )}
                      {phase.status === 'in_progress' && (
                        <Button size="sm" variant="ghost" onClick={() => change(phase, 'blocked')} title="Blocked">
                          <Ban className="w-4 h-4" />
                        </Button>
                      )}
                      {canManage && !finished && (
                        <Button size="sm" variant="ghost" onClick={() => change(phase, 'skipped')} title="Skip">
                          <SkipForward className="w-4 h-4" />
                        </Button>
                      )}
                      {canManage && finished && (
                        <Button size="sm" variant="ghost" onClick={() => change(phase, 'in_progress')} title="Reopen">
                          <RotateCcw className="w-4 h-4 mr-1" /> Reopen
                        </Button>
                      )}
                      {canManage && (
                        <>
                          <Button size="sm" variant="ghost" disabled={busy || index === 0} onClick={() => move(index, -1)} title="Move up">
                            <ArrowUp className="w-4 h-4" />
                          </Button>
                          <Button
                            size="sm"
                            variant="ghost"
                            disabled={busy || index === phases.length - 1}
                            onClick={() => move(index, 1)}
                            title="Move down"
                          >
                            <ArrowDown className="w-4 h-4" />
                          </Button>
                          <Button
                            size="sm"
                            variant="ghost"
                            onClick={() => {
                              setEditing(phase);
                              setFormOpen(true);
                            }}
                            title="Edit"
                          >
                            <Pencil className="w-4 h-4" />
                          </Button>
                          {phase.status !== 'completed' && (
                            <Button size="sm" variant="ghost" onClick={() => setDeleteTarget(phase)} title="Remove">
                              <Trash2 className="w-4 h-4 text-error-500" />
                            </Button>
                          )}
                        </>
                      )}
                    </div>
                  )}
                </div>
                <PhaseChecklist phase={phase} disabled={!editable} onChanged={() => onChanged()} />
              </li>
            );
          })}
        </ol>
      )}

      <PhaseFormModal isOpen={formOpen} jobUuid={jobUuid} phase={editing} onClose={() => setFormOpen(false)} onSaved={onChanged} />
      <ConfirmDialog
        isOpen={!!deleteTarget}
        onClose={() => setDeleteTarget(null)}
        onConfirm={remove}
        title="Remove phase"
        message={`Remove "${deleteTarget?.name || ''}" from this job? Visits and parts linked to it keep their records but lose the phase link.`}
        confirmText="Remove"
        variant="danger"
        isLoading={busy}
      />
      {dialogs}
    </SectionCard>
  );
}

export default PhasesPanel;

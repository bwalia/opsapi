'use client';

/**
 * Job Types — /dashboard/field-service/job-types
 *
 * Job types and their ordered phase templates. Creating a job of a type
 * copies these phases (with their checklists) onto the job, where they can
 * then be edited per job.
 */

import React, { useCallback, useEffect, useState } from 'react';
import toast from 'react-hot-toast';
import { ArrowDown, ArrowUp, Layers, Loader2, Pencil, PenLine, Plus, Trash2, MapPin } from 'lucide-react';
import { Button, ConfirmDialog, Input, Modal, Textarea } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { usePermissions } from '@/contexts/PermissionsContext';
import { fieldService, type FsJobType, type FsPhaseTemplate } from '@/services/field-service.service';
import { CheckboxField, FieldServiceNav, SectionCard, apiError, hours, money, optional, optionalNumber } from '@/components/field-service/shared';
import PhaseTemplateModal from '@/components/field-service/PhaseTemplateModal';
import { cn } from '@/lib/utils';

// ============================================================
// New job type modal
// ============================================================

function NewJobTypeModal({ isOpen, onClose, onCreated }: { isOpen: boolean; onClose: () => void; onCreated: (jt: FsJobType) => void }) {
  return (
    <Modal isOpen={isOpen} onClose={onClose} title="New job type" size="md">
      {isOpen && <NewJobTypeForm onClose={onClose} onCreated={onCreated} />}
    </Modal>
  );
}

function NewJobTypeForm({ onClose, onCreated }: { onClose: () => void; onCreated: (jt: FsJobType) => void }) {
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [color, setColor] = useState('#2563eb');
  const [rate, setRate] = useState('');
  const [phases, setPhases] = useState('');
  const [saving, setSaving] = useState(false);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!name.trim()) {
      toast.error('Name is required');
      return;
    }
    setSaving(true);
    try {
      const jt = await fieldService.createJobType({
        name: name.trim(),
        description: optional(description),
        color,
        default_hourly_rate: optionalNumber(rate),
        phases: phases
          .split('\n')
          .map((l) => l.trim())
          .filter(Boolean)
          .map((n) => ({ name: n })),
      });
      toast.success('Job type created');
      onCreated(jt);
      onClose();
    } catch (err) {
      toast.error(apiError(err, 'Failed to create job type'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <form onSubmit={submit} className="space-y-4">
      <Input label="Name *" value={name} onChange={(e) => setName(e.target.value)} placeholder="e.g. Boiler installation" autoFocus />
      <Textarea label="Description" value={description} onChange={(e) => setDescription(e.target.value)} rows={2} />
      <div className="grid grid-cols-2 gap-4">
        <Input label="Default hourly rate" value={rate} onChange={(e) => setRate(e.target.value)} inputMode="decimal" />
        <Input label="Colour" type="color" value={color} onChange={(e) => setColor(e.target.value)} className="h-10 p-1" />
      </div>
      <Textarea
        label="Phases (one per line, optional)"
        value={phases}
        onChange={(e) => setPhases(e.target.value)}
        rows={4}
        placeholder={'Survey\nQuote\nInstall\nCommission\nHandover'}
        helperText="You can add checklists and sign-off rules to each phase afterwards."
      />
      <div className="flex justify-end gap-2">
        <Button type="button" variant="ghost" onClick={onClose}>
          Cancel
        </Button>
        <Button type="submit" isLoading={saving}>
          Create job type
        </Button>
      </div>
    </form>
  );
}

// ============================================================
// Editor (keyed by job type so its form state resets on switch)
// ============================================================

function JobTypeEditor({
  jobType,
  canEdit,
  canDelete,
  onChanged,
  onDeleted,
}: {
  jobType: FsJobType;
  canEdit: boolean;
  canDelete: boolean;
  onChanged: () => void;
  onDeleted: () => void;
}) {
  const [name, setName] = useState(jobType.name);
  const [description, setDescription] = useState(jobType.description || '');
  const [color, setColor] = useState(jobType.color || '#2563eb');
  const [rate, setRate] = useState(jobType.default_hourly_rate != null ? String(jobType.default_hourly_rate) : '');
  const [active, setActive] = useState(jobType.is_active);
  const [saving, setSaving] = useState(false);
  const [templateOpen, setTemplateOpen] = useState(false);
  const [editingTemplate, setEditingTemplate] = useState<FsPhaseTemplate | null>(null);
  const [deleteTemplate, setDeleteTemplate] = useState<FsPhaseTemplate | null>(null);
  const [deleteTypeOpen, setDeleteTypeOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const phases = jobType.phases || [];

  const save = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!name.trim()) {
      toast.error('Name is required');
      return;
    }
    setSaving(true);
    try {
      await fieldService.updateJobType(jobType.uuid, {
        name: name.trim(),
        description: description.trim(),
        color,
        default_hourly_rate: rate.trim(),
        is_active: active,
      });
      toast.success('Job type saved');
      onChanged();
    } catch (err) {
      toast.error(apiError(err, 'Failed to save job type'));
    } finally {
      setSaving(false);
    }
  };

  const move = async (index: number, delta: number) => {
    const order = phases.map((p) => p.uuid);
    const target = index + delta;
    if (target < 0 || target >= order.length) return;
    [order[index], order[target]] = [order[target], order[index]];
    setBusy(true);
    try {
      await fieldService.reorderPhaseTemplates(jobType.uuid, order);
      onChanged();
    } catch (err) {
      toast.error(apiError(err, 'Could not reorder'));
    } finally {
      setBusy(false);
    }
  };

  const removeTemplate = async () => {
    if (!deleteTemplate) return;
    setBusy(true);
    try {
      await fieldService.deletePhaseTemplate(deleteTemplate.uuid);
      toast.success('Phase template removed');
      setDeleteTemplate(null);
      onChanged();
    } catch (err) {
      toast.error(apiError(err, 'Could not remove phase template'));
    } finally {
      setBusy(false);
    }
  };

  const removeType = async () => {
    setBusy(true);
    try {
      await fieldService.deleteJobType(jobType.uuid);
      toast.success('Job type deleted');
      setDeleteTypeOpen(false);
      onDeleted();
    } catch (err) {
      toast.error(apiError(err, 'Could not delete job type'));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="space-y-6">
      <SectionCard
        title="Details"
        actions={
          canDelete && (
            <Button size="sm" variant="ghost" onClick={() => setDeleteTypeOpen(true)}>
              <Trash2 className="w-4 h-4 mr-1 text-error-500" /> Delete
            </Button>
          )
        }
      >
        <form onSubmit={save} className="space-y-4">
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <Input label="Name *" value={name} onChange={(e) => setName(e.target.value)} disabled={!canEdit} />
            <div className="grid grid-cols-2 gap-2">
              <Input label="Default hourly rate" value={rate} onChange={(e) => setRate(e.target.value)} inputMode="decimal" disabled={!canEdit} />
              <Input label="Colour" type="color" value={color} onChange={(e) => setColor(e.target.value)} className="h-10 p-1" disabled={!canEdit} />
            </div>
          </div>
          <Textarea label="Description" value={description} onChange={(e) => setDescription(e.target.value)} rows={2} disabled={!canEdit} />
          <div className="flex flex-wrap items-center justify-between gap-3">
            <CheckboxField label="Active (offered when creating jobs)" checked={active} onChange={setActive} />
            {canEdit && (
              <Button type="submit" isLoading={saving}>
                Save details
              </Button>
            )}
          </div>
          <p className="text-xs text-secondary-500">Used by {jobType.job_count ?? 0} job(s).</p>
        </form>
      </SectionCard>

      <SectionCard
        title={`Phase templates (${phases.length})`}
        actions={
          canEdit && (
            <Button
              size="sm"
              variant="ghost"
              onClick={() => {
                setEditingTemplate(null);
                setTemplateOpen(true);
              }}
            >
              <Plus className="w-4 h-4 mr-1" /> Add phase
            </Button>
          )
        }
      >
        {phases.length === 0 ? (
          <p className="text-sm text-secondary-500">No phases yet. Jobs of this type will start with no phases.</p>
        ) : (
          <ol className="space-y-3">
            {phases.map((p, index) => (
              <li key={p.uuid} className="rounded-lg border border-secondary-200 p-4">
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div className="flex items-start gap-3 min-w-0">
                    <span className="mt-0.5 inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-secondary-100 text-xs font-semibold text-secondary-700">
                      {index + 1}
                    </span>
                    <div className="min-w-0">
                      <p className="font-medium text-secondary-900">{p.name}</p>
                      {p.description && <p className="text-sm text-secondary-600">{p.description}</p>}
                      <div className="mt-1 flex flex-wrap gap-3 text-xs text-secondary-500">
                        {p.requires_visit && (
                          <span className="inline-flex items-center gap-1">
                            <MapPin className="w-3 h-3" /> site visit
                          </span>
                        )}
                        {p.requires_signoff && (
                          <span className="inline-flex items-center gap-1">
                            <PenLine className="w-3 h-3" /> customer sign-off
                          </span>
                        )}
                        {p.estimated_hours ? <span>{hours(p.estimated_hours)} est.</span> : null}
                        {p.checklist.length > 0 && <span>{p.checklist.length} checklist item(s)</span>}
                      </div>
                      {p.checklist.length > 0 && (
                        <ul className="mt-2 list-disc pl-5 text-sm text-secondary-600 space-y-0.5">
                          {p.checklist.map((c, i) => (
                            <li key={`${i}-${c}`}>{c}</li>
                          ))}
                        </ul>
                      )}
                    </div>
                  </div>
                  {canEdit && (
                    <div className="flex items-center gap-1">
                      <Button size="sm" variant="ghost" disabled={busy || index === 0} onClick={() => move(index, -1)} title="Move up">
                        <ArrowUp className="w-4 h-4" />
                      </Button>
                      <Button size="sm" variant="ghost" disabled={busy || index === phases.length - 1} onClick={() => move(index, 1)} title="Move down">
                        <ArrowDown className="w-4 h-4" />
                      </Button>
                      <Button
                        size="sm"
                        variant="ghost"
                        title="Edit"
                        onClick={() => {
                          setEditingTemplate(p);
                          setTemplateOpen(true);
                        }}
                      >
                        <Pencil className="w-4 h-4" />
                      </Button>
                      <Button size="sm" variant="ghost" title="Remove" onClick={() => setDeleteTemplate(p)}>
                        <Trash2 className="w-4 h-4 text-error-500" />
                      </Button>
                    </div>
                  )}
                </div>
              </li>
            ))}
          </ol>
        )}
        <p className="mt-4 text-xs text-secondary-500">Changes apply to new jobs only — existing jobs keep the phases they were created with.</p>
      </SectionCard>

      <PhaseTemplateModal
        isOpen={templateOpen}
        jobTypeUuid={jobType.uuid}
        template={editingTemplate}
        onClose={() => setTemplateOpen(false)}
        onSaved={onChanged}
      />
      <ConfirmDialog
        isOpen={!!deleteTemplate}
        onClose={() => setDeleteTemplate(null)}
        onConfirm={removeTemplate}
        title="Remove phase template"
        message={`Remove "${deleteTemplate?.name || ''}"? Existing jobs are not affected.`}
        confirmText="Remove"
        variant="danger"
        isLoading={busy}
      />
      <ConfirmDialog
        isOpen={deleteTypeOpen}
        onClose={() => setDeleteTypeOpen(false)}
        onConfirm={removeType}
        title="Delete job type"
        message={`Delete "${jobType.name}"? Existing jobs keep their phases but lose the type label.`}
        confirmText="Delete"
        variant="danger"
        isLoading={busy}
      />
    </div>
  );
}

// ============================================================
// Page
// ============================================================

function JobTypesPageContent() {
  const { canCreate, canUpdate, canDelete } = usePermissions();
  const [types, setTypes] = useState<FsJobType[]>([]);
  const [selectedUuid, setSelectedUuid] = useState<string | null>(null);
  const [detail, setDetail] = useState<FsJobType | null>(null);
  const [loading, setLoading] = useState(true);
  const [newOpen, setNewOpen] = useState(false);

  const loadTypes = useCallback(async () => {
    try {
      const list = await fieldService.getJobTypes({ includeInactive: true });
      setTypes(list);
      setSelectedUuid((cur) => (cur && list.some((t) => t.uuid === cur) ? cur : list[0]?.uuid ?? null));
    } catch (err) {
      toast.error(apiError(err, 'Failed to load job types'));
    } finally {
      setLoading(false);
    }
  }, []);

  const loadDetail = useCallback(async (uuid: string) => {
    try {
      setDetail(await fieldService.getJobType(uuid));
    } catch (err) {
      toast.error(apiError(err, 'Failed to load job type'));
    }
  }, []);

  useEffect(() => {
    loadTypes();
  }, [loadTypes]);

  useEffect(() => {
    if (selectedUuid) loadDetail(selectedUuid);
  }, [selectedUuid, loadDetail]);

  const refresh = () => {
    loadTypes();
    if (selectedUuid) loadDetail(selectedUuid);
  };

  return (
    <div className="space-y-6">
      <PageHeader
        title="Job Types"
        description="Define the phases each kind of job goes through. New jobs copy them."
        icon={<Layers className="w-5 h-5" />}
        actions={
          canCreate('fs_job_types') && (
            <Button onClick={() => setNewOpen(true)}>
              <Plus className="w-4 h-4 mr-1.5" /> New job type
            </Button>
          )
        }
      />
      <FieldServiceNav />

      {loading ? (
        <div className="flex items-center justify-center py-16 text-secondary-500">
          <Loader2 className="w-5 h-5 animate-spin mr-2" /> Loading…
        </div>
      ) : types.length === 0 ? (
        <div className="text-center py-16 bg-surface rounded-xl border border-secondary-200">
          <Layers className="w-8 h-8 mx-auto text-secondary-300" />
          <p className="mt-2 font-medium text-secondary-900">No job types yet</p>
          <p className="text-sm text-secondary-500">Create one (e.g. “Boiler service”) with its phases to speed up job creation.</p>
        </div>
      ) : (
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <ul className="space-y-2">
            {types.map((t) => (
              <li key={t.uuid}>
                <button
                  type="button"
                  onClick={() => setSelectedUuid(t.uuid)}
                  className={cn(
                    'w-full text-left rounded-xl border p-4 transition',
                    selectedUuid === t.uuid ? 'border-primary-400 bg-primary-50/40 shadow-sm' : 'border-secondary-200 bg-surface hover:border-secondary-300'
                  )}
                >
                  <div className="flex items-center gap-2">
                    <span className="h-3 w-3 rounded-full shrink-0" style={{ backgroundColor: t.color || '#94a3b8' }} />
                    <span className="font-medium text-secondary-900">{t.name}</span>
                    {!t.is_active && <span className="text-xs text-secondary-400">(inactive)</span>}
                  </div>
                  <p className="mt-1 text-xs text-secondary-500">
                    {t.phase_count ?? 0} phase(s) · {t.job_count ?? 0} job(s)
                    {t.default_hourly_rate ? ` · ${money(t.default_hourly_rate)}/h` : ''}
                  </p>
                </button>
              </li>
            ))}
          </ul>
          <div className="lg:col-span-2">
            {detail && detail.uuid === selectedUuid ? (
              <JobTypeEditor
                key={`${detail.uuid}-${detail.updated_at}`}
                jobType={detail}
                canEdit={canUpdate('fs_job_types')}
                canDelete={canDelete('fs_job_types')}
                onChanged={refresh}
                onDeleted={() => {
                  setDetail(null);
                  setSelectedUuid(null);
                  loadTypes();
                }}
              />
            ) : (
              <div className="flex items-center justify-center py-16 text-secondary-500">
                <Loader2 className="w-5 h-5 animate-spin mr-2" /> Loading…
              </div>
            )}
          </div>
        </div>
      )}

      <NewJobTypeModal
        isOpen={newOpen}
        onClose={() => setNewOpen(false)}
        onCreated={(jt) => {
          loadTypes();
          setSelectedUuid(jt.uuid);
        }}
      />
    </div>
  );
}

export default function FieldServiceJobTypesPage() {
  return (
    <ProtectedPage module="fs_job_types" title="Job Types">
      <JobTypesPageContent />
    </ProtectedPage>
  );
}

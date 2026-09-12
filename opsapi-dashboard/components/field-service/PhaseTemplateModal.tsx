'use client';

import React, { useState } from 'react';
import toast from 'react-hot-toast';
import { Modal, Button, Input, Textarea } from '@/components/ui';
import { fieldService, type FsPhaseTemplate } from '@/services/field-service.service';
import { CheckboxField, apiError, optionalNumber } from './shared';

interface PhaseTemplateModalProps {
  isOpen: boolean;
  jobTypeUuid: string;
  template: FsPhaseTemplate | null;
  onClose: () => void;
  onSaved: () => void;
}

export function PhaseTemplateModal(props: PhaseTemplateModalProps) {
  return (
    <Modal isOpen={props.isOpen} onClose={props.onClose} title={props.template ? 'Edit phase template' : 'Add phase template'} size="lg">
      {props.isOpen && <PhaseTemplateForm {...props} />}
    </Modal>
  );
}

function PhaseTemplateForm({ jobTypeUuid, template, onClose, onSaved }: PhaseTemplateModalProps) {
  const [name, setName] = useState(template?.name || '');
  const [description, setDescription] = useState(template?.description || '');
  const [estimated, setEstimated] = useState(template?.estimated_hours != null ? String(template.estimated_hours) : '');
  const [requiresVisit, setRequiresVisit] = useState(template?.requires_visit ?? true);
  const [requiresSignoff, setRequiresSignoff] = useState(template?.requires_signoff ?? false);
  const [checklist, setChecklist] = useState((template?.checklist || []).join('\n'));
  const [saving, setSaving] = useState(false);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!name.trim()) {
      toast.error('Phase name is required');
      return;
    }
    const payload: Record<string, unknown> = {
      name: name.trim(),
      description: description.trim(),
      estimated_hours: template ? estimated.trim() : optionalNumber(estimated),
      requires_visit: requiresVisit,
      requires_signoff: requiresSignoff,
      checklist: checklist
        .split('\n')
        .map((l) => l.trim())
        .filter(Boolean),
    };
    setSaving(true);
    try {
      if (template) await fieldService.updatePhaseTemplate(template.uuid, payload);
      else await fieldService.addPhaseTemplate(jobTypeUuid, payload);
      toast.success(template ? 'Phase template updated' : 'Phase template added');
      onSaved();
      onClose();
    } catch (err) {
      toast.error(apiError(err, 'Failed to save phase template'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <form onSubmit={submit} className="space-y-4">
      <Input label="Name *" value={name} onChange={(e) => setName(e.target.value)} placeholder="e.g. Survey, Install, Commission" autoFocus />
      <Textarea label="Description" value={description} onChange={(e) => setDescription(e.target.value)} rows={2} />
      <Input label="Estimated hours" value={estimated} onChange={(e) => setEstimated(e.target.value)} inputMode="decimal" />
      <div className="flex flex-wrap gap-6">
        <CheckboxField label="Requires a site visit" checked={requiresVisit} onChange={setRequiresVisit} />
        <CheckboxField
          label="Requires customer sign-off"
          checked={requiresSignoff}
          onChange={setRequiresSignoff}
          hint="The engineer must capture who signed off before completing it."
        />
      </div>
      <Textarea
        label="Checklist (one item per line)"
        value={checklist}
        onChange={(e) => setChecklist(e.target.value)}
        rows={6}
        placeholder={'Isolate supply\nVisual inspection\nFlue gas analysis\nIssue certificate'}
      />
      <div className="flex justify-end gap-2">
        <Button type="button" variant="ghost" onClick={onClose}>
          Cancel
        </Button>
        <Button type="submit" isLoading={saving}>
          {template ? 'Save template' : 'Add template'}
        </Button>
      </div>
    </form>
  );
}

export default PhaseTemplateModal;

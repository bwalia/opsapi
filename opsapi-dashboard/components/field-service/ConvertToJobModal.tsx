'use client';

import React, { useEffect, useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { Modal, Button, Input, SearchableSelect, DateTimeField } from '@/components/ui';
import {
  fieldService,
  toApiDateTime,
  type FsConvertResult,
  type FsEngineer,
  type FsJobType,
  type FsServiceRequest,
} from '@/services/field-service.service';
import { apiError, optional } from './shared';

interface ConvertToJobModalProps {
  isOpen: boolean;
  request: FsServiceRequest;
  onClose: () => void;
  onConverted: (result: FsConvertResult) => void;
}

export function ConvertToJobModal(props: ConvertToJobModalProps) {
  return (
    <Modal
      isOpen={props.isOpen}
      onClose={props.onClose}
      title="Convert to job"
      description={`Turn ${props.request.request_number} into a scheduled job`}
      size="2xl"
    >
      {props.isOpen && <ConvertForm {...props} />}
    </Modal>
  );
}

function ConvertForm({ request, onClose, onConverted }: ConvertToJobModalProps) {
  const [jobTypeUuid, setJobTypeUuid] = useState('');
  const [managerUuid, setManagerUuid] = useState(request.assigned_manager_uuid || '');
  const [engineerUuid, setEngineerUuid] = useState('');
  const [visitAt, setVisitAt] = useState('');
  const [title, setTitle] = useState(request.title || '');
  const [dueDate, setDueDate] = useState('');
  const [jobTypes, setJobTypes] = useState<FsJobType[]>([]);
  const [members, setMembers] = useState<FsEngineer[]>([]);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    fieldService.getJobTypes().then(setJobTypes).catch(() => setJobTypes([]));
    fieldService.getEngineers().then(setMembers).catch(() => setMembers([]));
  }, []);

  const jobTypeOptions = useMemo(
    () => jobTypes.map((t) => ({ value: t.uuid, label: t.name, hint: t.phase_count ? `${t.phase_count} phase(s)` : undefined })),
    [jobTypes]
  );
  const managerOptions = useMemo(
    () => members.map((m) => ({
      value: m.uuid,
      label: m.name || m.email,
      hint: [m.role, m.email].filter(Boolean).join(' · ') || undefined,
    })),
    [members]
  );

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setSaving(true);
    const payload: Record<string, unknown> = {
      job_type_uuid: optional(jobTypeUuid),
      service_manager_uuid: optional(managerUuid),
      title: optional(title),
      due_date: optional(dueDate),
      // Assigning the engineer books their first visit, which is what makes the
      // job appear in their My Work and moves it out of draft.
      engineer_uuid: optional(engineerUuid),
      scheduled_start: engineerUuid && visitAt ? toApiDateTime(visitAt) : undefined,
    };
    try {
      const result = await fieldService.convertRequestToJob(request.uuid, payload);
      toast.success(engineerUuid ? `${result.job_number} created and assigned` : `${result.job_number} created`);
      onConverted(result);
      onClose();
    } catch (err) {
      toast.error(apiError(err, 'Failed to convert to job'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <form onSubmit={submit} className="space-y-4">
      <p className="text-sm text-secondary-500">
        The customer, site and faulty item carry over from the request.
      </p>
      <Input label="Job title" value={title} onChange={(e) => setTitle(e.target.value)} placeholder={request.title} />
      <SearchableSelect
        label="Job type"
        options={jobTypeOptions}
        value={jobTypeUuid}
        onChange={setJobTypeUuid}
        placeholder="No job type (add phases later)"
        clearable
      />

      {/* Assign the engineer who'll do the work + when they'll visit. */}
      <div className="rounded-xl border border-primary-100 bg-primary-50/40 p-3 space-y-3">
        <p className="text-xs font-semibold uppercase tracking-wide text-primary-700">Assign the engineer</p>
        <SearchableSelect
          label="Engineer"
          options={managerOptions}
          value={engineerUuid}
          onChange={setEngineerUuid}
          placeholder="Choose who does the repair"
          clearable
        />
        <DateTimeField
          label="First visit"
          value={visitAt}
          onChange={(e) => setVisitAt(e.target.value)}
          disabled={!engineerUuid}
        />
        <p className="text-xs text-secondary-500">
          {engineerUuid
            ? "Books their first visit — it shows in the engineer's My Work straight away."
            : 'Pick an engineer to book their visit now, or leave blank and schedule it later.'}
        </p>
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <SearchableSelect
          label="Service manager"
          options={managerOptions}
          value={managerUuid}
          onChange={setManagerUuid}
          placeholder="Unassigned"
          clearable
        />
        <DateTimeField label="Due date" mode="date" value={dueDate} onChange={(e) => setDueDate(e.target.value)} />
      </div>
      <div className="flex justify-end gap-2 -mx-5 sm:-mx-6 px-5 sm:px-6 pt-4 mt-5 border-t border-secondary-200">
        <Button type="button" variant="ghost" onClick={onClose}>
          Cancel
        </Button>
        <Button type="submit" isLoading={saving}>
          {engineerUuid ? 'Create & assign' : 'Create job'}
        </Button>
      </div>
    </form>
  );
}

export default ConvertToJobModal;

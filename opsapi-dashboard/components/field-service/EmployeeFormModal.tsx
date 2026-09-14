'use client';

import React, { useEffect, useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { Modal, Button, Input, SearchableSelect } from '@/components/ui';
import { fieldService, type FsEmployee, type FsEngineer } from '@/services/field-service.service';
import { apiError, optional, CheckboxField } from './shared';

interface EmployeeFormModalProps {
  isOpen: boolean;
  employee?: FsEmployee | null;
  onClose: () => void;
  onSaved: (employee: FsEmployee) => void;
}

const EMPTY = {
  user_uuid: '',
  employee_code: '',
  job_title: '',
  phone: '',
  email: '',
  region: '',
  skills: '',
  hourly_cost_rate: '',
  is_engineer: true,
  is_active: true,
};

type EmployeeForm = typeof EMPTY;

function formFromEmployee(employee?: FsEmployee | null): EmployeeForm {
  if (!employee) return { ...EMPTY };
  return {
    user_uuid: employee.user_uuid || '',
    employee_code: employee.employee_code || '',
    job_title: employee.job_title || '',
    phone: employee.phone || '',
    email: employee.email || '',
    region: employee.region || '',
    skills: (employee.skills || []).join(', '),
    hourly_cost_rate: employee.hourly_cost_rate != null ? String(employee.hourly_cost_rate) : '',
    is_engineer: !!employee.is_engineer,
    is_active: !!employee.is_active,
  };
}

export function EmployeeFormModal(props: EmployeeFormModalProps) {
  const title = props.employee ? 'Edit employee' : 'New employee';
  return (
    <Modal isOpen={props.isOpen} onClose={props.onClose} title={title} size="lg">
      {props.isOpen && <EmployeeForm {...props} />}
    </Modal>
  );
}

function EmployeeForm({ employee, onClose, onSaved }: EmployeeFormModalProps) {
  const [form, setForm] = useState<EmployeeForm>(() => formFromEmployee(employee));
  const [members, setMembers] = useState<FsEngineer[]>([]);
  const [saving, setSaving] = useState(false);
  const isEdit = !!employee;

  useEffect(() => {
    // Only needed when linking a new employee to an existing member.
    if (isEdit) return;
    fieldService.getEngineers().then(setMembers).catch(() => setMembers([]));
  }, [isEdit]);

  const memberOptions = useMemo(
    () => members.map((m) => ({ value: m.uuid, label: m.name || m.email, hint: m.email })),
    [members]
  );

  const set = (key: keyof EmployeeForm) => (e: React.ChangeEvent<HTMLInputElement>) =>
    setForm((f) => ({ ...f, [key]: e.target.value }));

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!isEdit && !form.user_uuid) {
      toast.error('Select the workspace member to link');
      return;
    }
    setSaving(true);
    const payload: Record<string, unknown> = {
      is_engineer: form.is_engineer,
      is_active: form.is_active,
      // Backend accepts a comma-separated string; empty clears to [].
      skills: form.skills.trim(),
      hourly_cost_rate: form.hourly_cost_rate.trim(),
    };
    if (!isEdit) payload.user_uuid = form.user_uuid;
    for (const key of ['employee_code', 'job_title', 'phone', 'email', 'region'] as const) {
      // On edit send empty strings so cleared fields are cleared server-side.
      payload[key] = isEdit ? form[key].trim() : optional(form[key]);
    }
    try {
      const saved = employee
        ? await fieldService.updateEmployee(employee.uuid, payload)
        : await fieldService.createEmployee(payload);
      toast.success(employee ? 'Employee updated' : 'Employee added');
      onSaved(saved);
      onClose();
    } catch (err) {
      toast.error(apiError(err, 'Failed to save employee'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <form onSubmit={submit} className="space-y-4">
      {isEdit ? (
        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">Login</label>
          <p className="text-sm text-secondary-800">{employee?.user_name || '—'}</p>
          {employee?.user_email && <p className="text-xs text-secondary-500">{employee.user_email}</p>}
        </div>
      ) : (
        <SearchableSelect
          label="Workspace member *"
          options={memberOptions}
          value={form.user_uuid}
          onChange={(v) => setForm((f) => ({ ...f, user_uuid: v }))}
          placeholder="Select the member to link"
        />
      )}
      {!isEdit && (
        <p className="text-xs text-secondary-500 -mt-2">
          The engineer must already be a member of this workspace (invite them first). This profile links to their login.
        </p>
      )}

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <Input label="Job title" value={form.job_title} onChange={set('job_title')} placeholder="e.g. Senior Engineer" />
        <Input label="Employee code" value={form.employee_code} onChange={set('employee_code')} placeholder="e.g. EMP-001" />
        <Input label="Phone" value={form.phone} onChange={set('phone')} />
        <Input label="Email" type="email" value={form.email} onChange={set('email')} />
        <Input label="Region / team" value={form.region} onChange={set('region')} />
        <Input
          label="Hourly cost rate"
          value={form.hourly_cost_rate}
          onChange={set('hourly_cost_rate')}
          inputMode="decimal"
          placeholder="Internal cost (£/h)"
        />
      </div>
      <Input
        label="Skills"
        value={form.skills}
        onChange={set('skills')}
        placeholder="Comma-separated, e.g. F-Gas, Electrical, HVAC"
      />

      <div className="flex flex-wrap gap-6 pt-1">
        <CheckboxField
          label="Engineer"
          hint="Can be assigned to site visits"
          checked={form.is_engineer}
          onChange={(v) => setForm((f) => ({ ...f, is_engineer: v }))}
        />
        <CheckboxField
          label="Active"
          hint="Available for new work"
          checked={form.is_active}
          onChange={(v) => setForm((f) => ({ ...f, is_active: v }))}
        />
      </div>

      <div className="flex justify-end gap-2">
        <Button type="button" variant="ghost" onClick={onClose}>
          Cancel
        </Button>
        <Button type="submit" isLoading={saving}>
          {employee ? 'Save changes' : 'Add employee'}
        </Button>
      </div>
    </form>
  );
}

export default EmployeeFormModal;

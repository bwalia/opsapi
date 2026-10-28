'use client';

import React, { useEffect, useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { Plus, X } from 'lucide-react';
import { Modal, Button, Input, SearchableSelect } from '@/components/ui';
import { useMenuStore } from '@/store/menu.store';
import { employeeService, type FsEmployee, type EmployeeCandidate } from '@/services/employees.service';
import { apiError, optional, CheckboxField } from '@/components/field-service/shared';

/** Field-service extras (engineer flag, F-Gas) only make sense where this workspace has field service. */
export const useFieldServiceOn = () =>
  useMenuStore((s) => s.menu.some((m) => m.module === 'fs_jobs' || m.module === 'fs_visits'));

/** Anything else a workspace wants to keep about someone, whatever its industry ("Licence no.", "Shift"…). */
type Detail = { label: string; value: string };

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
  fgas_certificate_no: '',
  hourly_cost_rate: '',
  is_engineer: false,
  is_active: true,
  details: [] as Detail[],
};

type EmployeeForm = typeof EMPTY;

function formFromEmployee(employee?: FsEmployee | null): EmployeeForm {
  if (!employee) return { ...EMPTY };
  return {
    user_uuid: employee.user_uuid || '',
    employee_code: employee.employee_code || '',
    job_title: employee.job_title || '',
    phone: employee.phone || '',
    email: employee.email || employee.user_email || '',
    region: employee.region || '',
    skills: (employee.skills || []).join(', '),
    fgas_certificate_no: employee.fgas_certificate_no || '',
    hourly_cost_rate: employee.hourly_cost_rate != null ? String(employee.hourly_cost_rate) : '',
    is_engineer: !!employee.is_engineer,
    is_active: !!employee.is_active,
    details: Array.isArray(employee.metadata?.details) ? (employee.metadata.details as Detail[]) : [],
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
  const [members, setMembers] = useState<EmployeeCandidate[]>([]);
  const [saving, setSaving] = useState(false);
  const isEdit = !!employee;
  const fieldService = useFieldServiceOn();

  useEffect(() => {
    // Only needed when linking a new employee to an existing member.
    if (isEdit) return;
    employeeService.getCandidates().then(setMembers).catch(() => setMembers([]));
  }, [isEdit]);

  const memberOptions = useMemo(
    () => members.map((m) => ({ value: m.uuid, label: m.name || m.email, hint: m.email })),
    [members]
  );

  const set = (key: keyof EmployeeForm) => (e: React.ChangeEvent<HTMLInputElement>) =>
    setForm((f) => ({ ...f, [key]: e.target.value }));
  const setDetail = (i: number, patch: Partial<Detail>) =>
    setForm((f) => ({ ...f, details: f.details.map((d, j) => (j === i ? { ...d, ...patch } : d)) }));

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
      metadata: {
        ...(employee?.metadata || {}),
        details: form.details
          .map((d) => ({ label: d.label.trim(), value: d.value.trim() }))
          .filter((d) => d.label && d.value),
      },
    };
    if (!isEdit) payload.user_uuid = form.user_uuid;
    const keys = ['employee_code', 'job_title', 'phone', 'email', 'region'] as const;
    for (const key of fieldService ? [...keys, 'fgas_certificate_no' as const] : keys) {
      // On edit send empty strings so cleared fields are cleared server-side.
      payload[key] = isEdit ? form[key].trim() : optional(form[key]);
    }
    try {
      const saved = employee
        ? await employeeService.updateEmployee(employee.uuid, payload)
        : await employeeService.createEmployee(payload);
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
          They must already be a member of this workspace (invite them first). This profile links to their login.
        </p>
      )}

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <Input label="Job title" value={form.job_title} onChange={set('job_title')} placeholder="e.g. Accountant, Developer" />
        <Input label="Employee code" value={form.employee_code} onChange={set('employee_code')} placeholder="e.g. EMP-001" />
        <Input label="Phone" value={form.phone} onChange={set('phone')} />
        <Input label="Email" type="email" value={form.email} onChange={set('email')} />
        <Input label="Team" value={form.region} onChange={set('region')} placeholder="e.g. Finance, North office" />
        <Input
          label="Hourly cost"
          value={form.hourly_cost_rate}
          onChange={set('hourly_cost_rate')}
          inputMode="decimal"
          placeholder="What an hour of their time costs you (£)"
        />
      </div>
      <Input
        label="Skills"
        value={form.skills}
        onChange={set('skills')}
        placeholder="Separate with commas, e.g. Payroll, Excel, React"
      />
      <CheckboxField
        label="Active"
        hint="Available for new work"
        checked={form.is_active}
        onChange={(v) => setForm((f) => ({ ...f, is_active: v }))}
      />

      {fieldService && (
        <div className="rounded-xl border border-secondary-200 p-3 space-y-4">
          <p className="text-xs font-semibold uppercase tracking-wide text-secondary-400">Field service</p>
          <CheckboxField
            label="Field engineer"
            hint="Can be sent on site visits"
            checked={form.is_engineer}
            onChange={(v) => setForm((f) => ({ ...f, is_engineer: v }))}
          />
          <Input
            label="F-Gas certificate no."
            value={form.fgas_certificate_no}
            onChange={set('fgas_certificate_no')}
            placeholder="Refrigerant handling cert"
          />
        </div>
      )}

      <div className="space-y-2">
        <p className="text-sm font-medium text-secondary-700">Additional information</p>
        <p className="text-xs text-secondary-500 -mt-1">Anything else you keep about them, e.g. Licence no., Shift, Start date.</p>
        {form.details.map((d, i) => (
          <div key={i} className="flex items-center gap-2">
            <div className="w-2/5">
              <Input
                aria-label="What it is"
                value={d.label}
                placeholder="e.g. Licence no."
                onChange={(e) => setDetail(i, { label: e.target.value })}
              />
            </div>
            <div className="flex-1">
              <Input aria-label="Value" value={d.value} onChange={(e) => setDetail(i, { value: e.target.value })} />
            </div>
            <button
              type="button"
              aria-label="Remove this line"
              className="rounded p-1.5 text-secondary-500 hover:bg-secondary-100"
              onClick={() => setForm((f) => ({ ...f, details: f.details.filter((_, j) => j !== i) }))}
            >
              <X className="h-4 w-4" />
            </button>
          </div>
        ))}
        <Button
          type="button"
          size="sm"
          variant="ghost"
          leftIcon={<Plus className="h-4 w-4" />}
          onClick={() => setForm((f) => ({ ...f, details: [...f.details, { label: '', value: '' }] }))}
        >
          Add a line
        </Button>
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

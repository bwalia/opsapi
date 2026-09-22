'use client';

/**
 * Add team member — one step for a non-technical admin. Creates the login, adds
 * them to the workspace with one of the workspace's own roles, and (optionally)
 * a staff/engineer profile. On success it shows a temporary password to hand
 * over; they also get a welcome email. Generic (not field-service-specific): the
 * roles come from this workspace, and the engineer fields are an explicit opt-in.
 */

import React, { useEffect, useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { CheckCircle2, Copy } from 'lucide-react';
import { Modal, Button, Input, Select } from '@/components/ui';
import { employeeService } from '@/services/employees.service';
import { namespaceService } from '@/services/namespace.service';
import { apiError, optional, CheckboxField } from '@/components/field-service/shared';
import type { NamespaceRole } from '@/types';

interface Props {
  isOpen: boolean;
  onClose: () => void;
  onCreated: () => void;
}

export function TeamMemberModal({ isOpen, onClose, onCreated }: Props) {
  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title="Add team member"
      description="Create their login, role and profile in one step"
      size="2xl"
    >
      {isOpen && <TeamMemberForm onClose={onClose} onCreated={onCreated} />}
    </Modal>
  );
}

const EMPTY = {
  first_name: '',
  last_name: '',
  email: '',
  role_name: '',
  phone: '',
  job_title: '',
  skills: '',
  fgas_certificate_no: '',
  hourly_cost_rate: '',
};

function TeamMemberForm({ onClose, onCreated }: { onClose: () => void; onCreated: () => void }) {
  const [form, setForm] = useState(EMPTY);
  const [roles, setRoles] = useState<NamespaceRole[]>([]);
  const [rolesLoaded, setRolesLoaded] = useState(false);
  const [isEngineer, setIsEngineer] = useState(false);
  const [saving, setSaving] = useState(false);
  const [done, setDone] = useState<{ name: string; email: string; temp_password: string } | null>(null);

  // The role choices are this workspace's own roles (never a hardcoded set).
  // Owner is excluded — you don't onboard someone straight to workspace owner.
  useEffect(() => {
    let cancelled = false;
    namespaceService
      .getRoles()
      .then((all) => {
        if (cancelled) return;
        const assignable = all.filter((r) => r.role_name !== 'owner');
        setRoles(assignable);
        setForm((f) => (f.role_name ? f : { ...f, role_name: assignable[0]?.role_name ?? '' }));
      })
      .catch(() => {})
      .finally(() => {
        if (!cancelled) setRolesLoaded(true);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const roleOptions = useMemo(
    () => roles.map((r) => ({ value: r.role_name, label: r.display_name || r.role_name })),
    [roles]
  );

  const set = (k: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) =>
    setForm((f) => ({ ...f, [k]: e.target.value }));

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!form.first_name.trim()) {
      toast.error('Enter their first name');
      return;
    }
    if (!form.email.trim()) {
      toast.error('Enter their email');
      return;
    }
    if (!form.role_name) {
      toast.error('Pick a role');
      return;
    }
    setSaving(true);
    try {
      const res = await employeeService.createTeamMember({
        first_name: form.first_name.trim(),
        last_name: optional(form.last_name),
        email: form.email.trim(),
        role_name: form.role_name,
        phone: optional(form.phone),
        job_title: optional(form.job_title),
        is_engineer: isEngineer,
        // Engineer-only detail; sent only when they're flagged as a field engineer.
        skills: isEngineer ? optional(form.skills) : undefined,
        fgas_certificate_no: isEngineer ? optional(form.fgas_certificate_no) : undefined,
        hourly_cost_rate: isEngineer ? optional(form.hourly_cost_rate) : undefined,
        login_url: typeof window !== 'undefined' ? `${window.location.origin}/login` : undefined,
      });
      setDone({ name: res.name || form.first_name.trim(), email: res.email, temp_password: res.temp_password });
      onCreated();
    } catch (err) {
      toast.error(apiError(err, 'Could not add the team member'));
    } finally {
      setSaving(false);
    }
  };

  if (done) {
    const copy = () => {
      navigator.clipboard?.writeText(done.temp_password).then(
        () => toast.success('Password copied'),
        () => toast.error('Could not copy')
      );
    };
    return (
      <div className="space-y-4">
        <div className="flex items-start gap-3 rounded-xl border border-emerald-200 bg-emerald-50 p-4">
          <CheckCircle2 className="w-5 h-5 text-emerald-600 mt-0.5 shrink-0" />
          <div>
            <p className="font-semibold text-emerald-900">{done.name} is ready</p>
            <p className="text-sm text-emerald-800 mt-1">
              They&apos;ve been emailed a welcome with sign-in instructions. Give them the temporary password below and
              ask them to change it after their first login.
            </p>
          </div>
        </div>
        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1.5">Sign-in email</label>
          <div className="rounded-lg border border-secondary-200 bg-secondary-50 px-3 py-2 text-sm font-mono break-all">
            {done.email}
          </div>
        </div>
        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1.5">Temporary password</label>
          <div className="flex items-center gap-2">
            <div className="flex-1 rounded-lg border border-secondary-200 bg-secondary-50 px-3 py-2 text-sm font-mono">
              {done.temp_password}
            </div>
            <Button type="button" variant="secondary" onClick={copy} leftIcon={<Copy className="w-4 h-4" />}>
              Copy
            </Button>
          </div>
        </div>
        <div className="flex justify-end gap-2 -mx-5 sm:-mx-6 px-5 sm:px-6 pt-4 border-t border-secondary-200">
          <Button onClick={onClose}>Done</Button>
        </div>
      </div>
    );
  }

  return (
    <form onSubmit={submit} className="space-y-4">
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <Input label="First name *" value={form.first_name} onChange={set('first_name')} autoFocus />
        <Input label="Last name" value={form.last_name} onChange={set('last_name')} />
      </div>
      <Input
        label="Email *"
        type="email"
        value={form.email}
        onChange={set('email')}
        placeholder="Where they'll sign in and get their welcome"
      />
      <Select label="Role" value={form.role_name} onChange={set('role_name')} disabled={roleOptions.length === 0}>
        {roleOptions.length === 0 ? (
          <option value="">{rolesLoaded ? 'No roles available' : 'Loading roles…'}</option>
        ) : (
          roleOptions.map((o) => (
            <option key={o.value} value={o.value}>
              {o.label}
            </option>
          ))
        )}
      </Select>
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <Input label="Phone" value={form.phone} onChange={set('phone')} placeholder="Optional" />
        <Input label="Job title" value={form.job_title} onChange={set('job_title')} placeholder="Optional" />
      </div>

      <CheckboxField
        label="Field engineer"
        hint="Can be assigned to site visits (adds an engineer profile)"
        checked={isEngineer}
        onChange={setIsEngineer}
      />

      {isEngineer && (
        <div className="rounded-xl border border-secondary-200 p-3 space-y-4">
          <p className="text-xs font-semibold uppercase tracking-wide text-secondary-400">Engineer details (optional)</p>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <Input label="F-Gas certificate no." value={form.fgas_certificate_no} onChange={set('fgas_certificate_no')} />
            <Input
              label="Hourly cost rate"
              value={form.hourly_cost_rate}
              onChange={set('hourly_cost_rate')}
              inputMode="decimal"
              placeholder="Internal £/h"
            />
          </div>
          <Input
            label="Skills"
            value={form.skills}
            onChange={set('skills')}
            placeholder="Comma-separated, e.g. F-Gas, Electrical, HVAC"
          />
        </div>
      )}

      <p className="text-xs text-secondary-500">
        Creates their login, adds them to this workspace with the role above, and emails them a welcome. You&apos;ll get
        a temporary password to hand over.
      </p>

      <div className="flex justify-end gap-2 -mx-5 sm:-mx-6 px-5 sm:px-6 pt-4 border-t border-secondary-200">
        <Button type="button" variant="ghost" onClick={onClose}>
          Cancel
        </Button>
        <Button type="submit" isLoading={saving}>
          Add team member
        </Button>
      </div>
    </form>
  );
}

export default TeamMemberModal;

'use client';

import React, { useEffect, useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { Plus } from 'lucide-react';
import { Modal, Button, Input, Textarea, SearchableSelect, Select } from '@/components/ui';
import {
  fieldService,
  type FsAccountLookup,
  type FsContactLookup,
  type FsEngineer,
  type FsJobDetail,
  type FsJobType,
  type FsSite,
} from '@/services/field-service.service';
import { PRIORITY_OPTIONS, apiError, optional, optionalNumber } from './shared';
import SiteFormModal from './SiteFormModal';

interface JobFormModalProps {
  isOpen: boolean;
  /** When set the modal edits this job; otherwise it creates a new one. */
  job?: FsJobDetail | null;
  onClose: () => void;
  onSaved: (job: FsJobDetail) => void;
}

export function JobFormModal(props: JobFormModalProps) {
  return (
    <Modal isOpen={props.isOpen} onClose={props.onClose} title={props.job ? `Edit ${props.job.job_number}` : 'New service job'} size="xl">
      {props.isOpen && <JobForm {...props} />}
    </Modal>
  );
}

function JobForm({ job, onClose, onSaved }: JobFormModalProps) {
  const [form, setForm] = useState(() => ({
    title: job?.title || '',
    job_type_uuid: job?.job_type_uuid || '',
    account_uuid: job?.account_uuid || '',
    contact_uuid: job?.contact_uuid || '',
    site_uuid: job?.site_uuid || '',
    priority: job?.priority || 'normal',
    service_manager_uuid: job?.service_manager_uuid || '',
    due_date: job?.due_date ? String(job.due_date).slice(0, 10) : '',
    customer_reference: job?.customer_reference || '',
    hourly_rate: job?.hourly_rate != null ? String(job.hourly_rate) : '',
    estimated_hours: job?.estimated_hours != null ? String(job.estimated_hours) : '',
    description: job?.description || '',
    notes: job?.notes || '',
  }));
  const [jobTypes, setJobTypes] = useState<FsJobType[]>([]);
  const [accounts, setAccounts] = useState<FsAccountLookup[]>([]);
  const [contacts, setContacts] = useState<FsContactLookup[]>([]);
  const [sites, setSites] = useState<FsSite[]>([]);
  const [engineers, setEngineers] = useState<FsEngineer[]>([]);
  const [siteModalOpen, setSiteModalOpen] = useState(false);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    fieldService.getJobTypes().then(setJobTypes).catch(() => setJobTypes([]));
    fieldService.lookupAccounts().then(setAccounts).catch(() => setAccounts([]));
    fieldService.getEngineers().then(setEngineers).catch(() => setEngineers([]));
  }, []);

  // Contacts and sites follow the chosen customer.
  useEffect(() => {
    const account = form.account_uuid || undefined;
    fieldService.lookupContacts(account).then(setContacts).catch(() => setContacts([]));
    fieldService
      .getSites({ account_uuid: account, per_page: 200 })
      .then((r) => setSites(r.data))
      .catch(() => setSites([]));
  }, [form.account_uuid]);

  const selectedType = jobTypes.find((t) => t.uuid === form.job_type_uuid);

  const accountOptions = useMemo(
    () => accounts.map((a) => ({ value: a.uuid, label: a.name, hint: a.postal_code || a.email || undefined })),
    [accounts]
  );
  const contactOptions = useMemo(
    () =>
      contacts.map((c) => ({
        value: c.uuid,
        label: `${c.first_name} ${c.last_name || ''}`.trim(),
        hint: c.email || c.phone || undefined,
      })),
    [contacts]
  );
  const siteOptions = useMemo(
    () => sites.map((s) => ({ value: s.uuid, label: s.name, hint: [s.address_line1, s.postal_code].filter(Boolean).join(', ') || undefined })),
    [sites]
  );
  const engineerOptions = useMemo(
    () => engineers.map((e) => ({ value: e.uuid, label: e.name || e.email, hint: e.email })),
    [engineers]
  );

  const setField = (key: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>) =>
    setForm((f) => ({ ...f, [key]: e.target.value }));

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!form.title.trim()) {
      toast.error('Title is required');
      return;
    }
    setSaving(true);
    // On edit, empty strings clear the field server-side; on create they are omitted.
    const pick = (v: string) => (job ? v.trim() : optional(v));
    const payload: Record<string, unknown> = {
      title: form.title.trim(),
      job_type_uuid: pick(form.job_type_uuid),
      account_uuid: pick(form.account_uuid),
      contact_uuid: pick(form.contact_uuid),
      site_uuid: pick(form.site_uuid),
      priority: form.priority,
      service_manager_uuid: pick(form.service_manager_uuid),
      due_date: pick(form.due_date),
      customer_reference: pick(form.customer_reference),
      hourly_rate: job ? form.hourly_rate.trim() : optionalNumber(form.hourly_rate),
      estimated_hours: job ? form.estimated_hours.trim() : optionalNumber(form.estimated_hours),
      description: pick(form.description),
    };
    if (job) payload.notes = form.notes.trim();
    try {
      const saved = job ? await fieldService.updateJob(job.uuid, payload) : await fieldService.createJob(payload);
      toast.success(job ? 'Job updated' : `Job ${saved.job_number} created`);
      onSaved(saved);
      onClose();
    } catch (err) {
      toast.error(apiError(err, 'Failed to save job'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <>
      <form onSubmit={submit} className="space-y-4">
        <Input label="Title *" value={form.title} onChange={setField('title')} placeholder="e.g. Annual boiler service" autoFocus />

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div>
            <SearchableSelect
              label="Job type"
              options={jobTypes.map((t) => ({ value: t.uuid, label: t.name, hint: t.phase_count ? `${t.phase_count} phases` : undefined }))}
              value={form.job_type_uuid}
              onChange={(v) => setForm((f) => ({ ...f, job_type_uuid: v }))}
              placeholder="No job type"
              clearable
            />
            {!job && selectedType && (
              <p className="mt-1 text-xs text-secondary-500">
                {selectedType.phase_count
                  ? `${selectedType.phase_count} phase(s) will be copied from this job type.`
                  : 'This job type has no phase templates yet.'}
              </p>
            )}
            {job && form.job_type_uuid !== (job.job_type_uuid || '') && (
              <p className="mt-1 text-xs text-amber-600">Changing the type does not change the job&apos;s existing phases.</p>
            )}
          </div>
          <Select label="Priority" value={form.priority} onChange={setField('priority')}>
            {PRIORITY_OPTIONS.map((o) => (
              <option key={o.value} value={o.value}>
                {o.label}
              </option>
            ))}
          </Select>

          <SearchableSelect
            label="Customer"
            options={accountOptions}
            value={form.account_uuid}
            onChange={(v) => setForm((f) => ({ ...f, account_uuid: v, contact_uuid: '', site_uuid: '' }))}
            placeholder="Select customer"
            clearable
          />
          <SearchableSelect
            label="Contact"
            options={contactOptions}
            value={form.contact_uuid}
            onChange={(v) => setForm((f) => ({ ...f, contact_uuid: v }))}
            placeholder={form.account_uuid ? 'Select contact' : 'Select a customer first (or any contact)'}
            clearable
          />

          <div className="sm:col-span-2">
            <div className="flex items-end gap-2">
              <div className="flex-1">
                <SearchableSelect
                  label="Site"
                  options={siteOptions}
                  value={form.site_uuid}
                  onChange={(v) => setForm((f) => ({ ...f, site_uuid: v }))}
                  placeholder={sites.length ? 'Select site' : 'No sites yet'}
                  clearable
                />
              </div>
              <Button type="button" variant="ghost" onClick={() => setSiteModalOpen(true)} title="Add a site">
                <Plus className="w-4 h-4 mr-1" /> New site
              </Button>
            </div>
          </div>

          <SearchableSelect
            label="Service manager"
            options={engineerOptions}
            value={form.service_manager_uuid}
            onChange={(v) => setForm((f) => ({ ...f, service_manager_uuid: v }))}
            placeholder={job ? 'Unassigned' : 'Me (default)'}
            clearable
          />
          <Input label="Due date" type="date" value={form.due_date} onChange={setField('due_date')} />
          <Input label="Customer reference / PO" value={form.customer_reference} onChange={setField('customer_reference')} />
          <div className="grid grid-cols-2 gap-2">
            <Input
              label="Hourly rate"
              value={form.hourly_rate}
              onChange={setField('hourly_rate')}
              inputMode="decimal"
              placeholder={selectedType?.default_hourly_rate ? String(selectedType.default_hourly_rate) : '0.00'}
            />
            <Input label="Est. hours" value={form.estimated_hours} onChange={setField('estimated_hours')} inputMode="decimal" />
          </div>
        </div>

        <Textarea label="Description" value={form.description} onChange={setField('description')} rows={3} placeholder="What needs doing?" />
        {job && <Textarea label="Internal notes" value={form.notes} onChange={setField('notes')} rows={2} />}

        <div className="flex justify-end gap-2">
          <Button type="button" variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button type="submit" isLoading={saving}>
            {job ? 'Save changes' : 'Create job'}
          </Button>
        </div>
      </form>

      <SiteFormModal
        isOpen={siteModalOpen}
        defaultAccountUuid={form.account_uuid || undefined}
        onClose={() => setSiteModalOpen(false)}
        onSaved={(site) => {
          setSites((prev) => [site, ...prev.filter((s) => s.uuid !== site.uuid)]);
          setForm((f) => ({ ...f, site_uuid: site.uuid, account_uuid: f.account_uuid || site.account_uuid || '' }));
        }}
      />
    </>
  );
}

export default JobFormModal;

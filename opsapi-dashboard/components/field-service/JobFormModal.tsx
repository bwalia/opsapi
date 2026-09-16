'use client';

import React, { useEffect, useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { Modal, Button, Input, Textarea, SearchableSelect, Select, DateTimeField } from '@/components/ui';
import {
  fieldService,
  type FsEngineer,
  type FsJobDetail,
  type FsJobType,
} from '@/services/field-service.service';
import { customersService } from '@/services/customers.service';
import { productsService } from '@/services/products.service';
import type { Customer, StoreProduct } from '@/types';
import { SitePicker, siteToAddress } from './SitePicker';
import { PRIORITY_OPTIONS, apiError, optional, optionalNumber } from './shared';

interface JobFormModalProps {
  isOpen: boolean;
  /** When set the modal edits this job; otherwise it creates a new one. */
  job?: FsJobDetail | null;
  onClose: () => void;
  onSaved: (job: FsJobDetail) => void;
}

function customerLabel(c: Customer): string {
  return `${c.first_name || ''} ${c.last_name || ''}`.trim() || c.email;
}

export function JobFormModal(props: JobFormModalProps) {
  return (
    <Modal
      isOpen={props.isOpen}
      onClose={props.onClose}
      title={props.job ? `Edit ${props.job.job_number}` : 'New service job'}
      description={props.job ? undefined : 'Create a job and assign the engineer who does the repair'}
      size="3xl"
    >
      {props.isOpen && <JobForm {...props} />}
    </Modal>
  );
}

function JobForm({ job, onClose, onSaved }: JobFormModalProps) {
  const [form, setForm] = useState(() => ({
    title: job?.title || '',
    job_type_uuid: job?.job_type_uuid || '',
    customer_uuid: job?.customer_uuid || '',
    site_uuid: job?.site_uuid || '',
    product_uuid: job?.product_uuid || '',
    product_ref: job?.product_ref || '',
    service_address: job?.service_address || '',
    service_postcode: job?.service_postcode || '',
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
  const [customers, setCustomers] = useState<Customer[]>([]);
  const [products, setProducts] = useState<StoreProduct[]>([]);
  const [engineers, setEngineers] = useState<FsEngineer[]>([]);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    fieldService.getJobTypes().then(setJobTypes).catch(() => setJobTypes([]));
    fieldService.getEngineers().then(setEngineers).catch(() => setEngineers([]));
    customersService.getCustomers({ perPage: 200 }).then((r) => setCustomers(r.data || [])).catch(() => setCustomers([]));
    productsService.getStoreProducts({ perPage: 200 }).then((r) => setProducts(r.data || [])).catch(() => setProducts([]));
  }, []);

  const selectedType = jobTypes.find((t) => t.uuid === form.job_type_uuid);

  const customerOptions = useMemo(
    () => customers.map((c) => ({ value: c.uuid, label: customerLabel(c), hint: c.email || undefined })),
    [customers]
  );
  const productOptions = useMemo(
    () => products.map((p) => ({ value: p.uuid, label: p.name, hint: p.sku || undefined })),
    [products]
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
      customer_uuid: pick(form.customer_uuid),
      site_uuid: pick(form.site_uuid),
      product_uuid: pick(form.product_uuid),
      product_ref: pick(form.product_ref),
      service_address: pick(form.service_address),
      service_postcode: pick(form.service_postcode),
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
    <form onSubmit={submit} className="space-y-4">
      <Input label="Title *" value={form.title} onChange={setField('title')} placeholder="e.g. AC repair — Ward 5" autoFocus />

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
          options={customerOptions}
          value={form.customer_uuid}
          onChange={(v) => setForm((f) => ({ ...f, customer_uuid: v, site_uuid: '' }))}
          placeholder="Select customer"
          clearable
        />
        <SitePicker
          customerUuid={form.customer_uuid}
          value={form.site_uuid}
          onChange={(v, site) => setForm((f) => ({ ...f, site_uuid: v, ...(site ? siteToAddress(site) : {}) }))}
        />
        <SearchableSelect
          label="Product (the item)"
          options={productOptions}
          value={form.product_uuid}
          onChange={(v) => setForm((f) => ({ ...f, product_uuid: v }))}
          placeholder="Select product"
          clearable
        />
        <Input label="Unit serial / reference" value={form.product_ref} onChange={setField('product_ref')} />
        <SearchableSelect
          label="Service manager"
          options={engineerOptions}
          value={form.service_manager_uuid}
          onChange={(v) => setForm((f) => ({ ...f, service_manager_uuid: v }))}
          placeholder={job ? 'Unassigned' : 'Me (default)'}
          clearable
        />

        <div className="sm:col-span-2 grid grid-cols-1 sm:grid-cols-3 gap-4">
          <div className="sm:col-span-2">
            <Input label="Service address" value={form.service_address} onChange={setField('service_address')} placeholder="Where the engineer visits" />
          </div>
          <Input label="Postcode" value={form.service_postcode} onChange={setField('service_postcode')} />
        </div>

        <DateTimeField label="Due date" mode="date" value={form.due_date} onChange={setField('due_date')} />
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

      <div className="flex justify-end gap-2 -mx-5 sm:-mx-6 px-5 sm:px-6 pt-4 mt-5 border-t border-secondary-200">
        <Button type="button" variant="ghost" onClick={onClose}>
          Cancel
        </Button>
        <Button type="submit" isLoading={saving}>
          {job ? 'Save changes' : 'Create job'}
        </Button>
      </div>
    </form>
  );
}

export default JobFormModal;

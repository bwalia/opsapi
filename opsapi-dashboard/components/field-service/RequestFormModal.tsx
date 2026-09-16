'use client';

import React, { useEffect, useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { Modal, Button, Input, Textarea, SearchableSelect, DateTimeField } from '@/components/ui';
import {
  fieldService,
  toApiDateTime,
  toLocalInputValue,
  type FsServiceRequest,
  type JobPriority,
  type RequestChannel,
} from '@/services/field-service.service';
import { customersService } from '@/services/customers.service';
import { productsService } from '@/services/products.service';
import type { Customer, StoreProduct } from '@/types';
import { SitePicker, siteToAddress } from './SitePicker';
import { apiError, optional, PRIORITY_OPTIONS, CHANNEL_LABELS } from './shared';

interface RequestFormModalProps {
  isOpen: boolean;
  request?: FsServiceRequest | null;
  onClose: () => void;
  onSaved: (request: FsServiceRequest) => void;
}

const CHANNEL_OPTIONS = (Object.keys(CHANNEL_LABELS) as RequestChannel[]).map((c) => ({
  value: c,
  label: CHANNEL_LABELS[c],
}));

function customerLabel(c: Customer): string {
  return `${c.first_name || ''} ${c.last_name || ''}`.trim() || c.email;
}

const EMPTY = {
  title: '',
  description: '',
  priority: 'normal' as JobPriority,
  channel: 'phone' as RequestChannel,
  fault_category: '',
  reported_by: '',
  customer_uuid: '',
  site_uuid: '',
  product_uuid: '',
  product_ref: '',
  service_address: '',
  service_postcode: '',
  sla_response_due_at: '',
  sla_resolve_due_at: '',
};

type RequestForm = typeof EMPTY;

function formFromRequest(r?: FsServiceRequest | null): RequestForm {
  if (!r) return { ...EMPTY };
  return {
    title: r.title || '',
    description: r.description || '',
    priority: r.priority || 'normal',
    channel: r.channel || 'phone',
    fault_category: r.fault_category || '',
    reported_by: r.reported_by || '',
    customer_uuid: r.customer_uuid || '',
    site_uuid: r.site_uuid || '',
    product_uuid: r.product_uuid || '',
    product_ref: r.product_ref || '',
    service_address: r.service_address || '',
    service_postcode: r.service_postcode || '',
    sla_response_due_at: toLocalInputValue(r.sla_response_due_at),
    sla_resolve_due_at: toLocalInputValue(r.sla_resolve_due_at),
  };
}

export function RequestFormModal(props: RequestFormModalProps) {
  const title = props.request ? `Edit ${props.request.request_number}` : 'New service request';
  return (
    <Modal
      isOpen={props.isOpen}
      onClose={props.onClose}
      title={title}
      description="Log a customer complaint. It becomes a job once assigned."
      size="3xl"
    >
      {props.isOpen && <RequestForm {...props} />}
    </Modal>
  );
}

/** Grouped section within a form modal — a small heading + hairline divider. */
function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section>
      <h3 className="text-xs font-semibold uppercase tracking-wide text-secondary-400 pb-2 mb-3 border-b border-secondary-100">
        {title}
      </h3>
      {children}
    </section>
  );
}

function RequestForm({ request, onClose, onSaved }: RequestFormModalProps) {
  const [form, setForm] = useState<RequestForm>(() => formFromRequest(request));
  const [customers, setCustomers] = useState<Customer[]>([]);
  const [products, setProducts] = useState<StoreProduct[]>([]);
  const [categories, setCategories] = useState<string[]>([]);
  const [saving, setSaving] = useState(false);
  const isEdit = !!request;

  useEffect(() => {
    customersService.getCustomers({ perPage: 200 }).then((r) => setCustomers(r.data || [])).catch(() => setCustomers([]));
    productsService.getStoreProducts({ perPage: 200 }).then((r) => setProducts(r.data || [])).catch(() => setProducts([]));
    fieldService.getFaultCategories().then(setCategories).catch(() => setCategories([]));
  }, []);

  const customerOptions = useMemo(
    () => customers.map((c) => ({ value: c.uuid, label: customerLabel(c), hint: c.email || undefined })),
    [customers]
  );
  const productOptions = useMemo(
    () => products.map((p) => ({ value: p.uuid, label: p.name, hint: p.sku || undefined })),
    [products]
  );
  // Include the current value so an existing/just-created category still shows
  // as selected even before the catalog list contains it.
  const categoryOptions = useMemo(() => {
    const set = new Set(categories);
    if (form.fault_category) set.add(form.fault_category);
    return Array.from(set).map((c) => ({ value: c, label: c }));
  }, [categories, form.fault_category]);

  const set = (key: keyof RequestForm) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) =>
    setForm((f) => ({ ...f, [key]: e.target.value }));

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!form.title.trim()) {
      toast.error('A short title is required');
      return;
    }
    setSaving(true);
    const payload: Record<string, unknown> = {
      title: form.title.trim(),
      priority: form.priority,
      channel: form.channel,
      description: isEdit ? form.description.trim() : optional(form.description),
      fault_category: isEdit ? form.fault_category.trim() : optional(form.fault_category),
      reported_by: isEdit ? form.reported_by.trim() : optional(form.reported_by),
      product_ref: isEdit ? form.product_ref.trim() : optional(form.product_ref),
      service_address: isEdit ? form.service_address.trim() : optional(form.service_address),
      service_postcode: isEdit ? form.service_postcode.trim() : optional(form.service_postcode),
      customer_uuid: form.customer_uuid || (isEdit ? '' : undefined),
      site_uuid: form.site_uuid || (isEdit ? '' : undefined),
      product_uuid: form.product_uuid || (isEdit ? '' : undefined),
      sla_response_due_at: form.sla_response_due_at ? toApiDateTime(form.sla_response_due_at) : (isEdit ? '' : undefined),
      sla_resolve_due_at: form.sla_resolve_due_at ? toApiDateTime(form.sla_resolve_due_at) : (isEdit ? '' : undefined),
    };
    try {
      const saved = request
        ? await fieldService.updateRequest(request.uuid, payload)
        : await fieldService.createRequest(payload);
      toast.success(request ? 'Request updated' : 'Request logged');
      onSaved(saved);
      onClose();
    } catch (err) {
      toast.error(apiError(err, 'Failed to save request'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <form onSubmit={submit} className="space-y-6">
      <div className="space-y-4">
        <Input label="What's the problem? *" value={form.title} onChange={set('title')} placeholder="e.g. AC not cooling" />
        <Textarea label="Details" value={form.description} onChange={set('description')} placeholder="What did the caller report?" rows={3} />
      </div>

      <Section title="Customer & location">
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <SearchableSelect
            label="Customer"
            options={customerOptions}
            value={form.customer_uuid}
            onChange={(v) => setForm((f) => ({ ...f, customer_uuid: v, site_uuid: '' }))}
            placeholder="No customer"
            clearable
          />
          <SitePicker
            customerUuid={form.customer_uuid}
            value={form.site_uuid}
            onChange={(v, site) => setForm((f) => ({ ...f, site_uuid: v, ...(site ? siteToAddress(site) : {}) }))}
          />
          <div className="sm:col-span-2 grid grid-cols-1 sm:grid-cols-3 gap-4">
            <div className="sm:col-span-2">
              <Input label="Service address" value={form.service_address} onChange={set('service_address')} placeholder="Where the engineer visits" />
            </div>
            <Input label="Postcode" value={form.service_postcode} onChange={set('service_postcode')} />
          </div>
        </div>
      </Section>

      <Section title="Equipment">
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <SearchableSelect
            label="Product (the faulty item)"
            options={productOptions}
            value={form.product_uuid}
            onChange={(v) => setForm((f) => ({ ...f, product_uuid: v }))}
            placeholder="No product"
            clearable
          />
          <Input label="Unit serial / reference" value={form.product_ref} onChange={set('product_ref')} />
        </div>
      </Section>

      <Section title="Logging details">
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <SearchableSelect
            label="Priority"
            options={PRIORITY_OPTIONS}
            value={form.priority}
            onChange={(v) => setForm((f) => ({ ...f, priority: (v as JobPriority) || 'normal' }))}
            placeholder="Priority"
          />
          <SearchableSelect
            label="Reported via"
            options={CHANNEL_OPTIONS}
            value={form.channel}
            onChange={(v) => setForm((f) => ({ ...f, channel: (v as RequestChannel) || 'phone' }))}
            placeholder="Channel"
          />
          <SearchableSelect
            label="Fault category"
            options={categoryOptions}
            value={form.fault_category}
            onChange={(v) => setForm((f) => ({ ...f, fault_category: v }))}
            placeholder="Search or add a category"
            searchPlaceholder="Search, or type a new one…"
            emptyMessage="No matches — type to create"
            creatable
            clearable
          />
          <Input label="Reported by" value={form.reported_by} onChange={set('reported_by')} placeholder="Caller's name" />
        </div>
      </Section>

      <Section title="SLA (optional)">
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <DateTimeField label="Respond by" value={form.sla_response_due_at} onChange={set('sla_response_due_at')} />
          <DateTimeField label="Resolve by" value={form.sla_resolve_due_at} onChange={set('sla_resolve_due_at')} />
        </div>
      </Section>

      <div className="flex justify-end gap-2 -mx-5 sm:-mx-6 px-5 sm:px-6 pt-4 border-t border-secondary-200">
        <Button type="button" variant="ghost" onClick={onClose}>
          Cancel
        </Button>
        <Button type="submit" isLoading={saving}>
          {request ? 'Save changes' : 'Log request'}
        </Button>
      </div>
    </form>
  );
}

export default RequestFormModal;

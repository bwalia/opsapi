'use client';

import React, { useEffect, useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { Modal, Button, Input, Textarea, SearchableSelect } from '@/components/ui';
import {
  fieldService,
  toApiDateTime,
  toLocalInputValue,
  type FsAccountLookup,
  type FsAsset,
  type FsContactLookup,
  type FsServiceRequest,
  type FsSite,
  type JobPriority,
  type RequestChannel,
} from '@/services/field-service.service';
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

const EMPTY = {
  title: '',
  description: '',
  priority: 'normal' as JobPriority,
  channel: 'phone' as RequestChannel,
  fault_category: '',
  reported_by: '',
  account_uuid: '',
  contact_uuid: '',
  site_uuid: '',
  asset_uuid: '',
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
    account_uuid: r.account_uuid || '',
    contact_uuid: r.contact_uuid || '',
    site_uuid: r.site_uuid || '',
    asset_uuid: r.asset_uuid || '',
    sla_response_due_at: toLocalInputValue(r.sla_response_due_at),
    sla_resolve_due_at: toLocalInputValue(r.sla_resolve_due_at),
  };
}

export function RequestFormModal(props: RequestFormModalProps) {
  const title = props.request ? `Edit ${props.request.request_number}` : 'New service request';
  return (
    <Modal isOpen={props.isOpen} onClose={props.onClose} title={title} size="lg">
      {props.isOpen && <RequestForm {...props} />}
    </Modal>
  );
}

function RequestForm({ request, onClose, onSaved }: RequestFormModalProps) {
  const [form, setForm] = useState<RequestForm>(() => formFromRequest(request));
  const [accounts, setAccounts] = useState<FsAccountLookup[]>([]);
  const [contacts, setContacts] = useState<FsContactLookup[]>([]);
  const [sites, setSites] = useState<FsSite[]>([]);
  const [assets, setAssets] = useState<FsAsset[]>([]);
  const [saving, setSaving] = useState(false);
  const isEdit = !!request;

  useEffect(() => {
    fieldService.lookupAccounts().then(setAccounts).catch(() => setAccounts([]));
    fieldService.lookupContacts().then(setContacts).catch(() => setContacts([]));
    fieldService.getSites({ per_page: 200 }).then((r) => setSites(r.data)).catch(() => setSites([]));
    fieldService.getAssets({ per_page: 200 }).then((r) => setAssets(r.data)).catch(() => setAssets([]));
  }, []);

  const accountOptions = useMemo(() => accounts.map((a) => ({ value: a.uuid, label: a.name })), [accounts]);
  // Related pickers narrow to the chosen customer (or show all when none is set).
  const contactOptions = useMemo(
    () =>
      contacts
        .filter((c) => !form.account_uuid || c.account_uuid === form.account_uuid)
        .map((c) => ({ value: c.uuid, label: `${c.first_name} ${c.last_name || ''}`.trim(), hint: c.email || undefined })),
    [contacts, form.account_uuid]
  );
  const siteOptions = useMemo(
    () =>
      sites
        .filter((s) => !form.account_uuid || s.account_uuid === form.account_uuid)
        .map((s) => ({ value: s.uuid, label: s.name, hint: s.city || s.postal_code || undefined })),
    [sites, form.account_uuid]
  );
  const assetOptions = useMemo(
    () =>
      assets
        .filter((a) => !form.account_uuid || a.account_uuid === form.account_uuid)
        .map((a) => ({ value: a.uuid, label: a.name, hint: a.serial_number || a.category || undefined })),
    [assets, form.account_uuid]
  );

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
      account_uuid: form.account_uuid || (isEdit ? '' : undefined),
      contact_uuid: form.contact_uuid || (isEdit ? '' : undefined),
      site_uuid: form.site_uuid || (isEdit ? '' : undefined),
      asset_uuid: form.asset_uuid || (isEdit ? '' : undefined),
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
    <form onSubmit={submit} className="space-y-4">
      <Input
        label="What's the problem? *"
        value={form.title}
        onChange={set('title')}
        placeholder="e.g. AC not cooling in Ward 5"
      />
      <Textarea
        label="Details"
        value={form.description}
        onChange={set('description')}
        placeholder="What did the caller report?"
        rows={3}
      />
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
        <Input label="Fault category" value={form.fault_category} onChange={set('fault_category')} placeholder="e.g. no_cooling" />
        <Input label="Reported by" value={form.reported_by} onChange={set('reported_by')} placeholder="Caller's name" />
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <SearchableSelect
          label="Customer"
          options={accountOptions}
          value={form.account_uuid}
          onChange={(v) => setForm((f) => ({ ...f, account_uuid: v, contact_uuid: '', site_uuid: '', asset_uuid: '' }))}
          placeholder="No customer"
          clearable
        />
        <SearchableSelect
          label="Contact"
          options={contactOptions}
          value={form.contact_uuid}
          onChange={(v) => setForm((f) => ({ ...f, contact_uuid: v }))}
          placeholder="Who called"
          clearable
        />
        <SearchableSelect
          label="Site"
          options={siteOptions}
          value={form.site_uuid}
          onChange={(v) => setForm((f) => ({ ...f, site_uuid: v }))}
          placeholder="No site"
          clearable
        />
        <SearchableSelect
          label="Faulty asset"
          options={assetOptions}
          value={form.asset_uuid}
          onChange={(v) => setForm((f) => ({ ...f, asset_uuid: v }))}
          placeholder="No asset"
          clearable
        />
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <Input
          label="Respond by (SLA)"
          type="datetime-local"
          value={form.sla_response_due_at}
          onChange={set('sla_response_due_at')}
        />
        <Input
          label="Resolve by (SLA)"
          type="datetime-local"
          value={form.sla_resolve_due_at}
          onChange={set('sla_resolve_due_at')}
        />
      </div>

      <div className="flex justify-end gap-2">
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

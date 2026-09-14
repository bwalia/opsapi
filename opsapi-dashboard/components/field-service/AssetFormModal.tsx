'use client';

import React, { useEffect, useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { Modal, Button, Input, Textarea, SearchableSelect } from '@/components/ui';
import {
  fieldService,
  type AssetStatus,
  type FsAccountLookup,
  type FsAsset,
  type FsSite,
} from '@/services/field-service.service';
import { apiError, optional } from './shared';

interface AssetFormModalProps {
  isOpen: boolean;
  asset?: FsAsset | null;
  /** Pre-select (and lock) a customer, e.g. when creating from an account. */
  defaultAccountUuid?: string;
  onClose: () => void;
  onSaved: (asset: FsAsset) => void;
}

const STATUS_OPTIONS: { value: AssetStatus; label: string }[] = [
  { value: 'active', label: 'Active' },
  { value: 'inactive', label: 'Inactive' },
  { value: 'decommissioned', label: 'Decommissioned' },
];

const EMPTY = {
  account_uuid: '',
  site_uuid: '',
  name: '',
  asset_tag: '',
  serial_number: '',
  category: '',
  manufacturer: '',
  model: '',
  location_detail: '',
  installed_at: '',
  warranty_expires_at: '',
  status: 'active' as AssetStatus,
  notes: '',
};

type AssetForm = typeof EMPTY;

function toDateInput(value?: string | null): string {
  if (!value) return '';
  return String(value).slice(0, 10);
}

function formFromAsset(asset?: FsAsset | null, accountUuid?: string): AssetForm {
  if (!asset) return { ...EMPTY, account_uuid: accountUuid || '' };
  return {
    account_uuid: asset.account_uuid || '',
    site_uuid: asset.site_uuid || '',
    name: asset.name || '',
    asset_tag: asset.asset_tag || '',
    serial_number: asset.serial_number || '',
    category: asset.category || '',
    manufacturer: asset.manufacturer || '',
    model: asset.model || '',
    location_detail: asset.location_detail || '',
    installed_at: toDateInput(asset.installed_at),
    warranty_expires_at: toDateInput(asset.warranty_expires_at),
    status: asset.status || 'active',
    notes: asset.notes || '',
  };
}

export function AssetFormModal(props: AssetFormModalProps) {
  const title = props.asset ? 'Edit asset' : 'New asset';
  return (
    <Modal isOpen={props.isOpen} onClose={props.onClose} title={title} size="lg">
      {props.isOpen && <AssetForm {...props} />}
    </Modal>
  );
}

function AssetForm({ asset, defaultAccountUuid, onClose, onSaved }: AssetFormModalProps) {
  const [form, setForm] = useState<AssetForm>(() => formFromAsset(asset, defaultAccountUuid));
  const [accounts, setAccounts] = useState<FsAccountLookup[]>([]);
  const [sites, setSites] = useState<FsSite[]>([]);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    fieldService.lookupAccounts().then(setAccounts).catch(() => setAccounts([]));
    fieldService
      .getSites({ per_page: 200 })
      .then((r) => setSites(r.data))
      .catch(() => setSites([]));
  }, []);

  const accountOptions = useMemo(
    () => accounts.map((a) => ({ value: a.uuid, label: a.name, hint: a.postal_code || a.city || undefined })),
    [accounts]
  );

  // Only offer sites belonging to the chosen customer (or all when none is set).
  const siteOptions = useMemo(
    () =>
      sites
        .filter((s) => !form.account_uuid || s.account_uuid === form.account_uuid)
        .map((s) => ({ value: s.uuid, label: s.name, hint: s.city || s.postal_code || undefined })),
    [sites, form.account_uuid]
  );

  const set = (key: keyof AssetForm) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) =>
    setForm((f) => ({ ...f, [key]: e.target.value }));

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!form.name.trim()) {
      toast.error('Asset name is required');
      return;
    }
    setSaving(true);
    const payload: Record<string, unknown> = {
      name: form.name.trim(),
      status: form.status,
      account_uuid: form.account_uuid || (asset ? '' : undefined),
      site_uuid: form.site_uuid || (asset ? '' : undefined),
    };
    for (const key of [
      'asset_tag', 'serial_number', 'category', 'manufacturer', 'model',
      'location_detail', 'installed_at', 'warranty_expires_at', 'notes',
    ] as const) {
      // On edit send empty strings so cleared fields are cleared server-side.
      payload[key] = asset ? form[key].trim() : optional(form[key]);
    }
    try {
      const saved = asset
        ? await fieldService.updateAsset(asset.uuid, payload)
        : await fieldService.createAsset(payload);
      toast.success(asset ? 'Asset updated' : 'Asset created');
      onSaved(saved);
      onClose();
    } catch (err) {
      toast.error(apiError(err, 'Failed to save asset'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <form onSubmit={submit} className="space-y-4">
      <Input
        label="Asset name *"
        value={form.name}
        onChange={set('name')}
        placeholder="e.g. Ward 3 walk-in chiller"
      />
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <SearchableSelect
          label="Customer (CRM account)"
          options={accountOptions}
          value={form.account_uuid}
          onChange={(v) => setForm((f) => ({ ...f, account_uuid: v, site_uuid: '' }))}
          placeholder="No customer"
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
        <Input label="Category" value={form.category} onChange={set('category')} placeholder="e.g. air_conditioner" />
        <SearchableSelect
          label="Status"
          options={STATUS_OPTIONS}
          value={form.status}
          onChange={(v) => setForm((f) => ({ ...f, status: (v as AssetStatus) || 'active' }))}
          placeholder="Status"
        />
        <Input label="Asset tag" value={form.asset_tag} onChange={set('asset_tag')} />
        <Input label="Serial number" value={form.serial_number} onChange={set('serial_number')} />
        <Input label="Manufacturer" value={form.manufacturer} onChange={set('manufacturer')} />
        <Input label="Model" value={form.model} onChange={set('model')} />
        <Input label="Installed on" type="date" value={form.installed_at} onChange={set('installed_at')} />
        <Input
          label="Warranty expires"
          type="date"
          value={form.warranty_expires_at}
          onChange={set('warranty_expires_at')}
        />
      </div>
      <Input
        label="Location on site"
        value={form.location_detail}
        onChange={set('location_detail')}
        placeholder="Building / floor / room"
      />
      <Textarea
        label="Notes"
        value={form.notes}
        onChange={set('notes')}
        placeholder="Anything engineers should know about this unit…"
        rows={3}
      />
      <div className="flex justify-end gap-2">
        <Button type="button" variant="ghost" onClick={onClose}>
          Cancel
        </Button>
        <Button type="submit" isLoading={saving}>
          {asset ? 'Save changes' : 'Create asset'}
        </Button>
      </div>
    </form>
  );
}

export default AssetFormModal;

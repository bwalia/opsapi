'use client';

import React, { useEffect, useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { Modal, Button, Input, Textarea, SearchableSelect } from '@/components/ui';
import { fieldService, type FsAccountLookup, type FsSite } from '@/services/field-service.service';
import { apiError, optional, optionalNumber } from './shared';

interface SiteFormModalProps {
  isOpen: boolean;
  site?: FsSite | null;
  /** Pre-select (and lock in the list) a customer, e.g. when creating from a job. */
  defaultAccountUuid?: string;
  onClose: () => void;
  onSaved: (site: FsSite) => void;
}

const EMPTY = {
  account_uuid: '',
  name: '',
  address_line1: '',
  address_line2: '',
  city: '',
  county: '',
  postal_code: '',
  country: 'GB',
  contact_name: '',
  contact_phone: '',
  contact_email: '',
  access_notes: '',
  latitude: '',
  longitude: '',
};

type SiteForm = typeof EMPTY;

function formFromSite(site?: FsSite | null, accountUuid?: string): SiteForm {
  if (!site) return { ...EMPTY, account_uuid: accountUuid || '' };
  return {
    account_uuid: site.account_uuid || '',
    name: site.name || '',
    address_line1: site.address_line1 || '',
    address_line2: site.address_line2 || '',
    city: site.city || '',
    county: site.county || '',
    postal_code: site.postal_code || '',
    country: site.country || 'GB',
    contact_name: site.contact_name || '',
    contact_phone: site.contact_phone || '',
    contact_email: site.contact_email || '',
    access_notes: site.access_notes || '',
    latitude: site.latitude != null ? String(site.latitude) : '',
    longitude: site.longitude != null ? String(site.longitude) : '',
  };
}

export function SiteFormModal(props: SiteFormModalProps) {
  const title = props.site ? 'Edit site' : 'New site';
  return (
    <Modal isOpen={props.isOpen} onClose={props.onClose} title={title} size="lg">
      {props.isOpen && <SiteForm {...props} />}
    </Modal>
  );
}

function SiteForm({ site, defaultAccountUuid, onClose, onSaved }: SiteFormModalProps) {
  const [form, setForm] = useState<SiteForm>(() => formFromSite(site, defaultAccountUuid));
  const [accounts, setAccounts] = useState<FsAccountLookup[]>([]);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    fieldService.lookupAccounts().then(setAccounts).catch(() => setAccounts([]));
  }, []);

  const accountOptions = useMemo(
    () => accounts.map((a) => ({ value: a.uuid, label: a.name, hint: a.postal_code || a.city || undefined })),
    [accounts]
  );

  const set = (key: keyof SiteForm) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) =>
    setForm((f) => ({ ...f, [key]: e.target.value }));

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!form.name.trim()) {
      toast.error('Site name is required');
      return;
    }
    setSaving(true);
    const payload: Record<string, unknown> = {
      name: form.name.trim(),
      account_uuid: form.account_uuid || (site ? '' : undefined),
      latitude: optionalNumber(form.latitude) ?? (site ? '' : undefined),
      longitude: optionalNumber(form.longitude) ?? (site ? '' : undefined),
    };
    for (const key of [
      'address_line1', 'address_line2', 'city', 'county', 'postal_code', 'country',
      'contact_name', 'contact_phone', 'contact_email', 'access_notes',
    ] as const) {
      // On edit send empty strings so cleared fields are cleared server-side.
      payload[key] = site ? form[key].trim() : optional(form[key]);
    }
    try {
      const saved = site ? await fieldService.updateSite(site.uuid, payload) : await fieldService.createSite(payload);
      toast.success(site ? 'Site updated' : 'Site created');
      onSaved(saved);
      onClose();
    } catch (err) {
      toast.error(apiError(err, 'Failed to save site'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <form onSubmit={submit} className="space-y-4">
      <SearchableSelect
        label="Customer (CRM account)"
        options={accountOptions}
        value={form.account_uuid}
        onChange={(v) => setForm((f) => ({ ...f, account_uuid: v }))}
        placeholder="No customer"
        clearable
      />
      <Input label="Site name *" value={form.name} onChange={set('name')} placeholder="e.g. Head office, Plant room B" />
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <Input label="Address line 1" value={form.address_line1} onChange={set('address_line1')} />
        <Input label="Address line 2" value={form.address_line2} onChange={set('address_line2')} />
        <Input label="Town / city" value={form.city} onChange={set('city')} />
        <Input label="County" value={form.county} onChange={set('county')} />
        <Input label="Postcode" value={form.postal_code} onChange={set('postal_code')} />
        <Input label="Country" value={form.country} onChange={set('country')} />
        <Input label="Site contact" value={form.contact_name} onChange={set('contact_name')} />
        <Input label="Contact phone" value={form.contact_phone} onChange={set('contact_phone')} />
        <Input label="Contact email" type="email" value={form.contact_email} onChange={set('contact_email')} />
        <div className="grid grid-cols-2 gap-2">
          <Input label="Latitude" value={form.latitude} onChange={set('latitude')} inputMode="decimal" />
          <Input label="Longitude" value={form.longitude} onChange={set('longitude')} inputMode="decimal" />
        </div>
      </div>
      <Textarea
        label="Access notes"
        value={form.access_notes}
        onChange={set('access_notes')}
        placeholder="Key safe code, parking, site induction, hazards…"
        rows={3}
      />
      <div className="flex justify-end gap-2">
        <Button type="button" variant="ghost" onClick={onClose}>
          Cancel
        </Button>
        <Button type="submit" isLoading={saving}>
          {site ? 'Save changes' : 'Create site'}
        </Button>
      </div>
    </form>
  );
}

export default SiteFormModal;

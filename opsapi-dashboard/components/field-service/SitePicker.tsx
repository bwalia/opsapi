'use client';

/**
 * SitePicker — choose (or add) a saved site for the selected customer.
 * Sites are scoped to a customer, so this is disabled until one is chosen.
 * Picking a site hands the full record back so the form can prefill the
 * service address.
 */

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { Modal, Button, Input, Textarea, SearchableSelect } from '@/components/ui';
import { fieldService, type FsSite } from '@/services/field-service.service';
import { apiError } from './shared';

/** Multi-line service address from a site record. */
export function siteToAddress(site: FsSite): { service_address: string; service_postcode: string } {
  const service_address = [site.address_line1, site.address_line2, site.city, site.county].filter(Boolean).join(', ');
  return { service_address, service_postcode: site.postal_code || '' };
}

interface SitePickerProps {
  customerUuid: string;
  value: string;
  onChange: (siteUuid: string, site?: FsSite) => void;
  label?: string;
}

export function SitePicker({ customerUuid, value, onChange, label = 'Site' }: SitePickerProps) {
  const [sites, setSites] = useState<FsSite[]>([]);
  const [loading, setLoading] = useState(false);
  const [addOpen, setAddOpen] = useState(false);

  const load = useCallback(async () => {
    if (!customerUuid) {
      setSites([]);
      return;
    }
    setLoading(true);
    try {
      const r = await fieldService.getSites({ customer_uuid: customerUuid, per_page: 200 });
      setSites(r.data || []);
    } catch {
      setSites([]);
    } finally {
      setLoading(false);
    }
  }, [customerUuid]);

  useEffect(() => {
    load();
  }, [load]);

  const options = useMemo(
    () => sites.map((s) => ({ value: s.uuid, label: s.name, hint: s.address || undefined })),
    [sites]
  );

  return (
    <div>
      <SearchableSelect
        label={label}
        options={options}
        value={value}
        onChange={(v) => onChange(v, sites.find((s) => s.uuid === v))}
        placeholder={customerUuid ? (loading ? 'Loading sites…' : 'Select a site') : 'Pick a customer first'}
        disabled={!customerUuid}
        clearable
      />
      {customerUuid && (
        <button type="button" onClick={() => setAddOpen(true)} className="mt-1 text-xs font-medium text-primary-600 hover:underline">
          + Add a new site
        </button>
      )}
      <SiteAddModal
        isOpen={addOpen}
        customerUuid={customerUuid}
        onClose={() => setAddOpen(false)}
        onCreated={(site) => {
          setSites((prev) => [site, ...prev]);
          onChange(site.uuid, site);
          setAddOpen(false);
        }}
      />
    </div>
  );
}

function SiteAddModal({
  isOpen,
  customerUuid,
  onClose,
  onCreated,
}: {
  isOpen: boolean;
  customerUuid: string;
  onClose: () => void;
  onCreated: (site: FsSite) => void;
}) {
  const [f, setF] = useState({ name: '', address_line1: '', city: '', postal_code: '', access_notes: '' });
  const [saving, setSaving] = useState(false);
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) =>
    setF((prev) => ({ ...prev, [k]: e.target.value }));

  const reset = () => setF({ name: '', address_line1: '', city: '', postal_code: '', access_notes: '' });

  const save = async () => {
    if (!f.name.trim()) {
      toast.error('Give the site a name');
      return;
    }
    setSaving(true);
    try {
      const site = await fieldService.createSite({
        customer_uuid: customerUuid,
        name: f.name.trim(),
        address_line1: f.address_line1.trim(),
        city: f.city.trim(),
        postal_code: f.postal_code.trim(),
        access_notes: f.access_notes.trim(),
      });
      toast.success('Site added');
      reset();
      onCreated(site);
    } catch (err) {
      toast.error(apiError(err, 'Failed to add site'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="New site" size="md">
      <div className="space-y-3">
        <Input label="Site name *" value={f.name} onChange={set('name')} placeholder="e.g. St Marys Hospital — Ward 5" autoFocus />
        <Input label="Address" value={f.address_line1} onChange={set('address_line1')} placeholder="Street / building" />
        <div className="grid grid-cols-2 gap-3">
          <Input label="Town / city" value={f.city} onChange={set('city')} />
          <Input label="Postcode" value={f.postal_code} onChange={set('postal_code')} />
        </div>
        <Textarea label="Access notes" rows={2} value={f.access_notes} onChange={set('access_notes')} placeholder="Parking, keys, who to ask for…" />
        <div className="flex justify-end gap-2 -mx-5 sm:-mx-6 px-5 sm:px-6 pt-4 mt-4 border-t border-secondary-200">
          <Button variant="ghost" onClick={onClose} disabled={saving}>Cancel</Button>
          <Button onClick={save} isLoading={saving}>Add site</Button>
        </div>
      </div>
    </Modal>
  );
}

export default SitePicker;

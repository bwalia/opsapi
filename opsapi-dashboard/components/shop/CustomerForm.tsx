'use client';

import React from 'react';
import { Input } from '@/components/ui';
import type { ShopAddress, ShopCustomer } from '@/types/shop';

export interface CustomerDraft {
  name: string;
  email: string;
  company: string;
  phone: string;
  vat_number: string;
  line1: string;
  line2: string;
  city: string;
  postal_code: string;
  country: string;
}

export function customerToDraft(c?: ShopCustomer | null): CustomerDraft {
  const a: ShopAddress = typeof c?.address === 'string' ? { line1: c.address } : ((c?.address as ShopAddress) ?? {});
  return {
    name: c?.name ?? '',
    email: c?.email ?? '',
    company: c?.company ?? '',
    phone: c?.phone ?? '',
    vat_number: c?.vat_number ?? '',
    line1: String(a.line1 ?? ''),
    line2: String(a.line2 ?? ''),
    city: String(a.city ?? ''),
    postal_code: String(a.postal_code ?? ''),
    country: String(a.country ?? 'GB'),
  };
}

export function draftToCustomer(d: CustomerDraft): ShopCustomer {
  const t = (s: string) => s.trim() || undefined;
  const address: ShopAddress = {
    line1: t(d.line1),
    line2: t(d.line2),
    city: t(d.city),
    postal_code: t(d.postal_code),
    country: t(d.country),
  };
  const hasAddress = !!(address.line1 || address.city || address.postal_code);
  return {
    name: d.name.trim(),
    email: d.email.trim(),
    company: t(d.company),
    phone: t(d.phone),
    vat_number: t(d.vat_number),
    address: hasAddress ? address : null,
  };
}

export function validateCustomer(d: CustomerDraft): string[] {
  const errs: string[] = [];
  if (!d.name.trim()) errs.push('Customer name is required');
  if (!d.email.trim()) errs.push('Customer email is required');
  else if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(d.email.trim())) errs.push('Customer email is invalid');
  return errs;
}

export function CustomerForm({
  value,
  onChange,
  disabled,
}: {
  value: CustomerDraft;
  onChange: (d: CustomerDraft) => void;
  disabled?: boolean;
}) {
  const set = (k: keyof CustomerDraft) => (e: React.ChangeEvent<HTMLInputElement>) => onChange({ ...value, [k]: e.target.value });
  return (
    <div className="space-y-3">
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <Input label="Name *" id="cust-name" value={value.name} onChange={set('name')} disabled={disabled} />
        <Input label="Email *" id="cust-email" type="email" value={value.email} onChange={set('email')} disabled={disabled} />
        <Input label="Company" id="cust-company" value={value.company} onChange={set('company')} disabled={disabled} />
        <Input label="Phone" id="cust-phone" value={value.phone} onChange={set('phone')} disabled={disabled} />
        <Input label="VAT number" id="cust-vat" value={value.vat_number} onChange={set('vat_number')} disabled={disabled} />
      </div>
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <Input label="Address line 1" id="cust-l1" value={value.line1} onChange={set('line1')} disabled={disabled} />
        <Input label="Address line 2" id="cust-l2" value={value.line2} onChange={set('line2')} disabled={disabled} />
        <Input label="City" id="cust-city" value={value.city} onChange={set('city')} disabled={disabled} />
        <div className="grid grid-cols-2 gap-3">
          <Input label="Postcode" id="cust-pc" value={value.postal_code} onChange={set('postal_code')} disabled={disabled} />
          <Input label="Country" id="cust-country" value={value.country} onChange={set('country')} disabled={disabled} maxLength={2} />
        </div>
      </div>
    </div>
  );
}

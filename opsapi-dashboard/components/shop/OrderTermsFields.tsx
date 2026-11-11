'use client';

import React from 'react';
import { Crown } from 'lucide-react';
import { Button, Input } from '@/components/ui';
import { VipBadge } from '@/components/shop/VipBadge';
import { useVipFor } from '@/hooks/useVipStatus';
import { minorToPounds, poundsToMinor } from '@/lib/shop';
import type { ShopDeliveryAddress, ShopQuote, ShopQuoteKind, ShopQuoteOrderFields } from '@/types/shop';
import type { CustomerDraft } from './CustomerForm';

/** Editable back-office order terms: document type, discounts and delivery. */
export interface OrderTermsDraft {
  kind: ShopQuoteKind;
  /** £ ex VAT, '' = none. */
  discount: string;
  discountLabel: string;
  /** Work out the VIP Trade discount from the membership terms on save. */
  applyTrade: boolean;
  deliveryMethod: string;
  address: Required<Record<keyof ShopDeliveryAddress, string>>;
}

const ADDRESS_KEYS: (keyof ShopDeliveryAddress)[] = ['name', 'company', 'line1', 'line2', 'city', 'county', 'postcode', 'country', 'email', 'phone', 'vat_number'];

const emptyAddress = () => Object.fromEntries(ADDRESS_KEYS.map((k) => [k, ''])) as OrderTermsDraft['address'];

export function orderTermsToDraft(q?: Partial<ShopQuote> | null, kind: ShopQuoteKind = 'quote'): OrderTermsDraft {
  const a = emptyAddress();
  for (const k of ADDRESS_KEYS) a[k] = String(q?.delivery_address?.[k] ?? '');
  return {
    kind: q?.kind ?? kind,
    discount: q?.discount_minor ? minorToPounds(q.discount_minor) : '',
    discountLabel: q?.discount_label ?? '',
    applyTrade: (q?.trade_discount_minor ?? 0) > 0,
    deliveryMethod: q?.delivery_method ?? '',
    address: a,
  };
}

/** Draft → API fields, or errors. `hadTrade`: the saved quote already carries a Trade discount. */
export function draftToOrderFields(d: OrderTermsDraft, hadTrade = false): { fields: ShopQuoteOrderFields; errors: string[] } {
  const errors: string[] = [];
  const discount = d.discount.trim() ? poundsToMinor(d.discount) : 0;
  if (discount === null || discount < 0) errors.push('Discount must be a valid amount');
  const address: ShopDeliveryAddress = {};
  for (const k of ADDRESS_KEYS) if (d.address[k].trim()) address[k] = d.address[k].trim();
  if (address.email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(address.email)) errors.push('Delivery contact email is invalid');
  const fields: ShopQuoteOrderFields = {
    kind: d.kind,
    discount_minor: discount ?? 0,
    discount_label: d.discountLabel.trim(),
    delivery_method: d.deliveryMethod.trim(),
    delivery_address: Object.keys(address).length ? address : null,
  };
  // Re-work it out on every save so it follows the lines; clear it only when it was on.
  if (d.applyTrade) fields.apply_trade_discount = true;
  else if (hadTrade) fields.apply_trade_discount = false;
  return { fields, errors };
}

const FIELD_LABELS: Record<keyof ShopDeliveryAddress, string> = {
  name: 'Contact name',
  company: 'Company',
  line1: 'Address line 1',
  line2: 'Address line 2',
  city: 'Town / city',
  county: 'County',
  postcode: 'Postcode',
  country: 'Country',
  email: 'Contact email',
  phone: 'Phone',
  vat_number: 'VAT number',
};

export function OrderTermsFields({
  value,
  onChange,
  customer,
  idPrefix = 'ot',
  tradeDiscountMinor,
}: {
  value: OrderTermsDraft;
  onChange: (v: OrderTermsDraft) => void;
  /** To copy the customer into "Deliver to" and look up their VIP status. */
  customer?: CustomerDraft;
  idPrefix?: string;
  /** The Trade discount on the saved quote, shown next to the switch. */
  tradeDiscountMinor?: number;
}) {
  const vip = useVipFor(customer?.email);
  const set = (patch: Partial<OrderTermsDraft>) => onChange({ ...value, ...patch });
  const setAddr = (k: keyof ShopDeliveryAddress, v: string) => onChange({ ...value, address: { ...value.address, [k]: v } });
  const copyCustomer = () => {
    if (!customer) return;
    onChange({
      ...value,
      address: {
        ...value.address,
        name: customer.name,
        company: customer.company,
        line1: customer.line1,
        line2: customer.line2,
        city: customer.city,
        postcode: customer.postal_code,
        country: customer.country,
        email: customer.email,
        phone: customer.phone,
        vat_number: customer.vat_number,
      },
    });
  };

  return (
    <div className="space-y-5">
      <fieldset>
        <legend className="mb-2 text-sm font-medium text-secondary-700">Document</legend>
        <div className="inline-flex rounded-lg border border-secondary-200 p-0.5" role="radiogroup">
          {(['order', 'quote'] as ShopQuoteKind[]).map((k) => (
            <button
              key={k}
              type="button"
              role="radio"
              aria-checked={value.kind === k}
              onClick={() => set({ kind: k })}
              className={`rounded-md px-3 py-1.5 text-sm font-medium ${value.kind === k ? 'bg-primary-500 text-white' : 'text-secondary-600 hover:bg-secondary-50'}`}
            >
              {k === 'order' ? 'Order Authorisation' : 'Quote'}
            </button>
          ))}
        </div>
        <p className="mt-1.5 text-xs text-secondary-500">
          {value.kind === 'order'
            ? 'The customer confirms the order, accepts the terms and can pay online, even while shop checkout is switched off.'
            : 'An ordinary quote. Customers can only pay it online while shop checkout is on.'}
        </p>
      </fieldset>

      <div className="space-y-3">
        <p className="text-sm font-medium text-secondary-700">Discounts</p>
        <div className={`rounded-lg border px-3 py-2.5 ${vip ? 'border-amber-200 bg-amber-50 dark:border-amber-500/40 dark:bg-amber-500/10' : 'border-secondary-200'}`}>
          <label className="flex items-start gap-2 text-sm">
            <input type="checkbox" className="mt-0.5" checked={value.applyTrade} onChange={(e) => set({ applyTrade: e.target.checked })} />
            <span>
              <span className="flex flex-wrap items-center gap-2 font-medium text-secondary-900">
                <Crown className="h-4 w-4 text-amber-500" aria-hidden="true" />
                Apply the VIP Trade discount
                <VipBadge vip={vip} />
              </span>
              <span className="block text-xs text-secondary-500">
                {vip
                  ? 'Worked out from the membership terms (order value tiers and the yearly cap) each time you save.'
                  : 'The customer has no membership in force, so this will be £0 unless they join.'}
                {tradeDiscountMinor ? ` Currently £${minorToPounds(tradeDiscountMinor)} ex VAT.` : ''}
              </span>
            </span>
          </label>
        </div>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <Input label="Extra discount (£ ex VAT)" id={`${idPrefix}-disc`} value={value.discount} inputMode="decimal" placeholder="0.00" onChange={(e) => set({ discount: e.target.value })} />
          <Input label="Discount label" id={`${idPrefix}-disc-label`} value={value.discountLabel} placeholder="e.g. Founding member welcome" onChange={(e) => set({ discountLabel: e.target.value })} />
        </div>
      </div>

      <div className="space-y-3">
        <div className="flex items-center justify-between gap-2">
          <p className="text-sm font-medium text-secondary-700">Delivery</p>
          {customer && (
            <Button type="button" size="sm" variant="ghost" onClick={copyCustomer}>Same as customer</Button>
          )}
        </div>
        <Input label="Delivery method" id={`${idPrefix}-method`} value={value.deliveryMethod} placeholder="e.g. Courier, next working day" onChange={(e) => set({ deliveryMethod: e.target.value })} />
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          {ADDRESS_KEYS.map((k) => (
            <Input key={k} label={FIELD_LABELS[k]} id={`${idPrefix}-addr-${k}`} value={value.address[k]} onChange={(e) => setAddr(k, e.target.value)} />
          ))}
        </div>
        <p className="text-xs text-secondary-500">Used as &ldquo;Deliver directly to&rdquo; on the supplier purchase order.</p>
      </div>
    </div>
  );
}

export default OrderTermsFields;

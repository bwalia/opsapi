/**
 * Payment methods ("Getting paid"): the same rules as the API (lapis/lib/payment-methods.lua), for
 * as-you-type formatting and validation in the dashboard. The server validates again.
 */

export type PaymentMethodKind = 'bank_transfer' | 'card' | 'cheque' | 'other';

export const PAYMENT_METHOD_KINDS: { value: PaymentMethodKind; label: string }[] = [
  { value: 'bank_transfer', label: 'Bank transfer' },
  { value: 'card', label: 'Card' },
  { value: 'cheque', label: 'Cheque' },
  { value: 'other', label: 'Other' },
];

export const kindLabel = (k: string) => PAYMENT_METHOD_KINDS.find((x) => x.value === k)?.label || k;

/** As the user types: keep digits, insert dashes ("1234" → "12-34"), max 6 digits. */
export function typeSortCode(v: string): string {
  const d = v.replace(/\D/g, '').slice(0, 6);
  return d.replace(/^(\d{2})(\d{1,2})?(\d{1,2})?$/, (_m, a: string, b?: string, c?: string) =>
    [a, b, c].filter(Boolean).join('-')
  );
}

/** "12-34-56" when complete, else null. */
export function formatSortCode(v: string): string | null {
  const d = v.replace(/[\s-]/g, '');
  return /^\d{6}$/.test(d) ? `${d.slice(0, 2)}-${d.slice(2, 4)}-${d.slice(4, 6)}` : null;
}

export function validAccountNumber(v: string): boolean {
  const d = v.replace(/[\s-]/g, '');
  return /^\d{6,10}$/.test(d);
}

/** IBAN with spaces every 4 characters, for display while typing. */
export function typeIban(v: string): string {
  return v
    .replace(/[^0-9a-zA-Z]/g, '')
    .toUpperCase()
    .slice(0, 34)
    .replace(/(.{4})(?=.)/g, '$1 ');
}

/** ISO 13616 mod-97 check. */
export function validIban(v: string): boolean {
  const s = v.replace(/\s/g, '').toUpperCase();
  if (!/^[A-Z]{2}\d{2}[A-Z0-9]+$/.test(s) || s.length < 15 || s.length > 34) return false;
  const moved = s.slice(4) + s.slice(0, 4);
  let rem = 0;
  for (const ch of moved) {
    const d = /\d/.test(ch) ? ch : String(ch.charCodeAt(0) - 55);
    for (const digit of d) rem = (rem * 10 + Number(digit)) % 97;
  }
  return rem === 1;
}

export function validBic(v: string): boolean {
  const s = v.replace(/\s/g, '').toUpperCase();
  return /^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$/.test(s);
}

/** The fields printed in a "How to pay" block (the public shape). */
export interface PaymentMethodPublic {
  kind: PaymentMethodKind | string;
  label: string;
  account_name?: string | null;
  bank_name?: string | null;
  sort_code?: string | null;
  account_number?: string | null;
  iban?: string | null;
  swift_bic?: string | null;
  currency?: string | null;
  instructions?: string | null;
}

/** Label/value rows for one method, in print order (shared by the preview, the invoice PDF and pages). */
export function paymentMethodRows(m: PaymentMethodPublic): [string, string][] {
  const rows: [string, string][] = [];
  if (m.kind === 'bank_transfer') {
    if (m.account_name) rows.push(['Account name', m.account_name]);
    if (m.bank_name) rows.push(['Bank', m.bank_name]);
    if (m.sort_code) rows.push(['Sort code', m.sort_code]);
    if (m.account_number) rows.push(['Account number', m.account_number]);
    if (m.iban) rows.push(['IBAN', typeIban(m.iban)]);
    if (m.swift_bic) rows.push(['SWIFT/BIC', m.swift_bic]);
    if (m.currency && m.currency !== 'GBP') rows.push(['Currency', m.currency]);
  }
  return rows;
}

'use client';

/**
 * Billing & Entitlements building blocks shared by /dashboard/billing/* and
 * the customer page's Billing panel.
 */

import React, { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { Check, Copy } from 'lucide-react';
import { SearchableSelect } from '@/components/ui';
import { cn } from '@/lib/utils';
import { usePermissions } from '@/contexts/PermissionsContext';
import { Pill } from '@/components/field-service/shared';
import {
  billingService,
  type AppKind,
  type BillingFeature,
  type FeatureMap,
  type FeatureValue,
} from '@/services/billing.service';

export const KIND_LABELS: Record<AppKind, string> = {
  web: 'Web app',
  desktop: 'Desktop app',
  self_hosted: 'Self-hosted',
  mobile: 'Mobile app',
};

const NAV = [
  { href: '/dashboard/billing', label: 'Apps & plans', module: 'billing' },
  { href: '/dashboard/billing/subscriptions', label: 'Subscriptions', module: 'subscriptions' },
  { href: '/dashboard/billing/licenses', label: 'Licences', module: 'licenses' },
  { href: '/dashboard/billing/coupons', label: 'Coupons', module: 'billing' },
  { href: '/dashboard/billing/payments', label: 'Payments', module: 'billing' },
];

export function BillingNav() {
  const pathname = usePathname() || '';
  const { canRead } = usePermissions();
  const items = NAV.filter((i) => canRead(i.module));
  if (items.length < 2) return null;
  return (
    <nav className="flex gap-1 overflow-x-auto border-b border-secondary-200" aria-label="Billing">
      {items.map((item) => {
        const active =
          item.href === '/dashboard/billing'
            ? pathname === item.href || pathname.startsWith('/dashboard/billing/apps')
            : pathname.startsWith(item.href);
        return (
          <Link
            key={item.href}
            href={item.href}
            className={cn(
              'whitespace-nowrap px-4 py-2.5 text-sm font-medium border-b-2 -mb-px transition-colors',
              active
                ? 'border-primary-500 text-primary-600'
                : 'border-transparent text-secondary-500 hover:text-secondary-800 hover:border-secondary-300'
            )}
            aria-current={active ? 'page' : undefined}
          >
            {item.label}
          </Link>
        );
      })}
    </nav>
  );
}

export function Tabs<T extends string>({
  tabs,
  value,
  onChange,
  label,
}: {
  tabs: { id: T; label: string }[];
  value: T;
  onChange: (id: T) => void;
  label: string;
}) {
  return (
    <div role="tablist" aria-label={label} className="flex gap-1 border-b border-secondary-200 overflow-x-auto">
      {tabs.map((t) => (
        <button
          key={t.id}
          type="button"
          role="tab"
          aria-selected={value === t.id}
          onClick={() => onChange(t.id)}
          className={cn(
            'px-4 py-2.5 -mb-px text-sm font-medium border-b-2 transition-colors cursor-pointer whitespace-nowrap',
            'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-500 rounded-t-md',
            value === t.id ? 'border-primary-500 text-primary-600' : 'border-transparent text-secondary-500 hover:text-secondary-800'
          )}
        >
          {t.label}
        </button>
      ))}
    </div>
  );
}

const STATUS_COLORS: Record<string, string> = {
  active: 'bg-green-50 text-green-700',
  trialing: 'bg-blue-50 text-blue-700',
  granted: 'bg-violet-50 text-violet-700',
  free: 'bg-secondary-100 text-secondary-700',
  past_due: 'bg-amber-50 text-amber-700',
  suspended: 'bg-amber-50 text-amber-700',
  canceled: 'bg-red-50 text-red-700',
  revoked: 'bg-red-50 text-red-700',
  expired: 'bg-secondary-100 text-secondary-500',
  none: 'bg-secondary-100 text-secondary-500',
};

export function StatusPill({ status }: { status: string }) {
  return (
    <Pill className={STATUS_COLORS[status] || 'bg-secondary-100 text-secondary-700'}>{status.replace(/_/g, ' ')}</Pill>
  );
}

export function CopyButton({ value, label = 'Copy' }: { value: string; label?: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      type="button"
      onClick={async () => {
        await navigator.clipboard.writeText(value);
        setCopied(true);
        setTimeout(() => setCopied(false), 1500);
      }}
      className="inline-flex items-center justify-center p-2 rounded-lg text-secondary-500 hover:text-primary-600 hover:bg-primary-50"
      aria-label={label}
      title={label}
    >
      {copied ? <Check className="w-4 h-4" /> : <Copy className="w-4 h-4" />}
    </button>
  );
}

/** Pick a workspace customer (server-side search on email, name, external id). */
export function CustomerPicker({
  value,
  onChange,
  label = 'Customer',
}: {
  value: string;
  onChange: (uuid: string) => void;
  label?: string;
}) {
  const [options, setOptions] = useState<{ value: string; label: string; hint?: string }[]>([]);
  const search = useCallback((q: string) => {
    billingService
      .searchCustomers(q)
      .then((rows) =>
        setOptions(
          rows.map((c) => ({
            value: c.uuid,
            label: c.email,
            hint: [[c.first_name, c.last_name].filter(Boolean).join(' '), c.external_id && `id: ${c.external_id}`]
              .filter(Boolean)
              .join(' · '),
          }))
        )
      )
      .catch(() => setOptions([]));
  }, []);
  useEffect(() => search(''), [search]);
  return (
    <SearchableSelect
      label={label}
      options={options}
      value={value}
      onChange={onChange}
      onSearch={search}
      placeholder="Search by email, name or app user id…"
      emptyMessage="No matching customers"
    />
  );
}

/**
 * Edit a feature map against an app's catalogue: a toggle per on/off feature,
 * a number (blank = not set) or "Unlimited" per limit. `optional` leaves
 * untouched features out of the map (for grants, which add to a plan).
 */
export function FeatureValuesEditor({
  features,
  value,
  onChange,
  optional = false,
}: {
  features: BillingFeature[];
  value: FeatureMap;
  onChange: (next: FeatureMap) => void;
  optional?: boolean;
}) {
  if (features.length === 0) {
    return <p className="text-sm text-secondary-500">This app has no features yet. Add them on the Features tab.</p>;
  }
  const set = (key: string, v: FeatureValue | undefined) => {
    const next = { ...value };
    if (v === undefined) delete next[key];
    else next[key] = v;
    onChange(next);
  };
  return (
    <div className="divide-y divide-secondary-100 rounded-lg border border-secondary-200">
      {features.map((f) => {
        const v = value[f.key];
        const id = `feature-${f.key}`;
        return (
          <div key={f.key} className="flex flex-wrap items-center justify-between gap-3 px-3 py-2.5">
            <label htmlFor={id} className="min-w-0">
              <span className="block text-sm font-medium text-secondary-900">{f.name}</span>
              <span className="block text-xs text-secondary-500 font-mono">{f.key}</span>
            </label>
            {f.type === 'boolean' ? (
              <select
                id={id}
                value={v === true ? 'on' : v === false ? 'off' : ''}
                onChange={(e) => set(f.key, e.target.value === '' ? undefined : e.target.value === 'on')}
                className="px-3 py-2 border border-secondary-300 rounded-lg text-sm bg-surface"
              >
                {optional && <option value="">Not changed</option>}
                <option value="on">Included</option>
                <option value="off">Not included</option>
              </select>
            ) : (
              <div className="flex items-center gap-2">
                <input
                  id={id}
                  type="number"
                  min={0}
                  step={1}
                  inputMode="numeric"
                  disabled={v === null}
                  value={typeof v === 'number' ? v : ''}
                  placeholder={v === null ? '∞' : optional ? 'Not changed' : '0'}
                  onChange={(e) => set(f.key, e.target.value === '' ? undefined : Math.max(0, Math.floor(Number(e.target.value))))}
                  className="w-28 px-3 py-2 border border-secondary-300 rounded-lg text-sm bg-surface disabled:bg-secondary-50"
                  aria-label={`${f.name} limit`}
                />
                {f.unit && <span className="text-xs text-secondary-500">{f.unit}</span>}
                <label className="flex items-center gap-1.5 text-xs text-secondary-600 cursor-pointer select-none">
                  <input
                    type="checkbox"
                    checked={v === null}
                    onChange={(e) => set(f.key, e.target.checked ? null : optional ? undefined : 0)}
                  />
                  Unlimited
                </label>
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

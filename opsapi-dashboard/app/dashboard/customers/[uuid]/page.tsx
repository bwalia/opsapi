'use client';

import React, { useState, useEffect, useCallback } from 'react';
import { useRouter, useParams } from 'next/navigation';
import {
  ArrowLeft,
  Save,
  Trash2,
  Mail,
  Phone,
  ShoppingBag,
  DollarSign,
  Loader2,
  User,
} from 'lucide-react';
import { Card, Badge, Button, ConfirmDialog } from '@/components/ui';
import { customersService } from '@/services/customers.service';
import { formatCurrency, formatDate } from '@/lib/utils';
import type {
  Customer,
  CustomerAddress,
  CreateCustomerDto,
  MarketingOptInLevel,
  CustomerState,
} from '@/types';
import toast from 'react-hot-toast';

const inputClass =
  'w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-surface';
const labelClass = 'block text-sm font-medium text-secondary-700 mb-1';

// Stored defaults sometimes arrive wrapped in literal quotes (e.g. "'single_opt_in'").
const clean = (v?: string | null) => (v || '').replace(/^'+|'+$/g, '');

// addresses is stored as a JSON text column, so it may come back as a string.
function parseAddresses(addresses: Customer['addresses']): CustomerAddress[] {
  if (Array.isArray(addresses)) return addresses;
  if (typeof addresses === 'string' && addresses.trim()) {
    try {
      const parsed = JSON.parse(addresses);
      return Array.isArray(parsed) ? parsed : [];
    } catch {
      return [];
    }
  }
  return [];
}

interface FormState {
  first_name: string;
  last_name: string;
  email: string;
  phone: string;
  date_of_birth: string;
  address1: string;
  address2: string;
  city: string;
  province: string;
  country: string;
  zip: string;
  notes: string;
  tags: string;
  accepts_marketing: boolean;
  verified_email: boolean;
  tax_exempt: boolean;
  marketing_opt_in_level: MarketingOptInLevel;
  state: CustomerState;
}

const EMPTY_FORM: FormState = {
  first_name: '',
  last_name: '',
  email: '',
  phone: '',
  date_of_birth: '',
  address1: '',
  address2: '',
  city: '',
  province: '',
  country: '',
  zip: '',
  notes: '',
  tags: '',
  accepts_marketing: false,
  verified_email: false,
  tax_exempt: false,
  marketing_opt_in_level: 'single_opt_in',
  state: 'enabled',
};

function customerToForm(c: Customer): FormState {
  const addresses = parseAddresses(c.addresses);
  const primary = addresses.find((a) => a.is_default) || addresses[0] || {};
  return {
    first_name: c.first_name || '',
    last_name: c.last_name || '',
    email: c.email || '',
    phone: c.phone || '',
    date_of_birth: c.date_of_birth ? c.date_of_birth.slice(0, 10) : '',
    address1: primary.address1 || '',
    address2: primary.address2 || '',
    city: primary.city || '',
    province: primary.province || '',
    country: primary.country || '',
    zip: primary.zip || '',
    notes: c.notes || '',
    tags: c.tags || '',
    accepts_marketing: !!c.accepts_marketing,
    verified_email: !!c.verified_email,
    tax_exempt: !!c.tax_exempt,
    marketing_opt_in_level: (clean(c.marketing_opt_in_level) as MarketingOptInLevel) || 'single_opt_in',
    state: (clean(c.state) as CustomerState) || 'enabled',
  };
}

const STATE_OPTIONS: CustomerState[] = ['enabled', 'disabled', 'invited', 'declined'];
const OPT_IN_OPTIONS: MarketingOptInLevel[] = ['single_opt_in', 'confirmed_opt_in', 'unknown'];

export default function CustomerDetailPage() {
  const router = useRouter();
  const params = useParams();
  const uuid = params?.uuid as string;

  const [customer, setCustomer] = useState<Customer | null>(null);
  const [form, setForm] = useState<FormState>(EMPTY_FORM);
  const [isLoading, setIsLoading] = useState(true);
  const [notFound, setNotFound] = useState(false);
  const [isSaving, setIsSaving] = useState(false);
  const [deleteOpen, setDeleteOpen] = useState(false);
  const [isDeleting, setIsDeleting] = useState(false);

  const load = useCallback(async () => {
    setIsLoading(true);
    try {
      const c = await customersService.getCustomer(uuid);
      if (!c || !c.uuid) {
        setNotFound(true);
      } else {
        setCustomer(c);
        setForm(customerToForm(c));
      }
    } catch (err) {
      console.error('Failed to load customer:', err);
      setNotFound(true);
    } finally {
      setIsLoading(false);
    }
  }, [uuid]);

  useEffect(() => {
    if (uuid) load();
  }, [uuid, load]);

  const setField = <K extends keyof FormState>(key: K, value: FormState[K]) =>
    setForm((prev) => ({ ...prev, [key]: value }));

  const handleSave = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!form.email.trim()) {
      toast.error('Email is required');
      return;
    }

    // Rebuild the addresses array, preserving any extra addresses beyond the primary.
    const existing = customer ? parseAddresses(customer.addresses) : [];
    const hasAddress =
      form.address1 || form.city || form.province || form.country || form.zip;
    const primary: CustomerAddress | null = hasAddress
      ? {
          address1: form.address1 || undefined,
          address2: form.address2 || undefined,
          city: form.city || undefined,
          province: form.province || undefined,
          country: form.country || undefined,
          zip: form.zip || undefined,
          is_default: true,
        }
      : null;
    const rest = existing.filter((a) => !a.is_default).slice(0, 9);
    const addresses = primary ? [primary, ...rest] : rest;

    const dto: Partial<CreateCustomerDto> = {
      first_name: form.first_name || undefined,
      last_name: form.last_name || undefined,
      email: form.email.trim(),
      phone: form.phone || undefined,
      date_of_birth: form.date_of_birth || undefined,
      addresses,
      notes: form.notes || undefined,
      tags: form.tags || undefined,
      accepts_marketing: form.accepts_marketing,
      verified_email: form.verified_email,
      tax_exempt: form.tax_exempt,
      marketing_opt_in_level: form.marketing_opt_in_level,
      state: form.state,
    };

    setIsSaving(true);
    try {
      const updated = await customersService.updateCustomer(uuid, dto);
      setCustomer(updated);
      setForm(customerToForm(updated));
      toast.success('Customer updated');
    } catch (err) {
      console.error('Failed to update customer:', err);
      toast.error('Failed to update customer');
    } finally {
      setIsSaving(false);
    }
  };

  const handleDelete = async () => {
    setIsDeleting(true);
    try {
      await customersService.deleteCustomer(uuid);
      toast.success('Customer deleted');
      router.push('/dashboard/customers');
    } catch (err) {
      console.error('Failed to delete customer:', err);
      toast.error('Failed to delete customer');
      setIsDeleting(false);
      setDeleteOpen(false);
    }
  };

  const fullName =
    [form.first_name, form.last_name].filter(Boolean).join(' ') || form.email || 'Customer';
  const initials =
    `${(form.first_name || form.email)[0] || ''}${form.last_name[0] || ''}`.toUpperCase();

  if (isLoading) {
    return (
      <div className="flex items-center justify-center py-24">
        <Loader2 className="w-8 h-8 text-primary-500 animate-spin" />
      </div>
    );
  }

  if (notFound) {
    return (
      <div className="space-y-4">
        <button
          onClick={() => router.push('/dashboard/customers')}
          className="inline-flex items-center gap-2 text-sm text-secondary-500 hover:text-secondary-700"
        >
          <ArrowLeft className="w-4 h-4" /> Back to customers
        </button>
        <Card className="text-center py-16">
          <User className="w-10 h-10 text-secondary-300 mx-auto mb-3" />
          <p className="text-secondary-700 font-medium">Customer not found</p>
          <p className="text-sm text-secondary-500 mt-1">It may have been deleted or the link is invalid.</p>
        </Card>
      </div>
    );
  }

  return (
    <form onSubmit={handleSave} className="space-y-5 sm:space-y-6 pb-4">
      {/* Top bar */}
      <div className="flex items-center justify-between gap-3">
        <button
          type="button"
          onClick={() => router.push('/dashboard/customers')}
          className="inline-flex items-center gap-2 text-sm text-secondary-500 hover:text-secondary-700"
        >
          <ArrowLeft className="w-4 h-4" /> Customers
        </button>
        <div className="flex items-center gap-2">
          <Button type="button" variant="danger" size="sm" onClick={() => setDeleteOpen(true)}>
            <Trash2 className="w-4 h-4 mr-1.5" /> Delete
          </Button>
          <Button type="submit" size="sm" isLoading={isSaving}>
            {!isSaving && <Save className="w-4 h-4 mr-1.5" />} Save changes
          </Button>
        </div>
      </div>

      {/* Header / summary */}
      <div className="relative overflow-hidden rounded-2xl gradient-primary text-white p-6 shadow-lg shadow-primary-500/20">
        <div className="pointer-events-none absolute -top-16 -right-10 w-64 h-64 rounded-full bg-white/10 blur-3xl" />
        <div className="relative flex flex-col sm:flex-row sm:items-center gap-4">
          <div className="w-16 h-16 rounded-2xl bg-white/15 ring-1 ring-white/25 flex items-center justify-center text-2xl font-bold flex-shrink-0">
            {initials || <User className="w-7 h-7" />}
          </div>
          <div className="min-w-0">
            <div className="flex items-center gap-3 flex-wrap">
              <h1 className="text-2xl font-bold tracking-tight truncate">{fullName}</h1>
              <Badge size="sm" status={form.state} />
            </div>
            <div className="flex items-center gap-4 mt-1.5 text-white/85 text-sm flex-wrap">
              {form.email && (
                <span className="inline-flex items-center gap-1.5">
                  <Mail className="w-4 h-4" /> {form.email}
                </span>
              )}
              {form.phone && (
                <span className="inline-flex items-center gap-1.5">
                  <Phone className="w-4 h-4" /> {form.phone}
                </span>
              )}
            </div>
          </div>
        </div>
      </div>

      {/* Stats */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-3 sm:gap-4">
        <Card padding="sm" className="shadow-sm">
          <p className="text-xs font-medium text-secondary-500">Orders</p>
          <p className="text-xl font-bold text-secondary-900 mt-1 flex items-center gap-2">
            <ShoppingBag className="w-4 h-4 text-primary-500" />
            {customer?.orders_count ?? 0}
          </p>
        </Card>
        <Card padding="sm" className="shadow-sm">
          <p className="text-xs font-medium text-secondary-500">Total spent</p>
          <p className="text-xl font-bold text-secondary-900 mt-1 flex items-center gap-2">
            <DollarSign className="w-4 h-4 text-primary-500" />
            {formatCurrency(customer?.total_spent ?? 0)}
          </p>
        </Card>
        <Card padding="sm" className="shadow-sm">
          <p className="text-xs font-medium text-secondary-500">Avg. order</p>
          <p className="text-xl font-bold text-secondary-900 mt-1">
            {formatCurrency(customer?.average_order_value ?? 0)}
          </p>
        </Card>
        <Card padding="sm" className="shadow-sm">
          <p className="text-xs font-medium text-secondary-500">Last order</p>
          <p className="text-sm font-semibold text-secondary-900 mt-2">
            {customer?.last_order_date ? formatDate(customer.last_order_date) : '—'}
          </p>
        </Card>
      </div>

      {/* Basic info */}
      <Card className="shadow-sm">
        <h2 className="text-base font-semibold text-secondary-900 mb-4">Basic information</h2>
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div>
            <label className={labelClass}>First name</label>
            <input className={inputClass} value={form.first_name} onChange={(e) => setField('first_name', e.target.value)} />
          </div>
          <div>
            <label className={labelClass}>Last name</label>
            <input className={inputClass} value={form.last_name} onChange={(e) => setField('last_name', e.target.value)} />
          </div>
          <div>
            <label className={labelClass}>Email *</label>
            <input type="email" className={inputClass} value={form.email} onChange={(e) => setField('email', e.target.value)} required />
          </div>
          <div>
            <label className={labelClass}>Phone</label>
            <input className={inputClass} value={form.phone} onChange={(e) => setField('phone', e.target.value)} />
          </div>
          <div>
            <label className={labelClass}>Date of birth</label>
            <input type="date" className={inputClass} value={form.date_of_birth} onChange={(e) => setField('date_of_birth', e.target.value)} />
          </div>
        </div>
      </Card>

      {/* Address */}
      <Card className="shadow-sm">
        <h2 className="text-base font-semibold text-secondary-900 mb-4">Primary address</h2>
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div className="sm:col-span-2">
            <label className={labelClass}>Address line 1</label>
            <input className={inputClass} value={form.address1} onChange={(e) => setField('address1', e.target.value)} />
          </div>
          <div className="sm:col-span-2">
            <label className={labelClass}>Address line 2</label>
            <input className={inputClass} value={form.address2} onChange={(e) => setField('address2', e.target.value)} />
          </div>
          <div>
            <label className={labelClass}>City</label>
            <input className={inputClass} value={form.city} onChange={(e) => setField('city', e.target.value)} />
          </div>
          <div>
            <label className={labelClass}>State / Province</label>
            <input className={inputClass} value={form.province} onChange={(e) => setField('province', e.target.value)} />
          </div>
          <div>
            <label className={labelClass}>Country</label>
            <input className={inputClass} value={form.country} onChange={(e) => setField('country', e.target.value)} />
          </div>
          <div>
            <label className={labelClass}>Postal code</label>
            <input className={inputClass} value={form.zip} onChange={(e) => setField('zip', e.target.value)} />
          </div>
        </div>
      </Card>

      {/* Preferences */}
      <Card className="shadow-sm">
        <h2 className="text-base font-semibold text-secondary-900 mb-4">Preferences & notes</h2>
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div>
            <label className={labelClass}>Tags (comma-separated)</label>
            <input className={inputClass} value={form.tags} onChange={(e) => setField('tags', e.target.value)} placeholder="vip, wholesale" />
          </div>
          <div>
            <label className={labelClass}>Account status</label>
            <select className={inputClass} value={form.state} onChange={(e) => setField('state', e.target.value as CustomerState)}>
              {STATE_OPTIONS.map((s) => (
                <option key={s} value={s} className="capitalize">{s}</option>
              ))}
            </select>
          </div>
          <div>
            <label className={labelClass}>Marketing opt-in level</label>
            <select
              className={inputClass}
              value={form.marketing_opt_in_level}
              onChange={(e) => setField('marketing_opt_in_level', e.target.value as MarketingOptInLevel)}
            >
              {OPT_IN_OPTIONS.map((o) => (
                <option key={o} value={o}>{o.replace(/_/g, ' ')}</option>
              ))}
            </select>
          </div>
          <div className="sm:col-span-2">
            <label className={labelClass}>Notes</label>
            <textarea
              className={`${inputClass} resize-none`}
              rows={3}
              value={form.notes}
              onChange={(e) => setField('notes', e.target.value)}
              placeholder="Internal notes about this customer…"
            />
          </div>
        </div>

        <div className="flex flex-wrap gap-x-6 gap-y-3 mt-4 pt-4 border-t border-secondary-200">
          <label className="flex items-center gap-2 text-sm text-secondary-700 cursor-pointer select-none">
            <input type="checkbox" className="w-4 h-4 rounded border-secondary-300 text-primary-600 focus:ring-primary-500/30"
              checked={form.accepts_marketing} onChange={(e) => setField('accepts_marketing', e.target.checked)} />
            Accepts marketing
          </label>
          <label className="flex items-center gap-2 text-sm text-secondary-700 cursor-pointer select-none">
            <input type="checkbox" className="w-4 h-4 rounded border-secondary-300 text-primary-600 focus:ring-primary-500/30"
              checked={form.verified_email} onChange={(e) => setField('verified_email', e.target.checked)} />
            Email verified
          </label>
          <label className="flex items-center gap-2 text-sm text-secondary-700 cursor-pointer select-none">
            <input type="checkbox" className="w-4 h-4 rounded border-secondary-300 text-primary-600 focus:ring-primary-500/30"
              checked={form.tax_exempt} onChange={(e) => setField('tax_exempt', e.target.checked)} />
            Tax exempt
          </label>
        </div>
      </Card>

      <ConfirmDialog
        isOpen={deleteOpen}
        onClose={() => setDeleteOpen(false)}
        onConfirm={handleDelete}
        title="Delete customer"
        message={`Are you sure you want to delete "${fullName}"? This action cannot be undone.`}
        confirmText="Delete"
        variant="danger"
        isLoading={isDeleting}
      />
    </form>
  );
}

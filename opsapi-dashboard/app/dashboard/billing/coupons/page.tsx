'use client';

/**
 * Billing — /dashboard/billing/coupons
 *
 * Discount coupons: percent or a fixed amount off, once / for some months /
 * forever on subscriptions, for every app or one app (and some of its plans),
 * with dates and limits. Customers enter the code at checkout.
 */

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { Pencil, Plus, Tag, Trash2 } from 'lucide-react';
import { Button, Card, ConfirmDialog, Input, Modal, Pagination, Select, Switch, Table } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { usePermissions } from '@/contexts/PermissionsContext';
import { apiError, Pill } from '@/components/field-service/shared';
import { BillingNav } from '@/components/billing/shared';
import { formatDate } from '@/lib/utils';
import { billingService, formatMinor, type BillingApp, type BillingPlan, type Coupon, type CouponInput } from '@/services/billing.service';
import type { TableColumn } from '@/types';

const PER_PAGE = 20;

const describe = (c: Coupon) =>
  (c.discount_type === 'percent' ? `${Number(c.percent_off)}% off` : `${formatMinor(c.amount_off || 0, c.currency || 'gbp')} off`) +
  (c.duration === 'forever' ? ', every payment' : c.duration === 'repeating' ? `, for ${c.duration_months} months` : '');

const day = (v?: string | null) => (v ? v.slice(0, 10) : '');

function CouponModal({
  coupon,
  apps,
  isOpen,
  onClose,
  onSaved,
}: {
  coupon: Coupon | null;
  apps: BillingApp[];
  isOpen: boolean;
  onClose: () => void;
  onSaved: () => void;
}) {
  const used = (coupon?.redemptions_count || 0) > 0;
  const [code, setCode] = useState('');
  const [name, setName] = useState('');
  const [app, setApp] = useState('');
  const [plans, setPlans] = useState<BillingPlan[]>([]);
  const [planIds, setPlanIds] = useState<string[]>([]);
  const [type, setType] = useState<'percent' | 'amount'>('percent');
  const [value, setValue] = useState('');
  const [currency, setCurrency] = useState('gbp');
  const [duration, setDuration] = useState<'once' | 'repeating' | 'forever'>('once');
  const [months, setMonths] = useState('3');
  const [maxUses, setMaxUses] = useState('');
  const [perCustomer, setPerCustomer] = useState('1');
  const [starts, setStarts] = useState('');
  const [expires, setExpires] = useState('');
  const [active, setActive] = useState(true);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!isOpen) return;
    setCode(coupon?.code || '');
    setName(coupon?.name || '');
    setApp(coupon?.app_uuid || '');
    setPlanIds(coupon?.plans || []);
    setType(coupon?.discount_type || 'percent');
    setValue(
      coupon ? (coupon.discount_type === 'percent' ? String(coupon.percent_off) : String((coupon.amount_off || 0) / 100)) : ''
    );
    setCurrency(coupon?.currency || 'gbp');
    setDuration(coupon?.duration || 'once');
    setMonths(String(coupon?.duration_months || 3));
    setMaxUses(coupon?.max_redemptions ? String(coupon.max_redemptions) : '');
    setPerCustomer(coupon ? (coupon.per_customer_limit ? String(coupon.per_customer_limit) : '') : '1');
    setStarts(day(coupon?.starts_at));
    setExpires(day(coupon?.expires_at));
    setActive(coupon?.active ?? true);
  }, [isOpen, coupon]);

  useEffect(() => {
    if (app) billingService.listPlans(app).then((p) => setPlans(p.filter((x) => x.active))).catch(() => setPlans([]));
    else setPlans([]);
  }, [app]);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setSaving(true);
    const body: CouponInput = {
      name: name.trim() || undefined,
      max_redemptions: maxUses ? Math.floor(Number(maxUses)) : null,
      per_customer_limit: perCustomer ? Math.floor(Number(perCustomer)) : null,
      starts_at: starts ? `${starts}T00:00:00Z` : null,
      expires_at: expires ? `${expires}T23:59:59Z` : null,
      active,
      plans: app ? planIds : undefined,
    };
    if (!used) {
      Object.assign(body, {
        discount_type: type,
        ...(type === 'percent'
          ? { percent_off: Number(value) }
          : { amount_off: Math.round(Number(value) * 100), currency }),
        duration,
        ...(duration === 'repeating' ? { duration_months: Math.floor(Number(months)) } : {}),
      });
    }
    try {
      if (coupon) await billingService.updateCoupon(coupon.uuid, body);
      else await billingService.createCoupon({ ...body, code: code.trim().toUpperCase(), app: app || undefined });
      toast.success(coupon ? 'Coupon updated' : 'Coupon created');
      onSaved();
    } catch (err) {
      toast.error(apiError(err, 'Could not save the coupon'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title={coupon ? `Edit ${coupon.code}` : 'New coupon'} size="lg">
      <form onSubmit={submit} className="space-y-4">
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <Input
            label="Code"
            value={code}
            onChange={(e) => setCode(e.target.value.toUpperCase())}
            disabled={!!coupon}
            pattern="[A-Za-z0-9_\-]{2,40}"
            placeholder="LAUNCH25"
            required
            className="font-mono"
          />
          <Input label="Name (optional)" value={name} onChange={(e) => setName(e.target.value)} placeholder="Launch offer" />
          <Select label="App" value={app} onChange={(e) => setApp(e.target.value)} disabled={!!coupon}>
            <option value="">Every app</option>
            {apps.map((a) => (
              <option key={a.uuid} value={a.uuid}>
                {a.name}
              </option>
            ))}
          </Select>
          <Select label="Discount" value={type} onChange={(e) => setType(e.target.value as 'percent' | 'amount')} disabled={used}>
            <option value="percent">Percent off</option>
            <option value="amount">Amount off</option>
          </Select>
          <div className="grid grid-cols-2 gap-3">
            <Input
              label={type === 'percent' ? 'Percent' : 'Amount'}
              type="number"
              min={0.01}
              max={type === 'percent' ? 100 : undefined}
              step="0.01"
              value={value}
              onChange={(e) => setValue(e.target.value)}
              disabled={used}
              required
            />
            {type === 'amount' && (
              <Select label="Currency" value={currency} onChange={(e) => setCurrency(e.target.value)} disabled={used}>
                {['gbp', 'usd', 'eur', 'inr', 'aud', 'cad'].map((c) => (
                  <option key={c} value={c}>
                    {c.toUpperCase()}
                  </option>
                ))}
              </Select>
            )}
          </div>
          <div className="grid grid-cols-2 gap-3">
            <Select
              label="On subscriptions"
              value={duration}
              onChange={(e) => setDuration(e.target.value as typeof duration)}
              disabled={used}
            >
              <option value="once">First payment</option>
              <option value="repeating">For some months</option>
              <option value="forever">Every payment</option>
            </Select>
            {duration === 'repeating' && (
              <Input label="Months" type="number" min={1} max={120} value={months} onChange={(e) => setMonths(e.target.value)} disabled={used} />
            )}
          </div>
          <Input label="Total uses (optional)" type="number" min={1} value={maxUses} onChange={(e) => setMaxUses(e.target.value)} helperText="Blank = unlimited" />
          <Input label="Uses per customer" type="number" min={1} value={perCustomer} onChange={(e) => setPerCustomer(e.target.value)} helperText="Blank = unlimited" />
          <Input label="Valid from (optional)" type="date" value={starts} onChange={(e) => setStarts(e.target.value)} />
          <Input label="Valid until (optional)" type="date" value={expires} onChange={(e) => setExpires(e.target.value)} />
        </div>
        {used && <p className="text-xs text-secondary-500">The discount can&apos;t change after the coupon has been used.</p>}
        {app && plans.length > 0 && (
          <fieldset className="rounded-lg border border-secondary-200 p-3">
            <legend className="px-1 text-sm font-medium text-secondary-800">Only for these plans (none = every plan)</legend>
            <div className="flex flex-wrap gap-3">
              {plans.map((p) => (
                <label key={p.uuid} className="flex items-center gap-1.5 text-sm text-secondary-700 cursor-pointer">
                  <input
                    type="checkbox"
                    checked={planIds.includes(p.uuid)}
                    onChange={(e) => setPlanIds((ids) => (e.target.checked ? [...ids, p.uuid] : ids.filter((i) => i !== p.uuid)))}
                  />
                  {p.name}
                </label>
              ))}
            </div>
          </fieldset>
        )}
        <div className="flex items-center justify-between rounded-lg border border-secondary-200 px-3 py-2">
          <p className="text-sm font-medium text-secondary-800">Active</p>
          <Switch checked={active} onChange={setActive} aria-label="Coupon active" />
        </div>
        <div className="flex justify-end gap-2">
          <Button type="button" variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button type="submit" isLoading={saving} disabled={!code.trim() || (!used && !value)}>
            {coupon ? 'Save' : 'Create coupon'}
          </Button>
        </div>
      </form>
    </Modal>
  );
}

function CouponsContent() {
  const { canCreate, canUpdate, canDelete } = usePermissions();
  const [apps, setApps] = useState<BillingApp[]>([]);
  const [rows, setRows] = useState<Coupon[]>([]);
  const [page, setPage] = useState(1);
  const [meta, setMeta] = useState({ total: 0, total_pages: 1 });
  const [loading, setLoading] = useState(true);
  const [editing, setEditing] = useState<Coupon | null>(null);
  const [open, setOpen] = useState(false);
  const [deleteTarget, setDeleteTarget] = useState<Coupon | null>(null);

  useEffect(() => {
    billingService.listApps().then(setApps).catch(() => setApps([]));
  }, []);

  const load = useCallback(() => {
    billingService
      .listCoupons({ page, per_page: PER_PAGE })
      .then((r) => {
        setRows(r.data);
        setMeta({ total: r.meta.total, total_pages: r.meta.total_pages || 1 });
      })
      .catch((err) => toast.error(apiError(err, 'Failed to load coupons')))
      .finally(() => setLoading(false));
  }, [page]);

  useEffect(() => {
    load();
  }, [load]);

  const remove = async () => {
    if (!deleteTarget) return;
    try {
      await billingService.deleteCoupon(deleteTarget.uuid);
      toast.success('Coupon deleted');
      setDeleteTarget(null);
      load();
    } catch (err) {
      toast.error(apiError(err, 'Could not delete'));
    }
  };

  const columns: TableColumn<Coupon>[] = useMemo(
    () => [
      {
        key: 'code',
        header: 'Code',
        render: (c) => (
          <div>
            <code className="font-semibold text-secondary-900">{c.code}</code>
            {c.name && <p className="text-xs text-secondary-500">{c.name}</p>}
          </div>
        ),
      },
      { key: 'discount', header: 'Discount', render: (c) => <span className="text-sm">{describe(c)}</span> },
      {
        key: 'scope',
        header: 'For',
        render: (c) => (
          <span className="text-sm text-secondary-600">
            {c.app_name || 'Every app'}
            {c.plans && c.plans.length > 0 ? ` · ${c.plans.length} plan${c.plans.length > 1 ? 's' : ''}` : ''}
          </span>
        ),
      },
      {
        key: 'uses',
        header: 'Used',
        render: (c) => (
          <span className="tabular-nums">
            {c.redemptions_count}
            {c.max_redemptions ? ` / ${c.max_redemptions}` : ''}
          </span>
        ),
      },
      {
        key: 'valid',
        header: 'Valid',
        render: (c) => (
          <span className="text-sm text-secondary-600">
            {c.starts_at ? formatDate(c.starts_at) : 'Now'} – {c.expires_at ? formatDate(c.expires_at) : 'no end'}
          </span>
        ),
      },
      {
        key: 'status',
        header: 'Status',
        render: (c) => (
          <Pill className={c.active ? 'bg-green-50 text-green-700' : 'bg-secondary-100 text-secondary-500'}>
            {c.active ? 'Active' : 'Off'}
          </Pill>
        ),
      },
      {
        key: 'actions',
        header: '',
        width: 'w-24',
        render: (c) => (
          <div className="flex items-center gap-1">
            {canUpdate('billing') && (
              <button
                type="button"
                onClick={() => {
                  setEditing(c);
                  setOpen(true);
                }}
                className="p-2 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg"
                aria-label={`Edit ${c.code}`}
              >
                <Pencil className="w-4 h-4" />
              </button>
            )}
            {canDelete('billing') && (
              <button
                type="button"
                onClick={() => setDeleteTarget(c)}
                className="p-2 text-secondary-500 hover:text-error-500 hover:bg-error-50 rounded-lg"
                aria-label={`Delete ${c.code}`}
              >
                <Trash2 className="w-4 h-4" />
              </button>
            )}
          </div>
        ),
      },
    ],
    [canUpdate, canDelete]
  );

  return (
    <div className="space-y-6">
      <PageHeader
        title="Coupons"
        description="Discount codes your customers can use at checkout."
        icon={<Tag className="w-5 h-5" />}
        actions={
          canCreate('billing') ? (
            <Button
              onClick={() => {
                setEditing(null);
                setOpen(true);
              }}
            >
              <Plus className="w-4 h-4 mr-1.5" /> New coupon
            </Button>
          ) : undefined
        }
      />
      <BillingNav />
      <Card padding="none">
        <Table columns={columns} data={rows} keyExtractor={(c) => c.uuid} isLoading={loading} emptyMessage="No coupons yet." />
      </Card>
      <Pagination currentPage={page} totalPages={meta.total_pages} totalItems={meta.total} perPage={PER_PAGE} onPageChange={setPage} />
      <CouponModal
        coupon={editing}
        apps={apps}
        isOpen={open}
        onClose={() => setOpen(false)}
        onSaved={() => {
          setOpen(false);
          load();
        }}
      />
      <ConfirmDialog
        isOpen={!!deleteTarget}
        onClose={() => setDeleteTarget(null)}
        onConfirm={remove}
        title={`Delete ${deleteTarget?.code || 'coupon'}?`}
        message="It can no longer be used. Past uses stay in purchases and the plan history."
        confirmText="Delete"
        variant="danger"
      />
    </div>
  );
}

export default function CouponsPage() {
  return (
    <ProtectedPage module="billing" title="Coupons">
      <CouponsContent />
    </ProtectedPage>
  );
}

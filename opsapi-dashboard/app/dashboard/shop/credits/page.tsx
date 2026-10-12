'use client';

import React, { useCallback, useEffect, useState } from 'react';
import { Gift, Plus, Search } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Badge, Button, Card, ConfirmDialog, Input, Modal, Pagination, Table, Textarea } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { FilterSelect } from '@/components/shop/shared';
import { shopService } from '@/services/shop.service';
import { extractApiError, formatDate } from '@/lib/utils';
import { formatMoney, humanize, poundsToMinor } from '@/lib/shop';
import { SHOP_CREDIT_STATUSES, type ShopCredit, type ShopCreditStatus, type TableColumn } from '@/types';

const PER_PAGE = 25;

const STATUS_VARIANT: Record<ShopCreditStatus, 'success' | 'warning' | 'secondary' | 'error'> = {
  available: 'success',
  reserved: 'warning',
  used: 'secondary',
  void: 'error',
};

const SOURCE_LABEL: Record<string, string> = { loyalty: 'Loyalty', vip_refund: 'VIP fee refund', admin: 'Admin' };

/** "£250.00 off the next order over £5,000.00" — the same wording the customer sees. */
function creditLabel(c: Pick<ShopCredit, 'amount_minor' | 'min_order_minor'>): string {
  return `${formatMoney(c.amount_minor)} off the next order${c.min_order_minor > 0 ? ` over ${formatMoney(c.min_order_minor)}` : ''}`;
}

interface GrantForm {
  email: string;
  amount: string;
  minOrder: string;
  reason: string;
  days: string;
  notify: boolean;
}

const EMPTY_FORM: GrantForm = { email: '', amount: '', minOrder: '', reason: '', days: '365', notify: true };

function GiveCreditModal({ open, onClose, onDone }: { open: boolean; onClose: () => void; onDone: () => void }) {
  const [form, setForm] = useState<GrantForm>(EMPTY_FORM);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (open) setForm(EMPTY_FORM);
  }, [open]);

  const amount = poundsToMinor(form.amount);
  const minOrder = form.minOrder.trim() ? poundsToMinor(form.minOrder) : 0;
  const days = parseInt(form.days, 10);
  const valid =
    /\S+@\S+\.\S+/.test(form.email) &&
    amount !== null && amount > 0 &&
    minOrder !== null && minOrder >= 0 &&
    form.reason.trim().length >= 3 &&
    Number.isInteger(days) && days >= 1 && days <= 3650;

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!valid || amount === null || minOrder === null) return;
    setSaving(true);
    try {
      const c = await shopService.grantCredit({
        email: form.email.trim(),
        amount_minor: amount,
        min_order_minor: minOrder,
        reason: form.reason.trim(),
        expires_in_days: days,
        notify: form.notify,
      });
      toast.success(`${creditLabel(c)} given to ${c.email}${c.notified ? ' — customer emailed' : ''}`);
      onDone();
      onClose();
    } catch (err) {
      toast.error(extractApiError(err, 'Failed to give credit'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal isOpen={open} onClose={onClose} title="Give credit" description="Credit towards the customer's next order, saved to their CRM lead." size="md">
      <form onSubmit={submit} className="space-y-4">
        <Input label="Customer email *" id="cr-email" type="email" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} autoFocus />
        <div className="grid gap-4 sm:grid-cols-2">
          <Input label="Credit (£, before VAT) *" id="cr-amount" inputMode="decimal" placeholder="250" value={form.amount} onChange={(e) => setForm({ ...form, amount: e.target.value })} />
          <Input label="On orders over (£, before VAT)" id="cr-min" inputMode="decimal" placeholder="Any order" value={form.minOrder} onChange={(e) => setForm({ ...form, minOrder: e.target.value })} />
        </div>
        <Input label="Use within (days)" id="cr-days" inputMode="numeric" value={form.days} onChange={(e) => setForm({ ...form, days: e.target.value })} />
        <Textarea label="Reason * (saved to the CRM)" id="cr-reason" rows={2} placeholder="e.g. Thank you for the university lab order" value={form.reason} onChange={(e) => setForm({ ...form, reason: e.target.value })} />
        <label className="flex items-start gap-2 text-sm text-secondary-700">
          <input type="checkbox" className="mt-1" checked={form.notify} onChange={(e) => setForm({ ...form, notify: e.target.checked })} />
          Email the customer about their credit and how to use it
        </label>
        {amount !== null && amount > 0 && (
          <p className="rounded-md bg-secondary-50 p-3 text-sm text-secondary-700">
            The customer will see: <strong>{creditLabel({ amount_minor: amount, min_order_minor: minOrder ?? 0 })}</strong> (before VAT). They
            sign in at the shop with this email and it comes off at checkout.
          </p>
        )}
        <div className="flex justify-end gap-2">
          <Button type="button" variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button type="submit" disabled={!valid || saving} isLoading={saving}>
            Give credit
          </Button>
        </div>
      </form>
    </Modal>
  );
}

function CreditsContent() {
  const [rows, setRows] = useState<ShopCredit[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [q, setQ] = useState('');
  const [status, setStatus] = useState<ShopCreditStatus | ''>('');
  const [page, setPage] = useState(1);
  const [giving, setGiving] = useState(false);
  const [toVoid, setToVoid] = useState<ShopCredit | null>(null);
  const [voiding, setVoiding] = useState(false);
  const [reload, setReload] = useState(0);

  useEffect(() => {
    const t = setTimeout(() => {
      setQ(search.trim());
      setPage(1);
    }, 300);
    return () => clearTimeout(t);
  }, [search]);

  useEffect(() => {
    let active = true;
    shopService
      .getCredits({ q: q || undefined, status, limit: PER_PAGE, offset: (page - 1) * PER_PAGE })
      .then((res) => {
        if (!active) return;
        setRows(res.data);
        setTotal(res.meta.total);
      })
      .catch((err) => active && toast.error(extractApiError(err, 'Failed to load credits')))
      .finally(() => active && setLoading(false));
    return () => {
      active = false;
    };
  }, [q, status, page, reload]);

  const refresh = useCallback(() => setReload((n) => n + 1), []);

  const confirmVoid = async () => {
    if (!toVoid) return;
    setVoiding(true);
    try {
      await shopService.voidCredit(toVoid.uuid);
      toast.success('Credit cancelled');
      setToVoid(null);
      refresh();
    } catch (err) {
      toast.error(extractApiError(err, 'Failed to cancel credit'));
    } finally {
      setVoiding(false);
    }
  };

  const columns: TableColumn<ShopCredit>[] = [
    {
      key: 'email',
      header: 'Customer',
      render: (c) => (
        <div className="min-w-0">
          <p className="truncate text-secondary-900">{c.email}</p>
          <p className="text-xs text-secondary-500">{SOURCE_LABEL[c.source] ?? humanize(c.source)}</p>
        </div>
      ),
    },
    {
      key: 'amount',
      header: 'Credit',
      render: (c) => (
        <div>
          <p className="font-medium tabular-nums">{formatMoney(c.amount_minor)}</p>
          <p className="text-xs text-secondary-500">{c.min_order_minor > 0 ? `orders over ${formatMoney(c.min_order_minor)}` : 'any order'}</p>
        </div>
      ),
    },
    {
      key: 'reason',
      header: 'Reason',
      render: (c) => (
        <div className="max-w-xs">
          <p className="line-clamp-2 text-sm text-secondary-700">{c.reason || '—'}</p>
          {c.created_by && <p className="text-xs text-secondary-500">by {c.created_by}</p>}
        </div>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      render: (c) => (
        <div>
          <Badge variant={c.expired && c.status === 'available' ? 'secondary' : STATUS_VARIANT[c.status]}>
            {c.expired && c.status === 'available' ? 'Expired' : humanize(c.status)}
          </Badge>
          {c.used_order_number && <p className="mt-1 font-mono text-xs text-secondary-500">{c.used_order_number}</p>}
          {c.reserved_order_number && <p className="mt-1 text-xs text-secondary-500">checkout {c.reserved_order_number}</p>}
        </div>
      ),
    },
    {
      key: 'dates',
      header: 'Given / use by',
      render: (c) => (
        <div className="text-sm text-secondary-600">
          <p className="whitespace-nowrap">{formatDate(c.created_at)}</p>
          {c.expires_at && <p className="whitespace-nowrap text-xs">use by {formatDate(c.expires_at)}</p>}
        </div>
      ),
    },
    {
      key: 'actions',
      header: '',
      render: (c) =>
        c.status === 'available' && !c.expired ? (
          <Button size="sm" variant="ghost" onClick={() => setToVoid(c)}>
            Cancel
          </Button>
        ) : null,
    },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="Customer credit"
        description="Reward big buyers with credit towards their next order. Every credit is saved to the customer's CRM lead."
        icon={<Gift className="h-5 w-5" />}
        actions={
          <Button onClick={() => setGiving(true)} leftIcon={<Plus className="h-4 w-4" />}>
            Give credit
          </Button>
        }
      />

      <Card padding="md">
        <div className="flex flex-wrap items-center gap-4">
          <div className="min-w-[200px] max-w-sm flex-1">
            <Input placeholder="Email or reason…" aria-label="Search credits" value={search} onChange={(e) => setSearch(e.target.value)} leftIcon={<Search className="h-4 w-4" />} />
          </div>
          <FilterSelect
            aria-label="Status"
            value={status}
            onChange={(e) => {
              setStatus(e.target.value as ShopCreditStatus | '');
              setPage(1);
            }}
          >
            <option value="">All statuses</option>
            {SHOP_CREDIT_STATUSES.map((s) => (
              <option key={s} value={s}>
                {humanize(s)}
              </option>
            ))}
          </FilterSelect>
        </div>
      </Card>

      <div>
        <Table columns={columns} data={rows} keyExtractor={(c) => c.uuid} isLoading={loading} emptyMessage="No credit given yet" caption="Customer credit" />
        <Pagination currentPage={page} totalPages={Math.max(1, Math.ceil(total / PER_PAGE))} totalItems={total} perPage={PER_PAGE} onPageChange={setPage} />
      </div>

      <GiveCreditModal open={giving} onClose={() => setGiving(false)} onDone={refresh} />
      <ConfirmDialog
        isOpen={!!toVoid}
        onClose={() => setToVoid(null)}
        onConfirm={confirmVoid}
        title="Cancel credit"
        message={toVoid ? `Cancel ${creditLabel(toVoid)} for ${toVoid.email}? They won't be able to use it. A note is added to their CRM lead.` : ''}
        confirmText="Cancel credit"
        variant="danger"
        isLoading={voiding}
      />
    </div>
  );
}

export default function ShopCreditsPage() {
  return (
    <ProtectedPage module="shop" title="Shop Credit">
      <CreditsContent />
    </ProtectedPage>
  );
}

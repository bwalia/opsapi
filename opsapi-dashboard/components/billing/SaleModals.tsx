'use client';

/**
 * Record a sale by hand (cash, invoice, reseller…) and upgrade a customer.
 * Both go through the same fulfilment as checkout: licences are created or
 * extended, coupons are redeemed, and the plan history records it.
 */

import React, { useEffect, useState } from 'react';
import toast from 'react-hot-toast';
import { AlertTriangle } from 'lucide-react';
import { Button, Input, Modal, Select, Textarea } from '@/components/ui';
import { apiError } from '@/components/field-service/shared';
import { CopyButton, CustomerPicker } from '@/components/billing/shared';
import {
  billingService,
  describePrice,
  formatMinor,
  type BillingApp,
  type BillingPlan,
  type SaleResult,
} from '@/services/billing.service';

function KeyOnce({ licenceKey, onDone }: { licenceKey: string; onDone: () => void }) {
  return (
    <div className="space-y-4">
      <div className="flex items-start gap-2 rounded-lg bg-amber-50 p-3 text-sm text-amber-800">
        <AlertTriangle className="w-4 h-4 mt-0.5 shrink-0" aria-hidden />
        <p>A licence key was issued. Copy it now and send it to the customer. It won&apos;t be shown again.</p>
      </div>
      <div className="flex items-center gap-2 rounded-lg border border-secondary-200 bg-secondary-50 px-3 py-3">
        <code className="flex-1 break-all text-base tracking-wider text-secondary-900">{licenceKey}</code>
        <CopyButton value={licenceKey} label="Copy licence key" />
      </div>
      <div className="flex justify-end">
        <Button onClick={onDone}>Done</Button>
      </div>
    </div>
  );
}

function useApps(isOpen: boolean, fixedApp?: string) {
  const [apps, setApps] = useState<BillingApp[]>([]);
  const [app, setApp] = useState('');
  const [plans, setPlans] = useState<BillingPlan[]>([]);
  useEffect(() => {
    if (!isOpen) return;
    billingService
      .listApps()
      .then((list) => {
        setApps(list);
        setApp(fixedApp || (list.length === 1 ? list[0].uuid : ''));
      })
      .catch(() => setApps([]));
  }, [isOpen, fixedApp]);
  useEffect(() => {
    if (!app) return;
    billingService.listPlans(app).then((p) => setPlans(p.filter((x) => x.active))).catch(() => setPlans([]));
  }, [app]);
  return { apps, app, setApp, plans: app ? plans : [] };
}

export function SaleModal({
  isOpen,
  onClose,
  onSaved,
  customer: fixedCustomer,
}: {
  isOpen: boolean;
  onClose: () => void;
  onSaved: () => void;
  customer?: string;
}) {
  const { apps, app, setApp, plans } = useApps(isOpen);
  const [customer, setCustomer] = useState('');
  const [plan, setPlan] = useState('');
  const [price, setPrice] = useState('');
  const [coupon, setCoupon] = useState('');
  const [expires, setExpires] = useState('');
  const [note, setNote] = useState('');
  const [saving, setSaving] = useState(false);
  const [result, setResult] = useState<SaleResult | null>(null);
  const chosen = plans.find((p) => p.uuid === plan);

  useEffect(() => {
    if (!isOpen) return;
    setCustomer(fixedCustomer || '');
    setPlan('');
    setPrice('');
    setCoupon('');
    setExpires('');
    setNote('');
    setResult(null);
  }, [isOpen, fixedCustomer]);

  useEffect(() => {
    if (chosen) setPrice(String(chosen.amount / 100));
  }, [chosen]);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setSaving(true);
    try {
      const res = await billingService.sell({
        app,
        customer,
        plan,
        amount: Math.round(Number(price) * 100),
        coupon: coupon.trim() || undefined,
        note: note.trim() || undefined,
        expires_at: chosen?.purchase_type === 'recurring' && expires ? `${expires}T23:59:59Z` : undefined,
      });
      toast.success('Sale recorded');
      onSaved();
      if (res.key) setResult(res);
      else onClose();
    } catch (err) {
      toast.error(apiError(err, 'Could not record the sale'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Record a sale" description="A sale made outside checkout: cash, invoice, reseller or a gift." size="lg">
      {result?.key ? (
        <KeyOnce licenceKey={result.key} onDone={onClose} />
      ) : (
        <form onSubmit={submit} className="space-y-4">
          <Select label="App" value={app} onChange={(e) => setApp(e.target.value)} required>
            <option value="">Choose an app…</option>
            {apps.map((a) => (
              <option key={a.uuid} value={a.uuid}>
                {a.name}
              </option>
            ))}
          </Select>
          {!fixedCustomer && <CustomerPicker value={customer} onChange={setCustomer} />}
          <Select label="Plan" value={plan} onChange={(e) => setPlan(e.target.value)} required disabled={!app}>
            <option value="">Choose a plan…</option>
            {plans.map((p) => (
              <option key={p.uuid} value={p.uuid}>
                {p.name} — {describePrice(p)}
              </option>
            ))}
          </Select>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <Input
              label={`Amount paid${chosen ? ` (${chosen.currency.toUpperCase()})` : ''}`}
              type="number"
              min={0}
              step="0.01"
              value={price}
              onChange={(e) => setPrice(e.target.value)}
              helperText="Before any coupon"
              required
            />
            <Input label="Coupon (optional)" value={coupon} onChange={(e) => setCoupon(e.target.value.toUpperCase())} className="font-mono" />
            {chosen?.purchase_type === 'recurring' && (
              <Input label="Paid until" type="date" value={expires} onChange={(e) => setExpires(e.target.value)} required />
            )}
          </div>
          <Textarea label="Note (optional)" value={note} onChange={(e) => setNote(e.target.value)} rows={2} />
          <div className="flex justify-end gap-2">
            <Button type="button" variant="outline" onClick={onClose}>
              Cancel
            </Button>
            <Button type="submit" isLoading={saving} disabled={!app || !customer || !plan}>
              Record sale
            </Button>
          </div>
        </form>
      )}
    </Modal>
  );
}

export function UpgradeModal({
  isOpen,
  onClose,
  onSaved,
  customer: fixedCustomer,
}: {
  isOpen: boolean;
  onClose: () => void;
  onSaved: () => void;
  customer?: string;
}) {
  const { apps, app, setApp, plans } = useApps(isOpen);
  const [customer, setCustomer] = useState('');
  const [toPlan, setToPlan] = useState('');
  const [coupon, setCoupon] = useState('');
  const [quote, setQuote] = useState<SaleResult | null>(null);
  const [quoteError, setQuoteError] = useState('');
  const [saving, setSaving] = useState(false);
  const [result, setResult] = useState<SaleResult | null>(null);

  useEffect(() => {
    if (!isOpen) return;
    setCustomer(fixedCustomer || '');
    setToPlan('');
    setCoupon('');
    setQuote(null);
    setResult(null);
  }, [isOpen, fixedCustomer]);

  useEffect(() => {
    if (!app || !customer || !toPlan) {
      setQuote(null);
      setQuoteError('');
      return;
    }
    let alive = true;
    const t = setTimeout(() => {
      billingService
        .upgrade({ app, customer, to_plan: toPlan, coupon: coupon.trim() || undefined }, true)
        .then((q) => {
          if (!alive) return;
          setQuote(q);
          setQuoteError('');
        })
        .catch((err) => {
          if (!alive) return;
          setQuote(null);
          setQuoteError(apiError(err, 'This upgrade is not available'));
        });
    }, 300);
    return () => {
      alive = false;
      clearTimeout(t);
    };
  }, [app, customer, toPlan, coupon]);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setSaving(true);
    try {
      const res = await billingService.upgrade({ app, customer, to_plan: toPlan, coupon: coupon.trim() || undefined });
      toast.success(
        res.pending
          ? `Switch to ${res.to_plan?.name ?? 'the new plan'} sent to Stripe: it applies once the prorated invoice is paid`
          : `Upgraded to ${res.to_plan?.name ?? 'the new plan'}`
      );
      onSaved();
      if (res.key) setResult(res);
      else onClose();
    } catch (err) {
      toast.error(apiError(err, 'Could not upgrade'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Upgrade a customer" description="Along one of the app's upgrade paths. Licences keep their key." size="lg">
      {result?.key ? (
        <KeyOnce licenceKey={result.key} onDone={onClose} />
      ) : (
        <form onSubmit={submit} className="space-y-4">
          <Select label="App" value={app} onChange={(e) => setApp(e.target.value)} required>
            <option value="">Choose an app…</option>
            {apps.map((a) => (
              <option key={a.uuid} value={a.uuid}>
                {a.name}
              </option>
            ))}
          </Select>
          {!fixedCustomer && <CustomerPicker value={customer} onChange={setCustomer} />}
          <Select label="Upgrade to" value={toPlan} onChange={(e) => setToPlan(e.target.value)} required disabled={!app}>
            <option value="">Choose a plan…</option>
            {plans.map((p) => (
              <option key={p.uuid} value={p.uuid}>
                {p.name}
              </option>
            ))}
          </Select>
          <Input label="Coupon (optional)" value={coupon} onChange={(e) => setCoupon(e.target.value.toUpperCase())} className="font-mono" />
          {quote && (
            <div className="rounded-lg border border-secondary-200 bg-secondary-50 p-3 text-sm" aria-live="polite">
              <p>
                {quote.from_plan?.name} → {quote.to_plan?.name}:{' '}
                <strong>{formatMinor(quote.amount ?? 0, quote.currency || 'gbp')}</strong>
                {quote.discount ? ` (after ${formatMinor(quote.discount, quote.currency || 'gbp')} off)` : ''}
              </p>
            </div>
          )}
          {quoteError && (
            <p className="text-sm text-error-600" role="alert">
              {quoteError}
            </p>
          )}
          <div className="flex justify-end gap-2">
            <Button type="button" variant="outline" onClick={onClose}>
              Cancel
            </Button>
            <Button type="submit" isLoading={saving} disabled={!quote}>
              Upgrade
            </Button>
          </div>
        </form>
      )}
    </Modal>
  );
}

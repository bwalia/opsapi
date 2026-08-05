'use client';

import React, { useCallback, useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { ArrowLeft, Landmark, CheckCircle2, AlertCircle, Wallet } from 'lucide-react';
import { Card, CardHeader, CardContent, Button, Badge } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import {
  academyService,
  type CreatorAccount,
  type CreatorBank,
} from '@/services/academy.service';
import toast from 'react-hot-toast';

const inputClass =
  'w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500';

const money = (minor: number, currency: string): string =>
  (minor / 100).toLocaleString(undefined, { style: 'currency', currency: (currency || 'usd').toUpperCase() });

const EMPTY_BANK: CreatorBank = {
  account_holder_name: '',
  bank_name: '',
  account_number: '',
  sort_code: '',
  routing_number: '',
  iban: '',
  swift_bic: '',
  bank_country: '',
  payout_email: '',
};

function CreatorMonetization(): React.ReactElement {
  const router = useRouter();
  const [account, setAccount] = useState<CreatorAccount | null>(null);
  const [loading, setLoading] = useState(true);

  const [bank, setBank] = useState<CreatorBank>(EMPTY_BANK);
  const [savingBank, setSavingBank] = useState(false);

  const [price, setPrice] = useState('');
  const [interval, setInterval] = useState<'month' | 'year'>('month');
  const [savingPlan, setSavingPlan] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const acc = await academyService.getCreatorAccount();
      setAccount(acc);
      setBank({ ...EMPTY_BANK, ...(acc.bank ?? {}) });
      if (acc.plan) {
        setPrice((acc.plan.amount / 100).toString());
        setInterval(acc.plan.interval === 'year' ? 'year' : 'month');
      }
    } catch (err) {
      console.error('Load creator account failed:', err);
      toast.error('Failed to load your monetization info');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const setBankField = (k: keyof CreatorBank, v: string) =>
    setBank((prev) => ({ ...prev, [k]: v }));

  const handleSaveBank = async (e: React.FormEvent): Promise<void> => {
    e.preventDefault();
    if (!bank.account_holder_name?.trim()) {
      toast.error('Account holder name is required');
      return;
    }
    if (!bank.account_number?.trim() && !bank.iban?.trim()) {
      toast.error('Enter an account number or IBAN');
      return;
    }
    setSavingBank(true);
    try {
      await academyService.saveBankDetails(bank);
      toast.success('Bank details saved');
      load();
    } catch (err) {
      console.error('Save bank failed:', err);
      toast.error('Failed to save bank details');
    } finally {
      setSavingBank(false);
    }
  };

  const handleSavePlan = async (e: React.FormEvent): Promise<void> => {
    e.preventDefault();
    const dollars = Number(price);
    if (!dollars || dollars <= 0) {
      toast.error('Enter a valid price');
      return;
    }
    setSavingPlan(true);
    try {
      await academyService.setSubscriptionPlan({ amount: Math.round(dollars * 100), interval });
      toast.success('Community membership price saved');
      load();
    } catch (err) {
      console.error('Save plan failed:', err);
      toast.error('Failed to save price');
    } finally {
      setSavingPlan(false);
    }
  };

  const e = account?.earnings;

  return (
    <div className="space-y-6 max-w-3xl">
      <button
        onClick={() => router.push('/dashboard/academy')}
        className="inline-flex items-center gap-1.5 text-sm text-secondary-500 hover:text-secondary-900"
      >
        <ArrowLeft size={16} /> Back to courses
      </button>

      <div>
        <h1 className="text-xl font-bold text-secondary-900">Monetization</h1>
        <p className="text-sm text-secondary-500">
          Sales are processed by the platform. We keep a {account ? account.fee_pct : '…'}% fee and
          pay you the rest to the bank account below.
        </p>
      </div>

      {/* Earnings */}
      <Card>
        <CardHeader>
          <div className="flex items-center gap-2">
            <Wallet size={18} className="text-primary-600" />
            <h2 className="text-sm font-semibold text-secondary-800">Earnings</h2>
          </div>
        </CardHeader>
        <CardContent>
          {loading || !e ? (
            <div className="h-10 animate-pulse rounded bg-secondary-100" />
          ) : (
            <div className="grid grid-cols-3 gap-4">
              <div>
                <p className="text-xs text-secondary-500">Owed to you</p>
                <p className="text-lg font-bold text-secondary-900">{money(e.owed, e.currency)}</p>
              </div>
              <div>
                <p className="text-xs text-secondary-500">Paid out</p>
                <p className="text-lg font-semibold text-secondary-700">{money(e.paid, e.currency)}</p>
              </div>
              <div>
                <p className="text-xs text-secondary-500">Sales</p>
                <p className="text-lg font-semibold text-secondary-700">{e.sales}</p>
              </div>
            </div>
          )}
        </CardContent>
      </Card>

      {/* Bank details */}
      <Card>
        <CardHeader>
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-2">
              <Landmark size={18} className="text-primary-600" />
              <h2 className="text-sm font-semibold text-secondary-800">Payout bank details</h2>
            </div>
            {account?.bank_details_complete ? (
              <Badge variant="success" className="inline-flex items-center gap-1">
                <CheckCircle2 size={14} /> Complete
              </Badge>
            ) : (
              <Badge variant="warning" className="inline-flex items-center gap-1">
                <AlertCircle size={14} /> Add details to get paid
              </Badge>
            )}
          </div>
        </CardHeader>
        <CardContent>
          <form onSubmit={handleSaveBank} className="grid grid-cols-2 gap-4">
            <div className="col-span-2">
              <label className="block text-sm font-medium text-secondary-700 mb-1">Account holder name *</label>
              <input className={inputClass} value={bank.account_holder_name ?? ''} onChange={(ev) => setBankField('account_holder_name', ev.target.value)} />
            </div>
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">Bank name</label>
              <input className={inputClass} value={bank.bank_name ?? ''} onChange={(ev) => setBankField('bank_name', ev.target.value)} />
            </div>
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">Country</label>
              <input className={inputClass} value={bank.bank_country ?? ''} onChange={(ev) => setBankField('bank_country', ev.target.value)} placeholder="e.g. GB / US" />
            </div>
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">Account number</label>
              <input className={inputClass} value={bank.account_number ?? ''} onChange={(ev) => setBankField('account_number', ev.target.value)} />
            </div>
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">Sort code (UK)</label>
              <input className={inputClass} value={bank.sort_code ?? ''} onChange={(ev) => setBankField('sort_code', ev.target.value)} />
            </div>
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">Routing number (US)</label>
              <input className={inputClass} value={bank.routing_number ?? ''} onChange={(ev) => setBankField('routing_number', ev.target.value)} />
            </div>
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">IBAN</label>
              <input className={inputClass} value={bank.iban ?? ''} onChange={(ev) => setBankField('iban', ev.target.value)} />
            </div>
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">SWIFT / BIC</label>
              <input className={inputClass} value={bank.swift_bic ?? ''} onChange={(ev) => setBankField('swift_bic', ev.target.value)} />
            </div>
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">Payout email</label>
              <input className={inputClass} type="email" value={bank.payout_email ?? ''} onChange={(ev) => setBankField('payout_email', ev.target.value)} />
            </div>
            <div className="col-span-2">
              <Button type="submit" isLoading={savingBank}>Save bank details</Button>
            </div>
          </form>
        </CardContent>
      </Card>

      {/* Community membership price */}
      <Card>
        <CardHeader>
          <h2 className="text-sm font-semibold text-secondary-800">Community membership price</h2>
        </CardHeader>
        <CardContent>
          <form onSubmit={handleSavePlan} className="space-y-4">
            {account?.plan ? (
              <p className="text-sm text-secondary-600">
                Current: <span className="font-medium text-secondary-900">{money(account.plan.amount, account.plan.currency)}</span> / {account.plan.interval}
              </p>
            ) : null}
            <div className="grid grid-cols-2 gap-4">
              <div>
                <label className="block text-sm font-medium text-secondary-700 mb-1">Price</label>
                <input className={inputClass} type="number" min={1} step="0.01" value={price} onChange={(ev) => setPrice(ev.target.value)} placeholder="9.99" />
              </div>
              <div>
                <label className="block text-sm font-medium text-secondary-700 mb-1">Billing</label>
                <select className={inputClass} value={interval} onChange={(ev) => setInterval(ev.target.value as 'month' | 'year')}>
                  <option value="month">Monthly</option>
                  <option value="year">Yearly</option>
                </select>
              </div>
            </div>
            <p className="text-xs text-secondary-400">Members who subscribe get access to all of your courses.</p>
            <Button type="submit" isLoading={savingPlan}>Save price</Button>
          </form>
        </CardContent>
      </Card>
    </div>
  );
}

export default function CreatorMonetizationPage(): React.ReactElement {
  return (
    <ProtectedPage module="courses" action="read" title="Monetization">
      <CreatorMonetization />
    </ProtectedPage>
  );
}

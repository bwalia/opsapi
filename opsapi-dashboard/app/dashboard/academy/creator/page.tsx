'use client';

import React, { Suspense, useCallback, useEffect, useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import {
  ArrowLeft,
  CreditCard,
  CheckCircle2,
  AlertCircle,
  ExternalLink,
} from 'lucide-react';
import { Card, CardHeader, CardContent, Button, Badge } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import {
  academyService,
  type CreatorAccountStatus,
} from '@/services/academy.service';
import toast from 'react-hot-toast';

const inputClass =
  'w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500';

function CreatorMonetization(): React.ReactElement {
  const router = useRouter();
  const searchParams = useSearchParams();

  const [account, setAccount] = useState<CreatorAccountStatus | null>(null);
  const [loading, setLoading] = useState(true);
  const [connecting, setConnecting] = useState(false);

  const [price, setPrice] = useState('');
  const [interval, setInterval] = useState<'month' | 'year'>('month');
  const [savingPlan, setSavingPlan] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const acc = await academyService.getCreatorAccount();
      setAccount(acc);
      if (acc.plan) {
        setPrice((acc.plan.amount / 100).toString());
        setInterval(acc.plan.interval === 'year' ? 'year' : 'month');
      }
    } catch (err) {
      console.error('Load creator account failed:', err);
      toast.error('Failed to load your monetization status');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  useEffect(() => {
    if (searchParams.get('connect') === 'done') {
      toast.success('Returned from Stripe — status updated.');
    }
  }, [searchParams]);

  const handleConnect = async (): Promise<void> => {
    setConnecting(true);
    try {
      const url = await academyService.startCreatorOnboarding();
      if (url) {
        window.location.href = url;
      } else {
        toast.error('Could not start Stripe onboarding');
        setConnecting(false);
      }
    } catch (err) {
      console.error('Stripe onboarding failed:', err);
      toast.error('Could not start Stripe onboarding');
      setConnecting(false);
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
      await academyService.setSubscriptionPlan({
        amount: Math.round(dollars * 100),
        interval,
      });
      toast.success('Community subscription price saved');
      load();
    } catch (err) {
      console.error('Save plan failed:', err);
      toast.error('Failed to save price — complete Stripe onboarding first');
    } finally {
      setSavingPlan(false);
    }
  };

  const chargesEnabled = account?.charges_enabled === true;

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
          Connect Stripe to sell courses and a community membership. Payouts and
          tax forms are handled by Stripe; the platform keeps a small fee.
        </p>
      </div>

      {/* Stripe Connect */}
      <Card>
        <CardHeader>
          <div className="flex items-center gap-2">
            <CreditCard size={18} className="text-primary-600" />
            <h2 className="text-sm font-semibold text-secondary-800">Payouts (Stripe)</h2>
          </div>
        </CardHeader>
        <CardContent>
          {loading ? (
            <div className="h-10 animate-pulse rounded bg-secondary-100" />
          ) : chargesEnabled ? (
            <div className="flex items-center gap-2 text-sm text-secondary-700">
              <Badge variant="success" className="inline-flex items-center gap-1">
                <CheckCircle2 size={14} /> Connected
              </Badge>
              <span>Your account can accept payments and receive payouts.</span>
            </div>
          ) : (
            <div className="space-y-3">
              <div className="flex items-center gap-2 text-sm text-secondary-600">
                <AlertCircle size={16} className="text-amber-500" />
                {account?.status === 'pending'
                  ? 'Onboarding started but not finished.'
                  : 'Not connected yet.'}
              </div>
              <Button
                isLoading={connecting}
                leftIcon={<ExternalLink size={16} />}
                onClick={() => void handleConnect()}
              >
                {account?.status === 'pending' ? 'Finish Stripe onboarding' : 'Connect with Stripe'}
              </Button>
            </div>
          )}
        </CardContent>
      </Card>

      {/* Community subscription price */}
      <Card>
        <CardHeader>
          <h2 className="text-sm font-semibold text-secondary-800">Community membership price</h2>
        </CardHeader>
        <CardContent>
          {!chargesEnabled ? (
            <p className="text-sm text-secondary-500">
              Connect Stripe above to set a membership price. Members who subscribe
              get access to all of your courses.
            </p>
          ) : (
            <form onSubmit={handleSavePlan} className="space-y-4">
              {account?.plan ? (
                <p className="text-sm text-secondary-600">
                  Current: <span className="font-medium text-secondary-900">
                    {(account.plan.amount / 100).toLocaleString(undefined, { style: 'currency', currency: (account.plan.currency || 'usd').toUpperCase() })}
                  </span> / {account.plan.interval}
                </p>
              ) : null}
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-secondary-700 mb-1">Price</label>
                  <input className={inputClass} type="number" min={1} step="0.01" value={price} onChange={(e) => setPrice(e.target.value)} placeholder="9.99" />
                </div>
                <div>
                  <label className="block text-sm font-medium text-secondary-700 mb-1">Billing</label>
                  <select className={inputClass} value={interval} onChange={(e) => setInterval(e.target.value as 'month' | 'year')}>
                    <option value="month">Monthly</option>
                    <option value="year">Yearly</option>
                  </select>
                </div>
              </div>
              <p className="text-xs text-secondary-400">
                Changing the price creates a new Stripe price; existing members keep their current rate until they resubscribe.
              </p>
              <Button type="submit" isLoading={savingPlan}>Save price</Button>
            </form>
          )}
        </CardContent>
      </Card>
    </div>
  );
}

export default function CreatorMonetizationPage(): React.ReactElement {
  return (
    <ProtectedPage module="courses" action="read" title="Monetization">
      <Suspense fallback={<div className="p-6 text-sm text-secondary-500">Loading…</div>}>
        <CreatorMonetization />
      </Suspense>
    </ProtectedPage>
  );
}

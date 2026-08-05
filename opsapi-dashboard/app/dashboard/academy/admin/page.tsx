'use client';

import React, { useCallback, useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { ArrowLeft, Percent, Banknote, RefreshCw } from 'lucide-react';
import { Card, CardHeader, CardContent, Button, Badge } from '@/components/ui';
import { usePermissions } from '@/contexts/PermissionsContext';
import { AccessDenied } from '@/components/permissions';
import { academyService, type PayoutRow } from '@/services/academy.service';
import toast from 'react-hot-toast';

const inputClass =
  'w-28 px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500';

const money = (minor: number, currency: string): string =>
  ((minor || 0) / 100).toLocaleString(undefined, { style: 'currency', currency: (currency || 'usd').toUpperCase() });

function bankSummary(bank: PayoutRow['bank']): string {
  if (!bank) return 'No bank details';
  const acct = bank.iban || bank.account_number || '—';
  const extra = bank.sort_code || bank.swift_bic || bank.routing_number || '';
  return `${bank.account_holder_name || '—'} · ${acct}${extra ? ' · ' + extra : ''}`;
}

function AdminPayouts(): React.ReactElement {
  const router = useRouter();
  const [defaultFee, setDefaultFee] = useState('');
  const [savingFee, setSavingFee] = useState(false);
  const [payouts, setPayouts] = useState<PayoutRow[]>([]);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [fee, rows] = await Promise.all([
        academyService.getDefaultFeePct(),
        academyService.getPayouts(),
      ]);
      setDefaultFee(String(fee));
      setPayouts(rows);
    } catch (err) {
      console.error('Load admin payouts failed:', err);
      toast.error('Failed to load payouts');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const saveFee = async (): Promise<void> => {
    const pct = Number(defaultFee);
    if (Number.isNaN(pct) || pct < 0 || pct > 100) {
      toast.error('Cut must be 0–100');
      return;
    }
    setSavingFee(true);
    try {
      await academyService.setDefaultFeePct(pct);
      toast.success('Default platform cut saved');
    } catch (err) {
      console.error('Save fee failed:', err);
      toast.error('Failed to save');
    } finally {
      setSavingFee(false);
    }
  };

  const setOverride = async (r: PayoutRow): Promise<void> => {
    const input = window.prompt(
      `Per-instructor cut % for ${r.instructor_name} (blank = use default):`,
      '',
    );
    if (input === null) return;
    const pct = input.trim() === '' ? null : Number(input);
    if (pct !== null && (Number.isNaN(pct) || pct < 0 || pct > 100)) {
      toast.error('Enter 0–100 or blank');
      return;
    }
    try {
      await academyService.setInstructorFeeOverride(r.user_uuid, pct);
      toast.success('Cut override updated');
    } catch (err) {
      console.error('Override failed:', err);
      toast.error('Failed to update override');
    }
  };

  const markPaid = async (r: PayoutRow): Promise<void> => {
    const ref = window.prompt(
      `Mark ${money(r.owed, r.currency)} as paid to ${r.instructor_name}? Optional bank reference:`,
      '',
    );
    if (ref === null) return;
    try {
      const res = await academyService.markPayoutPaid(r.user_uuid, ref);
      toast.success(`Recorded payout of ${money(res.amount, res.currency)}`);
      load();
    } catch (err) {
      console.error('Mark paid failed:', err);
      toast.error('Failed to mark paid');
    }
  };

  return (
    <div className="space-y-6">
      <button
        onClick={() => router.push('/dashboard/academy')}
        className="inline-flex items-center gap-1.5 text-sm text-secondary-500 hover:text-secondary-900"
      >
        <ArrowLeft size={16} /> Back to courses
      </button>

      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-bold text-secondary-900">Academy payouts &amp; fees</h1>
          <p className="text-sm text-secondary-500">Set the platform cut and pay instructors their owed earnings.</p>
        </div>
        <Button variant="outline" leftIcon={<RefreshCw size={16} />} onClick={load}>Refresh</Button>
      </div>

      {/* Global default cut */}
      <Card>
        <CardHeader>
          <div className="flex items-center gap-2">
            <Percent size={18} className="text-primary-600" />
            <h2 className="text-sm font-semibold text-secondary-800">Default platform cut</h2>
          </div>
        </CardHeader>
        <CardContent>
          <div className="flex items-end gap-3">
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">Cut %</label>
              <input className={inputClass} type="number" min={0} max={100} step="0.5" value={defaultFee} onChange={(e) => setDefaultFee(e.target.value)} />
            </div>
            <Button isLoading={savingFee} onClick={() => void saveFee()}>Save</Button>
            <p className="text-xs text-secondary-400 pb-2">Applied to every instructor unless they have an override.</p>
          </div>
        </CardContent>
      </Card>

      {/* Payouts owed */}
      <Card>
        <CardHeader>
          <div className="flex items-center gap-2">
            <Banknote size={18} className="text-primary-600" />
            <h2 className="text-sm font-semibold text-secondary-800">Owed to instructors</h2>
          </div>
        </CardHeader>
        <CardContent>
          {loading ? (
            <div className="h-16 animate-pulse rounded bg-secondary-100" />
          ) : payouts.length === 0 ? (
            <p className="text-sm text-secondary-500">Nothing owed right now.</p>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="text-left text-secondary-500 border-b border-secondary-200">
                    <th className="py-2 pr-4 font-medium">Instructor</th>
                    <th className="py-2 pr-4 font-medium">Owed</th>
                    <th className="py-2 pr-4 font-medium">Sales</th>
                    <th className="py-2 pr-4 font-medium">Bank</th>
                    <th className="py-2 pr-4 font-medium text-right">Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {payouts.map((r) => (
                    <tr key={r.user_uuid} className="border-b border-secondary-100">
                      <td className="py-3 pr-4">
                        <p className="font-medium text-secondary-900">{r.instructor_name}</p>
                        {r.instructor_email && <p className="text-xs text-secondary-400">{r.instructor_email}</p>}
                      </td>
                      <td className="py-3 pr-4 font-semibold text-secondary-900">{money(r.owed, r.currency)}</td>
                      <td className="py-3 pr-4 text-secondary-600">{r.sales}</td>
                      <td className="py-3 pr-4 max-w-xs">
                        {r.bank?.complete ? (
                          <span className="text-secondary-600">{bankSummary(r.bank)}</span>
                        ) : (
                          <Badge variant="warning">No bank details</Badge>
                        )}
                      </td>
                      <td className="py-3 pr-0 text-right whitespace-nowrap">
                        <button onClick={() => void setOverride(r)} className="mr-2 text-xs text-secondary-500 hover:text-secondary-900 underline">Set cut %</button>
                        <Button size="sm" disabled={!r.bank?.complete} onClick={() => void markPaid(r)}>Mark paid</Button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}

export default function AcademyAdminPage(): React.ReactElement {
  const { isAdmin, isLoading } = usePermissions();
  if (isLoading) {
    return <div className="p-6"><div className="h-32 animate-pulse rounded bg-secondary-100" /></div>;
  }
  if (!isAdmin) {
    return <AccessDenied title="Cannot Access Academy Payouts" message="This area is for platform administrators only." />;
  }
  return <AdminPayouts />;
}

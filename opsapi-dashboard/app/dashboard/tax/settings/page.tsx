'use client';

import React, { useEffect, useState, useCallback, Suspense } from 'react';
import { useSearchParams } from 'next/navigation';
import {
  Link2,
  CheckCircle,
  AlertCircle,
  Loader2,
  RefreshCw,
  ShieldCheck,
  FlaskConical,
  Calculator,
  Building2,
  KeyRound,
} from 'lucide-react';
import { Card } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { taxService } from '@/services/tax.service';
import { formatDateTime, formatCurrency, extractApiError } from '@/lib/utils';
import toast from 'react-hot-toast';

interface HmrcStatus {
  connected: boolean;
  is_valid?: boolean;
  expires_at?: string;
  scope?: string;
}

type TestUser = Awaited<ReturnType<typeof taxService.createHmrcSandboxTestUser>>;
type CalcResult = Awaited<ReturnType<typeof taxService.calculateHmrcPreview>>;

function HmrcSettingsContent() {
  const searchParams = useSearchParams();
  const [status, setStatus] = useState<HmrcStatus | null>(null);
  const [loading, setLoading] = useState(true);
  const [connecting, setConnecting] = useState(false);

  // Sandbox tooling state
  const [testUser, setTestUser] = useState<TestUser | null>(null);
  const [creatingUser, setCreatingUser] = useState(false);
  const [provisioning, setProvisioning] = useState(false);

  // Preview-calculation state
  const [taxYear, setTaxYear] = useState('2025-26');
  const [calculating, setCalculating] = useState(false);
  const [calc, setCalc] = useState<CalcResult | null>(null);

  const fetchStatus = useCallback(async () => {
    setLoading(true);
    try {
      setStatus(await taxService.getHmrcStatus());
    } catch {
      toast.error('Failed to load HMRC status');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchStatus();
  }, [fetchStatus]);

  // OAuth callback landing: `?hmrc_connected=true` or `?hmrc_error=...`.
  useEffect(() => {
    if (searchParams.get('hmrc_connected') === 'true') {
      toast.success('Connected to HMRC');
      fetchStatus();
    }
    const err = searchParams.get('hmrc_error');
    if (err) toast.error(`HMRC connection failed: ${err.replace(/_/g, ' ')}`);
  }, [searchParams, fetchStatus]);

  const handleConnect = async () => {
    setConnecting(true);
    try {
      const redirectUrl = `${window.location.origin}/dashboard/tax`;
      const authUrl = await taxService.initiateHmrcConnect(redirectUrl);
      if (!authUrl) throw new Error('No auth URL returned');
      window.location.href = authUrl;
    } catch {
      toast.error('Failed to start HMRC connection');
      setConnecting(false);
    }
  };

  const handleDisconnect = async () => {
    if (!confirm('Disconnect from HMRC? You will need to reconnect before filing.')) return;
    try {
      await taxService.disconnectHmrc();
      toast.success('Disconnected from HMRC');
      fetchStatus();
    } catch {
      toast.error('Failed to disconnect');
    }
  };

  const handleCreateTestUser = async () => {
    setCreatingUser(true);
    try {
      const user = await taxService.createHmrcSandboxTestUser();
      setTestUser(user);
      toast.success('Sandbox test user created');
    } catch {
      toast.error('Failed to create sandbox test user');
    } finally {
      setCreatingUser(false);
    }
  };

  const handleProvision = async () => {
    setProvisioning(true);
    try {
      const res = await taxService.provisionHmrcSandbox(taxYear);
      toast.success(`Sandbox business ready (${res.business_id})`);
    } catch (err: unknown) {
      toast.error(extractApiError(err, 'Failed to set up sandbox business'));
    } finally {
      setProvisioning(false);
    }
  };

  const handleCalculate = async () => {
    setCalculating(true);
    setCalc(null);
    try {
      const res = await taxService.calculateHmrcPreview(taxYear);
      setCalc(res);
      toast.success('Calculation retrieved from HMRC');
    } catch (err: unknown) {
      toast.error(extractApiError(err, 'Calculation failed'));
    } finally {
      setCalculating(false);
    }
  };

  const connected = status?.connected;
  const valid = status?.is_valid;
  const gbp = (n?: number) => (n == null ? '—' : formatCurrency(n, 'GBP', 'en-GB'));

  return (
    <div className="space-y-6 max-w-3xl">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">HMRC Filing</h1>
          <p className="text-sm text-secondary-500 mt-1">
            Connect to HMRC and preview your Self Assessment calculation (Making Tax Digital).
          </p>
        </div>
        <button
          onClick={fetchStatus}
          className="p-2 text-secondary-600 hover:bg-secondary-100 rounded-lg"
          title="Refresh status"
        >
          <RefreshCw className="w-4 h-4" />
        </button>
      </div>

      {/* Connection */}
      <Card padding="lg">
        {loading ? (
          <div className="py-8 flex items-center justify-center text-secondary-500">
            <Loader2 className="w-5 h-5 animate-spin mr-2" /> Checking connection…
          </div>
        ) : (
          <div className="space-y-5">
            <div className="flex items-start gap-3">
              <div
                className={`mt-0.5 w-10 h-10 rounded-full flex items-center justify-center ${
                  connected && valid
                    ? 'bg-green-100 text-green-600'
                    : connected
                      ? 'bg-amber-100 text-amber-600'
                      : 'bg-secondary-100 text-secondary-500'
                }`}
              >
                {connected && valid ? (
                  <CheckCircle className="w-5 h-5" />
                ) : connected ? (
                  <AlertCircle className="w-5 h-5" />
                ) : (
                  <Link2 className="w-5 h-5" />
                )}
              </div>
              <div className="flex-1">
                <p className="font-medium text-secondary-900">
                  {connected && valid ? 'Connected to HMRC' : connected ? 'Connection expired' : 'Not connected'}
                </p>
                <p className="text-sm text-secondary-500">
                  {connected && valid
                    ? 'Your HMRC authorisation is active and ready.'
                    : connected
                      ? 'Your HMRC authorisation has expired — reconnect to continue.'
                      : "You haven't authorised HMRC access yet."}
                </p>
                {connected && (
                  <dl className="mt-3 grid grid-cols-2 gap-x-4 gap-y-1 text-xs text-secondary-600">
                    {status?.scope && (
                      <>
                        <dt className="text-secondary-400">Scope</dt>
                        <dd className="font-mono">{status.scope}</dd>
                      </>
                    )}
                    {status?.expires_at && (
                      <>
                        <dt className="text-secondary-400">Expires</dt>
                        <dd>{formatDateTime(status.expires_at)}</dd>
                      </>
                    )}
                  </dl>
                )}
              </div>
            </div>

            <div className="flex items-center gap-3 pt-2 border-t border-secondary-100">
              <button
                onClick={handleConnect}
                disabled={connecting}
                className="flex items-center gap-2 px-4 py-2 bg-primary-600 text-white rounded-lg hover:bg-primary-700 disabled:opacity-50"
              >
                {connecting ? <Loader2 className="w-4 h-4 animate-spin" /> : <Link2 className="w-4 h-4" />}
                {connected ? 'Reconnect' : 'Connect to HMRC'}
              </button>
              {connected && (
                <button onClick={handleDisconnect} className="px-4 py-2 text-red-600 hover:bg-red-50 rounded-lg">
                  Disconnect
                </button>
              )}
            </div>
          </div>
        )}
      </Card>

      {/* Sandbox testing */}
      <Card padding="lg">
        <div className="flex items-center gap-2 mb-1">
          <FlaskConical className="w-4 h-4 text-primary-600" />
          <h2 className="font-semibold text-secondary-900">Sandbox testing</h2>
        </div>
        <p className="text-sm text-secondary-500 mb-4">
          Create a test taxpayer to connect with, then provision a test business so HMRC accepts a
          calculation for the tax year.
        </p>

        <div className="flex flex-wrap items-center gap-3">
          <button
            onClick={handleCreateTestUser}
            disabled={creatingUser}
            className="flex items-center gap-2 px-4 py-2 border border-secondary-300 text-secondary-700 rounded-lg hover:bg-secondary-100 disabled:opacity-50"
          >
            {creatingUser ? <Loader2 className="w-4 h-4 animate-spin" /> : <KeyRound className="w-4 h-4" />}
            Create sandbox test user
          </button>
          <button
            onClick={handleProvision}
            disabled={provisioning || !connected}
            title={!connected ? 'Connect first' : undefined}
            className="flex items-center gap-2 px-4 py-2 border border-secondary-300 text-secondary-700 rounded-lg hover:bg-secondary-100 disabled:opacity-50"
          >
            {provisioning ? <Loader2 className="w-4 h-4 animate-spin" /> : <Building2 className="w-4 h-4" />}
            Set up sandbox business ({taxYear})
          </button>
        </div>

        {testUser && (
          <div className="mt-4 rounded-lg border border-amber-200 bg-amber-50 p-4 text-sm">
            <p className="font-medium text-amber-900 mb-2">
              Use these to sign in when you click <strong>Connect to HMRC</strong>:
            </p>
            <dl className="grid grid-cols-[auto,1fr] gap-x-4 gap-y-1 text-amber-900 font-mono text-xs">
              {testUser.userId && (<><dt className="text-amber-700">User ID</dt><dd>{testUser.userId}</dd></>)}
              {testUser.password && (<><dt className="text-amber-700">Password</dt><dd>{testUser.password}</dd></>)}
              {testUser.nino && (<><dt className="text-amber-700">NINO</dt><dd>{testUser.nino}</dd></>)}
              {testUser.saUtr && (<><dt className="text-amber-700">UTR</dt><dd>{testUser.saUtr}</dd></>)}
            </dl>
            <p className="text-xs text-amber-700 mt-2">Saved to your profile — no need to copy the NINO.</p>
          </div>
        )}
      </Card>

      {/* Preview calculation */}
      <Card padding="lg">
        <div className="flex items-center gap-2 mb-1">
          <Calculator className="w-4 h-4 text-primary-600" />
          <h2 className="font-semibold text-secondary-900">Preview tax calculation</h2>
        </div>
        <p className="text-sm text-secondary-500 mb-4">
          Submits your classified figures to HMRC and triggers a non-binding calculation. This does
          <strong> not</strong> file your return.
        </p>

        <div className="flex flex-wrap items-end gap-3">
          <div>
            <label className="block text-xs font-medium text-secondary-500 mb-1">Tax year</label>
            <input
              value={taxYear}
              onChange={(e) => setTaxYear(e.target.value)}
              placeholder="2025-26"
              className="px-3 py-2 border border-secondary-300 rounded-lg text-sm bg-surface w-32"
            />
          </div>
          <button
            onClick={handleCalculate}
            disabled={calculating || !connected}
            title={!connected ? 'Connect first' : undefined}
            className="flex items-center gap-2 px-4 py-2 bg-primary-600 text-white rounded-lg hover:bg-primary-700 disabled:opacity-50"
          >
            {calculating ? <Loader2 className="w-4 h-4 animate-spin" /> : <Calculator className="w-4 h-4" />}
            {calculating ? 'Calculating…' : 'Run preview'}
          </button>
        </div>

        {calc && (
          <div className="mt-5 space-y-4">
            {calc.sandbox_placeholder && (
              <div className="flex items-start gap-2 rounded-lg bg-blue-50 border border-blue-200 p-3 text-xs text-blue-800">
                <AlertCircle className="w-4 h-4 mt-0.5 shrink-0" />
                <span>
                  Sandbox returns a fixed placeholder for the total tax figure — the breakdown below
                  is illustrative, not a real liability.
                </span>
              </div>
            )}
            <div className="grid grid-cols-2 sm:grid-cols-3 gap-3">
              {[
                ['Tax & NICs due', calc.figures.total_income_tax_and_nics_due],
                ['Taxable income', calc.figures.total_taxable_income],
                ['Income tax', calc.figures.income_tax_charged],
                ['Personal allowance', calc.figures.personal_allowance],
                ['Class 2 NIC', calc.figures.class2_nics],
                ['Class 4 NIC', calc.figures.class4_nics],
              ].map(([label, value]) => (
                <div key={label as string} className="rounded-lg border border-secondary-200 bg-surface p-3">
                  <p className="text-xs text-secondary-500">{label}</p>
                  <p className="text-base font-semibold text-secondary-900">
                    {calc.sandbox_placeholder && label === 'Tax & NICs due' ? '—' : gbp(value as number | undefined)}
                  </p>
                </div>
              ))}
            </div>
            <p className="text-xs text-secondary-400">
              Calculation ID <span className="font-mono">{calc.calculation_id}</span> · business{' '}
              <span className="font-mono">{calc.business_id}</span>
            </p>
          </div>
        )}
      </Card>

      <div className="flex items-start gap-3 bg-secondary-50 border border-secondary-200 rounded-xl p-4 text-sm text-secondary-600">
        <ShieldCheck className="w-5 h-5 text-secondary-400 mt-0.5 shrink-0" />
        <p>
          You&apos;ll be taken to HMRC&apos;s secure sign-in to authorise access. We never see your
          Government Gateway password — HMRC returns a token scoped to Self Assessment only.
        </p>
      </div>
    </div>
  );
}

export default function HmrcSettingsPage() {
  return (
    <ProtectedPage module="tax_statements" title="HMRC Filing">
      <Suspense fallback={null}>
        <HmrcSettingsContent />
      </Suspense>
    </ProtectedPage>
  );
}

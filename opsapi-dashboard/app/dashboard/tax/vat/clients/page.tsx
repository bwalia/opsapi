'use client';

/**
 * VAT clients — for accountants (RBAC module vat_agent). Save your Agent Reference
 * Number, connect to HMRC with your agent sign-in, ask a client (by VAT number) for
 * authority, and open a client's VAT once HMRC confirms it (VAT plan phase 8).
 * Backend: /api/v2/vat/agent/* (lapis/routes/vat.lua, queries/VatAgentQueries.lua).
 */

import React, { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import { ExternalLink, Loader2, RefreshCw, UserPlus, Users } from 'lucide-react';
import toast from 'react-hot-toast';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { extractApiError } from '@/lib/utils';
import vatService, { type VatAgentClient } from '@/services/vat.service';

const card = 'rounded-2xl border border-secondary-200 bg-surface-elevated p-4 sm:p-6';
const btn = 'inline-flex items-center gap-2 rounded-lg px-3.5 py-2 text-sm font-medium transition disabled:opacity-50';
const primary = `${btn} bg-primary-600 text-white hover:bg-primary-700`;
const ghost = `${btn} border border-secondary-300 text-secondary-700 hover:bg-secondary-50`;
const input = 'w-full rounded-lg border border-secondary-300 bg-surface px-3 py-2 text-sm';

const STATUS: Record<VatAgentClient['status'], { label: string; cls: string }> = {
  pending: { label: 'Waiting for the client to accept', cls: 'bg-amber-100 text-amber-800' },
  accepted: { label: 'Accepted — confirming with HMRC', cls: 'bg-blue-100 text-blue-800' },
  active: { label: 'You can act for this client', cls: 'bg-green-100 text-green-800' },
  rejected: { label: 'The client declined', cls: 'bg-red-100 text-red-800' },
  expired: { label: 'Request expired', cls: 'bg-secondary-100 text-secondary-700' },
  cancelled: { label: 'Cancelled', cls: 'bg-secondary-100 text-secondary-700' },
  revoked: { label: 'Authority ended at HMRC', cls: 'bg-red-100 text-red-800' },
};

function ClientsPage() {
  const [loading, setLoading] = useState(true);
  const [arn, setArn] = useState('');
  const [hasArn, setHasArn] = useState(false);
  const [clients, setClients] = useState<VatAgentClient[]>([]);
  const [vrn, setVrn] = useState('');
  const [regDate, setRegDate] = useState('');
  const [busy, setBusy] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const [p, c] = await Promise.all([vatService.agentProfile(), vatService.agentClients()]);
      if (p) { setArn(p.arn); setHasArn(true); }
      setClients(c);
    } catch (e) {
      toast.error(extractApiError(e, 'Could not load your clients'));
    } finally {
      setLoading(false);
    }
  }, []);
  useEffect(() => { load(); }, [load]);

  const act = async (key: string, fn: () => Promise<unknown>, ok?: string) => {
    setBusy(key);
    try {
      await fn();
      if (ok) toast.success(ok);
      await load();
    } catch (e) {
      const code = (e as { response?: { data?: { code?: string } } })?.response?.data?.code;
      if (code === 'AGENT_SCOPE_MISSING' || code === 'NOT_CONNECTED') {
        toast.error('Connect to HMRC with your agent sign-in first.');
      } else {
        toast.error(extractApiError(e, 'That did not work'));
      }
    } finally {
      setBusy(null);
    }
  };

  const connect = async () => {
    try {
      window.location.href = await vatService.connectUrl(`${window.location.origin}/dashboard/tax`, 'vat_agent');
    } catch (e) {
      toast.error(extractApiError(e, 'Could not start the HMRC connection'));
    }
  };

  if (loading) {
    return <div className="flex h-60 items-center justify-center"><Loader2 className="h-6 w-6 animate-spin text-secondary-400" /></div>;
  }

  return (
    <div className="space-y-4">
      <PageHeader title="VAT clients" icon={<Users className="h-5 w-5" />}
        description="Act for your clients' VAT once they authorise you at HMRC." />

      <div className={card}>
        <p className="font-semibold text-secondary-900">Your agent details</p>
        <div className="mt-3 flex flex-col gap-2 sm:flex-row sm:items-end">
          <label className="flex-1 text-sm">Agent Reference Number (ARN)
            <input className={input} placeholder="AARN1234567" value={arn} onChange={(e) => setArn(e.target.value)} />
          </label>
          <button type="button" className={primary} disabled={busy === 'arn'}
            onClick={() => act('arn', () => vatService.saveAgentProfile(arn), 'Saved')}>Save</button>
          <button type="button" className={ghost} onClick={connect}>Connect to HMRC (agent sign-in)</button>
        </div>
      </div>

      {hasArn && (
        <div className={card}>
          <p className="font-semibold text-secondary-900">Ask a client for authority</p>
          <p className="mt-1 text-sm text-secondary-600">
            The client must have added their VAT number in OpsAPI. HMRC sends them a link to accept; their VAT
            registration date proves you know the business.
          </p>
          <div className="mt-3 grid grid-cols-1 gap-2 sm:grid-cols-[1fr_1fr_auto] sm:items-end">
            <label className="text-sm">Client&apos;s VAT number
              <input className={input} placeholder="GB 123 4567 82" value={vrn} onChange={(e) => setVrn(e.target.value)} />
            </label>
            <label className="text-sm">VAT registration date (if not on file)
              <input className={input} type="date" value={regDate} onChange={(e) => setRegDate(e.target.value)} />
            </label>
            <button type="button" className={primary} disabled={!vrn || busy === 'invite'}
              onClick={() => act('invite', () => vatService.inviteClient(vrn, regDate || undefined),
                'Request sent. Share the HMRC link with your client.')}>
              <UserPlus className="h-4 w-4" /> Send request
            </button>
          </div>
        </div>
      )}

      <div className={card}>
        <p className="font-semibold text-secondary-900">Your clients ({clients.length})</p>
        {clients.length === 0 && <p className="mt-2 text-sm text-secondary-600">No clients yet.</p>}
        <div className="mt-2 divide-y divide-secondary-100">
          {clients.map((c) => (
            <div key={c.uuid} className="flex flex-col gap-2 py-3 sm:flex-row sm:items-center">
              <div className="min-w-0 flex-1">
                <p className="font-medium text-secondary-900">{c.business_name || 'Client'} · GB {c.client_vrn}</p>
                <span className={`mt-1 inline-block rounded-full px-2 py-0.5 text-xs font-medium ${STATUS[c.status].cls}`}>
                  {STATUS[c.status].label}
                </span>
                {c.status === 'pending' && c.client_action_url && (
                  <a href={c.client_action_url} target="_blank" rel="noopener noreferrer"
                    className="ml-2 inline-flex items-center gap-1 text-xs text-primary-700 underline">
                    Link for your client <ExternalLink className="h-3 w-3" />
                  </a>
                )}
              </div>
              <div className="flex shrink-0 gap-2">
                {c.status === 'active' && (
                  <Link href={`/dashboard/tax/vat?client=${c.uuid}`} className={primary}>Open their VAT</Link>
                )}
                {['pending', 'accepted', 'active'].includes(c.status) && (
                  <button type="button" className={ghost} disabled={busy === c.uuid}
                    onClick={() => act(c.uuid, () => vatService.refreshClient(c.uuid))}>
                    {busy === c.uuid ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />}
                    Check with HMRC
                  </button>
                )}
                {['pending', 'accepted', 'active'].includes(c.status) && (
                  <button type="button" className={ghost} disabled={busy === 'x' + c.uuid}
                    onClick={() => act('x' + c.uuid, () => vatService.cancelClient(c.uuid), 'Stopped')}>Stop</button>
                )}
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

export default function Page() {
  return (
    <ProtectedPage module="vat_agent" title="VAT clients">
      <ClientsPage />
    </ProtectedPage>
  );
}

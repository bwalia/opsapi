'use client';

/**
 * Simpro Sync — /dashboard/field-service/simpro
 *
 * The connection to the Simpro build and the audit trail of every push and
 * pull. Reading needs simpro_sync read; running a sync writes to the
 * customer's system of record, so it needs manage.
 */

import React, { useCallback, useEffect, useState } from 'react';
import toast from 'react-hot-toast';
import { ArrowDownToLine, ArrowUpFromLine, PlugZap, RefreshCw } from 'lucide-react';
import { Button, Pagination } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { usePermissions } from '@/contexts/PermissionsContext';
import { FieldServiceNav, FilterSelect, Pill, SectionCard, apiError } from '@/components/field-service/shared';
import { formatFsDateTime } from '@/services/field-service.service';
import {
  simproCrm,
  type SimproLogEntry,
  type SimproStatus,
  type SimproSyncResult,
} from '@/services/simpro-crm.service';

const ENTITY_LABELS: Record<string, string> = {
  customers: 'Customers',
  sites: 'Sites',
  assets: 'Assets',
  // Simpro's API exposes test history read-only; survey outcomes reach Simpro
  // through the asset's condition fields instead.
  asset_tests: 'Asset surveys (read-only in Simpro API)',
  jobs: 'Jobs & projects',
  quotes: 'Quotes',
  invoices: 'Invoices',
};

const LOG_STATUS: Record<string, string> = {
  ok: 'bg-green-50 text-green-700',
  conflict: 'bg-orange-50 text-orange-700',
  error: 'bg-red-50 text-red-700',
  skipped: 'bg-secondary-100 text-secondary-600',
};

const MODE: Record<string, string> = {
  mock: 'bg-violet-50 text-violet-700',
  sandbox: 'bg-blue-50 text-blue-700',
  live: 'bg-green-50 text-green-700',
};

function describe(result: SimproSyncResult): string {
  return Object.entries(result.results)
    .map(([entity, stats]) => {
      const parts = Object.entries(stats)
        .filter(([k, v]) => k !== 'queued_remaining' && Number(v) > 0)
        .map(([k, v]) => `${v} ${k}`);
      return parts.length ? `${entity}: ${parts.join(', ')}` : null;
    })
    .filter(Boolean)
    .join(' · ') || 'Nothing to do';
}

function SimproPageContent() {
  const { canManage } = usePermissions();
  const allowSync = canManage('simpro_sync');
  const [status, setStatus] = useState<SimproStatus | null>(null);
  const [log, setLog] = useState<SimproLogEntry[]>([]);
  const [logStatus, setLogStatus] = useState('all');
  const [page, setPage] = useState(1);
  const [pages, setPages] = useState(1);
  const [total, setTotal] = useState(0);
  const [busy, setBusy] = useState<'test' | 'pull' | 'push' | null>(null);
  const [lastRun, setLastRun] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const [s, l] = await Promise.all([
        simproCrm.getSimproStatus(),
        simproCrm.getSimproLog({ page, per_page: 25, status: logStatus }),
      ]);
      setStatus(s);
      setLog(l.data);
      setPages(l.meta.total_pages || 1);
      setTotal(l.meta.total);
    } catch (err) {
      toast.error(apiError(err, 'Failed to load Simpro status'));
    }
  }, [page, logStatus]);

  useEffect(() => {
    load();
  }, [load]);

  const act = async (kind: 'test' | 'pull' | 'push') => {
    setBusy(kind);
    try {
      if (kind === 'test') {
        const info = await simproCrm.testSimpro();
        toast.success(`Connected to ${info.company || info.base_url}`);
      } else {
        const result = kind === 'pull' ? await simproCrm.pullSimpro() : await simproCrm.pushSimpro();
        const text = describe(result);
        setLastRun(`${kind === 'pull' ? 'Pulled' : 'Pushed'} — ${text}`);
        toast.success(kind === 'pull' ? 'Pull complete' : 'Push complete');
        setPage(1);
      }
      await load();
    } catch (err) {
      toast.error(apiError(err, `Simpro ${kind} failed`));
    } finally {
      setBusy(null);
    }
  };

  const c = status?.connection;

  return (
    <div className="space-y-6">
      <PageHeader
        title="Simpro Sync"
        description="Simpro is the system of record. OpsAPI pulls customers, sites, assets and jobs from it and pushes back what changes here."
        icon={<RefreshCw className="w-5 h-5" />}
        actions={
          allowSync && c ? (
            <div className="flex gap-2">
              <Button variant="outline" onClick={() => act('test')} isLoading={busy === 'test'}>
                <PlugZap className="w-4 h-4 mr-1.5" /> Test
              </Button>
              <Button variant="outline" onClick={() => act('pull')} isLoading={busy === 'pull'}>
                <ArrowDownToLine className="w-4 h-4 mr-1.5" /> Pull
              </Button>
              <Button onClick={() => act('push')} isLoading={busy === 'push'} disabled={!c.push_enabled}>
                <ArrowUpFromLine className="w-4 h-4 mr-1.5" /> Push
              </Button>
            </div>
          ) : undefined
        }
      />
      <FieldServiceNav />

      {lastRun && <p className="rounded-lg bg-primary-50 px-4 py-2.5 text-sm text-primary-800">{lastRun}</p>}

      <div className="grid gap-6 xl:grid-cols-3">
        <SectionCard title="Connection">
          {c ? (
            <dl className="space-y-3 text-sm">
              <div className="flex justify-between gap-3">
                <dt className="text-secondary-500">Build</dt>
                <dd className="text-right">
                  <span className="font-medium text-secondary-900">{c.name}</span>
                  <span className="block text-xs font-mono text-secondary-500">{c.base_url}</span>
                </dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-secondary-500">Mode</dt>
                <dd><Pill className={MODE[c.mode]}>{c.mode}</Pill></dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-secondary-500">Company ID</dt>
                <dd className="font-mono">{c.company_id}</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-secondary-500">Pull / push</dt>
                <dd>{c.pull_enabled ? 'On' : 'Off'} / {c.push_enabled ? 'On' : 'Off'}</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-secondary-500">Last pull</dt>
                <dd>{formatFsDateTime(c.last_pull_at)}</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-secondary-500">Last push</dt>
                <dd>{formatFsDateTime(c.last_push_at)}</dd>
              </div>
              {c.mode === 'mock' && (
                <p className="rounded-lg bg-violet-50 px-3 py-2 text-xs text-violet-800">
                  Mock build: same endpoints and payloads as Simpro&apos;s API, served locally. Switch the mode to
                  sandbox or live and set the base URL and vault credentials to connect a real build.
                </p>
              )}
            </dl>
          ) : (
            <p className="text-sm text-secondary-500">No Simpro connection is configured for this workspace.</p>
          )}
        </SectionCard>

        <SectionCard title="Records" className="xl:col-span-2">
          <table className="min-w-full text-sm">
            <thead>
              <tr className="text-left text-secondary-500">
                <th className="py-1.5 font-medium">Entity</th>
                <th className="py-1.5 font-medium text-right">In Simpro</th>
                <th className="py-1.5 font-medium text-right">To push</th>
                <th className="py-1.5 font-medium text-right">Errors</th>
                <th className="py-1.5 font-medium text-right">OpsAPI only</th>
                <th className="py-1.5 font-medium text-right">Total</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-secondary-100 tabular-nums">
              {Object.entries(status?.counts || {}).map(([key, n]) => (
                <tr key={key}>
                  <td className="py-2 text-secondary-900">{ENTITY_LABELS[key] || key}</td>
                  <td className="py-2 text-right text-green-700">{n.synced}</td>
                  <td className="py-2 text-right text-amber-700">{n.pending}</td>
                  <td className="py-2 text-right text-red-700">{n.errored}</td>
                  <td className="py-2 text-right text-secondary-500">{n.local_only}</td>
                  <td className="py-2 text-right font-medium">{n.total}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </SectionCard>
      </div>

      <SectionCard
        title={`Sync log (${total})`}
        actions={
          <FilterSelect
            value={logStatus}
            onChange={(v) => {
              setLogStatus(v);
              setPage(1);
            }}
            ariaLabel="Log status"
            options={[
              { value: 'all', label: 'All outcomes' },
              { value: 'ok', label: 'OK' },
              { value: 'conflict', label: 'Conflicts' },
              { value: 'error', label: 'Errors' },
              { value: 'skipped', label: 'Skipped' },
            ]}
          />
        }
      >
        <div className="overflow-x-auto">
          <table className="min-w-full text-sm">
            <thead>
              <tr className="text-left text-secondary-500">
                <th className="py-1.5 pr-4 font-medium">When</th>
                <th className="py-1.5 pr-4 font-medium">Direction</th>
                <th className="py-1.5 pr-4 font-medium">Entity</th>
                <th className="py-1.5 pr-4 font-medium">Simpro ID</th>
                <th className="py-1.5 pr-4 font-medium">Operation</th>
                <th className="py-1.5 pr-4 font-medium">Outcome</th>
                <th className="py-1.5 font-medium">Detail</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-secondary-100">
              {log.map((e) => (
                <tr key={e.uuid}>
                  <td className="py-2 pr-4 whitespace-nowrap">{formatFsDateTime(e.created_at)}</td>
                  <td className="py-2 pr-4">
                    {e.direction === 'pull' ? (
                      <span className="inline-flex items-center gap-1"><ArrowDownToLine className="w-3.5 h-3.5" /> Pull</span>
                    ) : (
                      <span className="inline-flex items-center gap-1"><ArrowUpFromLine className="w-3.5 h-3.5" /> Push</span>
                    )}
                  </td>
                  <td className="py-2 pr-4 capitalize">{e.entity_type}</td>
                  <td className="py-2 pr-4 font-mono text-xs">{e.simpro_id || '—'}</td>
                  <td className="py-2 pr-4">{e.operation}</td>
                  <td className="py-2 pr-4"><Pill className={LOG_STATUS[e.status]}>{e.status}</Pill></td>
                  <td className="py-2 text-xs text-secondary-600">
                    {e.error_message ||
                      (e.status === 'conflict' ? 'Changed in OpsAPI and in Simpro; Simpro kept, local values logged.' : '')}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <Pagination currentPage={page} totalPages={pages} totalItems={total} perPage={25} onPageChange={setPage} />
      </SectionCard>
    </div>
  );
}

export default function FieldServiceSimproPage() {
  return (
    <ProtectedPage module="simpro_sync" title="Simpro Sync">
      <SimproPageContent />
    </ProtectedPage>
  );
}

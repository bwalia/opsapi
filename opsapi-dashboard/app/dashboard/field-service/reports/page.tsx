'use client';

/**
 * Reports — /dashboard/field-service/reports
 *
 * The Simpro report pack: asset failure history, asset history, PPM forecast,
 * routine maintenance performance, F-Gas register, employee licences, engineer
 * locations, labour forecast, response times, administration efficiency and
 * the Power BI extract. Each runs on screen, downloads as CSV (the server's
 * own export, so it matches the screen), and prints as a branded PDF.
 */

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { BarChart3, Download, FileDown, Play } from 'lucide-react';
import { Button, Card, Input } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { FieldServiceNav, FilterSelect, apiError } from '@/components/field-service/shared';
import { ReportTable } from '@/components/field-service/simpro';
import { useNamespaceStore } from '@/store/namespace.store';
import { companyFromNamespace, downloadReportPdf, summaryEntries } from '@/lib/report-pdf';
import {
  simproCrm,
  type Asset,
  type Contract,
  type Report,
  type ReportCatalogueEntry,
  type ReportFilters,
} from '@/services/simpro-crm.service';
import { cn } from '@/lib/utils';

const GROUP_ORDER = ['Assets', 'Compliance', 'Operations', 'Performance', 'Data'];

function isoDaysAgo(days: number): string {
  const d = new Date();
  d.setDate(d.getDate() - days);
  return d.toISOString().slice(0, 10);
}

function ReportsPageContent() {
  const current = useNamespaceStore((s) => s.currentNamespace);
  const namespaces = useNamespaceStore((s) => s.namespaces);
  const company = useMemo(
    () => companyFromNamespace(namespaces.find((n) => n.uuid === current?.uuid) || current),
    [current, namespaces]
  );

  const [catalogue, setCatalogue] = useState<ReportCatalogueEntry[]>([]);
  const [selected, setSelected] = useState<string>('asset_failure_history');
  const [report, setReport] = useState<Report | null>(null);
  const [running, setRunning] = useState(false);
  const [exporting, setExporting] = useState(false);

  const [dateFrom, setDateFrom] = useState(isoDaysAgo(365));
  const [dateTo, setDateTo] = useState(new Date().toISOString().slice(0, 10));
  const [months, setMonths] = useState('6');
  const [weeks, setWeeks] = useState('8');
  const [days, setDays] = useState('90');
  const [contractUuid, setContractUuid] = useState('all');
  const [assetUuid, setAssetUuid] = useState('');
  const [contracts, setContracts] = useState<Contract[]>([]);
  const [assets, setAssets] = useState<Asset[]>([]);

  const entry = catalogue.find((r) => r.key === selected);
  const wants = (f: string) => !!entry?.filters.includes(f);

  useEffect(() => {
    simproCrm
      .getReports()
      .then(setCatalogue)
      .catch((err) => toast.error(apiError(err, 'Failed to load reports')));
    simproCrm
      .getContracts({ per_page: 200 })
      .then((r) => setContracts(r.data))
      .catch(() => undefined);
    simproCrm
      .getAssets({ per_page: 200 })
      .then((r) => {
        setAssets(r.data);
        if (r.data[0]) setAssetUuid((u) => u || r.data[0].uuid);
      })
      .catch(() => undefined);
  }, []);

  const filters = useCallback((): ReportFilters => {
    const f: ReportFilters = {};
    if (wants('date_range')) {
      f.date_from = dateFrom;
      f.date_to = dateTo;
    }
    if (wants('months')) f.months = Number(months);
    if (wants('weeks')) f.weeks = Number(weeks);
    if (wants('expiring_within_days')) f.expiring_within_days = Number(days);
    if (wants('contract') && contractUuid !== 'all') f.contract_uuid = contractUuid;
    if (wants('asset')) f.asset_uuid = assetUuid;
    return f;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [entry, dateFrom, dateTo, months, weeks, days, contractUuid, assetUuid]);

  const run = useCallback(async () => {
    if (!entry) return;
    if (wants('asset') && !assetUuid) {
      toast.error('Pick an asset first');
      return;
    }
    setRunning(true);
    try {
      setReport(await simproCrm.runReport(entry.key, filters()));
    } catch (err) {
      toast.error(apiError(err, 'Report failed'));
    } finally {
      setRunning(false);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [entry, filters, assetUuid]);

  // Run as soon as a report is picked, so the page is never an empty form.
  useEffect(() => {
    if (entry) run();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [entry?.key]);

  const exportCsv = async () => {
    if (!entry) return;
    setExporting(true);
    try {
      const { blob, filename } = await simproCrm.downloadReportCsv(entry.key, filters());
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = filename;
      a.click();
      URL.revokeObjectURL(url);
    } catch (err) {
      toast.error(apiError(err, 'CSV export failed'));
    } finally {
      setExporting(false);
    }
  };

  const groups = GROUP_ORDER.map((g) => ({ group: g, items: catalogue.filter((r) => r.group === g) })).filter(
    (g) => g.items.length
  );

  return (
    <div className="space-y-6">
      <PageHeader
        title="Reports"
        description="The Simpro report pack. Run on screen, export CSV for Excel or Power BI, or download a branded PDF."
        icon={<BarChart3 className="w-5 h-5" />}
      />
      <FieldServiceNav />

      <div className="grid gap-6 lg:grid-cols-[260px_1fr]">
        <nav aria-label="Reports" className="space-y-5">
          {groups.map(({ group, items }) => (
            <div key={group}>
              <p className="px-2 text-xs font-semibold uppercase tracking-wide text-secondary-500">{group}</p>
              <ul className="mt-1.5 space-y-0.5">
                {items.map((r) => (
                  <li key={r.key}>
                    <button
                      type="button"
                      onClick={() => setSelected(r.key)}
                      className={cn(
                        'w-full text-left rounded-lg px-2.5 py-2 text-sm transition-colors',
                        r.key === selected
                          ? 'bg-primary-50 text-primary-700 font-medium'
                          : 'text-secondary-700 hover:bg-secondary-100'
                      )}
                      aria-current={r.key === selected ? 'true' : undefined}
                    >
                      {r.title}
                    </button>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </nav>

        <div className="space-y-5 min-w-0">
          <Card padding="md">
            <div className="flex flex-wrap items-end gap-4">
              {wants('date_range') && (
                <>
                  <div className="w-40">
                    <Input label="From" type="date" value={dateFrom} onChange={(e) => setDateFrom(e.target.value)} />
                  </div>
                  <div className="w-40">
                    <Input label="To" type="date" value={dateTo} onChange={(e) => setDateTo(e.target.value)} />
                  </div>
                </>
              )}
              {wants('months') && (
                <div className="w-32">
                  <Input label="Months ahead" type="number" min={1} max={36} value={months} onChange={(e) => setMonths(e.target.value)} />
                </div>
              )}
              {wants('weeks') && (
                <div className="w-32">
                  <Input label="Weeks ahead" type="number" min={1} max={52} value={weeks} onChange={(e) => setWeeks(e.target.value)} />
                </div>
              )}
              {wants('expiring_within_days') && (
                <div className="w-40">
                  <Input label="Expiring within (days)" type="number" min={1} max={730} value={days} onChange={(e) => setDays(e.target.value)} />
                </div>
              )}
              {wants('contract') && (
                <FilterSelect
                  value={contractUuid}
                  onChange={setContractUuid}
                  ariaLabel="Contract"
                  options={[
                    { value: 'all', label: 'All contracts' },
                    ...contracts.map((c) => ({ value: c.uuid, label: `${c.contract_number || ''} ${c.name}`.trim() })),
                  ]}
                />
              )}
              {wants('asset') && (
                <FilterSelect
                  value={assetUuid}
                  onChange={setAssetUuid}
                  ariaLabel="Asset"
                  options={assets.map((a) => ({ value: a.uuid, label: `${a.asset_tag || ''} — ${a.name}` }))}
                />
              )}
              <div className="flex gap-2 ml-auto">
                <Button onClick={run} isLoading={running}>
                  <Play className="w-4 h-4 mr-1.5" /> Run
                </Button>
                <Button variant="outline" onClick={exportCsv} disabled={!report} isLoading={exporting}>
                  <Download className="w-4 h-4 mr-1.5" /> CSV
                </Button>
                <Button variant="outline" onClick={() => report && downloadReportPdf(report, company)} disabled={!report}>
                  <FileDown className="w-4 h-4 mr-1.5" /> PDF
                </Button>
              </div>
            </div>
          </Card>

          {report && (
            <>
              <div>
                <h2 className="text-lg font-semibold text-secondary-900">{report.title}</h2>
                <p className="text-sm text-secondary-500">{report.description}</p>
              </div>
              <div className="grid gap-3 grid-cols-2 md:grid-cols-3 xl:grid-cols-5">
                {summaryEntries(report.summary).map(([label, value]) => (
                  <div key={label} className="rounded-xl border border-secondary-200 bg-surface px-4 py-3 shadow-sm">
                    <p className="text-xs font-medium text-secondary-500">{label}</p>
                    <p className="mt-1 text-xl font-bold text-secondary-900 tabular-nums">{value}</p>
                  </div>
                ))}
              </div>
              <ReportTable report={report} />
            </>
          )}
        </div>
      </div>
    </div>
  );
}

export default function FieldServiceReportsPage() {
  return (
    <ProtectedPage module="fs_reports" title="Reports">
      <ReportsPageContent />
    </ProtectedPage>
  );
}

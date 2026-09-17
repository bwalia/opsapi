'use client';

/**
 * Small presentational pieces shared by the Simpro-aligned pages: the sync-state
 * badge, the 1–6 condition pill, and a generic report table that renders any
 * report envelope using its typed columns.
 */

import React from 'react';
import { CheckCircle2, CircleDashed, AlertTriangle, CloudOff, GitCompare } from 'lucide-react';
import { Pill } from '@/components/field-service/shared';
import { formatReportCell } from '@/lib/report-pdf';
import type { Report, SimproSyncState } from '@/services/simpro-crm.service';

const SYNC: Record<SimproSyncState, { label: string; className: string; icon: React.ReactNode }> = {
  synced: { label: 'In Simpro', className: 'bg-green-50 text-green-700', icon: <CheckCircle2 className="w-3.5 h-3.5" /> },
  pending: { label: 'To push', className: 'bg-amber-50 text-amber-700', icon: <CircleDashed className="w-3.5 h-3.5" /> },
  conflict: { label: 'Conflict', className: 'bg-orange-50 text-orange-700', icon: <GitCompare className="w-3.5 h-3.5" /> },
  error: { label: 'Sync error', className: 'bg-red-50 text-red-700', icon: <AlertTriangle className="w-3.5 h-3.5" /> },
  local_only: { label: 'OpsAPI only', className: 'bg-secondary-100 text-secondary-600', icon: <CloudOff className="w-3.5 h-3.5" /> },
};

export function SimproBadge({ state, simproId }: { state?: SimproSyncState | null; simproId?: string | null }) {
  const s = SYNC[state || 'local_only'] || SYNC.local_only;
  return (
    <span title={simproId ? `Simpro #${simproId}` : undefined}>
      <Pill className={`inline-flex items-center gap-1 ${s.className}`}>
        {s.icon}
        {s.label}
      </Pill>
    </span>
  );
}

// DBS score 1 (excellent) to 6 (budget for replacement).
const CONDITION: Record<number, { label: string; className: string }> = {
  1: { label: 'Excellent', className: 'bg-green-50 text-green-700' },
  2: { label: 'Good', className: 'bg-green-50 text-green-700' },
  3: { label: 'Fair', className: 'bg-blue-50 text-blue-700' },
  4: { label: 'Poor', className: 'bg-amber-50 text-amber-700' },
  5: { label: 'Plan replacement', className: 'bg-orange-50 text-orange-700' },
  6: { label: 'Replace', className: 'bg-red-50 text-red-700' },
};

export function ConditionPill({ rating }: { rating?: number | null }) {
  if (!rating) return <span className="text-sm text-secondary-400">Not surveyed</span>;
  const c = CONDITION[rating] || CONDITION[3];
  return (
    <Pill className={c.className}>
      {rating} · {c.label}
    </Pill>
  );
}

export const CONDITION_OPTIONS = Object.entries(CONDITION).map(([value, c]) => ({
  value,
  label: `${value} — ${c.label}`,
}));

export function TestResultPill({ result }: { result: string }) {
  const map: Record<string, string> = {
    pass: 'bg-green-50 text-green-700',
    advisory: 'bg-amber-50 text-amber-700',
    fail: 'bg-red-50 text-red-700',
    not_tested: 'bg-secondary-100 text-secondary-600',
  };
  return <Pill className={map[result] || map.not_tested}>{result.replace('_', ' ')}</Pill>;
}

/** Render any report envelope as a table, formatting cells by column type. */
export function ReportTable({ report, maxRows = 500 }: { report: Report; maxRows?: number }) {
  const numeric = new Set(['number', 'money', 'hours']);
  const rows = report.rows.slice(0, maxRows);
  return (
    <div className="overflow-x-auto rounded-xl border border-secondary-200">
      <table className="min-w-full text-sm">
        <thead className="bg-secondary-50">
          <tr>
            {report.columns.map((c) => (
              <th
                key={c.key}
                scope="col"
                className={`px-3 py-2.5 font-semibold text-secondary-600 whitespace-nowrap ${
                  numeric.has(c.type) ? 'text-right' : 'text-left'
                }`}
              >
                {c.label}
              </th>
            ))}
          </tr>
        </thead>
        <tbody className="divide-y divide-secondary-100 bg-surface">
          {rows.map((row, i) => (
            <tr key={i} className="hover:bg-secondary-50/60">
              {report.columns.map((c) => (
                <td
                  key={c.key}
                  className={`px-3 py-2 whitespace-nowrap text-secondary-800 ${
                    numeric.has(c.type) ? 'text-right tabular-nums' : ''
                  }`}
                >
                  {formatReportCell(row[c.key], c.type)}
                </td>
              ))}
            </tr>
          ))}
          {!rows.length && (
            <tr>
              <td colSpan={report.columns.length} className="px-3 py-8 text-center text-secondary-500">
                No rows for these filters.
              </td>
            </tr>
          )}
        </tbody>
      </table>
      {report.rows.length > maxRows && (
        <p className="px-3 py-2 text-xs text-secondary-500 border-t border-secondary-200">
          Showing the first {maxRows} of {report.rows.length} rows. The CSV and PDF include them all.
        </p>
      )}
    </div>
  );
}

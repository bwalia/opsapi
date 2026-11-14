'use client';

/**
 * Our estimate (left) next to HMRC's calculation (right), line by line.
 *
 * OpsAPI works out an estimate itself (lib/tax-calc) from the first statement; HMRC
 * calculates the official figure once the figures are sent. When they differ, the
 * person or their accountant can open "Why is HMRC's figure different?" to see, per
 * line, the likely reason, plus the income sources, extra charges and messages HMRC
 * included. HMRC's figure is the one the return is filed on.
 * Data: `comparison` from POST /api/v2/tax/hmrc/calculate-preview (lapis/lib/tax-delta.lua).
 */

import React, { useState } from 'react';
import { AlertCircle, CheckCircle2, ChevronDown, ChevronUp, Info } from 'lucide-react';
import { formatCurrency } from '@/lib/utils';
import type { HmrcComparison } from '@/services/tax.service';

const gbp = (n?: number | null) => (n === null || n === undefined ? '—' : formatCurrency(n, 'GBP', 'en-GB'));
const signed = (n?: number | null) => {
  if (n === null || n === undefined) return '—';
  if (Math.abs(n) < 0.005) return '£0.00';
  return (n > 0 ? '+' : '−') + formatCurrency(Math.abs(n), 'GBP', 'en-GB');
};
const SOURCE_TYPES: Record<string, string> = {
  'uk-property': 'UK property',
  'self-employment': 'Self-employment',
  'foreign-property': 'Foreign property',
};

// cjson sends an empty Lua table as {} rather than [].
const list = <T,>(x: T[] | Record<string, never> | undefined | null): T[] => (Array.isArray(x) ? x : []);

export default function EstimateVsHmrc({ comparison: raw }: { comparison: HmrcComparison }) {
  const [open, setOpen] = useState(false);
  const comparison = {
    ...raw,
    rows: list(raw.rows),
    income_sources: list(raw.income_sources),
    extras: list(raw.extras),
    messages: {
      errors: list(raw.messages?.errors),
      warnings: list(raw.messages?.warnings),
      info: list(raw.messages?.info),
    },
  };
  const total = comparison.rows.find((r) => r.key === 'total');
  const differing = comparison.rows.filter((r) => r.differs);
  const hasMessages = (['errors', 'warnings', 'info'] as const).some((k) => comparison.messages[k].length > 0);

  return (
    <div className="space-y-3" data-testid="estimate-vs-hmrc">
      {/* The two totals, side by side */}
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
        <div className="rounded-lg border border-secondary-200 bg-surface p-3">
          <p className="text-xs font-medium uppercase tracking-wide text-secondary-500">Our estimate (OpsAPI)</p>
          <p className="mt-1 text-xl font-semibold text-secondary-900 tabular-nums">{gbp(total?.ours)}</p>
          <p className="text-xs text-secondary-500">Worked out by OpsAPI from your sorted transactions</p>
        </div>
        <div className="rounded-lg border border-primary-200 bg-primary-50/40 p-3">
          <p className="text-xs font-medium uppercase tracking-wide text-primary-700">HMRC&apos;s calculation</p>
          <p className="mt-1 text-xl font-semibold text-secondary-900 tabular-nums">
            {comparison.sandbox ? '—' : gbp(total?.hmrc)}
          </p>
          <p className="text-xs text-secondary-500">The figure your return is filed on</p>
        </div>
      </div>

      {comparison.sandbox ? (
        <div className="flex items-start gap-2 rounded-lg border border-blue-200 bg-blue-50 p-3 text-xs text-blue-800">
          <Info className="mt-0.5 h-4 w-4 shrink-0" />
          <span>
            HMRC&apos;s test service returns sample figures, so its column won&apos;t match ours here. Against
            HMRC&apos;s live service the two should agree, and any difference is explained below.
          </span>
        </div>
      ) : comparison.differs ? (
        <div className="flex items-start gap-2 rounded-lg border border-amber-200 bg-amber-50 p-3 text-xs text-amber-900">
          <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" />
          <span>
            HMRC&apos;s figure differs from our estimate by <strong>{signed(comparison.total_delta)}</strong>.
            HMRC&apos;s figure is the one that counts — open the reasons below to see why.
          </span>
        </div>
      ) : (
        <div className="flex items-center gap-2 rounded-lg border border-green-200 bg-green-50 p-3 text-xs text-green-800">
          <CheckCircle2 className="h-4 w-4 shrink-0" />
          <span>HMRC&apos;s calculation matches our estimate.</span>
        </div>
      )}

      {/* Line by line: ours | HMRC | difference */}
      <div className="overflow-x-auto rounded-lg border border-secondary-200">
        <table className="w-full text-sm">
          <thead className="bg-secondary-50 text-xs uppercase tracking-wide text-secondary-500">
            <tr>
              <th className="px-3 py-2 text-left font-medium">Line</th>
              <th className="px-3 py-2 text-right font-medium">Our estimate</th>
              <th className="px-3 py-2 text-right font-medium">HMRC</th>
              <th className="px-3 py-2 text-right font-medium">Difference</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-secondary-100">
            {comparison.rows.map((r) => (
              <tr
                key={r.key}
                className={`${r.differs ? 'bg-amber-50/60' : ''} ${r.is_total ? 'font-semibold' : ''}`}
                data-differs={r.differs ? 'true' : 'false'}
              >
                <td className="px-3 py-2 text-secondary-800">
                  {r.differs && <span className="mr-1.5 inline-block h-2 w-2 rounded-full bg-amber-500 align-middle" />}
                  {r.label}
                </td>
                <td className="px-3 py-2 text-right tabular-nums text-secondary-900">{gbp(r.ours)}</td>
                <td className="px-3 py-2 text-right tabular-nums text-secondary-900">
                  {comparison.sandbox && r.is_total ? '—' : gbp(r.hmrc)}
                </td>
                <td className={`px-3 py-2 text-right tabular-nums ${r.differs ? 'text-amber-800' : 'text-secondary-400'}`}>
                  {comparison.sandbox && r.is_total ? '—' : signed(r.delta)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {(differing.length > 0 || comparison.income_sources.length > 0 || comparison.extras.length > 0 || hasMessages) && (
        <button
          type="button"
          onClick={() => setOpen((o) => !o)}
          className="inline-flex items-center gap-1.5 text-sm font-medium text-primary-700 hover:text-primary-800"
          aria-expanded={open}
        >
          {open ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}
          {differing.length > 0 ? 'Why is HMRC’s figure different?' : 'What HMRC included'}
        </button>
      )}

      {open && (
        <div className="space-y-4 rounded-lg border border-secondary-200 bg-surface p-3 text-sm">
          {differing.length > 0 && (
            <div className="space-y-2">
              <p className="font-medium text-secondary-900">Lines that differ</p>
              <ul className="space-y-2">
                {differing.map((r) => (
                  <li key={r.key} className="rounded-md bg-amber-50/60 p-2">
                    <p className="font-medium text-secondary-900">
                      {r.label}: ours {gbp(r.ours)}, HMRC {comparison.sandbox && r.is_total ? '—' : gbp(r.hmrc)}
                      {r.delta !== null && r.delta !== undefined && !(comparison.sandbox && r.is_total)
                        ? ` (${signed(r.delta)})` : ''}
                    </p>
                    {r.why && <p className="mt-0.5 text-xs text-secondary-600">{r.why}</p>}
                  </li>
                ))}
              </ul>
            </div>
          )}

          {comparison.income_sources.length > 0 && (
            <div className="space-y-1">
              <p className="font-medium text-secondary-900">Income sources in HMRC&apos;s calculation</p>
              <div className="divide-y divide-secondary-100">
                {comparison.income_sources.map((s, i) => (
                  <div key={s.id || i} className="flex items-center justify-between py-1 text-xs">
                    <span className="text-secondary-700">
                      {s.name || SOURCE_TYPES[s.type || ''] || s.type || 'Income source'}
                      {s.income !== undefined && s.income !== null && (
                        <span className="text-secondary-400"> · income {gbp(s.income)}, expenses {gbp(s.expenses)}</span>
                      )}
                    </span>
                    <span className="tabular-nums text-secondary-900">profit {gbp(s.taxable_profit)}</span>
                  </div>
                ))}
              </div>
            </div>
          )}

          {comparison.extras.length > 0 && (
            <div className="space-y-1">
              <p className="font-medium text-secondary-900">In HMRC&apos;s calculation but not in our estimate</p>
              <div className="divide-y divide-secondary-100">
                {comparison.extras.map((e) => (
                  <div key={e.label} className="flex items-center justify-between py-1 text-xs">
                    <span className="text-secondary-700">{e.label}</span>
                    <span className="tabular-nums text-secondary-900">{gbp(e.amount)}</span>
                  </div>
                ))}
              </div>
            </div>
          )}

          {hasMessages && (
            <div className="space-y-1">
              <p className="font-medium text-secondary-900">HMRC&apos;s notes on this calculation</p>
              <ul className="space-y-1 text-xs">
                {comparison.messages.errors.map((m) => (
                  <li key={'e' + m.id + m.text} className="text-red-700">Error: {m.text}</li>
                ))}
                {comparison.messages.warnings.map((m) => (
                  <li key={'w' + m.id + m.text} className="text-amber-800">Warning: {m.text}</li>
                ))}
                {comparison.messages.info.map((m) => (
                  <li key={'i' + m.id + m.text} className="text-secondary-600">{m.text}</li>
                ))}
              </ul>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

'use client';

import React, { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import { ChevronRight, ClipboardList, Search } from 'lucide-react';
import { cn } from '@/lib/utils';
import { StageBadge, balanceText, fmtDate, fmtMoney, inputClass } from '@/components/supplier-portal/shared';
import { useSupplierMe } from '@/components/supplier-portal/SupplierPortalContext';
import { portalError, supplierPortalService, type SupplierPoListItem } from '@/services/supplier-portal.service';

const PER_PAGE = 25;

const BALANCE_TONE: Record<string, string> = {
  paid: 'text-emerald-700',
  part_paid: 'text-amber-700',
  unpaid: 'text-amber-700',
  overpaid: 'text-red-700',
  nothing_due: 'text-secondary-500',
};

export default function SupplierPurchaseOrdersPage() {
  const me = useSupplierMe();
  const [filter, setFilter] = useState<'open' | 'all'>('open');
  const [search, setSearch] = useState('');
  const [query, setQuery] = useState('');
  const [page, setPage] = useState(1);
  const [rows, setRows] = useState<SupplierPoListItem[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // Search as you type, a moment after the last key.
  useEffect(() => {
    const t = setTimeout(() => {
      setQuery(search.trim());
      setPage(1);
    }, 350);
    return () => clearTimeout(t);
  }, [search]);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const r = await supplierPortalService.listPurchaseOrders({
        stage: filter,
        search: query || undefined,
        page,
        perPage: PER_PAGE,
      });
      setRows(r.data);
      setTotal(r.total);
      setError(null);
    } catch (err) {
      setError(portalError(err, 'Your purchase orders could not be loaded').message);
    } finally {
      setLoading(false);
    }
  }, [filter, query, page]);

  useEffect(() => {
    void load();
  }, [load]);

  const pages = Math.max(1, Math.ceil(total / PER_PAGE));

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-semibold text-secondary-900">Purchase orders</h1>
        <p className="text-sm text-secondary-500">
          Purchase orders {me?.buyer.name ? `${me.buyer.name} has` : 'we have'} sent you. Open one to upload your proforma or
          invoice, enter dispatch and see our payments.
        </p>
      </div>

      <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
        <div className="inline-flex rounded-lg border border-secondary-300 bg-surface p-0.5" role="tablist">
          {(['open', 'all'] as const).map((f) => (
            <button
              key={f}
              type="button"
              role="tab"
              aria-selected={filter === f}
              onClick={() => {
                setFilter(f);
                setPage(1);
              }}
              className={cn(
                'rounded-md px-3 py-1.5 text-sm font-medium',
                filter === f ? 'bg-primary-600 text-white' : 'text-secondary-600 hover:text-secondary-900'
              )}
            >
              {f === 'open' ? 'Open' : 'All'}
            </button>
          ))}
        </div>
        <div className="relative sm:w-72">
          <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-secondary-400" />
          <input
            className={cn(inputClass, 'pl-9')}
            placeholder="Search PO number or reference"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
        </div>
      </div>

      {error && <p className="rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-700">{error}</p>}

      <div className="overflow-hidden rounded-xl border border-secondary-200 bg-surface shadow-sm">
        {loading && rows.length === 0 ? (
          <div className="space-y-2 p-4">
            {[0, 1, 2].map((i) => (
              <div key={i} className="h-12 animate-pulse rounded bg-secondary-100" />
            ))}
          </div>
        ) : rows.length === 0 ? (
          <div className="p-8 text-center">
            <ClipboardList className="mx-auto mb-2 h-10 w-10 text-secondary-300" />
            <p className="text-sm text-secondary-600">
              {query ? 'No purchase orders match your search.' : filter === 'open' ? 'No open purchase orders.' : 'No purchase orders yet.'}
            </p>
          </div>
        ) : (
          <>
            {/* Table on wider screens */}
            <table className="hidden w-full text-sm md:table">
              <thead className="bg-secondary-50 text-left text-xs uppercase tracking-wide text-secondary-500">
                <tr>
                  <th className="px-4 py-2.5">PO number</th>
                  <th className="px-4 py-2.5">Stage</th>
                  <th className="px-4 py-2.5">Date</th>
                  <th className="px-4 py-2.5 text-right">Total</th>
                  <th className="px-4 py-2.5">Payment</th>
                  <th className="px-4 py-2.5" />
                </tr>
              </thead>
              <tbody className="divide-y divide-secondary-100">
                {rows.map((r) => (
                  <tr key={r.id} className="hover:bg-secondary-50">
                    <td className="px-4 py-3">
                      <Link href={`/supplier/purchase-orders/${r.id}`} className="font-medium text-primary-700 hover:underline">
                        {r.po_number}
                      </Link>
                      {(r.deal_code || r.reference) && (
                        <p className="text-xs text-secondary-500">{r.deal_code || r.reference}</p>
                      )}
                    </td>
                    <td className="px-4 py-3">
                      <StageBadge stage={r.stage} label={r.stage_label} />
                    </td>
                    <td className="px-4 py-3 text-secondary-700">{fmtDate(r.issue_date)}</td>
                    <td className="px-4 py-3 text-right font-medium text-secondary-900">{fmtMoney(r.total, r.currency)}</td>
                    <td className={cn('px-4 py-3', BALANCE_TONE[r.balance?.state] || '')}>
                      {balanceText(r.balance)}
                      {r.balance && Number(r.balance.balance) > 0 && r.balance.state !== 'unpaid' && (
                        <span className="block text-xs text-secondary-500">
                          {fmtMoney(r.balance.balance, r.balance.currency)} still to pay
                        </span>
                      )}
                    </td>
                    <td className="px-4 py-3 text-right">
                      <Link href={`/supplier/purchase-orders/${r.id}`} className="text-sm text-primary-700 hover:underline">
                        Open
                      </Link>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            {/* Cards on phones */}
            <ul className="divide-y divide-secondary-100 md:hidden">
              {rows.map((r) => (
                <li key={r.id}>
                  <Link href={`/supplier/purchase-orders/${r.id}`} className="flex items-center gap-3 p-4 hover:bg-secondary-50">
                    <div className="min-w-0 flex-1 space-y-1">
                      <div className="flex flex-wrap items-center gap-2">
                        <span className="font-medium text-secondary-900">{r.po_number}</span>
                        <StageBadge stage={r.stage} label={r.stage_label} />
                      </div>
                      <p className="text-xs text-secondary-500">
                        {fmtDate(r.issue_date)}
                        {r.deal_code ? ` · ${r.deal_code}` : ''}
                      </p>
                      <p className="text-sm">
                        <span className="font-medium text-secondary-900">{fmtMoney(r.total, r.currency)}</span>
                        <span className={cn('ml-2', BALANCE_TONE[r.balance?.state] || '')}>{balanceText(r.balance)}</span>
                      </p>
                    </div>
                    <ChevronRight className="h-5 w-5 shrink-0 text-secondary-400" />
                  </Link>
                </li>
              ))}
            </ul>
          </>
        )}
      </div>

      {pages > 1 && (
        <div className="flex items-center justify-between text-sm">
          <button
            type="button"
            disabled={page <= 1}
            onClick={() => setPage((p) => Math.max(1, p - 1))}
            className="rounded-lg border border-secondary-300 bg-surface px-3 py-1.5 disabled:opacity-50"
          >
            Previous
          </button>
          <span className="text-secondary-600">
            Page {page} of {pages}
          </span>
          <button
            type="button"
            disabled={page >= pages}
            onClick={() => setPage((p) => p + 1)}
            className="rounded-lg border border-secondary-300 bg-surface px-3 py-1.5 disabled:opacity-50"
          >
            Next
          </button>
        </div>
      )}
    </div>
  );
}

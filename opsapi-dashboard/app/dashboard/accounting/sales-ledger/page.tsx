'use client';

import React, { useState, useEffect, useCallback, useRef } from 'react';
import Link from 'next/link';
import {
  ArrowLeft, RefreshCw, Search, PoundSterling, AlertTriangle,
  TrendingUp, Clock,
} from 'lucide-react';
import { cn, formatCurrency, formatDate } from '@/lib/utils';
import Badge from '@/components/ui/Badge';
import Pagination from '@/components/ui/Pagination';
import invoicesService from '@/services/invoices.service';
import type { Invoice } from '@/services/invoices.service';
import toast from 'react-hot-toast';

// ── Aging Helper ──────────────────────────────────────────────────────────────

function getAgingBucket(dueDate: string): string {
  if (!dueDate) return '-';
  const due = new Date(dueDate);
  const today = new Date();
  const diffDays = Math.floor((today.getTime() - due.getTime()) / (1000 * 60 * 60 * 24));
  if (diffDays <= 0) return 'Current';
  if (diffDays <= 30) return '1-30 days';
  if (diffDays <= 60) return '31-60 days';
  if (diffDays <= 90) return '61-90 days';
  return '90+ days';
}

function getAgingColor(bucket: string): string {
  switch (bucket) {
    case 'Current': return 'text-success-600';
    case '1-30 days': return 'text-warning-600';
    case '31-60 days': return 'text-warning-600';
    case '61-90 days': return 'text-error-500';
    case '90+ days': return 'text-error-600 font-semibold';
    default: return 'text-secondary-500';
  }
}

// ── Page Component ────────────────────────────────────────────────────────────

export default function SalesLedgerPage() {
  const [invoices, setInvoices] = useState<Invoice[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [search, setSearch] = useState('');
  const [statusFilter, setStatusFilter] = useState('');
  const [stats, setStats] = useState({
    totalOutstanding: 0,
    totalOverdue: 0,
    receiptsThisMonth: 0,
    totalInvoiced: 0,
  });
  const fetchIdRef = useRef(0);
  const searchTimeoutRef = useRef<NodeJS.Timeout | null>(null);

  const PER_PAGE = 20;

  // ── Data Fetching ─────────────────────────────────────────────────────────

  const fetchInvoices = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);

    try {
      const [invoiceRes, statsRes] = await Promise.all([
        invoicesService.getInvoices({
          page,
          perPage: PER_PAGE,
          search: search || undefined,
          status: (statusFilter as Invoice['status']) || undefined,
        }),
        invoicesService.getDashboardStats(),
      ]);

      if (fetchId !== fetchIdRef.current) return;

      const data = invoiceRes.data || [];
      setInvoices(data);
      setTotalPages(invoiceRes.total_pages || 1);
      setTotalItems(invoiceRes.total || 0);

      setStats({
        totalOutstanding: statsRes.total_outstanding || 0,
        totalOverdue: statsRes.total_overdue || 0,
        receiptsThisMonth: statsRes.total_paid || 0,
        totalInvoiced: statsRes.total_invoiced || 0,
      });
    } catch {
      toast.error('Failed to load sales ledger');
    } finally {
      if (fetchId === fetchIdRef.current) setIsLoading(false);
    }
  }, [page, search, statusFilter]);

  useEffect(() => {
    fetchInvoices();
  }, [fetchInvoices]);

  const handleSearchChange = useCallback((e: React.ChangeEvent<HTMLInputElement>) => {
    const value = e.target.value;
    setSearch(value);
    if (searchTimeoutRef.current) clearTimeout(searchTimeoutRef.current);
    searchTimeoutRef.current = setTimeout(() => {
      setPage(1);
    }, 300);
  }, []);

  // ── Render ────────────────────────────────────────────────────────────────

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div className="flex items-center gap-3">
          <Link
            href="/dashboard/accounting"
            className="p-2 text-secondary-500 hover:text-secondary-700 hover:bg-secondary-100 rounded-lg transition-colors"
            aria-label="Back to accounting"
          >
            <ArrowLeft className="w-5 h-5" />
          </Link>
          <div>
            <h1 className="text-2xl font-bold text-secondary-900">Sales Ledger</h1>
            <p className="text-sm text-secondary-500 mt-0.5">
              Customer invoices, receipts and aging balances
            </p>
          </div>
        </div>
        <button
          onClick={fetchInvoices}
          className="p-2.5 text-secondary-500 hover:text-secondary-700 hover:bg-secondary-100 rounded-lg transition-colors self-end"
          aria-label="Refresh data"
        >
          <RefreshCw className={cn('w-5 h-5', isLoading && 'animate-spin')} />
        </button>
      </div>

      {/* Stats Cards */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <div className="bg-surface rounded-xl border border-secondary-200 p-4 sm:p-5">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-xs sm:text-sm font-medium text-secondary-500">Total Invoiced</p>
              <p className="text-lg sm:text-2xl font-bold text-secondary-900 mt-1 tabular-nums">
                {formatCurrency(stats.totalInvoiced, 'GBP', 'en-GB')}
              </p>
            </div>
            <div className="w-10 h-10 sm:w-12 sm:h-12 gradient-primary rounded-lg sm:rounded-xl flex items-center justify-center text-white shadow-lg shadow-primary-500/25">
              <PoundSterling className="w-5 h-5 sm:w-6 sm:h-6" />
            </div>
          </div>
        </div>

        <div className="bg-surface rounded-xl border border-secondary-200 p-4 sm:p-5">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-xs sm:text-sm font-medium text-secondary-500">Outstanding</p>
              <p className="text-lg sm:text-2xl font-bold text-warning-600 mt-1 tabular-nums">
                {formatCurrency(stats.totalOutstanding, 'GBP', 'en-GB')}
              </p>
            </div>
            <div className="w-10 h-10 sm:w-12 sm:h-12 bg-warning-500 rounded-lg sm:rounded-xl flex items-center justify-center text-white shadow-lg shadow-warning-500/25">
              <Clock className="w-5 h-5 sm:w-6 sm:h-6" />
            </div>
          </div>
        </div>

        <div className="bg-surface rounded-xl border border-secondary-200 p-4 sm:p-5">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-xs sm:text-sm font-medium text-secondary-500">Overdue</p>
              <p className="text-lg sm:text-2xl font-bold text-error-600 mt-1 tabular-nums">
                {formatCurrency(stats.totalOverdue, 'GBP', 'en-GB')}
              </p>
            </div>
            <div className="w-10 h-10 sm:w-12 sm:h-12 bg-error-500 rounded-lg sm:rounded-xl flex items-center justify-center text-white shadow-lg shadow-error-500/25">
              <AlertTriangle className="w-5 h-5 sm:w-6 sm:h-6" />
            </div>
          </div>
        </div>

        <div className="bg-surface rounded-xl border border-secondary-200 p-4 sm:p-5">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-xs sm:text-sm font-medium text-secondary-500">Received This Month</p>
              <p className="text-lg sm:text-2xl font-bold text-success-600 mt-1 tabular-nums">
                {formatCurrency(stats.receiptsThisMonth, 'GBP', 'en-GB')}
              </p>
            </div>
            <div className="w-10 h-10 sm:w-12 sm:h-12 bg-success-500 rounded-lg sm:rounded-xl flex items-center justify-center text-white shadow-lg shadow-success-500/25">
              <TrendingUp className="w-5 h-5 sm:w-6 sm:h-6" />
            </div>
          </div>
        </div>
      </div>

      {/* Filters */}
      <div className="bg-surface rounded-xl border border-secondary-200 p-4">
        <div className="flex flex-col sm:flex-row gap-3">
          <div className="relative flex-1">
            <label htmlFor="sales-ledger-search" className="sr-only">Search invoices</label>
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-secondary-400" aria-hidden="true" />
            <input
              id="sales-ledger-search"
              type="search"
              value={search}
              onChange={handleSearchChange}
              placeholder="Search by invoice #, customer..."
              className="w-full pl-10 pr-4 py-2.5 rounded-lg border border-secondary-300 text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
            />
          </div>
          <select
            value={statusFilter}
            onChange={(e) => { setStatusFilter(e.target.value); setPage(1); }}
            className="px-4 py-2.5 rounded-lg border border-secondary-300 text-sm bg-surface focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
            aria-label="Filter by status"
          >
            <option value="">All Statuses</option>
            <option value="draft">Draft</option>
            <option value="sent">Sent</option>
            <option value="paid">Paid</option>
            <option value="partially_paid">Partially Paid</option>
            <option value="overdue">Overdue</option>
            <option value="cancelled">Cancelled</option>
          </select>
        </div>
      </div>

      {/* Invoice Table */}
      <div className="bg-surface rounded-xl border border-secondary-200 overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full">
            <thead>
              <tr className="bg-secondary-50 border-b border-secondary-200">
                <th scope="col" className="px-6 py-4 text-left text-xs font-semibold text-secondary-600 uppercase tracking-wider">Date</th>
                <th scope="col" className="px-6 py-4 text-left text-xs font-semibold text-secondary-600 uppercase tracking-wider">Invoice #</th>
                <th scope="col" className="px-6 py-4 text-left text-xs font-semibold text-secondary-600 uppercase tracking-wider">Customer</th>
                <th scope="col" className="px-6 py-4 text-right text-xs font-semibold text-secondary-600 uppercase tracking-wider">Amount</th>
                <th scope="col" className="px-6 py-4 text-right text-xs font-semibold text-secondary-600 uppercase tracking-wider">Paid</th>
                <th scope="col" className="px-6 py-4 text-right text-xs font-semibold text-secondary-600 uppercase tracking-wider">Balance</th>
                <th scope="col" className="px-6 py-4 text-left text-xs font-semibold text-secondary-600 uppercase tracking-wider">Status</th>
                <th scope="col" className="px-6 py-4 text-left text-xs font-semibold text-secondary-600 uppercase tracking-wider">Age</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-secondary-100">
              {isLoading ? (
                Array.from({ length: 5 }).map((_, i) => (
                  <tr key={i}>
                    {Array.from({ length: 8 }).map((_, j) => (
                      <td key={j} className="px-6 py-4">
                        <div className="h-4 bg-secondary-200 rounded animate-pulse" />
                      </td>
                    ))}
                  </tr>
                ))
              ) : invoices.length === 0 ? (
                <tr>
                  <td colSpan={8} className="px-6 py-12 text-center text-secondary-500">
                    No invoices found
                  </td>
                </tr>
              ) : (
                invoices.map((invoice) => {
                  const balance = (invoice.balance_due ?? (invoice.total - (invoice.amount_paid || 0)));
                  const agingBucket = invoice.status !== 'paid' ? getAgingBucket(invoice.due_date) : '-';

                  return (
                    <tr
                      key={invoice.uuid}
                      className="hover:bg-secondary-50 transition-colors cursor-pointer"
                      onClick={() => window.location.href = `/dashboard/invoices/${invoice.uuid}`}
                      tabIndex={0}
                      onKeyDown={(e) => {
                        if (e.key === 'Enter') window.location.href = `/dashboard/invoices/${invoice.uuid}`;
                      }}
                    >
                      <td className="px-6 py-4 text-sm text-secondary-900">{formatDate(invoice.issue_date)}</td>
                      <td className="px-6 py-4 text-sm font-medium text-secondary-900">{invoice.invoice_number || '-'}</td>
                      <td className="px-6 py-4 text-sm text-secondary-900">{invoice.customer_name || '-'}</td>
                      <td className="px-6 py-4 text-sm text-secondary-900 text-right tabular-nums">
                        {formatCurrency(invoice.total, 'GBP', 'en-GB')}
                      </td>
                      <td className="px-6 py-4 text-sm text-success-600 text-right tabular-nums">
                        {formatCurrency(invoice.amount_paid || 0, 'GBP', 'en-GB')}
                      </td>
                      <td className={cn('px-6 py-4 text-sm text-right tabular-nums font-medium', balance > 0 ? 'text-warning-600' : 'text-secondary-500')}>
                        {formatCurrency(balance, 'GBP', 'en-GB')}
                      </td>
                      <td className="px-6 py-4">
                        <Badge status={invoice.status} size="sm" />
                      </td>
                      <td className={cn('px-6 py-4 text-sm', getAgingColor(agingBucket))}>
                        {agingBucket}
                      </td>
                    </tr>
                  );
                })
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* Pagination */}
      <Pagination
        currentPage={page}
        totalPages={totalPages}
        totalItems={totalItems}
        perPage={PER_PAGE}
        onPageChange={setPage}
      />

      {/* Aging Summary */}
      {!isLoading && invoices.length > 0 && (
        <AgingSummary invoices={invoices} />
      )}
    </div>
  );
}

// ── Aging Summary Component ───────────────────────────────────────────────────

function AgingSummary({ invoices }: { invoices: Invoice[] }) {
  const unpaid = invoices.filter((inv) => inv.status !== 'paid' && inv.status !== 'cancelled' && inv.status !== 'void');

  const buckets = {
    Current: 0,
    '1-30 days': 0,
    '31-60 days': 0,
    '61-90 days': 0,
    '90+ days': 0,
  };

  unpaid.forEach((inv) => {
    const bucket = getAgingBucket(inv.due_date) as keyof typeof buckets;
    if (bucket in buckets) {
      buckets[bucket] += (inv.balance_due ?? (inv.total - (inv.amount_paid || 0)));
    }
  });

  const total = Object.values(buckets).reduce((a, b) => a + b, 0);
  if (total === 0) return null;

  return (
    <div className="bg-surface rounded-xl border border-secondary-200 p-6">
      <h3 className="text-sm font-semibold text-secondary-700 mb-4">Aging Analysis</h3>
      <div className="grid grid-cols-2 sm:grid-cols-5 gap-4">
        {Object.entries(buckets).map(([label, amount]) => (
          <div key={label} className="text-center">
            <p className="text-xs text-secondary-500 mb-1">{label}</p>
            <p className={cn(
              'text-sm font-semibold tabular-nums',
              label === 'Current' ? 'text-success-600' :
              label.includes('90') ? 'text-error-600' :
              'text-warning-600'
            )}>
              {formatCurrency(amount, 'GBP', 'en-GB')}
            </p>
            {total > 0 && (
              <div className="mt-2 h-2 bg-secondary-100 rounded-full overflow-hidden">
                <div
                  className={cn(
                    'h-full rounded-full transition-all',
                    label === 'Current' ? 'bg-success-500' :
                    label.includes('90') ? 'bg-error-500' :
                    'bg-warning-500'
                  )}
                  style={{ width: `${Math.max((amount / total) * 100, 2)}%` }}
                />
              </div>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}

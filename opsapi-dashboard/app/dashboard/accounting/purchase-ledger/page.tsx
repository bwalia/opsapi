'use client';

import React, { useState, useEffect, useCallback, useRef } from 'react';
import Link from 'next/link';
import {
  ArrowLeft, RefreshCw, Search, PoundSterling, AlertTriangle,
  TrendingDown, Clock,
} from 'lucide-react';
import { cn, formatCurrency, formatDate } from '@/lib/utils';
import Badge from '@/components/ui/Badge';
import Pagination from '@/components/ui/Pagination';
import accountingService from '@/services/accounting.service';
import type { Expense } from '@/services/accounting.service';
import toast from 'react-hot-toast';

// ── Aging Helper ──────────────────────────────────────────────────────────────

function getPaymentAge(expenseDate: string): string {
  if (!expenseDate) return '-';
  const created = new Date(expenseDate);
  const today = new Date();
  const diffDays = Math.floor((today.getTime() - created.getTime()) / (1000 * 60 * 60 * 24));
  if (diffDays <= 30) return 'Current';
  if (diffDays <= 60) return '31-60 days';
  if (diffDays <= 90) return '61-90 days';
  return '90+ days';
}

function getAgingColor(bucket: string): string {
  switch (bucket) {
    case 'Current': return 'text-success-600';
    case '31-60 days': return 'text-warning-600';
    case '61-90 days': return 'text-error-500';
    case '90+ days': return 'text-error-600 font-semibold';
    default: return 'text-secondary-500';
  }
}

// ── Page Component ────────────────────────────────────────────────────────────

export default function PurchaseLedgerPage() {
  const [expenses, setExpenses] = useState<Expense[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [search, setSearch] = useState('');
  const [statusFilter, setStatusFilter] = useState('');
  const [categoryFilter, setCategoryFilter] = useState('');
  const [stats, setStats] = useState({
    totalOwed: 0,
    totalPending: 0,
    expensesThisMonth: 0,
    vatReclaimable: 0,
  });
  const fetchIdRef = useRef(0);
  const searchTimeoutRef = useRef<NodeJS.Timeout | null>(null);

  const PER_PAGE = 20;

  // ── Data Fetching ─────────────────────────────────────────────────────────

  const fetchExpenses = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);

    try {
      const [expRes, statsRes] = await Promise.all([
        accountingService.getExpenses({
          page,
          perPage: PER_PAGE,
          search: search || undefined,
          status: statusFilter || undefined,
          category: categoryFilter || undefined,
        }),
        accountingService.getDashboardStats(),
      ]);

      if (fetchId !== fetchIdRef.current) return;

      const data = expRes.data || [];
      setExpenses(data);
      setTotalPages(expRes.total_pages || 1);
      setTotalItems(expRes.total || 0);

      // Compute stats from expenses
      const pending = data.filter((e) => e.status === 'pending' || e.status === 'approved');
      const totalPending = pending.reduce((sum, e) => sum + (e.amount || 0), 0);
      const vatReclaimable = data
        .filter((e) => e.is_vat_reclaimable)
        .reduce((sum, e) => sum + (e.vat_amount || 0), 0);

      setStats({
        totalOwed: statsRes.expenses_this_month || 0,
        totalPending,
        expensesThisMonth: statsRes.expenses_this_month || 0,
        vatReclaimable,
      });
    } catch {
      toast.error('Failed to load purchase ledger');
    } finally {
      if (fetchId === fetchIdRef.current) setIsLoading(false);
    }
  }, [page, search, statusFilter, categoryFilter]);

  useEffect(() => {
    fetchExpenses();
  }, [fetchExpenses]);

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
            <h1 className="text-2xl font-bold text-secondary-900">Purchase Ledger</h1>
            <p className="text-sm text-secondary-500 mt-0.5">
              Supplier invoices, expenses and payment tracking
            </p>
          </div>
        </div>
        <button
          onClick={fetchExpenses}
          className="p-2.5 text-secondary-500 hover:text-secondary-700 hover:bg-secondary-100 rounded-lg transition-colors self-end"
          aria-label="Refresh data"
        >
          <RefreshCw className={cn('w-5 h-5', isLoading && 'animate-spin')} />
        </button>
      </div>

      {/* Stats Cards */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <div className="bg-white rounded-xl border border-secondary-200 p-4 sm:p-5">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-xs sm:text-sm font-medium text-secondary-500">Expenses This Month</p>
              <p className="text-lg sm:text-2xl font-bold text-secondary-900 mt-1 tabular-nums">
                {formatCurrency(stats.expensesThisMonth, 'GBP', 'en-GB')}
              </p>
            </div>
            <div className="w-10 h-10 sm:w-12 sm:h-12 gradient-primary rounded-lg sm:rounded-xl flex items-center justify-center text-white shadow-lg shadow-primary-500/25">
              <PoundSterling className="w-5 h-5 sm:w-6 sm:h-6" />
            </div>
          </div>
        </div>

        <div className="bg-white rounded-xl border border-secondary-200 p-4 sm:p-5">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-xs sm:text-sm font-medium text-secondary-500">Pending Approval</p>
              <p className="text-lg sm:text-2xl font-bold text-warning-600 mt-1 tabular-nums">
                {formatCurrency(stats.totalPending, 'GBP', 'en-GB')}
              </p>
            </div>
            <div className="w-10 h-10 sm:w-12 sm:h-12 bg-warning-500 rounded-lg sm:rounded-xl flex items-center justify-center text-white shadow-lg shadow-warning-500/25">
              <Clock className="w-5 h-5 sm:w-6 sm:h-6" />
            </div>
          </div>
        </div>

        <div className="bg-white rounded-xl border border-secondary-200 p-4 sm:p-5">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-xs sm:text-sm font-medium text-secondary-500">Total Owed</p>
              <p className="text-lg sm:text-2xl font-bold text-error-600 mt-1 tabular-nums">
                {formatCurrency(stats.totalOwed, 'GBP', 'en-GB')}
              </p>
            </div>
            <div className="w-10 h-10 sm:w-12 sm:h-12 bg-error-500 rounded-lg sm:rounded-xl flex items-center justify-center text-white shadow-lg shadow-error-500/25">
              <AlertTriangle className="w-5 h-5 sm:w-6 sm:h-6" />
            </div>
          </div>
        </div>

        <div className="bg-white rounded-xl border border-secondary-200 p-4 sm:p-5">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-xs sm:text-sm font-medium text-secondary-500">VAT Reclaimable</p>
              <p className="text-lg sm:text-2xl font-bold text-accent-600 mt-1 tabular-nums">
                {formatCurrency(stats.vatReclaimable, 'GBP', 'en-GB')}
              </p>
            </div>
            <div className="w-10 h-10 sm:w-12 sm:h-12 bg-accent-500 rounded-lg sm:rounded-xl flex items-center justify-center text-white shadow-lg shadow-accent-500/25">
              <TrendingDown className="w-5 h-5 sm:w-6 sm:h-6" />
            </div>
          </div>
        </div>
      </div>

      {/* Filters */}
      <div className="bg-white rounded-xl border border-secondary-200 p-4">
        <div className="flex flex-col sm:flex-row gap-3">
          <div className="relative flex-1">
            <label htmlFor="purchase-ledger-search" className="sr-only">Search expenses</label>
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-secondary-400" aria-hidden="true" />
            <input
              id="purchase-ledger-search"
              type="search"
              value={search}
              onChange={handleSearchChange}
              placeholder="Search by description, vendor..."
              className="w-full pl-10 pr-4 py-2.5 rounded-lg border border-secondary-300 text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
            />
          </div>
          <select
            value={statusFilter}
            onChange={(e) => { setStatusFilter(e.target.value); setPage(1); }}
            className="px-4 py-2.5 rounded-lg border border-secondary-300 text-sm bg-white focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
            aria-label="Filter by status"
          >
            <option value="">All Statuses</option>
            <option value="pending">Pending</option>
            <option value="approved">Approved</option>
            <option value="rejected">Rejected</option>
            <option value="posted">Posted</option>
          </select>
          <select
            value={categoryFilter}
            onChange={(e) => { setCategoryFilter(e.target.value); setPage(1); }}
            className="px-4 py-2.5 rounded-lg border border-secondary-300 text-sm bg-white focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
            aria-label="Filter by category"
          >
            <option value="">All Categories</option>
            <option value="office">Office</option>
            <option value="travel">Travel</option>
            <option value="utilities">Utilities</option>
            <option value="marketing">Marketing</option>
            <option value="software">Software</option>
            <option value="professional_fees">Professional Fees</option>
            <option value="other">Other</option>
          </select>
        </div>
      </div>

      {/* Expenses Table */}
      <div className="bg-white rounded-xl border border-secondary-200 overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full">
            <thead>
              <tr className="bg-secondary-50 border-b border-secondary-200">
                <th scope="col" className="px-6 py-4 text-left text-xs font-semibold text-secondary-600 uppercase tracking-wider">Date</th>
                <th scope="col" className="px-6 py-4 text-left text-xs font-semibold text-secondary-600 uppercase tracking-wider">Supplier</th>
                <th scope="col" className="px-6 py-4 text-left text-xs font-semibold text-secondary-600 uppercase tracking-wider">Description</th>
                <th scope="col" className="px-6 py-4 text-left text-xs font-semibold text-secondary-600 uppercase tracking-wider">Category</th>
                <th scope="col" className="px-6 py-4 text-right text-xs font-semibold text-secondary-600 uppercase tracking-wider">Amount</th>
                <th scope="col" className="px-6 py-4 text-right text-xs font-semibold text-secondary-600 uppercase tracking-wider">VAT</th>
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
              ) : expenses.length === 0 ? (
                <tr>
                  <td colSpan={8} className="px-6 py-12 text-center text-secondary-500">
                    No expenses found
                  </td>
                </tr>
              ) : (
                expenses.map((expense) => {
                  const ageBucket = expense.status !== 'posted' ? getPaymentAge(expense.expense_date) : '-';

                  return (
                    <tr key={expense.uuid} className="hover:bg-secondary-50 transition-colors">
                      <td className="px-6 py-4 text-sm text-secondary-900">{formatDate(expense.expense_date)}</td>
                      <td className="px-6 py-4 text-sm font-medium text-secondary-900">{expense.vendor || '-'}</td>
                      <td className="px-6 py-4 text-sm text-secondary-700 max-w-[200px] truncate">{expense.description}</td>
                      <td className="px-6 py-4 text-sm text-secondary-600 capitalize">{expense.category?.replace(/_/g, ' ') || '-'}</td>
                      <td className="px-6 py-4 text-sm text-secondary-900 text-right tabular-nums font-medium">
                        {formatCurrency(expense.amount, 'GBP', 'en-GB')}
                      </td>
                      <td className="px-6 py-4 text-sm text-secondary-600 text-right tabular-nums">
                        {expense.vat_amount > 0 ? formatCurrency(expense.vat_amount, 'GBP', 'en-GB') : '-'}
                        {expense.is_vat_reclaimable && expense.vat_amount > 0 && (
                          <span className="ml-1 text-xs text-accent-600" title="VAT reclaimable">R</span>
                        )}
                      </td>
                      <td className="px-6 py-4">
                        <Badge status={expense.status} size="sm" />
                      </td>
                      <td className={cn('px-6 py-4 text-sm', getAgingColor(ageBucket))}>
                        {ageBucket}
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

      {/* Category Breakdown */}
      {!isLoading && expenses.length > 0 && (
        <CategoryBreakdown expenses={expenses} />
      )}
    </div>
  );
}

// ── Category Breakdown ────────────────────────────────────────────────────────

function CategoryBreakdown({ expenses }: { expenses: Expense[] }) {
  const categoryTotals = expenses.reduce<Record<string, number>>((acc, exp) => {
    const cat = exp.category || 'Uncategorized';
    acc[cat] = (acc[cat] || 0) + (exp.amount || 0);
    return acc;
  }, {});

  const sorted = Object.entries(categoryTotals).sort(([, a], [, b]) => b - a);
  const total = sorted.reduce((sum, [, amount]) => sum + amount, 0);
  if (total === 0) return null;

  return (
    <div className="bg-white rounded-xl border border-secondary-200 p-6">
      <h3 className="text-sm font-semibold text-secondary-700 mb-4">Expense Breakdown by Category</h3>
      <div className="space-y-3">
        {sorted.map(([category, amount]) => {
          const pct = (amount / total) * 100;
          return (
            <div key={category}>
              <div className="flex items-center justify-between mb-1">
                <span className="text-sm text-secondary-700 capitalize">{category.replace(/_/g, ' ')}</span>
                <span className="text-sm font-medium text-secondary-900 tabular-nums">
                  {formatCurrency(amount, 'GBP', 'en-GB')} ({pct.toFixed(1)}%)
                </span>
              </div>
              <div className="h-2 bg-secondary-100 rounded-full overflow-hidden">
                <div
                  className="h-full bg-primary-500 rounded-full transition-all"
                  style={{ width: `${pct}%` }}
                />
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

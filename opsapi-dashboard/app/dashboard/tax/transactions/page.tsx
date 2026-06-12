'use client';

import React, { useState, useEffect, useCallback, useRef, useMemo } from 'react';
import {
  Search,
  RefreshCw,
  CheckCircle,
  XCircle,
  TrendingUp,
  TrendingDown,
  AlertTriangle,
} from 'lucide-react';
import Link from 'next/link';
import { Input, Table, Card, Pagination, SearchableSelect } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import {
  taxService,
  type TaxTransaction,
  type TaxTransactionFilters,
  type TaxTransactionSummary,
  type TaxCategory,
} from '@/services/tax.service';
import { formatDate, formatCurrency, snakeToTitle } from '@/lib/utils';
import type { TableColumn } from '@/types';
import toast from 'react-hot-toast';

const PER_PAGE = 25;

// One-click corrections for a credit that was mis-filed as an expense. Income options
// re-file it under the right HMRC box; "exclude" clears the box so it never reaches the
// return. Mirrors the guided "File your tax" wizard so both surfaces behave identically.
const CREDIT_FIX_OPTIONS = [
  { value: 'turnover', label: 'Business income (sales / turnover)', category: 'sales_income', hmrc_category: 'turnover' },
  { value: 'other_income', label: 'Other business income', category: 'income_other', hmrc_category: 'other_income' },
  { value: 'exclude', label: 'Personal / transfer — exclude', category: 'transfer', hmrc_category: '' },
];

function TransactionsContent() {
  const [transactions, setTransactions] = useState<TaxTransaction[]>([]);
  const [categories, setCategories] = useState<TaxCategory[]>([]);
  const [summary, setSummary] = useState<TaxTransactionSummary | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [total, setTotal] = useState(0);
  const [totalPages, setTotalPages] = useState(0);
  const [page, setPage] = useState(1);

  // Server-side filter/sort state — every change refetches from the API.
  const [searchQuery, setSearchQuery] = useState('');
  const [typeFilter, setTypeFilter] = useState<string>('all');
  const [statusFilter, setStatusFilter] = useState<string>('all');
  const [sortBy, setSortBy] = useState<string>('transaction_date');
  const [sortOrder, setSortOrder] = useState<'ASC' | 'DESC'>('DESC');

  const [editingTxn, setEditingTxn] = useState<string | null>(null);
  const [editCategory, setEditCategory] = useState<string>('');
  const fetchIdRef = useRef(0);

  // Transactions store the category *key* (snake_case, e.g. "personal_expense").
  // Map it to the human label from the categories list for display; fall back to a
  // title-cased version of the key for any value not present in the list.
  const categoryLabels = useMemo(() => {
    const map: Record<string, string> = {};
    for (const c of categories) {
      if (c.key) map[c.key] = c.name;
    }
    return map;
  }, [categories]);
  const labelForCategory = useCallback(
    (key?: string) => (key ? categoryLabels[key] || snakeToTitle(key) : ''),
    [categoryLabels],
  );

  // Map category key → income/expense, so we can flag the filing-breaking case: a CREDIT
  // (money in) classified into an EXPENSE category. Left as-is it becomes a negative
  // period value that HMRC rejects (the "negative values" filing blocker).
  const categoryTypeByKey = useMemo(() => {
    const map: Record<string, string> = {};
    for (const c of categories) if (c.key) map[c.key] = c.category_type;
    return map;
  }, [categories]);
  const isMisfiledCredit = useCallback(
    (t: TaxTransaction) =>
      t.transaction_type === 'CREDIT' && categoryTypeByKey[t.category || ''] === 'expense',
    [categoryTypeByKey],
  );

  // Which flagged row has its quick-fix menu open.
  const [fixOpen, setFixOpen] = useState<string | null>(null);

  // Debounce search so we don't fire a request per keystroke.
  const [debouncedSearch, setDebouncedSearch] = useState('');
  useEffect(() => {
    const t = setTimeout(() => setDebouncedSearch(searchQuery), 350);
    return () => clearTimeout(t);
  }, [searchQuery]);

  const fetchTransactions = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);
    try {
      const filters: TaxTransactionFilters = {
        page,
        limit: PER_PAGE,
        search: debouncedSearch || undefined,
        transaction_type: typeFilter !== 'all' ? typeFilter : undefined,
        classification_status: statusFilter !== 'all' ? statusFilter : undefined,
        sort_by: sortBy,
        sort_order: sortOrder,
      };
      const result = await taxService.getTransactions(filters);
      if (fetchId === fetchIdRef.current) {
        setTransactions(result.data);
        setTotal(result.total);
        setTotalPages(result.total_pages);
      }
    } catch {
      toast.error('Failed to load transactions');
    } finally {
      if (fetchId === fetchIdRef.current) setIsLoading(false);
    }
  }, [page, debouncedSearch, typeFilter, statusFilter, sortBy, sortOrder]);

  const fetchSummary = useCallback(async () => {
    try {
      setSummary(await taxService.getTransactionsSummary());
    } catch {
      // summary is best-effort
    }
  }, []);

  const fetchCategories = useCallback(async () => {
    try {
      setCategories(await taxService.getCategories());
    } catch {
      // categories might not be seeded yet
    }
  }, []);

  useEffect(() => { fetchTransactions(); }, [fetchTransactions]);
  useEffect(() => { fetchCategories(); }, [fetchCategories]);
  useEffect(() => { fetchSummary(); }, [fetchSummary]);

  // Reset to page 1 whenever a filter changes.
  useEffect(() => { setPage(1); }, [debouncedSearch, typeFilter, statusFilter]);

  const handleSort = (columnKey: string) => {
    if (sortBy === columnKey) {
      setSortOrder((prev) => (prev === 'ASC' ? 'DESC' : 'ASC'));
    } else {
      setSortBy(columnKey);
      setSortOrder('ASC');
    }
    setPage(1);
  };

  const isConfirmed = (t: TaxTransaction) => t.classification_status === 'CONFIRMED';

  const handleVerify = async (txn: TaxTransaction) => {
    try {
      await taxService.updateTransaction(txn.uuid, {
        classification_status: isConfirmed(txn) ? 'PENDING' : 'CONFIRMED',
      });
      toast.success(isConfirmed(txn) ? 'Marked pending' : 'Confirmed');
      fetchTransactions();
      fetchSummary();
    } catch {
      toast.error('Failed to update transaction');
    }
  };

  const handleCategoryChange = async (txn: TaxTransaction, category: string) => {
    try {
      await taxService.updateTransaction(txn.uuid, { category });
      toast.success('Category updated');
      setEditingTxn(null);
      fetchTransactions();
    } catch {
      toast.error('Failed to update category');
    }
  };

  // Apply a one-click correction to a credit mis-filed as an expense.
  const applyCreditFix = async (
    txn: TaxTransaction,
    opt: (typeof CREDIT_FIX_OPTIONS)[number],
  ) => {
    try {
      await taxService.updateTransaction(txn.uuid, {
        category: opt.category,
        hmrc_category: opt.hmrc_category,
        classification_status: 'CONFIRMED',
      });
      toast.success('Transaction corrected');
      setFixOpen(null);
      fetchTransactions();
      fetchSummary();
    } catch {
      toast.error('Failed to correct transaction');
    }
  };

  const columns: TableColumn<TaxTransaction>[] = [
    {
      key: 'transaction_date',
      header: 'Date',
      sortable: true,
      width: 'w-28',
      render: (item) => <span className="text-sm">{formatDate(item.transaction_date)}</span>,
    },
    {
      key: 'description',
      header: 'Description',
      sortable: true,
      render: (item) => (
        <div className="max-w-xs">
          <p className="text-sm font-medium truncate">{item.description}</p>
          {item.user_notes && <p className="text-xs text-secondary-400 truncate">{item.user_notes}</p>}
          {item.bank_name && <p className="text-xs text-secondary-400 truncate">{item.bank_name}</p>}
        </div>
      ),
    },
    {
      key: 'amount',
      header: 'Amount',
      sortable: true,
      render: (item) => {
        const isCredit = item.transaction_type === 'CREDIT';
        return (
          <div className="flex items-center gap-1">
            {isCredit ? (
              <TrendingUp className="w-3 h-3 text-green-500" />
            ) : (
              <TrendingDown className="w-3 h-3 text-red-500" />
            )}
            <span className={`font-medium ${isCredit ? 'text-green-700' : 'text-red-700'}`}>
              {isCredit ? '+' : '-'}{formatCurrency(Math.abs(Number(item.amount)), 'GBP', 'en-GB')}
            </span>
          </div>
        );
      },
    },
    {
      key: 'category',
      header: 'Category',
      sortable: true,
      render: (item) => {
        if (editingTxn === item.uuid) {
          return (
            <div className="min-w-[180px]">
              <SearchableSelect
                options={categories.map((cat) => ({
                  // The transaction's `category` column stores the key, so the option
                  // value must be the key (not the human label) or the write corrupts it.
                  value: cat.key || cat.name,
                  label: cat.name,
                  hint: cat.category_type === 'income' ? 'Income' : 'Expense',
                }))}
                value={editCategory}
                onChange={(val) => {
                  setEditCategory(val);
                  handleCategoryChange(item, val);
                }}
                onClose={() => setEditingTxn(null)}
                placeholder="Select..."
                searchPlaceholder="Search categories..."
                size="sm"
                autoFocus
              />
            </div>
          );
        }

        // A credit mis-filed as an expense: offer the same one-click corrections as the
        // wizard, inline. The quick-fix menu replaces the category button while open.
        if (isMisfiledCredit(item) && fixOpen === item.uuid) {
          return (
            <div className="min-w-[210px] space-y-1">
              {CREDIT_FIX_OPTIONS.map((o) => (
                <button
                  key={o.value}
                  onClick={() => applyCreditFix(item, o)}
                  className="block w-full text-left text-xs px-2 py-1 rounded hover:bg-secondary-100 text-secondary-700"
                >
                  {o.label}
                </button>
              ))}
              <button onClick={() => setFixOpen(null)} className="text-[10px] text-secondary-400 px-2">
                cancel
              </button>
            </div>
          );
        }

        const flagged = isMisfiledCredit(item);
        return (
          <div className="flex items-center gap-1">
            {flagged && (
              <AlertTriangle
                className="w-3.5 h-3.5 text-red-500 shrink-0"
                aria-label="Credit filed as an expense — HMRC would reject this"
              />
            )}
            <button
              onClick={() => { setEditingTxn(item.uuid); setEditCategory(item.category || ''); }}
              className={`text-xs px-2 py-1 rounded hover:bg-secondary-100 text-left max-w-[150px] truncate ${
                flagged ? 'text-red-700' : ''
              }`}
            >
              {item.category ? labelForCategory(item.category) : <span className="text-secondary-400 italic">Unclassified</span>}
              {item.confidence_score != null && (
                <span className={`ml-1 text-[10px] ${
                  item.confidence_score > 0.8 ? 'text-green-500' : item.confidence_score > 0.5 ? 'text-amber-500' : 'text-red-500'
                }`}>
                  ({(item.confidence_score * 100).toFixed(0)}%)
                </span>
              )}
            </button>
            {flagged && (
              <button
                onClick={() => setFixOpen(item.uuid)}
                className="text-[10px] font-medium text-primary-600 hover:underline shrink-0"
              >
                Fix
              </button>
            )}
          </div>
        );
      },
    },
    {
      key: 'is_tax_deductible',
      header: 'Deductible',
      width: 'w-24',
      render: (item) => (
        <span className={`text-xs px-2 py-0.5 rounded-full ${
          item.is_tax_deductible ? 'bg-green-100 text-green-700' : 'bg-secondary-100 text-secondary-500'
        }`}>
          {item.is_tax_deductible ? 'Yes' : 'No'}
        </span>
      ),
    },
    {
      key: 'classification_status',
      header: 'Confirmed',
      sortable: true,
      width: 'w-28',
      render: (item) => (
        <button
          onClick={(e) => { e.stopPropagation(); handleVerify(item); }}
          className={`flex items-center gap-1 text-xs px-2 py-0.5 rounded-full ${
            isConfirmed(item) ? 'bg-green-100 text-green-700 hover:bg-green-200' : 'bg-secondary-100 text-secondary-500 hover:bg-secondary-200'
          }`}
        >
          {isConfirmed(item) ? <CheckCircle className="w-3 h-3" /> : <XCircle className="w-3 h-3" />}
          {isConfirmed(item) ? 'Yes' : 'No'}
        </button>
      ),
    },
  ];

  const flaggedOnPage = transactions.filter(isMisfiledCredit);

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Transactions</h1>
          <p className="text-sm text-secondary-500 mt-1">
            {total} transactions
            {summary && summary.pending_classification > 0 && ` (${summary.pending_classification} pending)`}
          </p>
        </div>
        <button
          onClick={() => { fetchTransactions(); fetchSummary(); }}
          className="p-2 text-secondary-600 hover:bg-secondary-100 rounded-lg"
        >
          <RefreshCw className="w-4 h-4" />
        </button>
      </div>

      {/* Stats row — server-side aggregate over ALL records */}
      <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
        <div className="bg-surface rounded-xl border border-secondary-200 p-4">
          <p className="text-xs text-secondary-500">Total Income</p>
          <p className="text-lg font-bold text-green-600">{formatCurrency(summary?.total_income || 0, 'GBP', 'en-GB')}</p>
        </div>
        <div className="bg-surface rounded-xl border border-secondary-200 p-4">
          <p className="text-xs text-secondary-500">Total Expenses</p>
          <p className="text-lg font-bold text-red-600">{formatCurrency(summary?.total_expenses || 0, 'GBP', 'en-GB')}</p>
        </div>
        <div className="bg-surface rounded-xl border border-secondary-200 p-4">
          <p className="text-xs text-secondary-500">Pending Classification</p>
          <p className="text-lg font-bold text-secondary-900">{summary?.pending_classification || 0}</p>
        </div>
        <div className="bg-surface rounded-xl border border-secondary-200 p-4">
          <p className="text-xs text-secondary-500">Total Records</p>
          <p className="text-lg font-bold text-secondary-900">{summary?.total_transactions ?? total}</p>
        </div>
      </div>

      {/* Filters */}
      <Card padding="md">
        <div className="flex flex-col md:flex-row gap-3">
          <div className="flex-1">
            <Input
              placeholder="Search transactions..."
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              leftIcon={<Search className="w-4 h-4" />}
            />
          </div>
          <select
            value={typeFilter}
            onChange={(e) => setTypeFilter(e.target.value)}
            className="px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:ring-2 focus:ring-primary-500"
          >
            <option value="all">All Types</option>
            <option value="CREDIT">Income (Credit)</option>
            <option value="DEBIT">Expense (Debit)</option>
          </select>
          <select
            value={statusFilter}
            onChange={(e) => setStatusFilter(e.target.value)}
            className="px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:ring-2 focus:ring-primary-500"
          >
            <option value="all">All Status</option>
            <option value="CONFIRMED">Confirmed</option>
            <option value="PENDING">Pending</option>
            <option value="MODIFIED">Modified</option>
          </select>
        </div>
      </Card>

      {/* Filing-blocker banner: credits classified as expenses would be rejected by HMRC. */}
      {flaggedOnPage.length > 0 && (
        <div className="rounded-xl border border-red-200 bg-red-50 p-3 flex items-start gap-2">
          <AlertTriangle className="w-4 h-4 text-red-500 mt-0.5 shrink-0" />
          <div className="text-sm">
            <p className="font-medium text-red-800">
              {flaggedOnPage.length} credit{flaggedOnPage.length > 1 ? 's' : ''} on this page{' '}
              {flaggedOnPage.length > 1 ? 'are' : 'is'} classified as an expense.
            </p>
            <p className="text-xs text-red-700 mt-0.5">
              Money coming in can&apos;t be a business expense — HMRC rejects the resulting negative value.
              Use the <strong>Fix</strong> action on each flagged row, or the guided{' '}
              <Link href="/dashboard/tax/file" className="underline font-medium">
                File your tax
              </Link>{' '}
              flow.
            </p>
          </div>
        </div>
      )}

      {/* Table */}
      <Table
        columns={columns}
        data={transactions}
        keyExtractor={(item) => item.uuid}
        isLoading={isLoading}
        sortColumn={sortBy}
        sortDirection={sortOrder.toLowerCase() as 'asc' | 'desc'}
        onSort={handleSort}
        emptyMessage="No transactions found. Upload and extract a bank statement first."
      />

      {totalPages > 1 && (
        <Pagination
          currentPage={page}
          totalPages={totalPages}
          onPageChange={setPage}
          totalItems={total}
          perPage={PER_PAGE}
        />
      )}
    </div>
  );
}

export default function TransactionsPage() {
  return (
    <ProtectedPage module="tax_transactions" title="Tax Transactions">
      <TransactionsContent />
    </ProtectedPage>
  );
}

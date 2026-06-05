'use client';

import React, { useState, useEffect, useCallback, useRef } from 'react';
import {
  Search,
  RefreshCw,
  CheckCircle,
  XCircle,
  TrendingUp,
  TrendingDown,
} from 'lucide-react';
import { Input, Table, Card, Pagination, SearchableSelect } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import {
  taxService,
  type TaxTransaction,
  type TaxTransactionFilters,
  type TaxTransactionSummary,
  type TaxCategory,
} from '@/services/tax.service';
import { formatDate, formatCurrency } from '@/lib/utils';
import type { TableColumn } from '@/types';
import toast from 'react-hot-toast';

const PER_PAGE = 25;

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
                  value: cat.name,
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

        return (
          <button
            onClick={() => { setEditingTxn(item.uuid); setEditCategory(item.category || ''); }}
            className="text-xs px-2 py-1 rounded hover:bg-secondary-100 text-left max-w-[150px] truncate"
          >
            {item.category || <span className="text-secondary-400 italic">Unclassified</span>}
            {item.confidence_score != null && (
              <span className={`ml-1 text-[10px] ${
                item.confidence_score > 0.8 ? 'text-green-500' : item.confidence_score > 0.5 ? 'text-amber-500' : 'text-red-500'
              }`}>
                ({(item.confidence_score * 100).toFixed(0)}%)
              </span>
            )}
          </button>
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

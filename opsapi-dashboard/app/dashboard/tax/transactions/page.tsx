'use client';

import React, { useState, useEffect, useCallback, useRef, useMemo } from 'react';
import {
  Search,
  ArrowLeftRight,
  Filter,
  RefreshCw,
  CheckCircle,
  XCircle,
  ChevronDown,
  TrendingUp,
  TrendingDown,
  Loader2,
} from 'lucide-react';
import { Input, Table, Card, Pagination } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import {
  taxService,
  type TaxTransaction,
  type TaxTransactionFilters,
  type TaxCategory,
} from '@/services/tax.service';
import { formatDate, formatCurrency } from '@/lib/utils';
import type { TableColumn } from '@/types';
import toast from 'react-hot-toast';

function TransactionsContent() {
  const [transactions, setTransactions] = useState<TaxTransaction[]>([]);
  const [categories, setCategories] = useState<TaxCategory[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [searchQuery, setSearchQuery] = useState('');
  const [typeFilter, setTypeFilter] = useState<string>('all');
  const [verifiedFilter, setVerifiedFilter] = useState<string>('all');
  const [showFilters, setShowFilters] = useState(false);
  const [editingTxn, setEditingTxn] = useState<string | null>(null);
  const [editCategory, setEditCategory] = useState<string>('');
  const perPage = 25;
  const fetchIdRef = useRef(0);

  const fetchTransactions = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);
    try {
      const filters: TaxTransactionFilters = {
        page,
        per_page: perPage,
        search: searchQuery || undefined,
        transaction_type: typeFilter !== 'all' ? typeFilter : undefined,
        is_verified: verifiedFilter !== 'all' ? verifiedFilter === 'true' : undefined,
      };
      const result = await taxService.getTransactions(filters);
      if (fetchId === fetchIdRef.current) {
        setTransactions(result.data);
        setTotal(result.total);
      }
    } catch {
      toast.error('Failed to load transactions');
    } finally {
      if (fetchId === fetchIdRef.current) setIsLoading(false);
    }
  }, [page, searchQuery, typeFilter, verifiedFilter]);

  const fetchCategories = useCallback(async () => {
    try {
      const data = await taxService.getCategories();
      setCategories(data);
    } catch {
      // Categories might not be seeded yet
    }
  }, []);

  useEffect(() => {
    fetchTransactions();
  }, [fetchTransactions]);

  useEffect(() => {
    fetchCategories();
  }, [fetchCategories]);

  const handleVerify = async (txn: TaxTransaction) => {
    try {
      await taxService.updateTransaction(txn.uuid, { is_verified: !txn.is_verified });
      toast.success(txn.is_verified ? 'Unverified' : 'Verified');
      fetchTransactions();
    } catch {
      toast.error('Failed to update transaction');
    }
  };

  const handleCategoryChange = async (txn: TaxTransaction, categoryId: string) => {
    try {
      await taxService.updateTransaction(txn.uuid, { category_id: Number(categoryId) } as Partial<TaxTransaction>);
      toast.success('Category updated');
      setEditingTxn(null);
      fetchTransactions();
    } catch {
      toast.error('Failed to update category');
    }
  };

  const stats = useMemo(() => {
    const income = transactions.filter((t) => t.transaction_type === 'credit').reduce((sum, t) => sum + Math.abs(Number(t.amount)), 0);
    const expenses = transactions.filter((t) => t.transaction_type === 'debit').reduce((sum, t) => sum + Math.abs(Number(t.amount)), 0);
    const verified = transactions.filter((t) => t.is_verified).length;
    return { income, expenses, verified, total: transactions.length };
  }, [transactions]);

  const columns: TableColumn<TaxTransaction>[] = [
    {
      key: 'transaction_date',
      header: 'Date',
      sortable: true,
      width: 'w-28',
      render: (item) => (
        <span className="text-sm">{formatDate(item.transaction_date)}</span>
      ),
    },
    {
      key: 'description',
      header: 'Description',
      render: (item) => (
        <div className="max-w-xs">
          <p className="text-sm font-medium truncate">{item.description}</p>
          {item.notes && <p className="text-xs text-secondary-400 truncate">{item.notes}</p>}
        </div>
      ),
    },
    {
      key: 'amount',
      header: 'Amount',
      sortable: true,
      render: (item) => {
        const isCredit = item.transaction_type === 'credit';
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
      key: 'category_name',
      header: 'Category',
      render: (item) => {
        if (editingTxn === item.uuid) {
          return (
            <select
              value={editCategory}
              onChange={(e) => {
                setEditCategory(e.target.value);
                handleCategoryChange(item, e.target.value);
              }}
              onBlur={() => setEditingTxn(null)}
              autoFocus
              className="text-xs px-2 py-1 border rounded focus:ring-1 focus:ring-primary-500 max-w-[150px]"
            >
              <option value="">Select...</option>
              {categories.map((cat) => (
                <option key={cat.id} value={cat.id}>{cat.name}</option>
              ))}
            </select>
          );
        }

        return (
          <button
            onClick={() => { setEditingTxn(item.uuid); setEditCategory(String(item.category_id || '')); }}
            className="text-xs px-2 py-1 rounded hover:bg-secondary-100 text-left max-w-[150px] truncate"
          >
            {item.category_name || (
              <span className="text-secondary-400 italic">Unclassified</span>
            )}
            {item.confidence != null && (
              <span className={`ml-1 text-[10px] ${
                item.confidence > 0.8 ? 'text-green-500' : item.confidence > 0.5 ? 'text-amber-500' : 'text-red-500'
              }`}>
                ({(item.confidence * 100).toFixed(0)}%)
              </span>
            )}
          </button>
        );
      },
    },
    {
      key: 'is_business',
      header: 'Business',
      width: 'w-20',
      render: (item) => (
        <span className={`text-xs px-2 py-0.5 rounded-full ${
          item.is_business ? 'bg-green-100 text-green-700' : 'bg-secondary-100 text-secondary-500'
        }`}>
          {item.is_business ? 'Yes' : 'No'}
        </span>
      ),
    },
    {
      key: 'is_verified',
      header: 'Verified',
      width: 'w-24',
      render: (item) => (
        <button
          onClick={(e) => { e.stopPropagation(); handleVerify(item); }}
          className={`flex items-center gap-1 text-xs px-2 py-0.5 rounded-full ${
            item.is_verified ? 'bg-green-100 text-green-700 hover:bg-green-200' : 'bg-secondary-100 text-secondary-500 hover:bg-secondary-200'
          }`}
        >
          {item.is_verified ? <CheckCircle className="w-3 h-3" /> : <XCircle className="w-3 h-3" />}
          {item.is_verified ? 'Yes' : 'No'}
        </button>
      ),
    },
  ];

  const totalPages = Math.ceil(total / perPage);

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Transactions</h1>
          <p className="text-sm text-secondary-500 mt-1">
            {total} transactions {stats.verified > 0 && `(${stats.verified} verified)`}
          </p>
        </div>
        <button
          onClick={fetchTransactions}
          className="p-2 text-secondary-600 hover:bg-secondary-100 rounded-lg"
        >
          <RefreshCw className="w-4 h-4" />
        </button>
      </div>

      {/* Stats row */}
      <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
        <div className="bg-white rounded-xl border border-secondary-200 p-4">
          <p className="text-xs text-secondary-500">Page Income</p>
          <p className="text-lg font-bold text-green-600">{formatCurrency(stats.income, 'GBP', 'en-GB')}</p>
        </div>
        <div className="bg-white rounded-xl border border-secondary-200 p-4">
          <p className="text-xs text-secondary-500">Page Expenses</p>
          <p className="text-lg font-bold text-red-600">{formatCurrency(stats.expenses, 'GBP', 'en-GB')}</p>
        </div>
        <div className="bg-white rounded-xl border border-secondary-200 p-4">
          <p className="text-xs text-secondary-500">Verified</p>
          <p className="text-lg font-bold text-secondary-900">{stats.verified} / {stats.total}</p>
        </div>
        <div className="bg-white rounded-xl border border-secondary-200 p-4">
          <p className="text-xs text-secondary-500">Total Records</p>
          <p className="text-lg font-bold text-secondary-900">{total}</p>
        </div>
      </div>

      {/* Filters */}
      <Card padding="md">
        <div className="flex flex-col md:flex-row gap-3">
          <div className="flex-1">
            <Input
              placeholder="Search transactions..."
              value={searchQuery}
              onChange={(e) => { setSearchQuery(e.target.value); setPage(1); }}
              leftIcon={<Search className="w-4 h-4" />}
            />
          </div>
          <select
            value={typeFilter}
            onChange={(e) => { setTypeFilter(e.target.value); setPage(1); }}
            className="px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:ring-2 focus:ring-primary-500"
          >
            <option value="all">All Types</option>
            <option value="credit">Income (Credit)</option>
            <option value="debit">Expense (Debit)</option>
          </select>
          <select
            value={verifiedFilter}
            onChange={(e) => { setVerifiedFilter(e.target.value); setPage(1); }}
            className="px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:ring-2 focus:ring-primary-500"
          >
            <option value="all">All Status</option>
            <option value="true">Verified</option>
            <option value="false">Unverified</option>
          </select>
        </div>
      </Card>

      {/* Table */}
      <Table
        columns={columns}
        data={transactions}
        keyExtractor={(item) => item.uuid || String(item.id)}
        isLoading={isLoading}
        emptyMessage="No transactions found. Upload and extract a bank statement first."
      />

      {totalPages > 1 && (
        <Pagination
          currentPage={page}
          totalPages={totalPages}
          onPageChange={setPage}
          totalItems={total}
          perPage={perPage}
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

'use client';

import React, { useState, useEffect, useCallback, useRef } from 'react';
import Link from 'next/link';
import { ArrowLeft, Plus, RefreshCw, Download, PoundSterling, TrendingUp, FileCheck } from 'lucide-react';
import { cn, formatCurrency, generateId } from '@/lib/utils';
import { SpreadsheetGrid } from '@/components/accounting';
import type { GridColumn, GridRow } from '@/components/accounting';
import accountingService from '@/services/accounting.service';
import type { AccountingAccount } from '@/services/accounting.service';
import toast from 'react-hot-toast';

// ── Constants ─────────────────────────────────────────────────────────────────

const VAT_RATES = [
  { value: '0', label: '0% (Zero rated)' },
  { value: '5', label: '5% (Reduced)' },
  { value: '20', label: '20% (Standard)' },
];

const DEFAULT_ROW_DATA: Record<string, string> = {
  date: new Date().toISOString().split('T')[0],
  description: '',
  customer: '',
  category: '',
  amount: '',
  vatRate: '20',
  vatAmount: '',
  reference: '',
};

// ── Helper: compute VAT from gross amount ─────────────────────────────────────

function computeVat(grossAmount: string, vatRate: string): string {
  const amount = parseFloat(grossAmount);
  const rate = parseFloat(vatRate);
  if (isNaN(amount) || isNaN(rate) || rate === 0) return '0.00';
  const vat = amount * (rate / (100 + rate));
  return vat.toFixed(2);
}

// ── Page Component ────────────────────────────────────────────────────────────

export default function MoneyInPage() {
  // State
  const [rows, setRows] = useState<GridRow[]>([]);
  const [accounts, setAccounts] = useState<AccountingAccount[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [stats, setStats] = useState({ totalReceived: 0, vatCollected: 0, entryCount: 0 });
  const fetchIdRef = useRef(0);

  // Columns definition
  const columns: GridColumn[] = [
    { key: 'date', header: 'Date', width: '130px', type: 'date', required: true },
    { key: 'description', header: 'Description', width: '1fr', type: 'text', required: true, placeholder: 'What was this payment for?' },
    { key: 'customer', header: 'Customer', width: '180px', type: 'text', placeholder: 'Customer name' },
    {
      key: 'category',
      header: 'Category',
      width: '200px',
      type: 'select',
      required: true,
      options: accounts
        .filter((a) => a.account_type === 'revenue' && a.is_active)
        .map((a) => ({ value: String(a.id), label: `${a.code} - ${a.name}` })),
    },
    { key: 'amount', header: 'Amount In', width: '130px', type: 'currency', required: true, placeholder: '0.00' },
    {
      key: 'vatRate',
      header: 'VAT Rate',
      width: '150px',
      type: 'select',
      options: VAT_RATES,
    },
    { key: 'vatAmount', header: 'VAT Amount', width: '120px', type: 'readonly' },
    { key: 'reference', header: 'Reference', width: '140px', type: 'text', placeholder: 'Ref / Invoice #' },
  ];

  // ── Data Fetching ─────────────────────────────────────────────────────────

  const fetchData = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);

    try {
      // Fetch accounts for category dropdown
      const [acctRes, txRes] = await Promise.all([
        accountingService.getAccounts({ perPage: 200 }),
        accountingService.getBankTransactions({
          perPage: 50,
        }),
      ]);

      if (fetchId !== fetchIdRef.current) return;

      const fetchedAccounts = acctRes.data || [];
      setAccounts(fetchedAccounts);

      // Convert existing income transactions to grid rows
      const transactions = txRes.data || [];
      const incomeRows: GridRow[] = transactions
        .filter((tx) => tx.transaction_type === 'credit')
        .map((tx) => ({
          id: tx.uuid,
          isNew: false,
          isDirty: false,
          isSaving: false,
          hasError: false,
          data: {
            date: tx.transaction_date?.split('T')[0] || '',
            description: tx.description || '',
            customer: '',
            category: '',
            amount: String(Math.abs(tx.amount || 0)),
            vatRate: '20',
            vatAmount: computeVat(String(Math.abs(tx.amount || 0)), '20'),
            reference: '',
          },
        }));

      setRows(incomeRows);

      // Compute stats
      const totalReceived = incomeRows.reduce(
        (sum: number, r: GridRow) => sum + (parseFloat(r.data.amount) || 0),
        0
      );
      const vatCollected = incomeRows.reduce(
        (sum: number, r: GridRow) => sum + (parseFloat(r.data.vatAmount) || 0),
        0
      );
      setStats({ totalReceived, vatCollected, entryCount: incomeRows.length });
    } catch {
      toast.error('Failed to load accounting data');
    } finally {
      if (fetchId === fetchIdRef.current) setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  // ── Row Handlers ──────────────────────────────────────────────────────────

  const handleRowChange = useCallback(
    (rowIndex: number, field: string, value: string) => {
      setRows((prev) => {
        const updated = [...prev];
        const row = { ...updated[rowIndex] };
        row.data = { ...row.data, [field]: value };
        row.isDirty = true;

        // Auto-compute VAT when amount or rate changes
        if (field === 'amount' || field === 'vatRate') {
          row.data.vatAmount = computeVat(
            row.data.amount,
            row.data.vatRate
          );
        }

        updated[rowIndex] = row;
        return updated;
      });
    },
    []
  );

  const handleRowCommit = useCallback(
    async (rowIndex: number) => {
      const row = rows[rowIndex];
      if (!row || !row.isDirty) return;

      // Validate required fields
      if (!row.data.date || !row.data.description || !row.data.amount) return;

      setRows((prev) => {
        const updated = [...prev];
        updated[rowIndex] = { ...updated[rowIndex], isSaving: true, hasError: false };
        return updated;
      });

      try {
        const amount = parseFloat(row.data.amount);
        const vatAmount = parseFloat(row.data.vatAmount || '0');

        // Create bank transaction
        const txDescription = [
          row.data.description,
          row.data.customer ? `(${row.data.customer})` : '',
          row.data.reference ? `Ref: ${row.data.reference}` : '',
        ].filter(Boolean).join(' ');

        await accountingService.importBankTransactions({
          transactions: [
            {
              transaction_date: row.data.date,
              description: txDescription,
              amount: amount,
              transaction_type: 'credit',
              category: row.data.category || undefined,
            },
          ],
        });

        // Auto-post journal entry if category selected
        if (row.data.category) {
          const netAmount = amount - vatAmount;
          const lines = [
            { account_id: 1, debit_amount: amount, credit_amount: 0, description: 'Bank receipt' },
            { account_id: parseInt(row.data.category), debit_amount: 0, credit_amount: netAmount, description: row.data.description },
          ];

          // Add VAT line if applicable
          if (vatAmount > 0) {
            lines.push({
              account_id: 2, // VAT output account - would be configurable
              debit_amount: 0,
              credit_amount: vatAmount,
              description: 'VAT on sales',
            });
          }

          await accountingService.createJournalEntry({
            entry_date: row.data.date,
            description: `Sales receipt: ${row.data.description}`,
            reference: row.data.reference || undefined,
            lines,
          });
        }

        setRows((prev) => {
          const updated = [...prev];
          updated[rowIndex] = {
            ...updated[rowIndex],
            isNew: false,
            isDirty: false,
            isSaving: false,
            hasError: false,
          };
          return updated;
        });

        // Update stats
        setStats((prev) => ({
          totalReceived: prev.totalReceived + amount,
          vatCollected: prev.vatCollected + vatAmount,
          entryCount: prev.entryCount + (row.isNew ? 1 : 0),
        }));
      } catch {
        toast.error('Failed to save entry');
        setRows((prev) => {
          const updated = [...prev];
          updated[rowIndex] = { ...updated[rowIndex], isSaving: false, hasError: true };
          return updated;
        });
      }
    },
    [rows]
  );

  const handleAddRow = useCallback(() => {
    setRows((prev) => [
      ...prev,
      {
        id: generateId(),
        isNew: true,
        isDirty: false,
        isSaving: false,
        hasError: false,
        data: { ...DEFAULT_ROW_DATA },
      },
    ]);
  }, []);

  const handleDeleteRow = useCallback(
    (rowIndex: number) => {
      setRows((prev) => prev.filter((_, i) => i !== rowIndex));
    },
    []
  );

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
            <h1 className="text-2xl font-bold text-secondary-900">Money In</h1>
            <p className="text-sm text-secondary-500 mt-0.5">
              Record sales, receipts and income - spreadsheet style
            </p>
          </div>
        </div>
        <div className="flex items-center gap-2">
          <button
            onClick={handleAddRow}
            className="inline-flex items-center gap-2 px-4 py-2.5 bg-primary-500 text-white rounded-lg hover:bg-primary-600 transition-colors text-sm font-medium shadow-sm"
          >
            <Plus className="w-4 h-4" />
            Add Row
          </button>
          <button
            onClick={fetchData}
            className="p-2.5 text-secondary-500 hover:text-secondary-700 hover:bg-secondary-100 rounded-lg transition-colors"
            aria-label="Refresh data"
          >
            <RefreshCw className={cn('w-5 h-5', isLoading && 'animate-spin')} />
          </button>
        </div>
      </div>

      {/* Stats Cards */}
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
        <div className="bg-surface rounded-xl border border-secondary-200 p-4 sm:p-5">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-xs sm:text-sm font-medium text-secondary-500">Total Received</p>
              <p className="text-lg sm:text-2xl font-bold text-secondary-900 mt-1 tabular-nums">
                {formatCurrency(stats.totalReceived, 'GBP', 'en-GB')}
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
              <p className="text-xs sm:text-sm font-medium text-secondary-500">VAT Collected</p>
              <p className="text-lg sm:text-2xl font-bold text-secondary-900 mt-1 tabular-nums">
                {formatCurrency(stats.vatCollected, 'GBP', 'en-GB')}
              </p>
            </div>
            <div className="w-10 h-10 sm:w-12 sm:h-12 bg-info-500 rounded-lg sm:rounded-xl flex items-center justify-center text-white shadow-lg shadow-info-500/25">
              <TrendingUp className="w-5 h-5 sm:w-6 sm:h-6" />
            </div>
          </div>
        </div>

        <div className="bg-surface rounded-xl border border-secondary-200 p-4 sm:p-5">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-xs sm:text-sm font-medium text-secondary-500">Entries</p>
              <p className="text-lg sm:text-2xl font-bold text-secondary-900 mt-1 tabular-nums">
                {stats.entryCount}
              </p>
            </div>
            <div className="w-10 h-10 sm:w-12 sm:h-12 bg-success-500 rounded-lg sm:rounded-xl flex items-center justify-center text-white shadow-lg shadow-success-500/25">
              <FileCheck className="w-5 h-5 sm:w-6 sm:h-6" />
            </div>
          </div>
        </div>
      </div>

      {/* Spreadsheet Grid */}
      <SpreadsheetGrid
        columns={columns}
        rows={rows}
        onRowChange={handleRowChange}
        onRowCommit={handleRowCommit}
        onRowDelete={handleDeleteRow}
        onAddRow={handleAddRow}
        isLoading={isLoading}
      />

      {/* Help text */}
      <div className="bg-secondary-50 rounded-xl border border-secondary-200 p-4">
        <h3 className="text-sm font-semibold text-secondary-700 mb-2">Quick Tips</h3>
        <ul className="text-xs text-secondary-500 space-y-1">
          <li><kbd className="px-1.5 py-0.5 bg-surface border border-secondary-200 rounded text-xs font-mono">Tab</kbd> Move to next cell</li>
          <li><kbd className="px-1.5 py-0.5 bg-surface border border-secondary-200 rounded text-xs font-mono">Enter</kbd> Save row and move down</li>
          <li><kbd className="px-1.5 py-0.5 bg-surface border border-secondary-200 rounded text-xs font-mono">Esc</kbd> Deselect current cell</li>
          <li>VAT is automatically calculated based on the amount and selected VAT rate</li>
          <li>Entries are auto-saved when you move to the next row</li>
        </ul>
      </div>
    </div>
  );
}

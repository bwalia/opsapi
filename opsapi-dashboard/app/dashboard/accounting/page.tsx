'use client';

import React, { useState, useEffect, useCallback, useRef, useMemo } from 'react';
import {
  Search,
  RefreshCw,
  Plus,
  Upload,
  FileText,
  PoundSterling,
  Receipt,
  TrendingUp,
  TrendingDown,
  CheckCircle,
  XCircle,
  Clock,
  AlertCircle,
  ChevronDown,
  ChevronRight,
  Send,
  Sparkles,
  ArrowUpRight,
  ArrowDownRight,
  Eye,
  Check,
  X,
  Calendar,
  Filter,
  MessageSquare,
  BarChart3,
  Landmark,
  BookOpen,
  CreditCard,
  Wallet,
} from 'lucide-react';
import { Input, Card, Modal, Pagination } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import {
  accountingService,
  type DashboardStats,
  type BankTransaction,
  type Expense,
  type AccountingAccount,
  type TrialBalance,
  type BalanceSheet,
  type ProfitAndLoss,
  type VatReturn,
  type AiQueryResponse,
  type AiStatusResponse,
} from '@/services/accounting.service';
import { formatDate } from '@/lib/utils';
import toast from 'react-hot-toast';

// ── Currency Formatter (GBP) ─────────────────────────────────────────────────

function formatGBP(amount: number | undefined | null): string {
  if (amount === undefined || amount === null || isNaN(amount)) return '\u00a30.00';
  return new Intl.NumberFormat('en-GB', { style: 'currency', currency: 'GBP' }).format(amount);
}

// ── Tab Types ────────────────────────────────────────────────────────────────

type MainTab = 'dashboard' | 'transactions' | 'expenses' | 'reports' | 'accounts';
type ReportSubTab = 'trial-balance' | 'balance-sheet' | 'pnl' | 'vat-returns';

// ── Stat Card ────────────────────────────────────────────────────────────────

interface StatCardProps {
  title: string;
  value: string;
  icon: React.ReactNode;
  color: 'green' | 'red' | 'amber' | 'blue';
  subtitle?: string;
}

const StatCard: React.FC<StatCardProps> = ({ title, value, icon, color, subtitle }) => {
  const colors = {
    green: 'bg-green-50 text-green-600 border-green-100',
    red: 'bg-red-50 text-red-600 border-red-100',
    amber: 'bg-amber-50 text-amber-600 border-amber-100',
    blue: 'bg-blue-50 text-blue-600 border-blue-100',
  };
  const iconBg = {
    green: 'bg-green-100 text-green-600',
    red: 'bg-red-100 text-red-600',
    amber: 'bg-amber-100 text-amber-600',
    blue: 'bg-blue-100 text-blue-600',
  };

  return (
    <div className={`rounded-xl border p-5 shadow-sm bg-white ${colors[color].split(' ').slice(2).join(' ')}`}>
      <div className="flex items-center justify-between">
        <div>
          <p className="text-sm font-medium text-secondary-500">{title}</p>
          <p className="text-2xl font-bold text-secondary-900 mt-1">{value}</p>
          {subtitle && <p className="text-xs text-secondary-400 mt-1">{subtitle}</p>}
        </div>
        <div className={`w-12 h-12 rounded-xl flex items-center justify-center ${iconBg[color]}`}>
          {icon}
        </div>
      </div>
    </div>
  );
};

// ── Status Badge ─────────────────────────────────────────────────────────────

const StatusBadge: React.FC<{ status: string }> = ({ status }) => {
  const styles: Record<string, string> = {
    pending: 'bg-amber-100 text-amber-700',
    approved: 'bg-green-100 text-green-700',
    rejected: 'bg-red-100 text-red-700',
    posted: 'bg-blue-100 text-blue-700',
    draft: 'bg-secondary-100 text-secondary-700',
    submitted: 'bg-purple-100 text-purple-700',
    void: 'bg-secondary-100 text-secondary-500',
    calculated: 'bg-amber-100 text-amber-700',
  };
  return (
    <span className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium capitalize ${styles[status] || 'bg-secondary-100 text-secondary-600'}`}>
      {status}
    </span>
  );
};

// ── Account Type Badge ───────────────────────────────────────────────────────

const AccountTypeBadge: React.FC<{ type: string }> = ({ type }) => {
  const styles: Record<string, string> = {
    asset: 'bg-blue-100 text-blue-700',
    liability: 'bg-red-100 text-red-700',
    equity: 'bg-purple-100 text-purple-700',
    revenue: 'bg-green-100 text-green-700',
    expense: 'bg-orange-100 text-orange-700',
  };
  return (
    <span className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium capitalize ${styles[type] || 'bg-secondary-100 text-secondary-600'}`}>
      {type}
    </span>
  );
};

// ── Loading Skeleton ─────────────────────────────────────────────────────────

const Skeleton: React.FC<{ className?: string }> = ({ className = '' }) => (
  <div className={`animate-pulse bg-secondary-200 rounded ${className}`} />
);

const TableSkeleton: React.FC<{ rows?: number; cols?: number }> = ({ rows = 5, cols = 5 }) => (
  <div className="space-y-3 p-4">
    {Array.from({ length: rows }).map((_, i) => (
      <div key={i} className="flex gap-4">
        {Array.from({ length: cols }).map((_, j) => (
          <Skeleton key={j} className="h-4 flex-1" />
        ))}
      </div>
    ))}
  </div>
);

// ── Empty State ──────────────────────────────────────────────────────────────

const EmptyState: React.FC<{ icon: React.ReactNode; title: string; message: string; action?: React.ReactNode }> = ({ icon, title, message, action }) => (
  <div className="flex flex-col items-center justify-center py-16 text-center">
    <div className="w-16 h-16 bg-secondary-100 rounded-2xl flex items-center justify-center mb-4 text-secondary-400">
      {icon}
    </div>
    <h3 className="text-lg font-semibold text-secondary-900 mb-1">{title}</h3>
    <p className="text-sm text-secondary-500 max-w-sm mb-4">{message}</p>
    {action}
  </div>
);

// ══════════════════════════════════════════════════════════════════════════════
// MAIN COMPONENT
// ══════════════════════════════════════════════════════════════════════════════

function AccountingPageContent() {
  // ── State ────────────────────────────────────────────────────────────────

  const [activeTab, setActiveTab] = useState<MainTab>('dashboard');
  const [reportSubTab, setReportSubTab] = useState<ReportSubTab>('trial-balance');

  // Dashboard
  const [stats, setStats] = useState<DashboardStats | null>(null);
  const [recentTransactions, setRecentTransactions] = useState<BankTransaction[]>([]);
  const [statsLoading, setStatsLoading] = useState(true);

  // Bank Transactions
  const [transactions, setTransactions] = useState<BankTransaction[]>([]);
  const [txLoading, setTxLoading] = useState(false);
  const [txPage, setTxPage] = useState(1);
  const [txTotal, setTxTotal] = useState(0);
  const [txTotalPages, setTxTotalPages] = useState(0);
  const [txSearch, setTxSearch] = useState('');
  const [txReconciledFilter, setTxReconciledFilter] = useState<string>('all');
  const [importModalOpen, setImportModalOpen] = useState(false);
  const [csvContent, setCsvContent] = useState('');
  const [importing, setImporting] = useState(false);
  const [reconcileModalOpen, setReconcileModalOpen] = useState(false);
  const [reconcileTarget, setReconcileTarget] = useState<BankTransaction | null>(null);
  const [reconcileAccountId, setReconcileAccountId] = useState<number | null>(null);

  // Expenses
  const [expenses, setExpenses] = useState<Expense[]>([]);
  const [expLoading, setExpLoading] = useState(false);
  const [expPage, setExpPage] = useState(1);
  const [expTotal, setExpTotal] = useState(0);
  const [expTotalPages, setExpTotalPages] = useState(0);
  const [expSearch, setExpSearch] = useState('');
  const [expStatusFilter, setExpStatusFilter] = useState<string>('all');
  const [expenseModalOpen, setExpenseModalOpen] = useState(false);
  const [expenseForm, setExpenseForm] = useState({
    expense_date: new Date().toISOString().slice(0, 10),
    description: '',
    amount: '',
    category: '',
    vendor: '',
    vat_rate: '20',
  });
  const [expenseSubmitting, setExpenseSubmitting] = useState(false);
  const [aiCategorizing, setAiCategorizing] = useState(false);

  // Accounts
  const [accounts, setAccounts] = useState<AccountingAccount[]>([]);
  const [acctLoading, setAcctLoading] = useState(false);
  const [accountModalOpen, setAccountModalOpen] = useState(false);
  const [accountForm, setAccountForm] = useState({
    code: '',
    name: '',
    account_type: 'expense' as AccountingAccount['account_type'],
    description: '',
    parent_id: '',
  });
  const [accountSubmitting, setAccountSubmitting] = useState(false);

  // Reports
  const [trialBalance, setTrialBalance] = useState<TrialBalance | null>(null);
  const [balanceSheet, setBalanceSheet] = useState<BalanceSheet | null>(null);
  const [profitAndLoss, setProfitAndLoss] = useState<ProfitAndLoss | null>(null);
  const [vatReturns, setVatReturns] = useState<VatReturn[]>([]);
  const [reportLoading, setReportLoading] = useState(false);
  const [reportDateFrom, setReportDateFrom] = useState('');
  const [reportDateTo, setReportDateTo] = useState('');
  const [vatModalOpen, setVatModalOpen] = useState(false);
  const [vatPeriodStart, setVatPeriodStart] = useState('');
  const [vatPeriodEnd, setVatPeriodEnd] = useState('');
  const [vatSubmitting, setVatSubmitting] = useState(false);

  // Journal Entry
  const [journalModalOpen, setJournalModalOpen] = useState(false);
  const [journalForm, setJournalForm] = useState({
    entry_date: new Date().toISOString().slice(0, 10),
    description: '',
    reference: '',
  });
  const [journalLines, setJournalLines] = useState<Array<{ account_id: string; debit_amount: string; credit_amount: string; description: string }>>([
    { account_id: '', debit_amount: '', credit_amount: '', description: '' },
    { account_id: '', debit_amount: '', credit_amount: '', description: '' },
  ]);
  const [journalSubmitting, setJournalSubmitting] = useState(false);

  // AI Assistant
  const [aiQuery, setAiQuery] = useState('');
  const [aiResponse, setAiResponse] = useState<AiQueryResponse | null>(null);
  const [aiLoading, setAiLoading] = useState(false);
  const [aiStatus, setAiStatus] = useState<AiStatusResponse | null>(null);

  // Refs
  const fetchIdRef = useRef(0);
  const searchTimeoutRef = useRef<NodeJS.Timeout | null>(null);
  const perPage = 10;

  // ── Data Fetching ────────────────────────────────────────────────────────

  const fetchDashboardData = useCallback(async () => {
    setStatsLoading(true);
    try {
      const [statsData, txData, statusData] = await Promise.all([
        accountingService.getDashboardStats(),
        accountingService.getBankTransactions({ perPage: 10 }),
        accountingService.aiStatus().catch(() => ({ available: false })),
      ]);
      setStats(statsData);
      setRecentTransactions(txData.data);
      setAiStatus(statusData);
    } catch (error) {
      console.error('Failed to load dashboard:', error);
      toast.error('Failed to load dashboard data');
    } finally {
      setStatsLoading(false);
    }
  }, []);

  const fetchTransactions = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setTxLoading(true);
    try {
      const filters: Record<string, unknown> = { page: txPage, perPage };
      if (txSearch.trim()) filters.search = txSearch.trim();
      if (txReconciledFilter === 'yes') filters.is_reconciled = true;
      if (txReconciledFilter === 'no') filters.is_reconciled = false;

      const response = await accountingService.getBankTransactions(filters);
      if (fetchId === fetchIdRef.current) {
        setTransactions(response.data);
        setTxTotal(response.total);
        setTxTotalPages(response.total_pages);
      }
    } catch (error) {
      if (fetchId === fetchIdRef.current) {
        console.error('Failed to fetch transactions:', error);
        toast.error('Failed to load bank transactions');
      }
    } finally {
      if (fetchId === fetchIdRef.current) setTxLoading(false);
    }
  }, [txPage, txSearch, txReconciledFilter]);

  const fetchExpenses = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setExpLoading(true);
    try {
      const filters: Record<string, unknown> = { page: expPage, perPage };
      if (expSearch.trim()) filters.search = expSearch.trim();
      if (expStatusFilter !== 'all') filters.status = expStatusFilter;

      const response = await accountingService.getExpenses(filters);
      if (fetchId === fetchIdRef.current) {
        setExpenses(response.data);
        setExpTotal(response.total);
        setExpTotalPages(response.total_pages);
      }
    } catch (error) {
      if (fetchId === fetchIdRef.current) {
        console.error('Failed to fetch expenses:', error);
        toast.error('Failed to load expenses');
      }
    } finally {
      if (fetchId === fetchIdRef.current) setExpLoading(false);
    }
  }, [expPage, expSearch, expStatusFilter]);

  const fetchAccounts = useCallback(async () => {
    setAcctLoading(true);
    try {
      const response = await accountingService.getAccounts({ perPage: 200 });
      setAccounts(response.data);
    } catch (error) {
      console.error('Failed to fetch accounts:', error);
      toast.error('Failed to load chart of accounts');
    } finally {
      setAcctLoading(false);
    }
  }, []);

  const fetchReport = useCallback(async (sub: ReportSubTab) => {
    setReportLoading(true);
    try {
      const dateParams = reportDateFrom || reportDateTo
        ? { date_from: reportDateFrom || undefined, date_to: reportDateTo || undefined }
        : undefined;

      switch (sub) {
        case 'trial-balance':
          setTrialBalance(await accountingService.getTrialBalance(dateParams));
          break;
        case 'balance-sheet':
          setBalanceSheet(await accountingService.getBalanceSheet(reportDateTo ? { as_of_date: reportDateTo } : undefined));
          break;
        case 'pnl':
          setProfitAndLoss(await accountingService.getProfitAndLoss(dateParams));
          break;
        case 'vat-returns':
          setVatReturns(await accountingService.getVatReturns());
          break;
      }
    } catch (error) {
      console.error('Failed to load report:', error);
      toast.error('Failed to load report');
    } finally {
      setReportLoading(false);
    }
  }, [reportDateFrom, reportDateTo]);

  // ── Effects ──────────────────────────────────────────────────────────────

  useEffect(() => {
    fetchDashboardData();
  }, [fetchDashboardData]);

  useEffect(() => {
    if (activeTab === 'transactions') fetchTransactions();
  }, [activeTab, fetchTransactions]);

  useEffect(() => {
    if (activeTab === 'expenses') fetchExpenses();
  }, [activeTab, fetchExpenses]);

  useEffect(() => {
    if (activeTab === 'accounts') fetchAccounts();
  }, [activeTab, fetchAccounts]);

  useEffect(() => {
    if (activeTab === 'reports') fetchReport(reportSubTab);
  }, [activeTab, reportSubTab, fetchReport]);

  // ── Handlers ─────────────────────────────────────────────────────────────

  const handleTxSearch = useCallback((value: string) => {
    setTxSearch(value);
    if (searchTimeoutRef.current) clearTimeout(searchTimeoutRef.current);
    searchTimeoutRef.current = setTimeout(() => setTxPage(1), 300);
  }, []);

  const handleExpSearch = useCallback((value: string) => {
    setExpSearch(value);
    if (searchTimeoutRef.current) clearTimeout(searchTimeoutRef.current);
    searchTimeoutRef.current = setTimeout(() => setExpPage(1), 300);
  }, []);

  const handleImportCSV = useCallback(async () => {
    if (!csvContent.trim()) { toast.error('Please paste CSV content'); return; }
    setImporting(true);
    try {
      const result = await accountingService.importBankTransactions({ csv_content: csvContent });
      toast.success(result.message || `Imported ${result.imported} transactions`);
      setCsvContent('');
      setImportModalOpen(false);
      fetchTransactions();
      fetchDashboardData();
    } catch (error) {
      console.error('Import failed:', error);
      toast.error('Failed to import bank statement');
    } finally {
      setImporting(false);
    }
  }, [csvContent, fetchTransactions, fetchDashboardData]);

  const handleReconcile = useCallback(async () => {
    if (!reconcileTarget || !reconcileAccountId) { toast.error('Please select an account'); return; }
    try {
      await accountingService.reconcileTransaction(reconcileTarget.uuid, { account_id: reconcileAccountId });
      toast.success('Transaction reconciled');
      setReconcileModalOpen(false);
      setReconcileTarget(null);
      setReconcileAccountId(null);
      fetchTransactions();
      fetchDashboardData();
    } catch (error) {
      console.error('Reconciliation failed:', error);
      toast.error('Failed to reconcile transaction');
    }
  }, [reconcileTarget, reconcileAccountId, fetchTransactions, fetchDashboardData]);

  const handleAiSuggest = useCallback(async (tx: BankTransaction) => {
    try {
      const result = await accountingService.aiCategorize({ description: tx.description, amount: tx.amount });
      toast.success(`AI suggests: ${result.category} (${Math.round(result.confidence * 100)}% confidence)`);
      // Update inline
      setTransactions((prev) =>
        prev.map((t) => t.uuid === tx.uuid ? { ...t, ai_category_suggestion: result.category, ai_confidence: result.confidence } : t)
      );
    } catch (error) {
      console.error('AI categorization failed:', error);
      toast.error('AI categorization unavailable');
    }
  }, []);

  const handleCreateExpense = useCallback(async () => {
    if (!expenseForm.description || !expenseForm.amount) { toast.error('Please fill required fields'); return; }
    setExpenseSubmitting(true);
    try {
      const vatRate = parseFloat(expenseForm.vat_rate) || 0;
      const amount = parseFloat(expenseForm.amount) || 0;
      await accountingService.createExpense({
        expense_date: expenseForm.expense_date,
        description: expenseForm.description,
        amount,
        category: expenseForm.category,
        vendor: expenseForm.vendor,
        vat_rate: vatRate,
        vat_amount: amount * (vatRate / (100 + vatRate)),
        is_vat_reclaimable: vatRate > 0,
      });
      toast.success('Expense created');
      setExpenseModalOpen(false);
      setExpenseForm({ expense_date: new Date().toISOString().slice(0, 10), description: '', amount: '', category: '', vendor: '', vat_rate: '20' });
      fetchExpenses();
      fetchDashboardData();
    } catch (error) {
      console.error('Failed to create expense:', error);
      toast.error('Failed to create expense');
    } finally {
      setExpenseSubmitting(false);
    }
  }, [expenseForm, fetchExpenses, fetchDashboardData]);

  const handleAiCategorizeExpense = useCallback(async () => {
    if (!expenseForm.description) { toast.error('Enter a description first'); return; }
    setAiCategorizing(true);
    try {
      const [catResult, vatResult] = await Promise.all([
        accountingService.aiCategorize({ description: expenseForm.description, amount: parseFloat(expenseForm.amount) || 0 }),
        accountingService.aiSuggestVat({ description: expenseForm.description, amount: parseFloat(expenseForm.amount) || 0 }),
      ]);
      setExpenseForm((prev) => ({
        ...prev,
        category: catResult.category || prev.category,
        vat_rate: String(vatResult.vat_rate ?? prev.vat_rate),
      }));
      toast.success(`AI: ${catResult.category}, VAT ${vatResult.vat_rate}%`);
    } catch {
      toast.error('AI suggestion unavailable');
    } finally {
      setAiCategorizing(false);
    }
  }, [expenseForm.description, expenseForm.amount]);

  const handleApproveExpense = useCallback(async (uuid: string) => {
    try {
      await accountingService.approveExpense(uuid);
      toast.success('Expense approved');
      fetchExpenses();
    } catch { toast.error('Failed to approve expense'); }
  }, [fetchExpenses]);

  const handleRejectExpense = useCallback(async (uuid: string) => {
    try {
      await accountingService.rejectExpense(uuid);
      toast.success('Expense rejected');
      fetchExpenses();
    } catch { toast.error('Failed to reject expense'); }
  }, [fetchExpenses]);

  const handleCreateAccount = useCallback(async () => {
    if (!accountForm.code || !accountForm.name) { toast.error('Please fill required fields'); return; }
    setAccountSubmitting(true);
    try {
      await accountingService.createAccount({
        code: accountForm.code,
        name: accountForm.name,
        account_type: accountForm.account_type,
        description: accountForm.description,
        parent_id: accountForm.parent_id ? parseInt(accountForm.parent_id) : undefined,
      });
      toast.success('Account created');
      setAccountModalOpen(false);
      setAccountForm({ code: '', name: '', account_type: 'expense', description: '', parent_id: '' });
      fetchAccounts();
    } catch (error) {
      console.error('Failed to create account:', error);
      toast.error('Failed to create account');
    } finally {
      setAccountSubmitting(false);
    }
  }, [accountForm, fetchAccounts]);

  const handleCreateJournalEntry = useCallback(async () => {
    if (!journalForm.description) { toast.error('Please add a description'); return; }
    const lines = journalLines
      .filter((l) => l.account_id && (l.debit_amount || l.credit_amount))
      .map((l) => ({
        account_id: parseInt(l.account_id),
        debit_amount: parseFloat(l.debit_amount) || 0,
        credit_amount: parseFloat(l.credit_amount) || 0,
        description: l.description,
      }));
    if (lines.length < 2) { toast.error('At least 2 journal lines required'); return; }
    const totalDebit = lines.reduce((s, l) => s + l.debit_amount, 0);
    const totalCredit = lines.reduce((s, l) => s + l.credit_amount, 0);
    if (Math.abs(totalDebit - totalCredit) > 0.01) { toast.error(`Debits (${formatGBP(totalDebit)}) must equal Credits (${formatGBP(totalCredit)})`); return; }

    setJournalSubmitting(true);
    try {
      await accountingService.createJournalEntry({
        entry_date: journalForm.entry_date,
        description: journalForm.description,
        reference: journalForm.reference || undefined,
        lines,
      });
      toast.success('Journal entry created');
      setJournalModalOpen(false);
      setJournalForm({ entry_date: new Date().toISOString().slice(0, 10), description: '', reference: '' });
      setJournalLines([
        { account_id: '', debit_amount: '', credit_amount: '', description: '' },
        { account_id: '', debit_amount: '', credit_amount: '', description: '' },
      ]);
    } catch (error) {
      console.error('Failed to create journal entry:', error);
      toast.error('Failed to create journal entry');
    } finally {
      setJournalSubmitting(false);
    }
  }, [journalForm, journalLines]);

  const handleCreateVatReturn = useCallback(async () => {
    if (!vatPeriodStart || !vatPeriodEnd) { toast.error('Please select period dates'); return; }
    setVatSubmitting(true);
    try {
      await accountingService.createVatReturn({ period_start: vatPeriodStart, period_end: vatPeriodEnd });
      toast.success('VAT return calculated');
      setVatModalOpen(false);
      setVatPeriodStart('');
      setVatPeriodEnd('');
      fetchReport('vat-returns');
    } catch (error) {
      console.error('Failed to create VAT return:', error);
      toast.error('Failed to calculate VAT return');
    } finally {
      setVatSubmitting(false);
    }
  }, [vatPeriodStart, vatPeriodEnd, fetchReport]);

  const handleSubmitVatReturn = useCallback(async (uuid: string) => {
    try {
      await accountingService.submitVatReturn(uuid);
      toast.success('VAT return submitted');
      fetchReport('vat-returns');
    } catch { toast.error('Failed to submit VAT return'); }
  }, [fetchReport]);

  const handleAiQuery = useCallback(async () => {
    if (!aiQuery.trim()) return;
    setAiLoading(true);
    setAiResponse(null);
    try {
      const result = await accountingService.aiQuery({ query: aiQuery.trim() });
      setAiResponse(result);
    } catch {
      toast.error('AI query failed');
    } finally {
      setAiLoading(false);
    }
  }, [aiQuery]);

  // Computed: expense accounts for dropdowns
  const expenseAccounts = useMemo(
    () => accounts.filter((a) => a.account_type === 'expense' && a.is_active),
    [accounts]
  );

  // ── Tab Navigation ───────────────────────────────────────────────────────

  const tabs: { key: MainTab; label: string; icon: React.ReactNode }[] = [
    { key: 'dashboard', label: 'Overview', icon: <BarChart3 className="w-4 h-4" /> },
    { key: 'transactions', label: 'Bank Transactions', icon: <CreditCard className="w-4 h-4" /> },
    { key: 'expenses', label: 'Expenses', icon: <Receipt className="w-4 h-4" /> },
    { key: 'reports', label: 'Reports', icon: <FileText className="w-4 h-4" /> },
    { key: 'accounts', label: 'Chart of Accounts', icon: <BookOpen className="w-4 h-4" /> },
  ];

  // ══════════════════════════════════════════════════════════════════════════
  // RENDER
  // ══════════════════════════════════════════════════════════════════════════

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Bookkeeping</h1>
          <p className="text-secondary-500 mt-1">Manage your accounts, expenses, and financial reports</p>
        </div>
        <button
          onClick={() => { fetchDashboardData(); if (activeTab === 'transactions') fetchTransactions(); if (activeTab === 'expenses') fetchExpenses(); if (activeTab === 'accounts') fetchAccounts(); if (activeTab === 'reports') fetchReport(reportSubTab); }}
          className="flex items-center gap-2 px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
        >
          <RefreshCw className={`w-4 h-4 ${statsLoading ? 'animate-spin' : ''}`} />
          Refresh
        </button>
      </div>

      {/* Tab Navigation */}
      <div className="border-b border-secondary-200">
        <nav className="flex gap-1 -mb-px overflow-x-auto">
          {tabs.map((tab) => (
            <button
              key={tab.key}
              onClick={() => setActiveTab(tab.key)}
              className={`flex items-center gap-2 px-4 py-3 text-sm font-medium border-b-2 transition-colors whitespace-nowrap ${
                activeTab === tab.key
                  ? 'border-primary-500 text-primary-600'
                  : 'border-transparent text-secondary-500 hover:text-secondary-700 hover:border-secondary-300'
              }`}
            >
              {tab.icon}
              {tab.label}
            </button>
          ))}
        </nav>
      </div>

      {/* ── Dashboard Tab ─────────────────────────────────────────────────── */}
      {activeTab === 'dashboard' && (
        <div className="space-y-6">
          {/* Stat Cards */}
          {statsLoading ? (
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
              {Array.from({ length: 4 }).map((_, i) => (
                <div key={i} className="bg-white rounded-xl border p-5 shadow-sm">
                  <Skeleton className="h-4 w-24 mb-3" />
                  <Skeleton className="h-8 w-32" />
                </div>
              ))}
            </div>
          ) : stats ? (
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
              <StatCard title="Cash Balance" value={formatGBP(stats.cash_balance)} icon={<Wallet className="w-6 h-6" />} color="green" />
              <StatCard title="Expenses This Month" value={formatGBP(stats.expenses_this_month)} icon={<TrendingDown className="w-6 h-6" />} color="red" />
              <StatCard title="VAT Owed" value={formatGBP(stats.vat_owed)} icon={<Landmark className="w-6 h-6" />} color="amber" subtitle="Next filing due" />
              <StatCard title="Unreconciled" value={String(stats.unreconciled_count)} icon={<AlertCircle className="w-6 h-6" />} color="blue" subtitle="transactions to review" />
            </div>
          ) : null}

          {/* Quick Actions */}
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
            {[
              { label: 'Import Bank Statement', icon: <Upload className="w-5 h-5" />, color: 'bg-blue-50 text-blue-600 hover:bg-blue-100', action: () => { setImportModalOpen(true); if (accounts.length === 0) fetchAccounts(); } },
              { label: 'Add Expense', icon: <Receipt className="w-5 h-5" />, color: 'bg-red-50 text-red-600 hover:bg-red-100', action: () => { setExpenseModalOpen(true); if (accounts.length === 0) fetchAccounts(); } },
              { label: 'Create Journal Entry', icon: <BookOpen className="w-5 h-5" />, color: 'bg-purple-50 text-purple-600 hover:bg-purple-100', action: () => { setJournalModalOpen(true); if (accounts.length === 0) fetchAccounts(); } },
              { label: 'Generate VAT Return', icon: <FileText className="w-5 h-5" />, color: 'bg-amber-50 text-amber-600 hover:bg-amber-100', action: () => setVatModalOpen(true) },
            ].map((item) => (
              <button
                key={item.label}
                onClick={item.action}
                className={`flex items-center gap-3 p-4 rounded-xl border border-secondary-200 transition-colors ${item.color}`}
              >
                {item.icon}
                <span className="text-sm font-medium">{item.label}</span>
              </button>
            ))}
          </div>

          {/* Recent Transactions */}
          <Card padding="none">
            <div className="px-5 py-4 border-b border-secondary-200 flex items-center justify-between">
              <h2 className="font-semibold text-secondary-900">Recent Transactions</h2>
              <button onClick={() => setActiveTab('transactions')} className="text-sm text-primary-600 hover:text-primary-700 font-medium">
                View all
              </button>
            </div>
            {statsLoading ? (
              <TableSkeleton rows={5} cols={4} />
            ) : recentTransactions.length === 0 ? (
              <EmptyState icon={<CreditCard className="w-8 h-8" />} title="No transactions yet" message="Import a bank statement to get started." />
            ) : (
              <div className="divide-y divide-secondary-100">
                {recentTransactions.map((tx) => (
                  <div key={tx.uuid} className="flex items-center justify-between px-5 py-3 hover:bg-secondary-50 transition-colors">
                    <div className="flex items-center gap-3">
                      <div className={`w-8 h-8 rounded-lg flex items-center justify-center ${tx.amount >= 0 ? 'bg-green-100 text-green-600' : 'bg-red-100 text-red-600'}`}>
                        {tx.amount >= 0 ? <ArrowUpRight className="w-4 h-4" /> : <ArrowDownRight className="w-4 h-4" />}
                      </div>
                      <div>
                        <p className="text-sm font-medium text-secondary-900">{tx.description}</p>
                        <p className="text-xs text-secondary-500">{formatDate(tx.transaction_date)}</p>
                      </div>
                    </div>
                    <div className="flex items-center gap-3">
                      {tx.is_reconciled && <CheckCircle className="w-4 h-4 text-green-500" />}
                      <span className={`text-sm font-semibold ${tx.amount >= 0 ? 'text-green-600' : 'text-red-600'}`}>
                        {tx.amount >= 0 ? '+' : ''}{formatGBP(tx.amount)}
                      </span>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </Card>

          {/* AI Assistant */}
          <Card padding="md">
            <div className="flex items-center gap-2 mb-4">
              <div className={`w-2 h-2 rounded-full ${aiStatus?.available ? 'bg-green-500' : 'bg-red-500'}`} />
              <h2 className="font-semibold text-secondary-900">Ask AI Assistant</h2>
              <span className="text-xs text-secondary-400">{aiStatus?.available ? 'Connected' : 'Unavailable'}</span>
            </div>

            {/* Example prompts */}
            <div className="flex flex-wrap gap-2 mb-4">
              {['How much did I spend on marketing?', "What's my profit this month?", 'Any unusual transactions?'].map((prompt) => (
                <button
                  key={prompt}
                  onClick={() => setAiQuery(prompt)}
                  className="px-3 py-1.5 text-xs bg-secondary-100 text-secondary-600 rounded-full hover:bg-secondary-200 transition-colors"
                >
                  {prompt}
                </button>
              ))}
            </div>

            <div className="flex gap-2">
              <input
                type="text"
                value={aiQuery}
                onChange={(e) => setAiQuery(e.target.value)}
                onKeyDown={(e) => e.key === 'Enter' && handleAiQuery()}
                placeholder="Ask about your finances..."
                className="flex-1 px-4 py-2.5 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
              />
              <button
                onClick={handleAiQuery}
                disabled={aiLoading || !aiQuery.trim()}
                className="px-4 py-2.5 bg-primary-600 text-white rounded-lg text-sm font-medium hover:bg-primary-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors flex items-center gap-2"
              >
                {aiLoading ? <RefreshCw className="w-4 h-4 animate-spin" /> : <Send className="w-4 h-4" />}
                Ask
              </button>
            </div>

            {aiResponse && (
              <div className="mt-4 p-4 bg-secondary-50 rounded-lg border border-secondary-200">
                <div className="flex items-start gap-2">
                  <Sparkles className="w-4 h-4 text-primary-500 mt-0.5 shrink-0" />
                  <p className="text-sm text-secondary-700 whitespace-pre-wrap">{aiResponse.answer}</p>
                </div>
              </div>
            )}
          </Card>
        </div>
      )}

      {/* ── Bank Transactions Tab ─────────────────────────────────────────── */}
      {activeTab === 'transactions' && (
        <div className="space-y-4">
          {/* Filters */}
          <Card padding="md">
            <div className="flex flex-wrap items-center gap-4">
              <div className="flex-1 min-w-[250px] max-w-md">
                <Input
                  placeholder="Search transactions..."
                  value={txSearch}
                  onChange={(e) => handleTxSearch(e.target.value)}
                  leftIcon={<Search className="w-4 h-4" />}
                />
              </div>
              <div className="relative">
                <select
                  value={txReconciledFilter}
                  onChange={(e) => { setTxReconciledFilter(e.target.value); setTxPage(1); }}
                  className="appearance-none px-4 py-2.5 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white cursor-pointer"
                >
                  <option value="all">All</option>
                  <option value="yes">Reconciled</option>
                  <option value="no">Unreconciled</option>
                </select>
                <ChevronDown className="w-4 h-4 absolute right-3 top-1/2 -translate-y-1/2 text-secondary-400 pointer-events-none" />
              </div>
              <button
                onClick={() => { setImportModalOpen(true); if (accounts.length === 0) fetchAccounts(); }}
                className="flex items-center gap-2 px-4 py-2.5 bg-primary-600 text-white rounded-lg text-sm font-medium hover:bg-primary-700 transition-colors"
              >
                <Upload className="w-4 h-4" />
                Import CSV
              </button>
            </div>
          </Card>

          {/* Table */}
          <Card padding="none">
            {txLoading ? (
              <TableSkeleton rows={8} cols={6} />
            ) : transactions.length === 0 ? (
              <EmptyState
                icon={<CreditCard className="w-8 h-8" />}
                title="No transactions"
                message="Import a bank statement to see your transactions here."
                action={
                  <button onClick={() => setImportModalOpen(true)} className="px-4 py-2 bg-primary-600 text-white rounded-lg text-sm font-medium hover:bg-primary-700 transition-colors">
                    Import Bank Statement
                  </button>
                }
              />
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead className="bg-secondary-50 border-b border-secondary-200">
                    <tr>
                      <th className="text-left px-4 py-3 text-secondary-600 font-medium">Date</th>
                      <th className="text-left px-4 py-3 text-secondary-600 font-medium">Description</th>
                      <th className="text-right px-4 py-3 text-secondary-600 font-medium">Amount</th>
                      <th className="text-left px-4 py-3 text-secondary-600 font-medium">Category</th>
                      <th className="text-center px-4 py-3 text-secondary-600 font-medium">Reconciled</th>
                      <th className="text-right px-4 py-3 text-secondary-600 font-medium">Actions</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-secondary-100">
                    {transactions.map((tx) => (
                      <tr key={tx.uuid} className="hover:bg-secondary-50 transition-colors">
                        <td className="px-4 py-3 text-secondary-700 whitespace-nowrap">{formatDate(tx.transaction_date)}</td>
                        <td className="px-4 py-3">
                          <p className="text-secondary-900 font-medium">{tx.description}</p>
                          {tx.ai_category_suggestion && (
                            <p className="text-xs text-primary-500 mt-0.5">
                              AI: {tx.ai_category_suggestion} ({Math.round((tx.ai_confidence || 0) * 100)}%)
                            </p>
                          )}
                        </td>
                        <td className={`px-4 py-3 text-right font-semibold whitespace-nowrap ${tx.amount >= 0 ? 'text-green-600' : 'text-red-600'}`}>
                          {tx.amount >= 0 ? '+' : ''}{formatGBP(tx.amount)}
                        </td>
                        <td className="px-4 py-3 text-secondary-600">{tx.category || '-'}</td>
                        <td className="px-4 py-3 text-center">
                          {tx.is_reconciled ? (
                            <CheckCircle className="w-5 h-5 text-green-500 inline-block" />
                          ) : (
                            <span className="w-5 h-5 inline-block rounded-full border-2 border-secondary-300" />
                          )}
                        </td>
                        <td className="px-4 py-3 text-right">
                          <div className="flex items-center justify-end gap-1">
                            {!tx.is_reconciled && (
                              <>
                                <button
                                  onClick={() => handleAiSuggest(tx)}
                                  className="px-2 py-1 text-xs font-medium text-primary-600 bg-primary-50 rounded hover:bg-primary-100 transition-colors"
                                  title="AI Suggest Category"
                                >
                                  <Sparkles className="w-3.5 h-3.5 inline-block mr-1" />
                                  AI
                                </button>
                                <button
                                  onClick={() => { setReconcileTarget(tx); setReconcileModalOpen(true); if (accounts.length === 0) fetchAccounts(); }}
                                  className="px-2 py-1 text-xs font-medium text-green-600 bg-green-50 rounded hover:bg-green-100 transition-colors"
                                  title="Reconcile"
                                >
                                  <Check className="w-3.5 h-3.5 inline-block mr-1" />
                                  Reconcile
                                </button>
                              </>
                            )}
                          </div>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </Card>

          <Pagination currentPage={txPage} totalPages={txTotalPages} totalItems={txTotal} perPage={perPage} onPageChange={setTxPage} />
        </div>
      )}

      {/* ── Expenses Tab ──────────────────────────────────────────────────── */}
      {activeTab === 'expenses' && (
        <div className="space-y-4">
          <Card padding="md">
            <div className="flex flex-wrap items-center gap-4">
              <div className="flex-1 min-w-[250px] max-w-md">
                <Input
                  placeholder="Search expenses..."
                  value={expSearch}
                  onChange={(e) => handleExpSearch(e.target.value)}
                  leftIcon={<Search className="w-4 h-4" />}
                />
              </div>
              <div className="relative">
                <select
                  value={expStatusFilter}
                  onChange={(e) => { setExpStatusFilter(e.target.value); setExpPage(1); }}
                  className="appearance-none px-4 py-2.5 pr-10 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white cursor-pointer"
                >
                  <option value="all">All Status</option>
                  <option value="pending">Pending</option>
                  <option value="approved">Approved</option>
                  <option value="rejected">Rejected</option>
                  <option value="posted">Posted</option>
                </select>
                <ChevronDown className="w-4 h-4 absolute right-3 top-1/2 -translate-y-1/2 text-secondary-400 pointer-events-none" />
              </div>
              <button
                onClick={() => { setExpenseModalOpen(true); if (accounts.length === 0) fetchAccounts(); }}
                className="flex items-center gap-2 px-4 py-2.5 bg-primary-600 text-white rounded-lg text-sm font-medium hover:bg-primary-700 transition-colors"
              >
                <Plus className="w-4 h-4" />
                Add Expense
              </button>
            </div>
          </Card>

          <Card padding="none">
            {expLoading ? (
              <TableSkeleton rows={8} cols={7} />
            ) : expenses.length === 0 ? (
              <EmptyState
                icon={<Receipt className="w-8 h-8" />}
                title="No expenses"
                message="Add your first expense to start tracking spending."
                action={
                  <button onClick={() => { setExpenseModalOpen(true); if (accounts.length === 0) fetchAccounts(); }} className="px-4 py-2 bg-primary-600 text-white rounded-lg text-sm font-medium hover:bg-primary-700 transition-colors">
                    Add Expense
                  </button>
                }
              />
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead className="bg-secondary-50 border-b border-secondary-200">
                    <tr>
                      <th className="text-left px-4 py-3 text-secondary-600 font-medium">Date</th>
                      <th className="text-left px-4 py-3 text-secondary-600 font-medium">Description</th>
                      <th className="text-right px-4 py-3 text-secondary-600 font-medium">Amount</th>
                      <th className="text-left px-4 py-3 text-secondary-600 font-medium">Category</th>
                      <th className="text-right px-4 py-3 text-secondary-600 font-medium">VAT</th>
                      <th className="text-center px-4 py-3 text-secondary-600 font-medium">Status</th>
                      <th className="text-right px-4 py-3 text-secondary-600 font-medium">Actions</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-secondary-100">
                    {expenses.map((exp) => (
                      <tr key={exp.uuid} className="hover:bg-secondary-50 transition-colors">
                        <td className="px-4 py-3 text-secondary-700 whitespace-nowrap">{formatDate(exp.expense_date)}</td>
                        <td className="px-4 py-3">
                          <p className="text-secondary-900 font-medium">{exp.description}</p>
                          {exp.vendor && <p className="text-xs text-secondary-500">{exp.vendor}</p>}
                        </td>
                        <td className="px-4 py-3 text-right font-semibold text-red-600 whitespace-nowrap">{formatGBP(exp.amount)}</td>
                        <td className="px-4 py-3 text-secondary-600">{exp.category || '-'}</td>
                        <td className="px-4 py-3 text-right text-secondary-600 whitespace-nowrap">
                          {exp.vat_rate}% ({formatGBP(exp.vat_amount)})
                        </td>
                        <td className="px-4 py-3 text-center"><StatusBadge status={exp.status} /></td>
                        <td className="px-4 py-3 text-right">
                          {exp.status === 'pending' && (
                            <div className="flex items-center justify-end gap-1">
                              <button
                                onClick={() => handleApproveExpense(exp.uuid)}
                                className="p-1.5 text-green-600 hover:bg-green-50 rounded transition-colors"
                                title="Approve"
                              >
                                <Check className="w-4 h-4" />
                              </button>
                              <button
                                onClick={() => handleRejectExpense(exp.uuid)}
                                className="p-1.5 text-red-600 hover:bg-red-50 rounded transition-colors"
                                title="Reject"
                              >
                                <X className="w-4 h-4" />
                              </button>
                            </div>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </Card>

          <Pagination currentPage={expPage} totalPages={expTotalPages} totalItems={expTotal} perPage={perPage} onPageChange={setExpPage} />
        </div>
      )}

      {/* ── Reports Tab ───────────────────────────────────────────────────── */}
      {activeTab === 'reports' && (
        <div className="space-y-4">
          {/* Sub-tabs */}
          <div className="flex items-center gap-1 bg-secondary-100 p-1 rounded-lg w-fit">
            {([
              { key: 'trial-balance', label: 'Trial Balance' },
              { key: 'balance-sheet', label: 'Balance Sheet' },
              { key: 'pnl', label: 'P&L' },
              { key: 'vat-returns', label: 'VAT Returns' },
            ] as { key: ReportSubTab; label: string }[]).map((sub) => (
              <button
                key={sub.key}
                onClick={() => setReportSubTab(sub.key)}
                className={`px-4 py-2 text-sm font-medium rounded-md transition-colors ${
                  reportSubTab === sub.key
                    ? 'bg-white text-secondary-900 shadow-sm'
                    : 'text-secondary-500 hover:text-secondary-700'
                }`}
              >
                {sub.label}
              </button>
            ))}
          </div>

          {/* Date Range Picker (for TB, P&L) */}
          {(reportSubTab === 'trial-balance' || reportSubTab === 'pnl' || reportSubTab === 'balance-sheet') && (
            <div className="flex items-center gap-3">
              <Calendar className="w-4 h-4 text-secondary-400" />
              <input
                type="date"
                value={reportDateFrom}
                onChange={(e) => setReportDateFrom(e.target.value)}
                className="px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white"
              />
              <span className="text-secondary-400">to</span>
              <input
                type="date"
                value={reportDateTo}
                onChange={(e) => setReportDateTo(e.target.value)}
                className="px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white"
              />
              <button
                onClick={() => fetchReport(reportSubTab)}
                className="px-3 py-2 bg-primary-600 text-white rounded-lg text-sm font-medium hover:bg-primary-700 transition-colors"
              >
                Apply
              </button>
            </div>
          )}

          {/* Trial Balance */}
          {reportSubTab === 'trial-balance' && (
            <Card padding="none">
              <div className="px-5 py-4 border-b border-secondary-200">
                <h2 className="font-semibold text-secondary-900">Trial Balance</h2>
              </div>
              {reportLoading ? (
                <TableSkeleton rows={10} cols={5} />
              ) : !trialBalance ? (
                <EmptyState icon={<BarChart3 className="w-8 h-8" />} title="No data" message="Select a date range and click Apply." />
              ) : (
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead className="bg-secondary-50 border-b border-secondary-200">
                      <tr>
                        <th className="text-left px-4 py-3 text-secondary-600 font-medium">Code</th>
                        <th className="text-left px-4 py-3 text-secondary-600 font-medium">Account Name</th>
                        <th className="text-left px-4 py-3 text-secondary-600 font-medium">Type</th>
                        <th className="text-right px-4 py-3 text-secondary-600 font-medium">Debits</th>
                        <th className="text-right px-4 py-3 text-secondary-600 font-medium">Credits</th>
                        <th className="text-right px-4 py-3 text-secondary-600 font-medium">Balance</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-secondary-100">
                      {trialBalance.accounts.map((acct, i) => (
                        <tr key={i} className="hover:bg-secondary-50">
                          <td className="px-4 py-3 text-secondary-600 font-mono text-xs">{acct.code}</td>
                          <td className="px-4 py-3 text-secondary-900 font-medium">{acct.name}</td>
                          <td className="px-4 py-3"><AccountTypeBadge type={acct.account_type} /></td>
                          <td className="px-4 py-3 text-right text-secondary-700">{formatGBP(acct.total_debits)}</td>
                          <td className="px-4 py-3 text-right text-secondary-700">{formatGBP(acct.total_credits)}</td>
                          <td className={`px-4 py-3 text-right font-semibold ${acct.net_balance >= 0 ? 'text-secondary-900' : 'text-red-600'}`}>
                            {formatGBP(acct.net_balance)}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                    <tfoot className="bg-secondary-100 border-t-2 border-secondary-300">
                      <tr>
                        <td className="px-4 py-3 font-bold text-secondary-900" colSpan={3}>Totals</td>
                        <td className="px-4 py-3 text-right font-bold text-secondary-900">{formatGBP(trialBalance.total_debits)}</td>
                        <td className="px-4 py-3 text-right font-bold text-secondary-900">{formatGBP(trialBalance.total_credits)}</td>
                        <td className="px-4 py-3 text-right">
                          <span className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-bold ${trialBalance.is_balanced ? 'bg-green-100 text-green-700' : 'bg-red-100 text-red-700'}`}>
                            {trialBalance.is_balanced ? <CheckCircle className="w-3.5 h-3.5" /> : <XCircle className="w-3.5 h-3.5" />}
                            {trialBalance.is_balanced ? 'Balanced' : 'Unbalanced'}
                          </span>
                        </td>
                      </tr>
                    </tfoot>
                  </table>
                </div>
              )}
            </Card>
          )}

          {/* Balance Sheet */}
          {reportSubTab === 'balance-sheet' && (
            <Card padding="none">
              <div className="px-5 py-4 border-b border-secondary-200">
                <h2 className="font-semibold text-secondary-900">Balance Sheet</h2>
              </div>
              {reportLoading ? (
                <TableSkeleton rows={10} cols={3} />
              ) : !balanceSheet ? (
                <EmptyState icon={<BarChart3 className="w-8 h-8" />} title="No data" message="Select a date and click Apply." />
              ) : (
                <div className="p-5 space-y-6">
                  {/* Assets */}
                  <div>
                    <h3 className="text-sm font-semibold text-blue-700 uppercase tracking-wide mb-2">Assets</h3>
                    <div className="space-y-1">
                      {balanceSheet.assets.map((a, i) => (
                        <div key={i} className="flex justify-between py-1.5 px-3 rounded hover:bg-blue-50">
                          <span className="text-sm text-secondary-700">{a.code} - {a.name}</span>
                          <span className="text-sm font-medium text-secondary-900">{formatGBP(a.balance)}</span>
                        </div>
                      ))}
                      <div className="flex justify-between py-2 px-3 border-t border-blue-200 mt-2">
                        <span className="text-sm font-bold text-blue-700">Total Assets</span>
                        <span className="text-sm font-bold text-blue-700">{formatGBP(balanceSheet.total_assets)}</span>
                      </div>
                    </div>
                  </div>

                  {/* Liabilities */}
                  <div>
                    <h3 className="text-sm font-semibold text-red-700 uppercase tracking-wide mb-2">Liabilities</h3>
                    <div className="space-y-1">
                      {balanceSheet.liabilities.map((a, i) => (
                        <div key={i} className="flex justify-between py-1.5 px-3 rounded hover:bg-red-50">
                          <span className="text-sm text-secondary-700">{a.code} - {a.name}</span>
                          <span className="text-sm font-medium text-secondary-900">{formatGBP(a.balance)}</span>
                        </div>
                      ))}
                      <div className="flex justify-between py-2 px-3 border-t border-red-200 mt-2">
                        <span className="text-sm font-bold text-red-700">Total Liabilities</span>
                        <span className="text-sm font-bold text-red-700">{formatGBP(balanceSheet.total_liabilities)}</span>
                      </div>
                    </div>
                  </div>

                  {/* Equity */}
                  <div>
                    <h3 className="text-sm font-semibold text-purple-700 uppercase tracking-wide mb-2">Equity</h3>
                    <div className="space-y-1">
                      {balanceSheet.equity.map((a, i) => (
                        <div key={i} className="flex justify-between py-1.5 px-3 rounded hover:bg-purple-50">
                          <span className="text-sm text-secondary-700">{a.code} - {a.name}</span>
                          <span className="text-sm font-medium text-secondary-900">{formatGBP(a.balance)}</span>
                        </div>
                      ))}
                      <div className="flex justify-between py-2 px-3 border-t border-purple-200 mt-2">
                        <span className="text-sm font-bold text-purple-700">Total Equity</span>
                        <span className="text-sm font-bold text-purple-700">{formatGBP(balanceSheet.total_equity)}</span>
                      </div>
                    </div>
                  </div>

                  {/* Balance Check */}
                  <div className={`p-4 rounded-lg border ${
                    Math.abs(balanceSheet.total_assets - (balanceSheet.total_liabilities + balanceSheet.total_equity)) < 0.01
                      ? 'bg-green-50 border-green-200'
                      : 'bg-red-50 border-red-200'
                  }`}>
                    <div className="flex justify-between items-center">
                      <span className="text-sm font-bold">Total Assets = Total Liabilities + Equity</span>
                      <span className="text-sm font-bold">
                        {formatGBP(balanceSheet.total_assets)} = {formatGBP(balanceSheet.total_liabilities + balanceSheet.total_equity)}
                      </span>
                    </div>
                  </div>
                </div>
              )}
            </Card>
          )}

          {/* Profit & Loss */}
          {reportSubTab === 'pnl' && (
            <Card padding="none">
              <div className="px-5 py-4 border-b border-secondary-200">
                <h2 className="font-semibold text-secondary-900">Profit & Loss</h2>
              </div>
              {reportLoading ? (
                <TableSkeleton rows={10} cols={3} />
              ) : !profitAndLoss ? (
                <EmptyState icon={<TrendingUp className="w-8 h-8" />} title="No data" message="Select a date range and click Apply." />
              ) : (
                <div className="p-5 space-y-6">
                  {/* Revenue */}
                  <div>
                    <h3 className="text-sm font-semibold text-green-700 uppercase tracking-wide mb-2">Revenue</h3>
                    <div className="space-y-1">
                      {profitAndLoss.revenue.map((r, i) => (
                        <div key={i} className="flex justify-between py-1.5 px-3 rounded hover:bg-green-50">
                          <span className="text-sm text-secondary-700">{r.code} - {r.name}</span>
                          <span className="text-sm font-medium text-green-700">{formatGBP(r.amount)}</span>
                        </div>
                      ))}
                      <div className="flex justify-between py-2 px-3 border-t border-green-200 mt-2">
                        <span className="text-sm font-bold text-green-700">Total Revenue</span>
                        <span className="text-sm font-bold text-green-700">{formatGBP(profitAndLoss.total_revenue)}</span>
                      </div>
                    </div>
                  </div>

                  {/* Expenses */}
                  <div>
                    <h3 className="text-sm font-semibold text-red-700 uppercase tracking-wide mb-2">Expenses</h3>
                    <div className="space-y-1">
                      {profitAndLoss.expenses.map((e, i) => (
                        <div key={i} className="flex justify-between py-1.5 px-3 rounded hover:bg-red-50">
                          <span className="text-sm text-secondary-700">{e.code} - {e.name}</span>
                          <span className="text-sm font-medium text-red-700">{formatGBP(e.amount)}</span>
                        </div>
                      ))}
                      <div className="flex justify-between py-2 px-3 border-t border-red-200 mt-2">
                        <span className="text-sm font-bold text-red-700">Total Expenses</span>
                        <span className="text-sm font-bold text-red-700">{formatGBP(profitAndLoss.total_expenses)}</span>
                      </div>
                    </div>
                  </div>

                  {/* Net Profit */}
                  <div className={`p-4 rounded-lg border ${profitAndLoss.net_profit >= 0 ? 'bg-green-50 border-green-200' : 'bg-red-50 border-red-200'}`}>
                    <div className="flex justify-between items-center">
                      <span className="text-lg font-bold text-secondary-900">Net {profitAndLoss.net_profit >= 0 ? 'Profit' : 'Loss'}</span>
                      <span className={`text-lg font-bold ${profitAndLoss.net_profit >= 0 ? 'text-green-700' : 'text-red-700'}`}>
                        {formatGBP(profitAndLoss.net_profit)}
                      </span>
                    </div>
                  </div>
                </div>
              )}
            </Card>
          )}

          {/* VAT Returns */}
          {reportSubTab === 'vat-returns' && (
            <div className="space-y-4">
              <div className="flex justify-end">
                <button
                  onClick={() => setVatModalOpen(true)}
                  className="flex items-center gap-2 px-4 py-2.5 bg-primary-600 text-white rounded-lg text-sm font-medium hover:bg-primary-700 transition-colors"
                >
                  <Plus className="w-4 h-4" />
                  New VAT Return
                </button>
              </div>
              <Card padding="none">
                {reportLoading ? (
                  <TableSkeleton rows={5} cols={6} />
                ) : vatReturns.length === 0 ? (
                  <EmptyState
                    icon={<FileText className="w-8 h-8" />}
                    title="No VAT returns"
                    message="Create a VAT return to see the summary here."
                    action={
                      <button onClick={() => setVatModalOpen(true)} className="px-4 py-2 bg-primary-600 text-white rounded-lg text-sm font-medium hover:bg-primary-700 transition-colors">
                        New VAT Return
                      </button>
                    }
                  />
                ) : (
                  <div className="overflow-x-auto">
                    <table className="w-full text-sm">
                      <thead className="bg-secondary-50 border-b border-secondary-200">
                        <tr>
                          <th className="text-left px-4 py-3 text-secondary-600 font-medium">Period</th>
                          <th className="text-right px-4 py-3 text-secondary-600 font-medium">VAT Due (Sales)</th>
                          <th className="text-right px-4 py-3 text-secondary-600 font-medium">VAT Reclaimed</th>
                          <th className="text-right px-4 py-3 text-secondary-600 font-medium">Net VAT</th>
                          <th className="text-center px-4 py-3 text-secondary-600 font-medium">Status</th>
                          <th className="text-right px-4 py-3 text-secondary-600 font-medium">Actions</th>
                        </tr>
                      </thead>
                      <tbody className="divide-y divide-secondary-100">
                        {vatReturns.map((vr) => (
                          <tr key={vr.uuid} className="hover:bg-secondary-50">
                            <td className="px-4 py-3 text-secondary-900 font-medium">
                              {formatDate(vr.period_start)} - {formatDate(vr.period_end)}
                            </td>
                            <td className="px-4 py-3 text-right text-secondary-700">{formatGBP(vr.box1_vat_due_sales)}</td>
                            <td className="px-4 py-3 text-right text-green-600">{formatGBP(vr.box4_vat_reclaimed)}</td>
                            <td className={`px-4 py-3 text-right font-semibold ${vr.box5_net_vat >= 0 ? 'text-red-600' : 'text-green-600'}`}>
                              {formatGBP(vr.box5_net_vat)}
                            </td>
                            <td className="px-4 py-3 text-center"><StatusBadge status={vr.status} /></td>
                            <td className="px-4 py-3 text-right">
                              {(vr.status === 'calculated' || vr.status === 'draft') && (
                                <button
                                  onClick={() => handleSubmitVatReturn(vr.uuid)}
                                  className="px-3 py-1 text-xs font-medium text-primary-600 bg-primary-50 rounded hover:bg-primary-100 transition-colors"
                                >
                                  Submit
                                </button>
                              )}
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                )}
              </Card>
            </div>
          )}
        </div>
      )}

      {/* ── Chart of Accounts Tab ─────────────────────────────────────────── */}
      {activeTab === 'accounts' && (
        <div className="space-y-4">
          <div className="flex justify-end">
            <button
              onClick={() => setAccountModalOpen(true)}
              className="flex items-center gap-2 px-4 py-2.5 bg-primary-600 text-white rounded-lg text-sm font-medium hover:bg-primary-700 transition-colors"
            >
              <Plus className="w-4 h-4" />
              Add Account
            </button>
          </div>

          <Card padding="none">
            {acctLoading ? (
              <TableSkeleton rows={15} cols={5} />
            ) : accounts.length === 0 ? (
              <EmptyState
                icon={<BookOpen className="w-8 h-8" />}
                title="No accounts"
                message="Set up your chart of accounts to start bookkeeping."
                action={
                  <button onClick={() => setAccountModalOpen(true)} className="px-4 py-2 bg-primary-600 text-white rounded-lg text-sm font-medium hover:bg-primary-700 transition-colors">
                    Add Account
                  </button>
                }
              />
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead className="bg-secondary-50 border-b border-secondary-200">
                    <tr>
                      <th className="text-left px-4 py-3 text-secondary-600 font-medium">Code</th>
                      <th className="text-left px-4 py-3 text-secondary-600 font-medium">Name</th>
                      <th className="text-left px-4 py-3 text-secondary-600 font-medium">Type</th>
                      <th className="text-right px-4 py-3 text-secondary-600 font-medium">Balance</th>
                      <th className="text-center px-4 py-3 text-secondary-600 font-medium">Status</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-secondary-100">
                    {accounts.map((acct) => (
                      <tr key={acct.uuid} className={`hover:bg-secondary-50 transition-colors ${!acct.is_active ? 'opacity-50' : ''}`}>
                        <td className="px-4 py-3 font-mono text-xs text-secondary-600" style={{ paddingLeft: `${1 + acct.depth * 1.5}rem` }}>
                          {acct.code}
                        </td>
                        <td className="px-4 py-3 text-secondary-900 font-medium">{acct.name}</td>
                        <td className="px-4 py-3"><AccountTypeBadge type={acct.account_type} /></td>
                        <td className="px-4 py-3 text-right font-semibold text-secondary-900">{formatGBP(acct.current_balance)}</td>
                        <td className="px-4 py-3 text-center">
                          {acct.is_active ? (
                            <span className="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-green-100 text-green-700">Active</span>
                          ) : (
                            <span className="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-secondary-100 text-secondary-500">Inactive</span>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </Card>
        </div>
      )}

      {/* ══════════════════════════════════════════════════════════════════════
          MODALS
          ══════════════════════════════════════════════════════════════════════ */}

      {/* Import CSV Modal */}
      <Modal isOpen={importModalOpen} onClose={() => setImportModalOpen(false)} title="Import Bank Statement">
        <div className="space-y-4">
          <p className="text-sm text-secondary-500">Paste your bank statement CSV content below. The system will parse and import the transactions.</p>
          <textarea
            value={csvContent}
            onChange={(e) => setCsvContent(e.target.value)}
            placeholder="Date,Description,Amount,Balance&#10;2024-01-15,Coffee Shop,-3.50,1234.50&#10;..."
            className="w-full h-48 px-3 py-2 border border-secondary-300 rounded-lg text-sm font-mono focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 resize-none"
          />
          <div className="flex justify-end gap-3">
            <button onClick={() => setImportModalOpen(false)} className="px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors">
              Cancel
            </button>
            <button
              onClick={handleImportCSV}
              disabled={importing || !csvContent.trim()}
              className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors flex items-center gap-2"
            >
              {importing && <RefreshCw className="w-4 h-4 animate-spin" />}
              Import
            </button>
          </div>
        </div>
      </Modal>

      {/* Reconcile Modal */}
      <Modal isOpen={reconcileModalOpen} onClose={() => { setReconcileModalOpen(false); setReconcileTarget(null); }} title="Reconcile Transaction">
        <div className="space-y-4">
          {reconcileTarget && (
            <div className="p-3 bg-secondary-50 rounded-lg">
              <p className="text-sm font-medium text-secondary-900">{reconcileTarget.description}</p>
              <p className={`text-sm font-semibold mt-1 ${reconcileTarget.amount >= 0 ? 'text-green-600' : 'text-red-600'}`}>
                {formatGBP(reconcileTarget.amount)}
              </p>
            </div>
          )}
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Target Account</label>
            <select
              value={reconcileAccountId || ''}
              onChange={(e) => setReconcileAccountId(e.target.value ? parseInt(e.target.value) : null)}
              className="w-full px-3 py-2.5 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white"
            >
              <option value="">Select account...</option>
              {accounts.map((a) => (
                <option key={a.id} value={a.id}>{a.code} - {a.name}</option>
              ))}
            </select>
          </div>
          <div className="flex justify-end gap-3">
            <button onClick={() => { setReconcileModalOpen(false); setReconcileTarget(null); }} className="px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors">
              Cancel
            </button>
            <button
              onClick={handleReconcile}
              disabled={!reconcileAccountId}
              className="px-4 py-2 text-sm font-medium text-white bg-green-600 rounded-lg hover:bg-green-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
            >
              Reconcile
            </button>
          </div>
        </div>
      </Modal>

      {/* Add Expense Modal */}
      <Modal isOpen={expenseModalOpen} onClose={() => setExpenseModalOpen(false)} title="Add Expense">
        <div className="space-y-4">
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">Date</label>
              <input
                type="date"
                value={expenseForm.expense_date}
                onChange={(e) => setExpenseForm((f) => ({ ...f, expense_date: e.target.value }))}
                className="w-full px-3 py-2.5 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">Amount</label>
              <input
                type="number"
                step="0.01"
                value={expenseForm.amount}
                onChange={(e) => setExpenseForm((f) => ({ ...f, amount: e.target.value }))}
                placeholder="0.00"
                className="w-full px-3 py-2.5 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
              />
            </div>
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Description</label>
            <input
              type="text"
              value={expenseForm.description}
              onChange={(e) => setExpenseForm((f) => ({ ...f, description: e.target.value }))}
              placeholder="What was this expense for?"
              className="w-full px-3 py-2.5 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
            />
          </div>
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">Category</label>
              <select
                value={expenseForm.category}
                onChange={(e) => setExpenseForm((f) => ({ ...f, category: e.target.value }))}
                className="w-full px-3 py-2.5 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white"
              >
                <option value="">Select category...</option>
                {expenseAccounts.length > 0 ? (
                  expenseAccounts.map((a) => <option key={a.uuid} value={a.name}>{a.code} - {a.name}</option>)
                ) : (
                  <>
                    <option value="Office Supplies">Office Supplies</option>
                    <option value="Travel">Travel</option>
                    <option value="Software">Software</option>
                    <option value="Marketing">Marketing</option>
                    <option value="Professional Services">Professional Services</option>
                    <option value="Utilities">Utilities</option>
                    <option value="Other">Other</option>
                  </>
                )}
              </select>
            </div>
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">VAT Rate</label>
              <select
                value={expenseForm.vat_rate}
                onChange={(e) => setExpenseForm((f) => ({ ...f, vat_rate: e.target.value }))}
                className="w-full px-3 py-2.5 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white"
              >
                <option value="0">0% (Exempt)</option>
                <option value="5">5% (Reduced)</option>
                <option value="20">20% (Standard)</option>
              </select>
            </div>
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Vendor</label>
            <input
              type="text"
              value={expenseForm.vendor}
              onChange={(e) => setExpenseForm((f) => ({ ...f, vendor: e.target.value }))}
              placeholder="Who did you pay?"
              className="w-full px-3 py-2.5 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
            />
          </div>
          <div className="flex justify-between pt-2">
            <button
              onClick={handleAiCategorizeExpense}
              disabled={aiCategorizing || !expenseForm.description}
              className="flex items-center gap-2 px-3 py-2 text-sm font-medium text-primary-600 bg-primary-50 rounded-lg hover:bg-primary-100 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
            >
              {aiCategorizing ? <RefreshCw className="w-4 h-4 animate-spin" /> : <Sparkles className="w-4 h-4" />}
              AI Categorize
            </button>
            <div className="flex gap-3">
              <button onClick={() => setExpenseModalOpen(false)} className="px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors">
                Cancel
              </button>
              <button
                onClick={handleCreateExpense}
                disabled={expenseSubmitting || !expenseForm.description || !expenseForm.amount}
                className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors flex items-center gap-2"
              >
                {expenseSubmitting && <RefreshCw className="w-4 h-4 animate-spin" />}
                Save Expense
              </button>
            </div>
          </div>
        </div>
      </Modal>

      {/* Add Account Modal */}
      <Modal isOpen={accountModalOpen} onClose={() => setAccountModalOpen(false)} title="Add Account">
        <div className="space-y-4">
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">Code</label>
              <input
                type="text"
                value={accountForm.code}
                onChange={(e) => setAccountForm((f) => ({ ...f, code: e.target.value }))}
                placeholder="e.g. 4100"
                className="w-full px-3 py-2.5 border border-secondary-300 rounded-lg text-sm font-mono focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">Type</label>
              <select
                value={accountForm.account_type}
                onChange={(e) => setAccountForm((f) => ({ ...f, account_type: e.target.value as AccountingAccount['account_type'] }))}
                className="w-full px-3 py-2.5 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white"
              >
                <option value="asset">Asset</option>
                <option value="liability">Liability</option>
                <option value="equity">Equity</option>
                <option value="revenue">Revenue</option>
                <option value="expense">Expense</option>
              </select>
            </div>
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Name</label>
            <input
              type="text"
              value={accountForm.name}
              onChange={(e) => setAccountForm((f) => ({ ...f, name: e.target.value }))}
              placeholder="Account name"
              className="w-full px-3 py-2.5 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Parent Account (optional)</label>
            <select
              value={accountForm.parent_id}
              onChange={(e) => setAccountForm((f) => ({ ...f, parent_id: e.target.value }))}
              className="w-full px-3 py-2.5 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white"
            >
              <option value="">None (top level)</option>
              {accounts.filter((a) => a.account_type === accountForm.account_type).map((a) => (
                <option key={a.id} value={a.id}>{a.code} - {a.name}</option>
              ))}
            </select>
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Description</label>
            <input
              type="text"
              value={accountForm.description}
              onChange={(e) => setAccountForm((f) => ({ ...f, description: e.target.value }))}
              placeholder="Optional description"
              className="w-full px-3 py-2.5 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
            />
          </div>
          <div className="flex justify-end gap-3 pt-2">
            <button onClick={() => setAccountModalOpen(false)} className="px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors">
              Cancel
            </button>
            <button
              onClick={handleCreateAccount}
              disabled={accountSubmitting || !accountForm.code || !accountForm.name}
              className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors flex items-center gap-2"
            >
              {accountSubmitting && <RefreshCw className="w-4 h-4 animate-spin" />}
              Create Account
            </button>
          </div>
        </div>
      </Modal>

      {/* Journal Entry Modal */}
      <Modal isOpen={journalModalOpen} onClose={() => setJournalModalOpen(false)} title="Create Journal Entry">
        <div className="space-y-4">
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">Date</label>
              <input
                type="date"
                value={journalForm.entry_date}
                onChange={(e) => setJournalForm((f) => ({ ...f, entry_date: e.target.value }))}
                className="w-full px-3 py-2.5 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">Reference</label>
              <input
                type="text"
                value={journalForm.reference}
                onChange={(e) => setJournalForm((f) => ({ ...f, reference: e.target.value }))}
                placeholder="Optional ref #"
                className="w-full px-3 py-2.5 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
              />
            </div>
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Description</label>
            <input
              type="text"
              value={journalForm.description}
              onChange={(e) => setJournalForm((f) => ({ ...f, description: e.target.value }))}
              placeholder="What is this entry for?"
              className="w-full px-3 py-2.5 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
            />
          </div>

          {/* Journal Lines */}
          <div>
            <div className="flex items-center justify-between mb-2">
              <label className="block text-sm font-medium text-secondary-700">Lines</label>
              <button
                onClick={() => setJournalLines((l) => [...l, { account_id: '', debit_amount: '', credit_amount: '', description: '' }])}
                className="text-xs text-primary-600 hover:text-primary-700 font-medium"
              >
                + Add Line
              </button>
            </div>
            <div className="space-y-2">
              <div className="grid grid-cols-12 gap-2 text-xs font-medium text-secondary-500 px-1">
                <div className="col-span-5">Account</div>
                <div className="col-span-3">Debit</div>
                <div className="col-span-3">Credit</div>
                <div className="col-span-1"></div>
              </div>
              {journalLines.map((line, idx) => (
                <div key={idx} className="grid grid-cols-12 gap-2">
                  <select
                    value={line.account_id}
                    onChange={(e) => {
                      const newLines = [...journalLines];
                      newLines[idx] = { ...newLines[idx], account_id: e.target.value };
                      setJournalLines(newLines);
                    }}
                    className="col-span-5 px-2 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white"
                  >
                    <option value="">Select...</option>
                    {accounts.map((a) => (
                      <option key={a.id} value={a.id}>{a.code} - {a.name}</option>
                    ))}
                  </select>
                  <input
                    type="number"
                    step="0.01"
                    value={line.debit_amount}
                    onChange={(e) => {
                      const newLines = [...journalLines];
                      newLines[idx] = { ...newLines[idx], debit_amount: e.target.value };
                      setJournalLines(newLines);
                    }}
                    placeholder="0.00"
                    className="col-span-3 px-2 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
                  />
                  <input
                    type="number"
                    step="0.01"
                    value={line.credit_amount}
                    onChange={(e) => {
                      const newLines = [...journalLines];
                      newLines[idx] = { ...newLines[idx], credit_amount: e.target.value };
                      setJournalLines(newLines);
                    }}
                    placeholder="0.00"
                    className="col-span-3 px-2 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
                  />
                  <button
                    onClick={() => { if (journalLines.length > 2) setJournalLines((l) => l.filter((_, i) => i !== idx)); }}
                    className="col-span-1 flex items-center justify-center text-secondary-400 hover:text-red-500 transition-colors"
                    disabled={journalLines.length <= 2}
                  >
                    <X className="w-4 h-4" />
                  </button>
                </div>
              ))}
            </div>
            {/* Totals */}
            <div className="grid grid-cols-12 gap-2 mt-2 pt-2 border-t border-secondary-200 text-sm font-semibold">
              <div className="col-span-5 text-right text-secondary-600 pr-2">Totals:</div>
              <div className="col-span-3 text-secondary-900">
                {formatGBP(journalLines.reduce((s, l) => s + (parseFloat(l.debit_amount) || 0), 0))}
              </div>
              <div className="col-span-3 text-secondary-900">
                {formatGBP(journalLines.reduce((s, l) => s + (parseFloat(l.credit_amount) || 0), 0))}
              </div>
              <div className="col-span-1"></div>
            </div>
          </div>

          <div className="flex justify-end gap-3 pt-2">
            <button onClick={() => setJournalModalOpen(false)} className="px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors">
              Cancel
            </button>
            <button
              onClick={handleCreateJournalEntry}
              disabled={journalSubmitting || !journalForm.description}
              className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors flex items-center gap-2"
            >
              {journalSubmitting && <RefreshCw className="w-4 h-4 animate-spin" />}
              Create Entry
            </button>
          </div>
        </div>
      </Modal>

      {/* VAT Return Modal */}
      <Modal isOpen={vatModalOpen} onClose={() => setVatModalOpen(false)} title="New VAT Return">
        <div className="space-y-4">
          <p className="text-sm text-secondary-500">Select the VAT period to calculate the return. The system will automatically compute Boxes 1-9.</p>
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">Period Start</label>
              <input
                type="date"
                value={vatPeriodStart}
                onChange={(e) => setVatPeriodStart(e.target.value)}
                className="w-full px-3 py-2.5 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">Period End</label>
              <input
                type="date"
                value={vatPeriodEnd}
                onChange={(e) => setVatPeriodEnd(e.target.value)}
                className="w-full px-3 py-2.5 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-white"
              />
            </div>
          </div>
          <div className="flex justify-end gap-3 pt-2">
            <button onClick={() => setVatModalOpen(false)} className="px-4 py-2 text-sm font-medium text-secondary-700 bg-white border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors">
              Cancel
            </button>
            <button
              onClick={handleCreateVatReturn}
              disabled={vatSubmitting || !vatPeriodStart || !vatPeriodEnd}
              className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors flex items-center gap-2"
            >
              {vatSubmitting && <RefreshCw className="w-4 h-4 animate-spin" />}
              Calculate VAT Return
            </button>
          </div>
        </div>
      </Modal>
    </div>
  );
}

// ══════════════════════════════════════════════════════════════════════════════
// EXPORT
// ══════════════════════════════════════════════════════════════════════════════

export default function AccountingPage() {
  return (
    <ProtectedPage module="accounting" title="Bookkeeping">
      <AccountingPageContent />
    </ProtectedPage>
  );
}

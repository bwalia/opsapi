'use client';

import React, { useState, useEffect, useCallback, useRef, useMemo } from 'react';
import {
  Upload,
  FileText,
  Trash2,
  Briefcase,
  Play,
  RefreshCw,
  CheckCircle,
  AlertCircle,
  Loader2,
  FileUp,
  Eye,
  Link2,
} from 'lucide-react';
import { Table, Modal, Pagination } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import {
  taxService,
  type TaxStatement,
  type TaxBankAccount,
  type TaxTransaction,
  type TaxCategory,
} from '@/services/tax.service';
import { formatDate, formatCurrency, snakeToTitle } from '@/lib/utils';
import type { TableColumn } from '@/types';
import toast from 'react-hot-toast';

const STATUS_CONFIG: Record<string, { label: string; classes: string; icon: React.ReactNode }> = {
  uploaded: { label: 'Uploaded', classes: 'bg-blue-100 text-blue-700', icon: <FileUp className="w-3 h-3" /> },
  processing: { label: 'Processing', classes: 'bg-amber-100 text-amber-700', icon: <Loader2 className="w-3 h-3 animate-spin" /> },
  extracted: { label: 'Extracted', classes: 'bg-purple-100 text-purple-700', icon: <CheckCircle className="w-3 h-3" /> },
  classified: { label: 'Classified', classes: 'bg-green-100 text-green-700', icon: <CheckCircle className="w-3 h-3" /> },
  error: { label: 'Error', classes: 'bg-red-100 text-red-700', icon: <AlertCircle className="w-3 h-3" /> },
};

// The API returns workflow_step (UPLOADED/EXTRACTED/CLASSIFIED) and
// processing_status (PROCESSING/COMPLETED/ERROR), not a lowercase `status`.
// Derive the UI status the badge + action buttons expect.
function statementStatus(item: TaxStatement): 'uploaded' | 'processing' | 'extracted' | 'classified' | 'error' {
  if (item.status) return item.status;
  const proc = (item.processing_status || '').toUpperCase();
  if (proc === 'PROCESSING') return 'processing';
  if (proc === 'ERROR') return 'error';
  const step = (item.workflow_step || '').toUpperCase();
  if (step === 'CLASSIFIED') return 'classified';
  if (step === 'EXTRACTED') return 'extracted';
  return 'uploaded';
}

// Per-transaction classification status badge for the inline view modal.
const TXN_STATUS: Record<string, { label: string; classes: string }> = {
  CONFIRMED: { label: 'Confirmed', classes: 'bg-green-100 text-green-700' },
  CLASSIFIED: { label: 'Classified', classes: 'bg-blue-100 text-blue-700' },
  NEEDS_REVIEW: { label: 'Needs review', classes: 'bg-amber-100 text-amber-700' },
  PENDING: { label: 'Pending', classes: 'bg-secondary-100 text-secondary-500' },
};
function txnStatusBadge(status?: string) {
  const cfg = TXN_STATUS[(status || 'PENDING').toUpperCase()] || TXN_STATUS.PENDING;
  return <span className={`text-xs px-2 py-0.5 rounded-full ${cfg.classes}`}>{cfg.label}</span>;
}

function StatementsContent() {
  const [statements, setStatements] = useState<TaxStatement[]>([]);
  const [bankAccounts, setBankAccounts] = useState<TaxBankAccount[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const perPage = 20;

  const [showUploadModal, setShowUploadModal] = useState(false);
  const [selectedFile, setSelectedFile] = useState<File | null>(null);
  // Holds the bank account UUID (string). The list endpoint returns `uuid as id`,
  // so the account identifier is a string, and the backend /tax/upload keys on it.
  const [selectedBankAccountId, setSelectedBankAccountId] = useState<string>('');
  const [statementDate, setStatementDate] = useState('');
  const [isUploading, setIsUploading] = useState(false);
  const [processingId, setProcessingId] = useState<number | null>(null);
  const [isDeletingAll, setIsDeletingAll] = useState(false);
  // Business profile that classification runs as (prefilled from the saved default).
  const [profileOptions, setProfileOptions] = useState<
    Array<{ profile_key: string; display_name: string; filing_supported: boolean }>
  >([]);
  const [selectedProfile, setSelectedProfile] = useState<string>('');
  const [savedProfile, setSavedProfile] = useState<string>('');

  const fileInputRef = useRef<HTMLInputElement>(null);
  const fetchIdRef = useRef(0);

  // Inline transactions view — opens automatically after extract/classify and via the
  // per-row eye button, so the user sees results without leaving the statements page.
  const [viewStatement, setViewStatement] = useState<TaxStatement | null>(null);
  const [viewTxns, setViewTxns] = useState<TaxTransaction[]>([]);
  const [viewLoading, setViewLoading] = useState(false);
  const [categories, setCategories] = useState<TaxCategory[]>([]);

  // Transactions store the category key (snake_case); show the human label.
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

  const fetchStatements = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);
    try {
      const result = await taxService.getStatements({ page, per_page: perPage });
      if (fetchId === fetchIdRef.current) {
        setStatements(result.data);
        setTotal(result.total);
      }
    } catch {
      toast.error('Failed to load statements');
    } finally {
      if (fetchId === fetchIdRef.current) setIsLoading(false);
    }
  }, [page]);

  const fetchBankAccounts = useCallback(async () => {
    try {
      const data = await taxService.getBankAccounts();
      setBankAccounts(data);
    } catch {
      // Silently fail - user can still view statements
    }
  }, []);

  const fetchProfiles = useCallback(async () => {
    try {
      const [opts, def] = await Promise.all([
        taxService.getProfileOptions(),
        taxService.getDefaultProfileKey(),
      ]);
      setProfileOptions(opts);
      const initial = def || 'sole_trader';
      setSavedProfile(def || '');
      setSelectedProfile(initial);
    } catch {
      // Non-fatal: fall back to the backend default (sole_trader) at classify time.
    }
  }, []);

  const fetchCategories = useCallback(async () => {
    try {
      setCategories(await taxService.getCategories());
    } catch {
      // Non-fatal: the view modal falls back to title-cased keys.
    }
  }, []);

  useEffect(() => {
    fetchStatements();
    fetchBankAccounts();
    fetchProfiles();
    fetchCategories();
  }, [fetchStatements, fetchBankAccounts, fetchProfiles, fetchCategories]);

  // Open the inline transactions view for a statement and load its rows.
  const openStatementView = useCallback(async (statement: TaxStatement) => {
    setViewStatement(statement);
    setViewTxns([]);
    setViewLoading(true);
    try {
      setViewTxns(await taxService.getStatementTransactions(statement.id));
    } catch {
      toast.error('Failed to load transactions');
    } finally {
      setViewLoading(false);
    }
  }, []);

  const handleSetDefaultProfile = async () => {
    if (!selectedProfile || selectedProfile === savedProfile) return;
    try {
      await taxService.setDefaultProfileKey(selectedProfile);
      setSavedProfile(selectedProfile);
      toast.success('Default business profile saved');
    } catch {
      toast.error('Failed to save default profile');
    }
  };

  const handleFileSelect = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;

    const maxSize = 25 * 1024 * 1024; // 25MB
    if (file.size > maxSize) {
      toast.error('File size exceeds 25MB limit');
      return;
    }

    const allowedTypes = ['application/pdf', 'text/csv', 'image/jpeg', 'image/png', 'image/gif', 'image/webp'];
    if (!allowedTypes.includes(file.type) && !file.name.endsWith('.csv')) {
      toast.error('Unsupported file type. Use PDF, CSV, JPG, PNG, GIF, or WebP.');
      return;
    }

    setSelectedFile(file);
  };

  const handleUpload = async () => {
    if (!selectedFile) {
      toast.error('Please select a file');
      return;
    }
    if (!selectedBankAccountId) {
      toast.error('Please select a bank account');
      return;
    }

    setIsUploading(true);
    try {
      await taxService.uploadStatement(selectedFile, selectedBankAccountId, statementDate || undefined);
      toast.success('Statement uploaded successfully');
      setShowUploadModal(false);
      setSelectedFile(null);
      setSelectedBankAccountId('');
      setStatementDate('');
      if (fileInputRef.current) fileInputRef.current.value = '';
      fetchStatements();
    } catch (err: unknown) {
      const msg = (err as { response?: { data?: { error?: string } } })?.response?.data?.error || 'Upload failed';
      toast.error(msg);
    } finally {
      setIsUploading(false);
    }
  };

  const handleExtract = async (statement: TaxStatement) => {
    setProcessingId(statement.id);
    try {
      const result = await taxService.extractTransactions(statement.id);
      // Report exactly what happened: saved vs skipped duplicates.
      const parts = [`${result.saved} saved`];
      if (result.skipped > 0) parts.push(`${result.skipped} skipped (duplicates)`);
      if (result.failed > 0) parts.push(`${result.failed} failed`);
      const detail = `${result.parsed} transactions read — ${parts.join(', ')}.`;
      if (result.saved > 0) {
        toast.success(detail);
      } else if (result.skipped > 0) {
        toast(`No new transactions — ${result.skipped} already imported.`, { icon: 'ℹ️' });
      } else {
        toast(detail);
      }
      fetchStatements();
      // Surface the freshly extracted rows inline without leaving the page.
      if (result.saved > 0 || result.skipped > 0) openStatementView(statement);
    } catch {
      toast.error('Failed to extract transactions');
    } finally {
      setProcessingId(null);
    }
  };

  // `reclassify` re-runs already-classified rows (AI-set only; user-confirmed rows are
  // preserved server-side) — used by the Re-classify action on classified statements.
  const handleClassify = async (statement: TaxStatement, reclassify = false) => {
    if (reclassify && !confirm('Re-run AI classification for this statement? Transactions you have already confirmed are kept; everything else is re-classified.')) return;
    setProcessingId(statement.id);
    try {
      const result = await taxService.classifyTransactions(statement.id, selectedProfile || undefined, reclassify);
      toast.success(
        `${result.message || 'Classification complete'}${result.profile_type ? ` (as ${result.profile_type})` : ''}`,
      );
      fetchStatements();
      // Show the (re)classified results inline.
      openStatementView(statement);
    } catch {
      toast.error('Failed to classify transactions');
    } finally {
      setProcessingId(null);
    }
  };

  const handleDelete = async (statement: TaxStatement) => {
    if (!confirm('Delete this statement and all its transactions? This cannot be undone.')) return;
    try {
      await taxService.deleteStatement(statement.id);
      toast.success('Statement deleted');
      fetchStatements();
    } catch {
      toast.error('Failed to delete statement');
    }
  };

  // Delete every statement (and, via the backend cascade, their transactions) so the
  // user can start a fresh upload/test. Fetches across pages, then deletes each.
  const handleDeleteAll = async () => {
    if (!confirm('Delete ALL statements and their transactions? This cannot be undone.')) return;
    setIsDeletingAll(true);
    try {
      const all = await taxService.getStatements({ page: 1, per_page: 1000 });
      const list = all.data || [];
      if (list.length === 0) {
        toast.success('No statements to delete');
        return;
      }
      await Promise.all(list.map((s) => taxService.deleteStatement(s.id)));
      toast.success(`Deleted ${list.length} statement${list.length === 1 ? '' : 's'}`);
      setPage(1);
      fetchStatements();
    } catch {
      toast.error('Failed to delete all statements');
    } finally {
      setIsDeletingAll(false);
    }
  };

  const columns: TableColumn<TaxStatement>[] = [
    {
      key: 'file_name',
      header: 'File',
      render: (item) => (
        <div className="flex items-center gap-2">
          <FileText className="w-4 h-4 text-secondary-400" />
          <div>
            <p className="font-medium text-sm">{item.file_name || 'Unknown'}</p>
            {item.file_size && (
              <p className="text-xs text-secondary-400">
                {(item.file_size / 1024).toFixed(1)} KB
              </p>
            )}
          </div>
        </div>
      ),
    },
    {
      key: 'bank_name',
      header: 'Bank',
      render: (item) => item.bank_name || '-',
    },
    {
      key: 'statement_date',
      header: 'Statement Date',
      render: (item) => item.statement_date ? formatDate(item.statement_date) : '-',
    },
    {
      key: 'status',
      header: 'Status',
      render: (item) => {
        const config = STATUS_CONFIG[statementStatus(item)] || STATUS_CONFIG.uploaded;
        return (
          <span className={`inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full text-xs font-medium ${config.classes}`}>
            {config.icon}
            {config.label}
          </span>
        );
      },
    },
    {
      key: 'transaction_count',
      header: 'Transactions',
      render: (item) => item.transaction_count ?? '-',
    },
    {
      key: 'created_at',
      header: 'Uploaded',
      render: (item) => formatDate(item.created_at),
    },
    {
      key: 'actions',
      header: '',
      width: 'w-36',
      render: (item) => (
        <div className="flex items-center gap-1">
          {statementStatus(item) === 'uploaded' && (
            <button
              onClick={(e) => { e.stopPropagation(); handleExtract(item); }}
              disabled={processingId === item.id}
              className="p-1.5 rounded-lg hover:bg-blue-50 text-blue-600 disabled:opacity-50"
              title="Extract transactions"
            >
              {processingId === item.id ? <Loader2 className="w-4 h-4 animate-spin" /> : <Play className="w-4 h-4" />}
            </button>
          )}
          {(statementStatus(item) === 'extracted' || statementStatus(item) === 'classified') && (
            <button
              onClick={(e) => { e.stopPropagation(); openStatementView(item); }}
              className="p-1.5 rounded-lg hover:bg-secondary-100 text-secondary-600"
              title="View transactions"
            >
              <Eye className="w-4 h-4" />
            </button>
          )}
          {statementStatus(item) === 'classified' && (
            <button
              onClick={(e) => { e.stopPropagation(); handleClassify(item, true); }}
              disabled={processingId === item.id}
              className="p-1.5 rounded-lg hover:bg-purple-50 text-purple-600 disabled:opacity-50"
              title="Re-classify transactions"
            >
              {processingId === item.id ? <Loader2 className="w-4 h-4 animate-spin" /> : <RefreshCw className="w-4 h-4" />}
            </button>
          )}
          {statementStatus(item) === 'extracted' && (
            <button
              onClick={(e) => { e.stopPropagation(); handleClassify(item); }}
              disabled={processingId === item.id}
              className="px-2 py-1 text-xs rounded-lg bg-purple-50 text-purple-700 hover:bg-purple-100 disabled:opacity-50"
              title="Classify transactions"
            >
              {processingId === item.id ? 'Processing...' : 'Classify'}
            </button>
          )}
          <button
            onClick={(e) => { e.stopPropagation(); handleDelete(item); }}
            className="p-1.5 rounded-lg hover:bg-red-50 text-secondary-500 hover:text-red-600"
          >
            <Trash2 className="w-4 h-4" />
          </button>
        </div>
      ),
    },
  ];

  const totalPages = Math.ceil(total / perPage);

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold text-secondary-900">Bank Statements</h1>
        <div className="flex items-center gap-2">
          <button
            onClick={fetchStatements}
            className="p-2 text-secondary-600 hover:bg-secondary-100 rounded-lg"
          >
            <RefreshCw className="w-4 h-4" />
          </button>
          <a
            href="/dashboard/tax/settings"
            className="flex items-center gap-2 px-4 py-2 border border-secondary-300 text-secondary-700 rounded-lg hover:bg-secondary-100"
          >
            <Link2 className="w-4 h-4" />
            HMRC
          </a>
          {statements.length > 0 && (
            <button
              onClick={handleDeleteAll}
              disabled={isDeletingAll}
              className="flex items-center gap-2 px-4 py-2 bg-red-600 text-white rounded-lg hover:bg-red-700 disabled:opacity-50"
            >
              <Trash2 className="w-4 h-4" />
              {isDeletingAll ? 'Deleting…' : 'Delete All'}
            </button>
          )}
          <button
            onClick={() => setShowUploadModal(true)}
            className="flex items-center gap-2 px-4 py-2 bg-primary-600 text-white rounded-lg hover:bg-primary-700"
          >
            <Upload className="w-4 h-4" />
            Upload Statement
          </button>
        </div>
      </div>

      {/* Business profile — classification runs as this profile (saved default, overridable per run) */}
      <div className="flex flex-wrap items-center gap-3 bg-secondary-50 border border-secondary-200 rounded-xl p-4">
        <div className="flex items-center gap-2">
          <Briefcase className="w-4 h-4 text-secondary-500" />
          <span className="text-sm font-medium text-secondary-700">Classify as:</span>
        </div>
        <select
          value={selectedProfile}
          onChange={(e) => setSelectedProfile(e.target.value)}
          className="px-3 py-2 border border-secondary-300 rounded-lg text-sm bg-white"
        >
          {profileOptions.length === 0 && <option value="sole_trader">Sole Trader</option>}
          {profileOptions.map((p) => (
            <option key={p.profile_key} value={p.profile_key}>
              {p.display_name}{!p.filing_supported ? ' (triage only)' : ''}
            </option>
          ))}
        </select>
        {selectedProfile && selectedProfile !== savedProfile ? (
          <button
            onClick={handleSetDefaultProfile}
            className="text-sm px-3 py-2 border border-primary-300 text-primary-700 rounded-lg hover:bg-primary-50"
          >
            Set as my default
          </button>
        ) : (
          savedProfile && <span className="text-xs text-secondary-500">Your saved default</span>
        )}
      </div>

      {/* Info banner */}
      {bankAccounts.length === 0 && !isLoading && (
        <div className="bg-amber-50 border border-amber-200 rounded-xl p-4 flex items-start gap-3">
          <AlertCircle className="w-5 h-5 text-amber-600 mt-0.5 shrink-0" />
          <div>
            <p className="font-medium text-amber-800">No bank accounts yet</p>
            <p className="text-sm text-amber-700 mt-1">
              You need to add a bank account before uploading statements.{' '}
              <a href="/dashboard/tax/bank-accounts" className="underline font-medium">Add one now</a>
            </p>
          </div>
        </div>
      )}

      {/* Table */}
      <Table
        columns={columns}
        data={statements}
        keyExtractor={(item) => item.uuid || String(item.id)}
        isLoading={isLoading}
        emptyMessage="No statements uploaded yet. Click 'Upload Statement' to get started."
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

      {/* Upload Modal */}
      {showUploadModal && (
        <Modal
          isOpen={showUploadModal}
          onClose={() => {
            setShowUploadModal(false);
            setSelectedFile(null);
            setSelectedBankAccountId('');
            setStatementDate('');
          }}
          title="Upload Bank Statement"
        >
          <div className="space-y-4">
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">Bank Account *</label>
              <select
                value={selectedBankAccountId}
                onChange={(e) => setSelectedBankAccountId(e.target.value)}
                className="w-full px-3 py-2 border border-secondary-300 rounded-lg focus:ring-2 focus:ring-primary-500 focus:border-primary-500"
              >
                <option value="">Select a bank account...</option>
                {bankAccounts.map((acc) => {
                  // List endpoint returns `uuid as id`, so `id` is the uuid the
                  // backend keys on. Prefer an explicit `uuid` if present.
                  const accountId = acc.uuid ?? acc.id;
                  return (
                    <option key={accountId} value={accountId}>
                      {acc.bank_name} {acc.account_number ? `(****${acc.account_number.slice(-4)})` : ''}
                    </option>
                  );
                })}
              </select>
              {bankAccounts.length === 0 && (
                <p className="text-xs text-amber-600 mt-1">
                  No bank accounts found. <a href="/dashboard/tax/bank-accounts" className="underline">Add one first.</a>
                </p>
              )}
            </div>

            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">Statement Date</label>
              <input
                type="date"
                value={statementDate}
                onChange={(e) => setStatementDate(e.target.value)}
                className="w-full px-3 py-2 border border-secondary-300 rounded-lg focus:ring-2 focus:ring-primary-500 focus:border-primary-500"
              />
            </div>

            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">File *</label>
              <div className="border-2 border-dashed border-secondary-300 rounded-lg p-6 text-center hover:border-primary-400 transition-colors">
                <input
                  ref={fileInputRef}
                  type="file"
                  accept=".pdf,.csv,.jpg,.jpeg,.png,.gif,.webp"
                  onChange={handleFileSelect}
                  className="hidden"
                  id="statement-file"
                />
                <label htmlFor="statement-file" className="cursor-pointer">
                  <Upload className="w-8 h-8 text-secondary-400 mx-auto mb-2" />
                  {selectedFile ? (
                    <div>
                      <p className="font-medium text-secondary-900">{selectedFile.name}</p>
                      <p className="text-xs text-secondary-500">{(selectedFile.size / 1024).toFixed(1)} KB</p>
                    </div>
                  ) : (
                    <div>
                      <p className="text-secondary-600">Click to select a file</p>
                      <p className="text-xs text-secondary-400 mt-1">PDF, CSV, JPG, PNG, GIF, WebP (max 25MB)</p>
                    </div>
                  )}
                </label>
              </div>
            </div>

            <div className="flex justify-end gap-3 pt-2">
              <button
                onClick={() => {
                  setShowUploadModal(false);
                  setSelectedFile(null);
                }}
                className="px-4 py-2 text-secondary-600 hover:bg-secondary-100 rounded-lg"
              >
                Cancel
              </button>
              <button
                onClick={handleUpload}
                disabled={isUploading || !selectedFile || !selectedBankAccountId}
                className="flex items-center gap-2 px-4 py-2 bg-primary-600 text-white rounded-lg hover:bg-primary-700 disabled:opacity-50"
              >
                {isUploading ? (
                  <>
                    <Loader2 className="w-4 h-4 animate-spin" />
                    Uploading...
                  </>
                ) : (
                  <>
                    <Upload className="w-4 h-4" />
                    Upload
                  </>
                )}
              </button>
            </div>
          </div>
        </Modal>
      )}

      {/* Inline transactions view (auto-opens after extract/classify) */}
      {viewStatement && (
        <Modal
          isOpen={!!viewStatement}
          onClose={() => setViewStatement(null)}
          title={`Transactions — ${viewStatement.file_name || 'Statement'}`}
          size="2xl"
        >
          {viewLoading ? (
            <div className="py-12 flex items-center justify-center text-secondary-500">
              <Loader2 className="w-5 h-5 animate-spin mr-2" /> Loading transactions…
            </div>
          ) : viewTxns.length === 0 ? (
            <div className="py-12 text-center text-secondary-500">
              No transactions found for this statement.
            </div>
          ) : (
            <div className="space-y-4">
              {/* Summary chips */}
              <div className="flex flex-wrap gap-2 text-xs">
                <span className="px-2 py-1 rounded-full bg-secondary-100 text-secondary-700">
                  {viewTxns.length} transactions
                </span>
                <span className="px-2 py-1 rounded-full bg-blue-100 text-blue-700">
                  {viewTxns.filter((t) => !!t.category).length} classified
                </span>
                {viewTxns.filter((t) => t.classification_status === 'NEEDS_REVIEW').length > 0 && (
                  <span className="px-2 py-1 rounded-full bg-amber-100 text-amber-700">
                    {viewTxns.filter((t) => t.classification_status === 'NEEDS_REVIEW').length} need review
                  </span>
                )}
              </div>

              <div className="overflow-x-auto border border-secondary-200 rounded-lg">
                <table className="w-full text-sm">
                  <thead className="bg-secondary-50 text-secondary-500 text-xs">
                    <tr>
                      <th className="text-left px-3 py-2 font-medium">Date</th>
                      <th className="text-left px-3 py-2 font-medium">Description</th>
                      <th className="text-right px-3 py-2 font-medium">Amount</th>
                      <th className="text-left px-3 py-2 font-medium">Category</th>
                      <th className="text-center px-3 py-2 font-medium">Deductible</th>
                      <th className="text-left px-3 py-2 font-medium">Status</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-secondary-100">
                    {viewTxns.map((t) => {
                      const isCredit = t.transaction_type === 'CREDIT';
                      return (
                        <tr key={t.uuid} className="hover:bg-secondary-50">
                          <td className="px-3 py-2 whitespace-nowrap text-secondary-600">
                            {formatDate(t.transaction_date)}
                          </td>
                          <td className="px-3 py-2 max-w-[220px] truncate" title={t.description}>
                            {t.description}
                          </td>
                          <td className="px-3 py-2 text-right whitespace-nowrap">
                            <span className={isCredit ? 'text-green-700' : 'text-red-700'}>
                              {isCredit ? '+' : '-'}
                              {formatCurrency(Math.abs(Number(t.amount)), 'GBP', 'en-GB')}
                            </span>
                          </td>
                          <td className="px-3 py-2">
                            {t.category ? (
                              <span>
                                {labelForCategory(t.category)}
                                {t.confidence_score != null && (
                                  <span
                                    className={`ml-1 text-[10px] ${
                                      t.confidence_score > 0.8
                                        ? 'text-green-500'
                                        : t.confidence_score > 0.5
                                          ? 'text-amber-500'
                                          : 'text-red-500'
                                    }`}
                                  >
                                    ({Math.round(t.confidence_score * 100)}%)
                                  </span>
                                )}
                              </span>
                            ) : (
                              <span className="text-secondary-400 italic">Unclassified</span>
                            )}
                          </td>
                          <td className="px-3 py-2 text-center">
                            <span
                              className={`text-xs px-2 py-0.5 rounded-full ${
                                t.is_tax_deductible
                                  ? 'bg-green-100 text-green-700'
                                  : 'bg-secondary-100 text-secondary-500'
                              }`}
                            >
                              {t.is_tax_deductible ? 'Yes' : 'No'}
                            </span>
                          </td>
                          <td className="px-3 py-2">{txnStatusBadge(t.classification_status)}</td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>

              <div className="flex justify-end">
                <a href="/dashboard/tax/transactions" className="text-sm text-primary-600 hover:underline">
                  Open full transactions page →
                </a>
              </div>
            </div>
          )}
        </Modal>
      )}
    </div>
  );
}

export default function StatementsPage() {
  return (
    <ProtectedPage module="tax_statements" title="Tax Statements">
      <StatementsContent />
    </ProtectedPage>
  );
}

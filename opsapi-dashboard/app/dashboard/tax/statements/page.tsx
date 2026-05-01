'use client';

import React, { useState, useEffect, useCallback, useRef } from 'react';
import {
  Search,
  Upload,
  FileText,
  Trash2,
  Play,
  RefreshCw,
  CheckCircle,
  Clock,
  AlertCircle,
  Loader2,
  FileUp,
} from 'lucide-react';
import { Input, Table, Card, Modal, Pagination } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import {
  taxService,
  type TaxStatement,
  type TaxBankAccount,
  type TaxStatementFilters,
} from '@/services/tax.service';
import { formatDate, formatCurrency } from '@/lib/utils';
import type { TableColumn } from '@/types';
import toast from 'react-hot-toast';

const STATUS_CONFIG: Record<string, { label: string; classes: string; icon: React.ReactNode }> = {
  uploaded: { label: 'Uploaded', classes: 'bg-blue-100 text-blue-700', icon: <FileUp className="w-3 h-3" /> },
  processing: { label: 'Processing', classes: 'bg-amber-100 text-amber-700', icon: <Loader2 className="w-3 h-3 animate-spin" /> },
  extracted: { label: 'Extracted', classes: 'bg-purple-100 text-purple-700', icon: <CheckCircle className="w-3 h-3" /> },
  classified: { label: 'Classified', classes: 'bg-green-100 text-green-700', icon: <CheckCircle className="w-3 h-3" /> },
  error: { label: 'Error', classes: 'bg-red-100 text-red-700', icon: <AlertCircle className="w-3 h-3" /> },
};

function StatementsContent() {
  const [statements, setStatements] = useState<TaxStatement[]>([]);
  const [bankAccounts, setBankAccounts] = useState<TaxBankAccount[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const perPage = 20;

  const [showUploadModal, setShowUploadModal] = useState(false);
  const [selectedFile, setSelectedFile] = useState<File | null>(null);
  const [selectedBankAccountId, setSelectedBankAccountId] = useState<number | ''>('');
  const [statementDate, setStatementDate] = useState('');
  const [isUploading, setIsUploading] = useState(false);
  const [processingId, setProcessingId] = useState<number | null>(null);

  const fileInputRef = useRef<HTMLInputElement>(null);
  const fetchIdRef = useRef(0);

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

  useEffect(() => {
    fetchStatements();
    fetchBankAccounts();
  }, [fetchStatements, fetchBankAccounts]);

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
      await taxService.uploadStatement(selectedFile, Number(selectedBankAccountId), statementDate || undefined);
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
      toast.success(result.message || 'Extraction started');
      fetchStatements();
    } catch {
      toast.error('Failed to extract transactions');
    } finally {
      setProcessingId(null);
    }
  };

  const handleClassify = async (statement: TaxStatement) => {
    setProcessingId(statement.id);
    try {
      const result = await taxService.classifyTransactions(statement.id);
      toast.success(result.message || 'Classification started');
      fetchStatements();
    } catch {
      toast.error('Failed to classify transactions');
    } finally {
      setProcessingId(null);
    }
  };

  const handleDelete = async (statement: TaxStatement) => {
    if (!confirm('Delete this statement and all its transactions? This cannot be undone.')) return;
    try {
      await taxService.deleteStatement(statement.uuid);
      toast.success('Statement deleted');
      fetchStatements();
    } catch {
      toast.error('Failed to delete statement');
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
        const config = STATUS_CONFIG[item.status] || STATUS_CONFIG.uploaded;
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
          {item.status === 'uploaded' && (
            <button
              onClick={(e) => { e.stopPropagation(); handleExtract(item); }}
              disabled={processingId === item.id}
              className="p-1.5 rounded-lg hover:bg-blue-50 text-blue-600 disabled:opacity-50"
              title="Extract transactions"
            >
              {processingId === item.id ? <Loader2 className="w-4 h-4 animate-spin" /> : <Play className="w-4 h-4" />}
            </button>
          )}
          {item.status === 'extracted' && (
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
          <button
            onClick={() => setShowUploadModal(true)}
            className="flex items-center gap-2 px-4 py-2 bg-primary-600 text-white rounded-lg hover:bg-primary-700"
          >
            <Upload className="w-4 h-4" />
            Upload Statement
          </button>
        </div>
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
                onChange={(e) => setSelectedBankAccountId(e.target.value ? Number(e.target.value) : '')}
                className="w-full px-3 py-2 border border-secondary-300 rounded-lg focus:ring-2 focus:ring-primary-500 focus:border-primary-500"
              >
                <option value="">Select a bank account...</option>
                {bankAccounts.map((acc) => (
                  <option key={acc.id} value={acc.id}>
                    {acc.bank_name} {acc.account_number ? `(****${acc.account_number.slice(-4)})` : ''}
                  </option>
                ))}
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

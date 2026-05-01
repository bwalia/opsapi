'use client';

import React, { useState, useEffect, useCallback, useRef } from 'react';
import {
  Search,
  Plus,
  Landmark,
  Trash2,
  Edit2,
  RefreshCw,
} from 'lucide-react';
import { Input, Table, Card, Modal } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { taxService, type TaxBankAccount } from '@/services/tax.service';
import { formatDate } from '@/lib/utils';
import type { TableColumn } from '@/types';
import toast from 'react-hot-toast';

function BankAccountsContent() {
  const [accounts, setAccounts] = useState<TaxBankAccount[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState('');
  const [showCreateModal, setShowCreateModal] = useState(false);
  const [editingAccount, setEditingAccount] = useState<TaxBankAccount | null>(null);
  const fetchIdRef = useRef(0);

  // Form state
  const [formData, setFormData] = useState({
    bank_name: '',
    account_number: '',
    sort_code: '',
    account_type: 'current',
    currency: 'GBP',
  });
  const [isSaving, setIsSaving] = useState(false);

  const fetchAccounts = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);
    try {
      const data = await taxService.getBankAccounts();
      if (fetchId === fetchIdRef.current) {
        setAccounts(data);
      }
    } catch {
      toast.error('Failed to load bank accounts');
    } finally {
      if (fetchId === fetchIdRef.current) {
        setIsLoading(false);
      }
    }
  }, []);

  useEffect(() => {
    fetchAccounts();
  }, [fetchAccounts]);

  const filteredAccounts = accounts.filter((a) =>
    !searchQuery ||
    a.bank_name?.toLowerCase().includes(searchQuery.toLowerCase()) ||
    a.account_number?.includes(searchQuery)
  );

  const handleCreate = async () => {
    if (!formData.bank_name.trim()) {
      toast.error('Bank name is required');
      return;
    }
    setIsSaving(true);
    try {
      await taxService.createBankAccount(formData);
      toast.success('Bank account created');
      setShowCreateModal(false);
      resetForm();
      fetchAccounts();
    } catch {
      toast.error('Failed to create bank account');
    } finally {
      setIsSaving(false);
    }
  };

  const handleUpdate = async () => {
    if (!editingAccount) return;
    setIsSaving(true);
    try {
      await taxService.updateBankAccount(editingAccount.uuid, formData);
      toast.success('Bank account updated');
      setEditingAccount(null);
      resetForm();
      fetchAccounts();
    } catch {
      toast.error('Failed to update bank account');
    } finally {
      setIsSaving(false);
    }
  };

  const handleDelete = async (account: TaxBankAccount) => {
    if (!confirm(`Delete bank account "${account.bank_name}"? This cannot be undone.`)) return;
    try {
      await taxService.deleteBankAccount(account.uuid);
      toast.success('Bank account deleted');
      fetchAccounts();
    } catch {
      toast.error('Failed to delete bank account');
    }
  };

  const openEdit = (account: TaxBankAccount) => {
    setFormData({
      bank_name: account.bank_name || '',
      account_number: account.account_number || '',
      sort_code: account.sort_code || '',
      account_type: account.account_type || 'current',
      currency: account.currency || 'GBP',
    });
    setEditingAccount(account);
  };

  const resetForm = () => {
    setFormData({ bank_name: '', account_number: '', sort_code: '', account_type: 'current', currency: 'GBP' });
  };

  const columns: TableColumn<TaxBankAccount>[] = [
    {
      key: 'bank_name',
      header: 'Bank Name',
      sortable: true,
      render: (item) => (
        <div className="flex items-center gap-2">
          <Landmark className="w-4 h-4 text-secondary-400" />
          <span className="font-medium">{item.bank_name}</span>
        </div>
      ),
    },
    {
      key: 'account_number',
      header: 'Account Number',
      render: (item) => item.account_number ? `****${item.account_number.slice(-4)}` : '-',
    },
    {
      key: 'sort_code',
      header: 'Sort Code',
      render: (item) => item.sort_code || '-',
    },
    {
      key: 'account_type',
      header: 'Type',
      render: (item) => (
        <span className="capitalize">{item.account_type || 'current'}</span>
      ),
    },
    {
      key: 'created_at',
      header: 'Added',
      render: (item) => formatDate(item.created_at),
    },
    {
      key: 'actions',
      header: '',
      width: 'w-24',
      render: (item) => (
        <div className="flex items-center gap-1">
          <button
            onClick={(e) => { e.stopPropagation(); openEdit(item); }}
            className="p-1.5 rounded-lg hover:bg-secondary-100 text-secondary-500 hover:text-secondary-700"
          >
            <Edit2 className="w-4 h-4" />
          </button>
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

  const renderForm = () => (
    <div className="space-y-4">
      <div>
        <label className="block text-sm font-medium text-secondary-700 mb-1">Bank Name *</label>
        <input
          type="text"
          value={formData.bank_name}
          onChange={(e) => setFormData({ ...formData, bank_name: e.target.value })}
          placeholder="e.g., Barclays, HSBC, Lloyds"
          className="w-full px-3 py-2 border border-secondary-300 rounded-lg focus:ring-2 focus:ring-primary-500 focus:border-primary-500"
        />
      </div>
      <div className="grid grid-cols-2 gap-4">
        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">Account Number</label>
          <input
            type="text"
            value={formData.account_number}
            onChange={(e) => setFormData({ ...formData, account_number: e.target.value })}
            placeholder="12345678"
            maxLength={8}
            className="w-full px-3 py-2 border border-secondary-300 rounded-lg focus:ring-2 focus:ring-primary-500 focus:border-primary-500"
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">Sort Code</label>
          <input
            type="text"
            value={formData.sort_code}
            onChange={(e) => setFormData({ ...formData, sort_code: e.target.value })}
            placeholder="20-00-00"
            className="w-full px-3 py-2 border border-secondary-300 rounded-lg focus:ring-2 focus:ring-primary-500 focus:border-primary-500"
          />
        </div>
      </div>
      <div className="grid grid-cols-2 gap-4">
        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">Account Type</label>
          <select
            value={formData.account_type}
            onChange={(e) => setFormData({ ...formData, account_type: e.target.value })}
            className="w-full px-3 py-2 border border-secondary-300 rounded-lg focus:ring-2 focus:ring-primary-500 focus:border-primary-500"
          >
            <option value="current">Current</option>
            <option value="savings">Savings</option>
            <option value="business">Business</option>
            <option value="credit_card">Credit Card</option>
          </select>
        </div>
        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">Currency</label>
          <select
            value={formData.currency}
            onChange={(e) => setFormData({ ...formData, currency: e.target.value })}
            className="w-full px-3 py-2 border border-secondary-300 rounded-lg focus:ring-2 focus:ring-primary-500 focus:border-primary-500"
          >
            <option value="GBP">GBP</option>
            <option value="EUR">EUR</option>
            <option value="USD">USD</option>
          </select>
        </div>
      </div>
      <div className="flex justify-end gap-3 pt-2">
        <button
          onClick={() => { setShowCreateModal(false); setEditingAccount(null); resetForm(); }}
          className="px-4 py-2 text-secondary-600 hover:bg-secondary-100 rounded-lg"
        >
          Cancel
        </button>
        <button
          onClick={editingAccount ? handleUpdate : handleCreate}
          disabled={isSaving}
          className="px-4 py-2 bg-primary-600 text-white rounded-lg hover:bg-primary-700 disabled:opacity-50"
        >
          {isSaving ? 'Saving...' : editingAccount ? 'Update' : 'Create'}
        </button>
      </div>
    </div>
  );

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold text-secondary-900">Bank Accounts</h1>
        <div className="flex items-center gap-2">
          <button
            onClick={fetchAccounts}
            className="p-2 text-secondary-600 hover:bg-secondary-100 rounded-lg"
          >
            <RefreshCw className="w-4 h-4" />
          </button>
          <button
            onClick={() => { resetForm(); setShowCreateModal(true); }}
            className="flex items-center gap-2 px-4 py-2 bg-primary-600 text-white rounded-lg hover:bg-primary-700"
          >
            <Plus className="w-4 h-4" />
            Add Account
          </button>
        </div>
      </div>

      {/* Search */}
      <Card padding="md">
        <Input
          placeholder="Search bank accounts..."
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
          leftIcon={<Search className="w-4 h-4" />}
        />
      </Card>

      {/* Table */}
      <Table
        columns={columns}
        data={filteredAccounts}
        keyExtractor={(item) => item.uuid || String(item.id)}
        isLoading={isLoading}
        emptyMessage="No bank accounts yet. Click 'Add Account' to get started."
      />

      {/* Create Modal */}
      {showCreateModal && (
        <Modal
          isOpen={showCreateModal}
          onClose={() => { setShowCreateModal(false); resetForm(); }}
          title="Add Bank Account"
        >
          {renderForm()}
        </Modal>
      )}

      {/* Edit Modal */}
      {editingAccount && (
        <Modal
          isOpen={!!editingAccount}
          onClose={() => { setEditingAccount(null); resetForm(); }}
          title="Edit Bank Account"
        >
          {renderForm()}
        </Modal>
      )}
    </div>
  );
}

export default function BankAccountsPage() {
  return (
    <ProtectedPage module="tax_bank_accounts" title="Tax Bank Accounts">
      <BankAccountsContent />
    </ProtectedPage>
  );
}

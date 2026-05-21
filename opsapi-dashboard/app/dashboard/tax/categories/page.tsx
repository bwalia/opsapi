'use client';

import React, { useState, useEffect, useCallback, useRef, useMemo } from 'react';
import {
  Search,
  Plus,
  Tags,
  Trash2,
  Edit2,
  RefreshCw,
  TrendingUp,
  TrendingDown,
} from 'lucide-react';
import { AxiosError } from 'axios';
import { Input, Table, Card, Modal } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { taxService, type TaxCategory, type TaxCategoryInput } from '@/services/tax.service';
import type { TableColumn } from '@/types';
import toast from 'react-hot-toast';

const EMPTY_FORM: TaxCategoryInput = {
  label: '',
  type: 'expense',
  description: '',
  is_tax_deductible: true,
};

// Surface the API's error message (e.g. 403 "Platform admin access required").
function apiError(err: unknown, fallback: string): string {
  const ax = err as AxiosError<{ error?: string; message?: string }>;
  return ax?.response?.data?.error || ax?.response?.data?.message || fallback;
}

function CategoriesContent() {
  const [categories, setCategories] = useState<TaxCategory[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState('');
  const [typeFilter, setTypeFilter] = useState<'all' | 'income' | 'expense'>('all');
  const [showCreateModal, setShowCreateModal] = useState(false);
  const [editing, setEditing] = useState<TaxCategory | null>(null);
  const [formData, setFormData] = useState<TaxCategoryInput>(EMPTY_FORM);
  const [isSaving, setIsSaving] = useState(false);
  const fetchIdRef = useRef(0);

  const fetchCategories = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);
    try {
      const data = await taxService.getCategories();
      if (fetchId === fetchIdRef.current) setCategories(data);
    } catch {
      toast.error('Failed to load categories');
    } finally {
      if (fetchId === fetchIdRef.current) setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchCategories();
  }, [fetchCategories]);

  const filtered = useMemo(() => {
    const q = searchQuery.toLowerCase();
    return categories.filter((c) => {
      const matchesType = typeFilter === 'all' || (c.type || c.category_type) === typeFilter;
      const matchesSearch =
        !q ||
        (c.label || c.name || '').toLowerCase().includes(q) ||
        (c.key || '').toLowerCase().includes(q);
      return matchesType && matchesSearch;
    });
  }, [categories, searchQuery, typeFilter]);

  const counts = useMemo(() => ({
    income: categories.filter((c) => (c.type || c.category_type) === 'income').length,
    expense: categories.filter((c) => (c.type || c.category_type) === 'expense').length,
  }), [categories]);

  const resetForm = () => setFormData(EMPTY_FORM);

  const handleCreate = async () => {
    if (!formData.label.trim()) {
      toast.error('Name is required');
      return;
    }
    setIsSaving(true);
    try {
      await taxService.createCategory(formData);
      toast.success('Category created');
      setShowCreateModal(false);
      resetForm();
      fetchCategories();
    } catch (err) {
      toast.error(apiError(err, 'Failed to create category'));
    } finally {
      setIsSaving(false);
    }
  };

  const handleUpdate = async () => {
    if (!editing) return;
    if (!formData.label.trim()) {
      toast.error('Name is required');
      return;
    }
    setIsSaving(true);
    try {
      await taxService.updateCategory(editing.uuid, formData);
      toast.success('Category updated');
      setEditing(null);
      resetForm();
      fetchCategories();
    } catch (err) {
      toast.error(apiError(err, 'Failed to update category'));
    } finally {
      setIsSaving(false);
    }
  };

  const handleDelete = async (cat: TaxCategory) => {
    if (!confirm(`Deactivate category "${cat.label || cat.name}"? It will be hidden but existing transactions keep it.`)) return;
    try {
      await taxService.deleteCategory(cat.uuid);
      toast.success('Category deactivated');
      fetchCategories();
    } catch (err) {
      toast.error(apiError(err, 'Failed to deactivate category'));
    }
  };

  const openEdit = (cat: TaxCategory) => {
    setFormData({
      label: cat.label || cat.name || '',
      type: (cat.type || cat.category_type || 'expense') as 'income' | 'expense',
      description: cat.description || '',
      is_tax_deductible: cat.is_tax_deductible ?? cat.is_deductible ?? true,
    });
    setEditing(cat);
  };

  const columns: TableColumn<TaxCategory>[] = [
    {
      key: 'label',
      header: 'Name',
      sortable: true,
      render: (item) => (
        <div className="flex items-center gap-2">
          <Tags className="w-4 h-4 text-secondary-400" />
          <span className="font-medium">{item.label || item.name}</span>
        </div>
      ),
    },
    {
      key: 'type',
      header: 'Type',
      width: 'w-32',
      render: (item) => {
        const isIncome = (item.type || item.category_type) === 'income';
        return (
          <span className={`inline-flex items-center gap-1 text-xs px-2 py-0.5 rounded-full ${
            isIncome ? 'bg-green-100 text-green-700' : 'bg-amber-100 text-amber-700'
          }`}>
            {isIncome ? <TrendingUp className="w-3 h-3" /> : <TrendingDown className="w-3 h-3" />}
            {isIncome ? 'Income' : 'Expense'}
          </span>
        );
      },
    },
    {
      key: 'is_tax_deductible',
      header: 'Deductible',
      width: 'w-28',
      render: (item) => {
        const deductible = item.is_tax_deductible ?? item.is_deductible;
        return (
          <span className={`text-xs px-2 py-0.5 rounded-full ${
            deductible ? 'bg-primary-500/10 text-primary-600' : 'bg-secondary-100 text-secondary-500'
          }`}>
            {deductible ? 'Yes' : 'No'}
          </span>
        );
      },
    },
    {
      key: 'key',
      header: 'Key',
      render: (item) => <span className="text-xs text-secondary-400 font-mono">{item.key}</span>,
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
        <label className="block text-sm font-medium text-secondary-700 mb-1">Name *</label>
        <input
          type="text"
          value={formData.label}
          onChange={(e) => setFormData({ ...formData, label: e.target.value })}
          placeholder="e.g., Office Supplies, Travel, Consulting Income"
          className="w-full px-3 py-2 border border-secondary-300 rounded-lg focus:ring-2 focus:ring-primary-500 focus:border-primary-500"
        />
      </div>
      <div className="grid grid-cols-2 gap-4">
        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">Type</label>
          <select
            value={formData.type}
            onChange={(e) => setFormData({ ...formData, type: e.target.value as 'income' | 'expense' })}
            className="w-full px-3 py-2 border border-secondary-300 rounded-lg focus:ring-2 focus:ring-primary-500 focus:border-primary-500"
          >
            <option value="expense">Expense</option>
            <option value="income">Income</option>
          </select>
        </div>
        <div className="flex items-end">
          <label className="flex items-center gap-2 text-sm font-medium text-secondary-700 mb-2">
            <input
              type="checkbox"
              checked={!!formData.is_tax_deductible}
              onChange={(e) => setFormData({ ...formData, is_tax_deductible: e.target.checked })}
              className="w-4 h-4 rounded border-secondary-300 text-primary-600 focus:ring-primary-500"
            />
            Tax deductible
          </label>
        </div>
      </div>
      <div>
        <label className="block text-sm font-medium text-secondary-700 mb-1">Description</label>
        <textarea
          value={formData.description}
          onChange={(e) => setFormData({ ...formData, description: e.target.value })}
          rows={2}
          placeholder="Optional — what kind of transactions belong here"
          className="w-full px-3 py-2 border border-secondary-300 rounded-lg focus:ring-2 focus:ring-primary-500 focus:border-primary-500"
        />
      </div>
      <div className="flex justify-end gap-3 pt-2">
        <button
          onClick={() => { setShowCreateModal(false); setEditing(null); resetForm(); }}
          className="px-4 py-2 text-secondary-600 hover:bg-secondary-100 rounded-lg"
        >
          Cancel
        </button>
        <button
          onClick={editing ? handleUpdate : handleCreate}
          disabled={isSaving}
          className="px-4 py-2 bg-primary-600 text-white rounded-lg hover:bg-primary-700 disabled:opacity-50"
        >
          {isSaving ? 'Saving...' : editing ? 'Update' : 'Create'}
        </button>
      </div>
    </div>
  );

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Categories</h1>
          <p className="text-sm text-secondary-500 mt-1">
            {counts.income} income · {counts.expense} expense categories
          </p>
        </div>
        <div className="flex items-center gap-2">
          <button
            onClick={fetchCategories}
            className="p-2 text-secondary-600 hover:bg-secondary-100 rounded-lg"
          >
            <RefreshCw className="w-4 h-4" />
          </button>
          <button
            onClick={() => { resetForm(); setShowCreateModal(true); }}
            className="flex items-center gap-2 px-4 py-2 bg-primary-600 text-white rounded-lg hover:bg-primary-700"
          >
            <Plus className="w-4 h-4" />
            Add Category
          </button>
        </div>
      </div>

      {/* Filters */}
      <Card padding="md">
        <div className="flex flex-col md:flex-row gap-3">
          <div className="flex-1">
            <Input
              placeholder="Search categories..."
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              leftIcon={<Search className="w-4 h-4" />}
            />
          </div>
          <select
            value={typeFilter}
            onChange={(e) => setTypeFilter(e.target.value as 'all' | 'income' | 'expense')}
            className="px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:ring-2 focus:ring-primary-500"
          >
            <option value="all">All Types</option>
            <option value="income">Income</option>
            <option value="expense">Expense</option>
          </select>
        </div>
      </Card>

      {/* Table */}
      <Table
        columns={columns}
        data={filtered}
        keyExtractor={(item) => item.uuid || String(item.id)}
        isLoading={isLoading}
        emptyMessage="No categories found. Click 'Add Category' to create one."
      />

      {/* Create Modal */}
      {showCreateModal && (
        <Modal
          isOpen={showCreateModal}
          onClose={() => { setShowCreateModal(false); resetForm(); }}
          title="Add Category"
        >
          {renderForm()}
        </Modal>
      )}

      {/* Edit Modal */}
      {editing && (
        <Modal
          isOpen={!!editing}
          onClose={() => { setEditing(null); resetForm(); }}
          title="Edit Category"
        >
          {renderForm()}
        </Modal>
      )}
    </div>
  );
}

export default function CategoriesPage() {
  return (
    <ProtectedPage module="tax_categories" title="Tax Categories">
      <CategoriesContent />
    </ProtectedPage>
  );
}

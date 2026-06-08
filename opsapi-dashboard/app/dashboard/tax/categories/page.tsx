'use client';

import React, { useState, useEffect, useCallback, useRef } from 'react';
import {
  Search,
  Plus,
  Tags,
  Trash2,
  Edit2,
  RefreshCw,
  Lock,
} from 'lucide-react';
import { Input, Table, Card, Modal } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { taxService, type TaxCategory, type TaxCategoryInput } from '@/services/tax.service';
import type { TableColumn } from '@/types';
import toast from 'react-hot-toast';

const EMPTY_FORM: TaxCategoryInput = {
  name: '',
  category_type: 'expense',
  is_deductible: false,
  description: '',
};

function CategoriesContent() {
  const [categories, setCategories] = useState<TaxCategory[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState('');
  const [typeFilter, setTypeFilter] = useState<string>('all');
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

  useEffect(() => { fetchCategories(); }, [fetchCategories]);

  const filtered = categories.filter((c) => {
    const matchesSearch = !searchQuery ||
      c.name?.toLowerCase().includes(searchQuery.toLowerCase()) ||
      c.description?.toLowerCase().includes(searchQuery.toLowerCase());
    const matchesType = typeFilter === 'all' || c.category_type === typeFilter;
    return matchesSearch && matchesType;
  });

  const resetForm = () => setFormData(EMPTY_FORM);

  const handleCreate = async () => {
    if (!formData.name.trim()) {
      toast.error('Name is required');
      return;
    }
    setIsSaving(true);
    try {
      await taxService.createCategory({ ...formData, name: formData.name.trim() });
      toast.success('Category created');
      setShowCreateModal(false);
      resetForm();
      fetchCategories();
    } catch {
      toast.error('Failed to create category');
    } finally {
      setIsSaving(false);
    }
  };

  const handleUpdate = async () => {
    if (!editing) return;
    if (!formData.name.trim()) {
      toast.error('Name is required');
      return;
    }
    setIsSaving(true);
    try {
      await taxService.updateCategory(editing.uuid, { ...formData, name: formData.name.trim() });
      toast.success('Category updated');
      setEditing(null);
      resetForm();
      fetchCategories();
    } catch {
      toast.error('Failed to update category');
    } finally {
      setIsSaving(false);
    }
  };

  const handleDelete = async (cat: TaxCategory) => {
    if (!confirm(`Delete category "${cat.name}"? This cannot be undone.`)) return;
    try {
      await taxService.deleteCategory(cat.uuid);
      toast.success('Category deleted');
      fetchCategories();
    } catch {
      toast.error('Failed to delete category');
    }
  };

  const openEdit = (cat: TaxCategory) => {
    setFormData({
      name: cat.name || '',
      category_type: cat.category_type || 'expense',
      is_deductible: !!cat.is_deductible,
      description: cat.description || '',
    });
    setEditing(cat);
  };

  const columns: TableColumn<TaxCategory>[] = [
    {
      key: 'name',
      header: 'Name',
      sortable: true,
      render: (item) => (
        <div className="flex items-center gap-2">
          <Tags className="w-4 h-4 text-secondary-400" />
          <span className="font-medium">{item.name}</span>
          {item.is_global && (
            <span className="inline-flex items-center gap-1 text-[10px] px-1.5 py-0.5 rounded-full bg-secondary-100 text-secondary-500">
              <Lock className="w-3 h-3" /> Global
            </span>
          )}
        </div>
      ),
    },
    {
      key: 'category_type',
      header: 'Type',
      render: (item) => (
        <span className={`text-xs px-2 py-0.5 rounded-full ${
          item.category_type === 'income' ? 'bg-green-100 text-green-700' : 'bg-red-100 text-red-700'
        }`}>
          {item.category_type === 'income' ? 'Income' : 'Expense'}
        </span>
      ),
    },
    {
      key: 'is_deductible',
      header: 'Deductible',
      width: 'w-24',
      render: (item) => (
        <span className={`text-xs px-2 py-0.5 rounded-full ${
          item.is_deductible ? 'bg-green-100 text-green-700' : 'bg-secondary-100 text-secondary-500'
        }`}>
          {item.is_deductible ? 'Yes' : 'No'}
        </span>
      ),
    },
    {
      key: 'description',
      header: 'Description',
      render: (item) => (
        <span className="text-sm text-secondary-500 truncate max-w-xs block">
          {item.description || '-'}
        </span>
      ),
    },
    {
      key: 'actions',
      header: '',
      width: 'w-24',
      render: (item) => (
        item.is_global ? (
          <span className="text-xs text-secondary-400 italic">Read-only</span>
        ) : (
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
        )
      ),
    },
  ];

  const renderForm = () => (
    <div className="space-y-4">
      <div>
        <label className="block text-sm font-medium text-secondary-700 mb-1">Name *</label>
        <input
          type="text"
          value={formData.name}
          onChange={(e) => setFormData({ ...formData, name: e.target.value })}
          placeholder="e.g., Office Supplies, Consulting Income"
          className="w-full px-3 py-2 border border-secondary-300 rounded-lg focus:ring-2 focus:ring-primary-500 focus:border-primary-500"
        />
      </div>
      <div className="grid grid-cols-2 gap-4">
        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">Type</label>
          <select
            value={formData.category_type}
            onChange={(e) => setFormData({ ...formData, category_type: e.target.value as 'income' | 'expense' })}
            className="w-full px-3 py-2 border border-secondary-300 rounded-lg focus:ring-2 focus:ring-primary-500 focus:border-primary-500"
          >
            <option value="expense">Expense</option>
            <option value="income">Income</option>
          </select>
        </div>
        <div className="flex items-end pb-2">
          <label className="flex items-center gap-2 text-sm font-medium text-secondary-700">
            <input
              type="checkbox"
              checked={!!formData.is_deductible}
              onChange={(e) => setFormData({ ...formData, is_deductible: e.target.checked })}
              className="rounded border-secondary-300 text-primary-600 focus:ring-primary-500"
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
          placeholder="Optional notes about what belongs in this category"
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
            Manage your custom tax categories. Global categories are shared and read-only.
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
            onChange={(e) => setTypeFilter(e.target.value)}
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

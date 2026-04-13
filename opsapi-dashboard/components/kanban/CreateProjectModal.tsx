'use client';

import React, { memo, useState } from 'react';
import Modal from '@/components/ui/Modal';
import Button from '@/components/ui/Button';
import Input from '@/components/ui/Input';
import type { CreateKanbanProjectDto, BudgetCurrency, KanbanProjectVisibility } from '@/types';
import { DEFAULT_LABEL_COLORS } from '@/services/kanban.service';

// ============================================
// Color Picker Component
// ============================================

const COLORS = [
  '#ef4444', '#f97316', '#eab308', '#22c55e', '#14b8a6',
  '#3b82f6', '#6366f1', '#8b5cf6', '#ec4899', '#1f2937',
];

interface ColorPickerProps {
  value: string;
  onChange: (color: string) => void;
}

const ColorPicker = memo(function ColorPicker({ value, onChange }: ColorPickerProps) {
  return (
    <div className="flex flex-wrap gap-2">
      {COLORS.map((color) => (
        <button
          key={color}
          type="button"
          onClick={() => onChange(color)}
          className={`w-8 h-8 rounded-lg transition-all ${
            value === color ? 'ring-2 ring-offset-2 ring-primary-500 scale-110' : ''
          }`}
          style={{ backgroundColor: color }}
        />
      ))}
    </div>
  );
});

// ============================================
// Currency Select Component
// ============================================

const CURRENCIES: { value: BudgetCurrency; label: string }[] = [
  { value: 'USD', label: '$ USD' },
  { value: 'EUR', label: '€ EUR' },
  { value: 'GBP', label: '£ GBP' },
  { value: 'INR', label: '₹ INR' },
  { value: 'CAD', label: '$ CAD' },
  { value: 'AUD', label: '$ AUD' },
  { value: 'JPY', label: '¥ JPY' },
  { value: 'CNY', label: '¥ CNY' },
];

// ============================================
// Main Create Project Modal Component
// ============================================

export interface CreateProjectModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSubmit: (data: CreateKanbanProjectDto) => Promise<void>;
  isLoading?: boolean;
}

const CreateProjectModal = memo(function CreateProjectModal({
  isOpen,
  onClose,
  onSubmit,
  isLoading,
}: CreateProjectModalProps) {
  const [formData, setFormData] = useState<CreateKanbanProjectDto>({
    name: '',
    description: '',
    visibility: 'private',
    color: '#6366f1',
    budget: 0,
    budget_currency: 'USD',
  });

  const [errors, setErrors] = useState<Record<string, string>>({});
  const [showAdvanced, setShowAdvanced] = useState(false);

  const handleChange = (
    e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>
  ) => {
    const { name, value } = e.target;
    setFormData((prev) => ({
      ...prev,
      [name]: name === 'budget' || name === 'hourly_rate' ? parseFloat(value) || 0 : value,
    }));
    // Clear error when field is modified
    if (errors[name]) {
      setErrors((prev) => ({ ...prev, [name]: '' }));
    }
  };

  const validate = (): boolean => {
    const newErrors: Record<string, string> = {};

    if (!formData.name?.trim()) {
      newErrors.name = 'Project name is required';
    } else if (formData.name.length < 2) {
      newErrors.name = 'Project name must be at least 2 characters';
    } else if (formData.name.length > 100) {
      newErrors.name = 'Project name must be less than 100 characters';
    }

    if (formData.description && formData.description.length > 500) {
      newErrors.description = 'Description must be less than 500 characters';
    }

    if (formData.budget && formData.budget < 0) {
      newErrors.budget = 'Budget cannot be negative';
    }

    if (formData.hourly_rate && formData.hourly_rate < 0) {
      newErrors.hourly_rate = 'Hourly rate cannot be negative';
    }

    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!validate()) return;

    await onSubmit(formData);
    // Reset form on success
    setFormData({
      name: '',
      description: '',
      visibility: 'private',
      color: '#6366f1',
      budget: 0,
      budget_currency: 'USD',
    });
    setShowAdvanced(false);
  };

  const handleClose = () => {
    setFormData({
      name: '',
      description: '',
      visibility: 'private',
      color: '#6366f1',
      budget: 0,
      budget_currency: 'USD',
    });
    setErrors({});
    setShowAdvanced(false);
    onClose();
  };

  return (
    <Modal isOpen={isOpen} onClose={handleClose} title="Create New Project" size="lg">
      <form onSubmit={handleSubmit} className="space-y-6">
        {/* Project Name */}
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">
            Project Name <span className="text-red-500">*</span>
          </label>
          <Input
            name="name"
            value={formData.name}
            onChange={handleChange}
            placeholder="Enter project name"
            className={errors.name ? 'border-red-500' : ''}
            disabled={isLoading}
          />
          {errors.name && (
            <p className="mt-1 text-sm text-red-500">{errors.name}</p>
          )}
        </div>

        {/* Description */}
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">
            Description
          </label>
          <textarea
            name="description"
            value={formData.description || ''}
            onChange={handleChange}
            placeholder="Describe your project..."
            className={`w-full px-4 py-2 border rounded-lg resize-none focus:outline-none focus:ring-2 focus:ring-primary-500 ${
              errors.description ? 'border-red-500' : 'border-gray-300'
            }`}
            rows={3}
            disabled={isLoading}
          />
          {errors.description && (
            <p className="mt-1 text-sm text-red-500">{errors.description}</p>
          )}
        </div>

        {/* Color */}
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-2">
            Project Color
          </label>
          <ColorPicker
            value={formData.color || '#6366f1'}
            onChange={(color) => setFormData((prev) => ({ ...prev, color }))}
          />
        </div>

        {/* Visibility */}
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">
            Visibility
          </label>
          <select
            name="visibility"
            value={formData.visibility}
            onChange={handleChange}
            className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary-500"
            disabled={isLoading}
          >
            <option value="private">Private - Only members can access</option>
            <option value="internal">Internal - Visible to namespace members</option>
            <option value="public">Public - Visible to everyone</option>
          </select>
        </div>

        {/* Advanced Options Toggle */}
        <button
          type="button"
          onClick={() => setShowAdvanced(!showAdvanced)}
          className="text-sm text-primary-600 hover:text-primary-700"
        >
          {showAdvanced ? '- Hide advanced options' : '+ Show advanced options'}
        </button>

        {/* Advanced Options */}
        {showAdvanced && (
          <div className="space-y-4 pt-4 border-t border-gray-200">
            {/* Budget */}
            <div className="grid grid-cols-2 gap-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Budget
                </label>
                <div className="flex">
                  <select
                    name="budget_currency"
                    value={formData.budget_currency}
                    onChange={handleChange}
                    className="px-3 py-2 border border-r-0 border-gray-300 rounded-l-lg focus:outline-none focus:ring-2 focus:ring-primary-500"
                    disabled={isLoading}
                  >
                    {CURRENCIES.map((c) => (
                      <option key={c.value} value={c.value}>
                        {c.label}
                      </option>
                    ))}
                  </select>
                  <input
                    type="number"
                    name="budget"
                    value={formData.budget || ''}
                    onChange={handleChange}
                    placeholder="0.00"
                    min="0"
                    step="0.01"
                    className={`flex-1 px-4 py-2 border border-gray-300 rounded-r-lg focus:outline-none focus:ring-2 focus:ring-primary-500 ${
                      errors.budget ? 'border-red-500' : ''
                    }`}
                    disabled={isLoading}
                  />
                </div>
                {errors.budget && (
                  <p className="mt-1 text-sm text-red-500">{errors.budget}</p>
                )}
              </div>

              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Hourly Rate
                </label>
                <input
                  type="number"
                  name="hourly_rate"
                  value={formData.hourly_rate || ''}
                  onChange={handleChange}
                  placeholder="0.00"
                  min="0"
                  step="0.01"
                  className={`w-full px-4 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary-500 ${
                    errors.hourly_rate ? 'border-red-500' : ''
                  }`}
                  disabled={isLoading}
                />
                {errors.hourly_rate && (
                  <p className="mt-1 text-sm text-red-500">{errors.hourly_rate}</p>
                )}
              </div>
            </div>

            {/* Dates */}
            <div className="grid grid-cols-2 gap-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Start Date
                </label>
                <input
                  type="date"
                  name="start_date"
                  value={formData.start_date || ''}
                  onChange={handleChange}
                  className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary-500"
                  disabled={isLoading}
                />
              </div>

              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  Due Date
                </label>
                <input
                  type="date"
                  name="due_date"
                  value={formData.due_date || ''}
                  onChange={handleChange}
                  className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary-500"
                  disabled={isLoading}
                />
              </div>
            </div>
          </div>
        )}

        {/* Actions */}
        <div className="flex justify-end gap-3 pt-4 border-t border-gray-200">
          <Button
            type="button"
            variant="outline"
            onClick={handleClose}
            disabled={isLoading}
          >
            Cancel
          </Button>
          <Button type="submit" isLoading={isLoading}>
            Create Project
          </Button>
        </div>
      </form>
    </Modal>
  );
});

export default CreateProjectModal;

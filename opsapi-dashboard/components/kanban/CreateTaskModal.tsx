'use client';

import React, { memo, useState, useEffect } from 'react';
import {
  Calendar,
  Clock,
  Flag,
  User,
  Tag,
  FileText,
  Target,
  ChevronDown,
  ChevronUp,
} from 'lucide-react';
import Modal from '@/components/ui/Modal';
import Button from '@/components/ui/Button';
import Input from '@/components/ui/Input';
import type {
  CreateKanbanTaskDto,
  KanbanTaskPriority,
  KanbanTaskStatus,
  KanbanProjectMember,
  KanbanLabel,
  KanbanColumn,
} from '@/types';

// ============================================
// Priority Options
// ============================================

const PRIORITIES: { value: KanbanTaskPriority; label: string; color: string }[] = [
  { value: 'critical', label: 'Critical', color: '#ef4444' },
  { value: 'high', label: 'High', color: '#f97316' },
  { value: 'medium', label: 'Medium', color: '#eab308' },
  { value: 'low', label: 'Low', color: '#3b82f6' },
  { value: 'none', label: 'None', color: '#6b7280' },
];

const STATUSES: { value: KanbanTaskStatus; label: string }[] = [
  { value: 'open', label: 'Open' },
  { value: 'in_progress', label: 'In Progress' },
  { value: 'blocked', label: 'Blocked' },
  { value: 'review', label: 'In Review' },
  { value: 'completed', label: 'Completed' },
  { value: 'cancelled', label: 'Cancelled' },
];

// ============================================
// Priority Select Component
// ============================================

interface PrioritySelectProps {
  value: KanbanTaskPriority;
  onChange: (value: KanbanTaskPriority) => void;
}

const PrioritySelect = memo(function PrioritySelect({
  value,
  onChange,
}: PrioritySelectProps) {
  const selected = PRIORITIES.find((p) => p.value === value);

  return (
    <div className="relative">
      <select
        value={value}
        onChange={(e) => onChange(e.target.value as KanbanTaskPriority)}
        className="w-full px-3 py-2 pr-10 text-sm border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-transparent appearance-none bg-white"
      >
        {PRIORITIES.map((priority) => (
          <option key={priority.value} value={priority.value}>
            {priority.label}
          </option>
        ))}
      </select>
      <div
        className="absolute right-3 top-1/2 -translate-y-1/2 w-3 h-3 rounded-full pointer-events-none"
        style={{ backgroundColor: selected?.color }}
      />
    </div>
  );
});

// ============================================
// Member Select Component
// ============================================

interface MemberSelectProps {
  members: KanbanProjectMember[];
  selectedUuids: string[];
  onChange: (uuids: string[]) => void;
}

const MemberSelect = memo(function MemberSelect({
  members,
  selectedUuids,
  onChange,
}: MemberSelectProps) {
  const [isOpen, setIsOpen] = useState(false);

  const toggleMember = (uuid: string) => {
    if (selectedUuids.includes(uuid)) {
      onChange(selectedUuids.filter((u) => u !== uuid));
    } else {
      onChange([...selectedUuids, uuid]);
    }
  };

  const selectedMembers = members.filter((m) => selectedUuids.includes(m.user_uuid));

  return (
    <div className="relative">
      <button
        type="button"
        onClick={() => setIsOpen(!isOpen)}
        className="w-full px-3 py-2 text-sm text-left border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary-500 hover:bg-gray-50 flex items-center justify-between"
      >
        <span className="text-gray-700">
          {selectedMembers.length > 0
            ? selectedMembers.map((m) => m.user?.first_name || 'User').join(', ')
            : 'Select assignees...'}
        </span>
        {isOpen ? <ChevronUp size={16} /> : <ChevronDown size={16} />}
      </button>

      {isOpen && (
        <>
          <div className="fixed inset-0 z-10" onClick={() => setIsOpen(false)} />
          <div className="absolute z-20 w-full mt-1 bg-white border border-gray-200 rounded-lg shadow-lg max-h-48 overflow-y-auto">
            {members.length === 0 ? (
              <div className="px-3 py-2 text-sm text-gray-500">No members available</div>
            ) : (
              members.map((member) => (
                <button
                  key={member.user_uuid}
                  type="button"
                  onClick={() => toggleMember(member.user_uuid)}
                  className={`w-full px-3 py-2 text-sm text-left hover:bg-gray-50 flex items-center gap-2 ${
                    selectedUuids.includes(member.user_uuid) ? 'bg-primary-50' : ''
                  }`}
                >
                  <div className="w-6 h-6 rounded-full bg-gray-300 flex items-center justify-center text-xs font-medium text-gray-600">
                    {member.user?.first_name?.[0] || 'U'}
                  </div>
                  <span>
                    {member.user?.first_name} {member.user?.last_name}
                  </span>
                  {selectedUuids.includes(member.user_uuid) && (
                    <span className="ml-auto text-primary-600">✓</span>
                  )}
                </button>
              ))
            )}
          </div>
        </>
      )}
    </div>
  );
});

// ============================================
// Label Select Component
// ============================================

interface LabelSelectProps {
  labels: KanbanLabel[];
  selectedIds: number[];
  onChange: (ids: number[]) => void;
}

const LabelSelect = memo(function LabelSelect({
  labels,
  selectedIds,
  onChange,
}: LabelSelectProps) {
  const [isOpen, setIsOpen] = useState(false);

  const toggleLabel = (id: number) => {
    if (selectedIds.includes(id)) {
      onChange(selectedIds.filter((i) => i !== id));
    } else {
      onChange([...selectedIds, id]);
    }
  };

  const selectedLabels = labels.filter((l) => selectedIds.includes(l.id));

  return (
    <div className="relative">
      <button
        type="button"
        onClick={() => setIsOpen(!isOpen)}
        className="w-full px-3 py-2 text-sm text-left border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary-500 hover:bg-gray-50 flex items-center justify-between"
      >
        <div className="flex flex-wrap gap-1">
          {selectedLabels.length > 0 ? (
            selectedLabels.map((label) => (
              <span
                key={label.id}
                className="px-2 py-0.5 text-xs rounded text-white"
                style={{ backgroundColor: label.color }}
              >
                {label.name}
              </span>
            ))
          ) : (
            <span className="text-gray-500">Select labels...</span>
          )}
        </div>
        {isOpen ? <ChevronUp size={16} /> : <ChevronDown size={16} />}
      </button>

      {isOpen && (
        <>
          <div className="fixed inset-0 z-10" onClick={() => setIsOpen(false)} />
          <div className="absolute z-20 w-full mt-1 bg-white border border-gray-200 rounded-lg shadow-lg max-h-48 overflow-y-auto">
            {labels.length === 0 ? (
              <div className="px-3 py-2 text-sm text-gray-500">No labels available</div>
            ) : (
              labels.map((label) => (
                <button
                  key={label.id}
                  type="button"
                  onClick={() => toggleLabel(label.id)}
                  className={`w-full px-3 py-2 text-sm text-left hover:bg-gray-50 flex items-center gap-2 ${
                    selectedIds.includes(label.id) ? 'bg-primary-50' : ''
                  }`}
                >
                  <div
                    className="w-4 h-4 rounded"
                    style={{ backgroundColor: label.color }}
                  />
                  <span>{label.name}</span>
                  {selectedIds.includes(label.id) && (
                    <span className="ml-auto text-primary-600">✓</span>
                  )}
                </button>
              ))
            )}
          </div>
        </>
      )}
    </div>
  );
});

// ============================================
// Main Create Task Modal Component
// ============================================

export interface CreateTaskModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSubmit: (data: CreateKanbanTaskDto) => Promise<void>;
  columnId: number;
  columns?: (KanbanColumn & { tasks: unknown[] })[];
  members?: KanbanProjectMember[];
  labels?: KanbanLabel[];
  isLoading?: boolean;
}

const CreateTaskModal = memo(function CreateTaskModal({
  isOpen,
  onClose,
  onSubmit,
  columnId,
  columns = [],
  members = [],
  labels = [],
  isLoading,
}: CreateTaskModalProps) {
  const [formData, setFormData] = useState<CreateKanbanTaskDto>({
    title: '',
    description: '',
    column_id: columnId,
    priority: 'medium',
    status: 'open',
    assignee_uuids: [],
    label_ids: [],
  });

  const [errors, setErrors] = useState<Record<string, string>>({});
  const [showAdvanced, setShowAdvanced] = useState(false);

  // Reset form when modal opens
  useEffect(() => {
    if (isOpen) {
      setFormData({
        title: '',
        description: '',
        column_id: columnId,
        priority: 'medium',
        status: 'open',
        assignee_uuids: [],
        label_ids: [],
      });
      setErrors({});
      setShowAdvanced(false);
    }
  }, [isOpen, columnId]);

  const handleChange = (
    e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>
  ) => {
    const { name, value } = e.target;
    setFormData((prev) => ({
      ...prev,
      [name]:
        name === 'story_points' ||
        name === 'time_estimate_minutes' ||
        name === 'budget' ||
        name === 'column_id'
          ? value ? parseInt(value, 10) || 0 : undefined
          : value,
    }));
    if (errors[name]) {
      setErrors((prev) => ({ ...prev, [name]: '' }));
    }
  };

  const validate = (): boolean => {
    const newErrors: Record<string, string> = {};

    if (!formData.title?.trim()) {
      newErrors.title = 'Task title is required';
    }

    if (formData.due_date && formData.start_date) {
      const start = new Date(formData.start_date);
      const due = new Date(formData.due_date);
      if (due < start) {
        newErrors.due_date = 'Due date must be after start date';
      }
    }

    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!validate()) return;

    try {
      await onSubmit(formData);
      onClose();
    } catch (error) {
      console.error('Failed to create task:', error);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Create New Task" size="lg">
      <form onSubmit={handleSubmit} className="space-y-6">
        {/* Title - Required */}
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">
            Task Title <span className="text-red-500">*</span>
          </label>
          <Input
            name="title"
            value={formData.title || ''}
            onChange={handleChange}
            placeholder="Enter task title..."
            error={errors.title}
            autoFocus
          />
        </div>

        {/* Description */}
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">
            <FileText size={14} className="inline mr-1" />
            Description
          </label>
          <textarea
            name="description"
            value={formData.description || ''}
            onChange={handleChange}
            placeholder="Add a more detailed description..."
            rows={3}
            className="w-full px-3 py-2 text-sm border border-gray-300 rounded-lg resize-none focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-transparent"
          />
        </div>

        {/* Column & Priority Row */}
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">
              Column
            </label>
            <select
              name="column_id"
              value={formData.column_id || ''}
              onChange={handleChange}
              className="w-full px-3 py-2 text-sm border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-transparent"
            >
              {columns.map((col) => (
                <option key={col.id} value={col.id}>
                  {col.name}
                </option>
              ))}
            </select>
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">
              <Flag size={14} className="inline mr-1" />
              Priority
            </label>
            <PrioritySelect
              value={formData.priority || 'medium'}
              onChange={(value) => setFormData((prev) => ({ ...prev, priority: value }))}
            />
          </div>
        </div>

        {/* Dates Row */}
        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">
              <Calendar size={14} className="inline mr-1" />
              Start Date
            </label>
            <Input
              type="date"
              name="start_date"
              value={formData.start_date || ''}
              onChange={handleChange}
            />
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">
              <Calendar size={14} className="inline mr-1" />
              Due Date
            </label>
            <Input
              type="date"
              name="due_date"
              value={formData.due_date || ''}
              onChange={handleChange}
              error={errors.due_date}
            />
          </div>
        </div>

        {/* Assignees */}
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">
            <User size={14} className="inline mr-1" />
            Assignees
          </label>
          <MemberSelect
            members={members}
            selectedUuids={formData.assignee_uuids || []}
            onChange={(uuids) => setFormData((prev) => ({ ...prev, assignee_uuids: uuids }))}
          />
        </div>

        {/* Labels */}
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">
            <Tag size={14} className="inline mr-1" />
            Labels
          </label>
          <LabelSelect
            labels={labels}
            selectedIds={formData.label_ids || []}
            onChange={(ids) => setFormData((prev) => ({ ...prev, label_ids: ids }))}
          />
        </div>

        {/* Advanced Options Toggle */}
        <button
          type="button"
          onClick={() => setShowAdvanced(!showAdvanced)}
          className="flex items-center gap-2 text-sm text-gray-600 hover:text-gray-900"
        >
          {showAdvanced ? <ChevronUp size={16} /> : <ChevronDown size={16} />}
          Advanced Options
        </button>

        {/* Advanced Options */}
        {showAdvanced && (
          <div className="space-y-4 pt-4 border-t border-gray-200">
            {/* Story Points & Time Estimate */}
            <div className="grid grid-cols-2 gap-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  <Target size={14} className="inline mr-1" />
                  Story Points
                </label>
                <Input
                  type="number"
                  name="story_points"
                  value={formData.story_points || ''}
                  onChange={handleChange}
                  placeholder="0"
                  min="0"
                />
              </div>

              <div>
                <label className="block text-sm font-medium text-gray-700 mb-1">
                  <Clock size={14} className="inline mr-1" />
                  Time Estimate (minutes)
                </label>
                <Input
                  type="number"
                  name="time_estimate_minutes"
                  value={formData.time_estimate_minutes || ''}
                  onChange={handleChange}
                  placeholder="0"
                  min="0"
                />
              </div>
            </div>

            {/* Budget */}
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">
                Budget
              </label>
              <Input
                type="number"
                name="budget"
                value={formData.budget || ''}
                onChange={handleChange}
                placeholder="0.00"
                min="0"
                step="0.01"
              />
            </div>

            {/* Status */}
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">
                Initial Status
              </label>
              <select
                name="status"
                value={formData.status || 'open'}
                onChange={handleChange}
                className="w-full px-3 py-2 text-sm border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-transparent"
              >
                {STATUSES.map((status) => (
                  <option key={status.value} value={status.value}>
                    {status.label}
                  </option>
                ))}
              </select>
            </div>
          </div>
        )}

        {/* Actions */}
        <div className="flex justify-end gap-3 pt-4 border-t border-gray-200">
          <Button type="button" variant="outline" onClick={onClose} disabled={isLoading}>
            Cancel
          </Button>
          <Button type="submit" isLoading={isLoading}>
            Create Task
          </Button>
        </div>
      </form>
    </Modal>
  );
});

export default CreateTaskModal;

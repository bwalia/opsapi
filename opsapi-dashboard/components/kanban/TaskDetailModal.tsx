'use client';

import React, { memo, useState, useCallback, useEffect } from 'react';
import {
  X,
  Calendar,
  Clock,
  Tag,
  Users,
  MessageSquare,
  Paperclip,
  CheckSquare,
  Activity,
  MoreHorizontal,
  Edit2,
  Trash2,
  Copy,
  Archive,
  AlertTriangle,
  ArrowUp,
  ArrowDown,
  Minus,
  Circle,
  Plus,
  Send,
  Check,
} from 'lucide-react';
import { cn } from '@/lib/utils';
import type {
  KanbanTask,
  KanbanLabel,
  KanbanComment,
  KanbanChecklist,
  KanbanTaskPriority,
  KanbanTaskStatus,
  KanbanProjectMember,
  UpdateKanbanTaskDto,
} from '@/types';
import Button from '@/components/ui/Button';
import Modal from '@/components/ui/Modal';
import {
  formatPriority,
  formatTaskStatus,
  formatTimeMinutes,
  getPriorityColor,
  getTaskStatusColor,
  isTaskOverdue,
  getDaysUntilDue,
} from '@/services/kanban.service';

// ============================================
// Priority Selector Component
// ============================================

const PRIORITIES: KanbanTaskPriority[] = ['critical', 'high', 'medium', 'low', 'none'];

const PriorityIcon = ({ priority }: { priority: KanbanTaskPriority }) => {
  switch (priority) {
    case 'critical':
      return <AlertTriangle size={14} className="text-red-500" />;
    case 'high':
      return <ArrowUp size={14} className="text-orange-500" />;
    case 'medium':
      return <Minus size={14} className="text-yellow-500" />;
    case 'low':
      return <ArrowDown size={14} className="text-blue-500" />;
    default:
      return <Circle size={14} className="text-gray-400" />;
  }
};

interface PrioritySelectorProps {
  value: KanbanTaskPriority;
  onChange: (priority: KanbanTaskPriority) => void;
}

const PrioritySelector = memo(function PrioritySelector({
  value,
  onChange,
}: PrioritySelectorProps) {
  const [isOpen, setIsOpen] = useState(false);

  return (
    <div className="relative">
      <button
        onClick={() => setIsOpen(!isOpen)}
        className={cn(
          'flex items-center gap-2 px-3 py-1.5 rounded-md text-sm border transition-colors',
          getPriorityColor(value)
        )}
      >
        <PriorityIcon priority={value} />
        {formatPriority(value)}
      </button>

      {isOpen && (
        <>
          <div className="fixed inset-0 z-10" onClick={() => setIsOpen(false)} />
          <div className="absolute left-0 mt-1 w-40 bg-white rounded-lg shadow-lg border border-gray-200 py-1 z-20">
            {PRIORITIES.map((priority) => (
              <button
                key={priority}
                onClick={() => {
                  onChange(priority);
                  setIsOpen(false);
                }}
                className={cn(
                  'w-full flex items-center gap-2 px-3 py-2 text-sm hover:bg-gray-50',
                  value === priority && 'bg-gray-50'
                )}
              >
                <PriorityIcon priority={priority} />
                {formatPriority(priority)}
              </button>
            ))}
          </div>
        </>
      )}
    </div>
  );
});

// ============================================
// Status Selector Component
// ============================================

const STATUSES: KanbanTaskStatus[] = ['open', 'in_progress', 'blocked', 'review', 'completed', 'cancelled'];

interface StatusSelectorProps {
  value: KanbanTaskStatus;
  onChange: (status: KanbanTaskStatus) => void;
}

const StatusSelector = memo(function StatusSelector({
  value,
  onChange,
}: StatusSelectorProps) {
  const [isOpen, setIsOpen] = useState(false);

  return (
    <div className="relative">
      <button
        onClick={() => setIsOpen(!isOpen)}
        className={cn(
          'flex items-center gap-2 px-3 py-1.5 rounded-md text-sm border transition-colors',
          getTaskStatusColor(value)
        )}
      >
        {formatTaskStatus(value)}
      </button>

      {isOpen && (
        <>
          <div className="fixed inset-0 z-10" onClick={() => setIsOpen(false)} />
          <div className="absolute left-0 mt-1 w-40 bg-white rounded-lg shadow-lg border border-gray-200 py-1 z-20">
            {STATUSES.map((status) => (
              <button
                key={status}
                onClick={() => {
                  onChange(status);
                  setIsOpen(false);
                }}
                className={cn(
                  'w-full flex items-center gap-2 px-3 py-2 text-sm hover:bg-gray-50',
                  value === status && 'bg-gray-50'
                )}
              >
                <span
                  className={cn(
                    'w-2 h-2 rounded-full',
                    status === 'open' && 'bg-gray-400',
                    status === 'in_progress' && 'bg-blue-500',
                    status === 'blocked' && 'bg-red-500',
                    status === 'review' && 'bg-purple-500',
                    status === 'completed' && 'bg-green-500',
                    status === 'cancelled' && 'bg-gray-400'
                  )}
                />
                {formatTaskStatus(status)}
              </button>
            ))}
          </div>
        </>
      )}
    </div>
  );
});

// ============================================
// Assignees Section Component
// ============================================

interface AssigneesSectionProps {
  assignees: KanbanTask['assignees'];
  members: KanbanProjectMember[];
  onAdd: (userUuid: string) => void;
  onRemove: (userUuid: string) => void;
}

const AssigneesSection = memo(function AssigneesSection({
  assignees,
  members,
  onAdd,
  onRemove,
}: AssigneesSectionProps) {
  const [showPicker, setShowPicker] = useState(false);

  const assignedUuids = new Set(assignees?.map((a) => a.user_uuid) || []);
  const availableMembers = members.filter((m) => !assignedUuids.has(m.user_uuid));

  return (
    <div>
      <div className="flex items-center gap-2 text-sm text-gray-500 mb-2">
        <Users size={14} />
        <span>Assignees</span>
      </div>
      <div className="flex flex-wrap gap-2">
        {assignees?.map((assignee) => (
          <div
            key={assignee.uuid}
            className="flex items-center gap-2 bg-gray-100 px-2 py-1 rounded-full"
          >
            <div className="w-6 h-6 rounded-full bg-primary-100 text-primary-700 text-xs font-medium flex items-center justify-center">
              {assignee.user?.first_name?.[0]}
              {assignee.user?.last_name?.[0]}
            </div>
            <span className="text-sm">
              {assignee.user?.first_name} {assignee.user?.last_name}
            </span>
            <button
              onClick={() => onRemove(assignee.user_uuid)}
              className="text-gray-400 hover:text-gray-600"
            >
              <X size={14} />
            </button>
          </div>
        ))}

        <div className="relative">
          <button
            onClick={() => setShowPicker(!showPicker)}
            className="flex items-center gap-1 px-2 py-1 text-sm text-gray-500 hover:text-gray-700 border border-dashed border-gray-300 rounded-full hover:border-gray-400"
          >
            <Plus size={14} />
            Add
          </button>

          {showPicker && availableMembers.length > 0 && (
            <>
              <div className="fixed inset-0 z-10" onClick={() => setShowPicker(false)} />
              <div className="absolute left-0 mt-1 w-56 bg-white rounded-lg shadow-lg border border-gray-200 py-1 z-20 max-h-48 overflow-y-auto">
                {availableMembers.map((member) => (
                  <button
                    key={member.uuid}
                    onClick={() => {
                      onAdd(member.user_uuid);
                      setShowPicker(false);
                    }}
                    className="w-full flex items-center gap-2 px-3 py-2 text-sm hover:bg-gray-50"
                  >
                    <div className="w-6 h-6 rounded-full bg-primary-100 text-primary-700 text-xs font-medium flex items-center justify-center">
                      {member.user?.first_name?.[0]}
                      {member.user?.last_name?.[0]}
                    </div>
                    <span>
                      {member.user?.first_name} {member.user?.last_name}
                    </span>
                  </button>
                ))}
              </div>
            </>
          )}
        </div>
      </div>
    </div>
  );
});

// ============================================
// Labels Section Component
// ============================================

interface LabelsSectionProps {
  taskLabels: KanbanLabel[] | undefined;
  projectLabels: KanbanLabel[];
  onAdd: (labelId: number) => void;
  onRemove: (labelId: number) => void;
}

const LabelsSection = memo(function LabelsSection({
  taskLabels,
  projectLabels,
  onAdd,
  onRemove,
}: LabelsSectionProps) {
  const [showPicker, setShowPicker] = useState(false);

  const usedLabelIds = new Set(taskLabels?.map((l) => l.id) || []);
  const availableLabels = projectLabels.filter((l) => !usedLabelIds.has(l.id));

  return (
    <div>
      <div className="flex items-center gap-2 text-sm text-gray-500 mb-2">
        <Tag size={14} />
        <span>Labels</span>
      </div>
      <div className="flex flex-wrap gap-2">
        {taskLabels?.map((label) => (
          <div
            key={label.uuid}
            className="flex items-center gap-1 px-2 py-1 rounded-full text-sm"
            style={{
              backgroundColor: `${label.color}20`,
              color: label.color,
            }}
          >
            <span>{label.name}</span>
            <button
              onClick={() => onRemove(label.id)}
              className="hover:opacity-70"
            >
              <X size={12} />
            </button>
          </div>
        ))}

        <div className="relative">
          <button
            onClick={() => setShowPicker(!showPicker)}
            className="flex items-center gap-1 px-2 py-1 text-sm text-gray-500 hover:text-gray-700 border border-dashed border-gray-300 rounded-full hover:border-gray-400"
          >
            <Plus size={14} />
            Add
          </button>

          {showPicker && availableLabels.length > 0 && (
            <>
              <div className="fixed inset-0 z-10" onClick={() => setShowPicker(false)} />
              <div className="absolute left-0 mt-1 w-48 bg-white rounded-lg shadow-lg border border-gray-200 py-1 z-20 max-h-48 overflow-y-auto">
                {availableLabels.map((label) => (
                  <button
                    key={label.uuid}
                    onClick={() => {
                      onAdd(label.id);
                      setShowPicker(false);
                    }}
                    className="w-full flex items-center gap-2 px-3 py-2 text-sm hover:bg-gray-50"
                  >
                    <div
                      className="w-3 h-3 rounded-full"
                      style={{ backgroundColor: label.color }}
                    />
                    <span>{label.name}</span>
                  </button>
                ))}
              </div>
            </>
          )}
        </div>
      </div>
    </div>
  );
});

// ============================================
// Comments Section Component
// ============================================

interface CommentsSectionProps {
  comments: KanbanComment[] | undefined;
  onAddComment: (content: string) => void;
  onDeleteComment: (uuid: string) => void;
  isAddingComment?: boolean;
}

const CommentsSection = memo(function CommentsSection({
  comments,
  onAddComment,
  onDeleteComment,
  isAddingComment,
}: CommentsSectionProps) {
  const [newComment, setNewComment] = useState('');

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (newComment.trim()) {
      onAddComment(newComment.trim());
      setNewComment('');
    }
  };

  return (
    <div>
      <div className="flex items-center gap-2 text-sm text-gray-500 mb-3">
        <MessageSquare size={14} />
        <span>Comments ({comments?.length || 0})</span>
      </div>

      {/* Comment List */}
      <div className="space-y-3 mb-4">
        {comments?.map((comment) => (
          <div key={comment.uuid} className="flex gap-3">
            <div className="w-8 h-8 rounded-full bg-primary-100 text-primary-700 text-xs font-medium flex items-center justify-center flex-shrink-0">
              {comment.user?.first_name?.[0]}
              {comment.user?.last_name?.[0]}
            </div>
            <div className="flex-1">
              <div className="flex items-center gap-2">
                <span className="text-sm font-medium">
                  {comment.user?.first_name} {comment.user?.last_name}
                </span>
                <span className="text-xs text-gray-400">
                  {new Date(comment.created_at).toLocaleDateString()}
                </span>
                {comment.is_edited && (
                  <span className="text-xs text-gray-400">(edited)</span>
                )}
              </div>
              <p className="text-sm text-gray-700 mt-1">{comment.content}</p>
            </div>
          </div>
        ))}
      </div>

      {/* Add Comment Form */}
      <form onSubmit={handleSubmit} className="flex gap-2">
        <input
          type="text"
          value={newComment}
          onChange={(e) => setNewComment(e.target.value)}
          placeholder="Write a comment..."
          className="flex-1 px-3 py-2 text-sm border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary-500"
          disabled={isAddingComment}
        />
        <Button
          type="submit"
          size="sm"
          disabled={!newComment.trim() || isAddingComment}
          isLoading={isAddingComment}
        >
          <Send size={14} />
        </Button>
      </form>
    </div>
  );
});

// ============================================
// Checklist Section Component
// ============================================

interface ChecklistSectionProps {
  checklists: KanbanChecklist[] | undefined;
  onToggleItem: (itemUuid: string) => void;
  onAddChecklist: (name: string) => void;
  onAddItem: (checklistUuid: string, content: string) => void;
}

const ChecklistSection = memo(function ChecklistSection({
  checklists,
  onToggleItem,
  onAddChecklist,
  onAddItem,
}: ChecklistSectionProps) {
  const [showAddChecklist, setShowAddChecklist] = useState(false);
  const [newChecklistName, setNewChecklistName] = useState('');
  const [addingItemTo, setAddingItemTo] = useState<string | null>(null);
  const [newItemContent, setNewItemContent] = useState('');

  const handleAddChecklist = (e: React.FormEvent) => {
    e.preventDefault();
    if (newChecklistName.trim()) {
      onAddChecklist(newChecklistName.trim());
      setNewChecklistName('');
      setShowAddChecklist(false);
    }
  };

  const handleAddItem = (checklistUuid: string) => {
    if (newItemContent.trim()) {
      onAddItem(checklistUuid, newItemContent.trim());
      setNewItemContent('');
      setAddingItemTo(null);
    }
  };

  return (
    <div>
      <div className="flex items-center justify-between mb-3">
        <div className="flex items-center gap-2 text-sm text-gray-500">
          <CheckSquare size={14} />
          <span>Checklists</span>
        </div>
        <button
          onClick={() => setShowAddChecklist(true)}
          className="text-sm text-primary-600 hover:text-primary-700"
        >
          + Add checklist
        </button>
      </div>

      {/* Add Checklist Form */}
      {showAddChecklist && (
        <form onSubmit={handleAddChecklist} className="mb-3 flex gap-2">
          <input
            type="text"
            value={newChecklistName}
            onChange={(e) => setNewChecklistName(e.target.value)}
            placeholder="Checklist name..."
            className="flex-1 px-3 py-2 text-sm border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary-500"
            autoFocus
          />
          <Button type="submit" size="sm" disabled={!newChecklistName.trim()}>
            Add
          </Button>
          <Button
            type="button"
            variant="ghost"
            size="sm"
            onClick={() => setShowAddChecklist(false)}
          >
            Cancel
          </Button>
        </form>
      )}

      {/* Checklist List */}
      <div className="space-y-4">
        {checklists?.map((checklist) => {
          const progress = checklist.item_count > 0
            ? Math.round((checklist.completed_item_count / checklist.item_count) * 100)
            : 0;

          return (
            <div key={checklist.uuid}>
              <div className="flex items-center justify-between mb-2">
                <span className="font-medium text-sm">{checklist.name}</span>
                <span className="text-xs text-gray-500">
                  {checklist.completed_item_count}/{checklist.item_count}
                </span>
              </div>

              {/* Progress Bar */}
              <div className="h-1.5 bg-gray-200 rounded-full mb-2">
                <div
                  className="h-full bg-green-500 rounded-full transition-all"
                  style={{ width: `${progress}%` }}
                />
              </div>

              {/* Items */}
              <div className="space-y-1">
                {checklist.items?.map((item) => (
                  <div
                    key={item.uuid}
                    className="flex items-center gap-2 p-1 hover:bg-gray-50 rounded"
                  >
                    <button
                      onClick={() => onToggleItem(item.uuid)}
                      className={cn(
                        'w-4 h-4 rounded border flex items-center justify-center',
                        item.is_completed
                          ? 'bg-green-500 border-green-500 text-white'
                          : 'border-gray-300'
                      )}
                    >
                      {item.is_completed && <Check size={12} />}
                    </button>
                    <span
                      className={cn(
                        'text-sm',
                        item.is_completed && 'line-through text-gray-400'
                      )}
                    >
                      {item.content}
                    </span>
                  </div>
                ))}

                {/* Add Item */}
                {addingItemTo === checklist.uuid ? (
                  <div className="flex gap-2 mt-2">
                    <input
                      type="text"
                      value={newItemContent}
                      onChange={(e) => setNewItemContent(e.target.value)}
                      placeholder="Add an item..."
                      className="flex-1 px-2 py-1 text-sm border border-gray-300 rounded focus:outline-none focus:ring-2 focus:ring-primary-500"
                      autoFocus
                      onKeyDown={(e) => {
                        if (e.key === 'Enter') handleAddItem(checklist.uuid);
                        if (e.key === 'Escape') setAddingItemTo(null);
                      }}
                    />
                    <Button size="sm" onClick={() => handleAddItem(checklist.uuid)}>
                      Add
                    </Button>
                  </div>
                ) : (
                  <button
                    onClick={() => setAddingItemTo(checklist.uuid)}
                    className="text-sm text-gray-500 hover:text-gray-700 mt-1"
                  >
                    + Add item
                  </button>
                )}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
});

// ============================================
// Main Task Detail Modal Component
// ============================================

export interface TaskDetailModalProps {
  isOpen: boolean;
  onClose: () => void;
  task: KanbanTask | null;
  members: KanbanProjectMember[];
  labels: KanbanLabel[];
  isLoading?: boolean;
  onUpdate: (uuid: string, data: UpdateKanbanTaskDto) => Promise<void>;
  onDelete: (uuid: string) => Promise<void>;
  onAddAssignee: (taskUuid: string, userUuid: string) => Promise<void>;
  onRemoveAssignee: (taskUuid: string, userUuid: string) => Promise<void>;
  onAddLabel: (taskUuid: string, labelId: number) => Promise<void>;
  onRemoveLabel: (taskUuid: string, labelId: number) => Promise<void>;
  onAddComment: (taskUuid: string, content: string) => Promise<void>;
  onDeleteComment: (commentUuid: string) => Promise<void>;
  onToggleChecklistItem: (itemUuid: string) => Promise<void>;
  onAddChecklist: (taskUuid: string, name: string) => Promise<void>;
  onAddChecklistItem: (checklistUuid: string, content: string) => Promise<void>;
}

const TaskDetailModal = memo(function TaskDetailModal({
  isOpen,
  onClose,
  task,
  members,
  labels,
  isLoading,
  onUpdate,
  onDelete,
  onAddAssignee,
  onRemoveAssignee,
  onAddLabel,
  onRemoveLabel,
  onAddComment,
  onDeleteComment,
  onToggleChecklistItem,
  onAddChecklist,
  onAddChecklistItem,
}: TaskDetailModalProps) {
  const [isEditing, setIsEditing] = useState(false);
  const [editedTitle, setEditedTitle] = useState('');
  const [editedDescription, setEditedDescription] = useState('');
  const [showMenu, setShowMenu] = useState(false);

  useEffect(() => {
    if (task) {
      setEditedTitle(task.title);
      setEditedDescription(task.description || '');
    }
  }, [task]);

  const handleSave = async () => {
    if (task && editedTitle.trim()) {
      await onUpdate(task.uuid, {
        title: editedTitle.trim(),
        description: editedDescription.trim() || undefined,
      });
      setIsEditing(false);
    }
  };

  const handlePriorityChange = async (priority: KanbanTaskPriority) => {
    if (task) {
      await onUpdate(task.uuid, { priority });
    }
  };

  const handleStatusChange = async (status: KanbanTaskStatus) => {
    if (task) {
      await onUpdate(task.uuid, { status });
    }
  };

  const handleDelete = async () => {
    if (task && window.confirm('Are you sure you want to delete this task?')) {
      await onDelete(task.uuid);
      onClose();
    }
  };

  if (!task) return null;

  const overdue = isTaskOverdue(task);

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="" size="xl">
      <div className="flex flex-col lg:flex-row gap-6 max-h-[80vh]">
        {/* Main Content */}
        <div className="flex-1 overflow-y-auto pr-4">
          {/* Header */}
          <div className="mb-4">
            <div className="flex items-start gap-2">
              <span className="text-sm text-gray-400 font-mono mt-1">
                #{task.task_number}
              </span>
              {isEditing ? (
                <div className="flex-1">
                  <input
                    type="text"
                    value={editedTitle}
                    onChange={(e) => setEditedTitle(e.target.value)}
                    className="w-full text-xl font-bold px-2 py-1 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary-500"
                    autoFocus
                  />
                </div>
              ) : (
                <h2 className="text-xl font-bold text-gray-900 flex-1">
                  {task.title}
                </h2>
              )}

              {/* Menu */}
              <div className="relative">
                <button
                  onClick={() => setShowMenu(!showMenu)}
                  className="p-1 rounded hover:bg-gray-100"
                >
                  <MoreHorizontal size={20} />
                </button>
                {showMenu && (
                  <>
                    <div className="fixed inset-0 z-10" onClick={() => setShowMenu(false)} />
                    <div className="absolute right-0 mt-1 w-40 bg-white rounded-lg shadow-lg border border-gray-200 py-1 z-20">
                      <button
                        onClick={() => {
                          setIsEditing(true);
                          setShowMenu(false);
                        }}
                        className="w-full flex items-center gap-2 px-3 py-2 text-sm hover:bg-gray-50"
                      >
                        <Edit2 size={14} />
                        Edit
                      </button>
                      <button
                        onClick={() => {
                          navigator.clipboard.writeText(task.uuid);
                          setShowMenu(false);
                        }}
                        className="w-full flex items-center gap-2 px-3 py-2 text-sm hover:bg-gray-50"
                      >
                        <Copy size={14} />
                        Copy ID
                      </button>
                      <button
                        onClick={handleDelete}
                        className="w-full flex items-center gap-2 px-3 py-2 text-sm text-red-600 hover:bg-red-50"
                      >
                        <Trash2 size={14} />
                        Delete
                      </button>
                    </div>
                  </>
                )}
              </div>
            </div>

            {/* Status & Priority */}
            <div className="flex items-center gap-3 mt-3">
              <StatusSelector value={task.status} onChange={handleStatusChange} />
              <PrioritySelector value={task.priority} onChange={handlePriorityChange} />
              {overdue && (
                <span className="text-sm text-red-600 font-medium">Overdue</span>
              )}
            </div>
          </div>

          {/* Description */}
          <div className="mb-6">
            <h3 className="text-sm font-medium text-gray-700 mb-2">Description</h3>
            {isEditing ? (
              <textarea
                value={editedDescription}
                onChange={(e) => setEditedDescription(e.target.value)}
                placeholder="Add a description..."
                className="w-full px-3 py-2 border border-gray-300 rounded-lg resize-none focus:outline-none focus:ring-2 focus:ring-primary-500"
                rows={4}
              />
            ) : (
              <p className="text-sm text-gray-600 whitespace-pre-wrap">
                {task.description || 'No description'}
              </p>
            )}
            {isEditing && (
              <div className="flex gap-2 mt-2">
                <Button size="sm" onClick={handleSave}>
                  Save
                </Button>
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => {
                    setIsEditing(false);
                    setEditedTitle(task.title);
                    setEditedDescription(task.description || '');
                  }}
                >
                  Cancel
                </Button>
              </div>
            )}
          </div>

          {/* Checklists */}
          <div className="mb-6">
            <ChecklistSection
              checklists={task.checklists}
              onToggleItem={onToggleChecklistItem}
              onAddChecklist={(name) => onAddChecklist(task.uuid, name)}
              onAddItem={onAddChecklistItem}
            />
          </div>

          {/* Comments */}
          <div>
            <CommentsSection
              comments={task.comments}
              onAddComment={(content) => onAddComment(task.uuid, content)}
              onDeleteComment={onDeleteComment}
            />
          </div>
        </div>

        {/* Sidebar */}
        <div className="w-full lg:w-72 space-y-6 border-t lg:border-t-0 lg:border-l border-gray-200 pt-4 lg:pt-0 lg:pl-6">
          {/* Assignees */}
          <AssigneesSection
            assignees={task.assignees}
            members={members}
            onAdd={(userUuid) => onAddAssignee(task.uuid, userUuid)}
            onRemove={(userUuid) => onRemoveAssignee(task.uuid, userUuid)}
          />

          {/* Labels */}
          <LabelsSection
            taskLabels={task.labels}
            projectLabels={labels}
            onAdd={(labelId) => onAddLabel(task.uuid, labelId)}
            onRemove={(labelId) => onRemoveLabel(task.uuid, labelId)}
          />

          {/* Due Date */}
          <div>
            <div className="flex items-center gap-2 text-sm text-gray-500 mb-2">
              <Calendar size={14} />
              <span>Due date</span>
            </div>
            <input
              type="date"
              value={task.due_date?.split('T')[0] || ''}
              onChange={(e) =>
                onUpdate(task.uuid, { due_date: e.target.value || undefined })
              }
              className="w-full px-3 py-2 text-sm border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary-500"
            />
          </div>

          {/* Time Tracking */}
          <div>
            <div className="flex items-center gap-2 text-sm text-gray-500 mb-2">
              <Clock size={14} />
              <span>Time tracking</span>
            </div>
            <div className="flex items-center gap-2 text-sm">
              <span className="text-gray-600">
                Spent: {formatTimeMinutes(task.time_spent_minutes || 0)}
              </span>
              {task.time_estimate_minutes && (
                <>
                  <span className="text-gray-400">/</span>
                  <span className="text-gray-600">
                    Est: {formatTimeMinutes(task.time_estimate_minutes)}
                  </span>
                </>
              )}
            </div>
          </div>

          {/* Story Points */}
          <div>
            <div className="flex items-center gap-2 text-sm text-gray-500 mb-2">
              <span>Story points</span>
            </div>
            <input
              type="number"
              min="0"
              value={task.story_points || ''}
              onChange={(e) =>
                onUpdate(task.uuid, {
                  story_points: e.target.value ? parseInt(e.target.value) : undefined,
                })
              }
              placeholder="0"
              className="w-20 px-3 py-2 text-sm border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary-500"
            />
          </div>

          {/* Activity */}
          <div>
            <div className="flex items-center gap-2 text-sm text-gray-500 mb-2">
              <Activity size={14} />
              <span>Activity</span>
            </div>
            <div className="text-xs text-gray-400">
              <p>Created {new Date(task.created_at).toLocaleDateString()}</p>
              <p>Updated {new Date(task.updated_at).toLocaleDateString()}</p>
            </div>
          </div>
        </div>
      </div>
    </Modal>
  );
});

export default TaskDetailModal;

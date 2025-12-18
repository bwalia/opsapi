'use client';

import React, { memo, useState, useCallback } from 'react';
import { Plus, MoreHorizontal, Edit2, Trash2, AlertCircle } from 'lucide-react';
import { useDroppable } from '@dnd-kit/core';
import {
  SortableContext,
  verticalListSortingStrategy,
} from '@dnd-kit/sortable';
import { cn } from '@/lib/utils';
import type { KanbanColumn as KanbanColumnType, KanbanTask } from '@/types';
import KanbanTaskCard from './KanbanTaskCard';
import Button from '@/components/ui/Button';

// ============================================
// Column Header Component
// ============================================

interface ColumnHeaderProps {
  column: KanbanColumnType;
  taskCount: number;
  onEdit?: (column: KanbanColumnType) => void;
  onDelete?: (column: KanbanColumnType) => void;
  onAddTask?: () => void;
}

const ColumnHeader = memo(function ColumnHeader({
  column,
  taskCount,
  onEdit,
  onDelete,
  onAddTask,
}: ColumnHeaderProps) {
  const [showMenu, setShowMenu] = useState(false);

  const handleMenuToggle = (e: React.MouseEvent) => {
    e.stopPropagation();
    setShowMenu(!showMenu);
  };

  const handleEdit = (e: React.MouseEvent) => {
    e.stopPropagation();
    setShowMenu(false);
    onEdit?.(column);
  };

  const handleDelete = (e: React.MouseEvent) => {
    e.stopPropagation();
    setShowMenu(false);
    onDelete?.(column);
  };

  const isOverWipLimit = column.wip_limit && taskCount > column.wip_limit;

  return (
    <div className="flex items-center justify-between px-3 py-2 bg-gray-50 rounded-t-lg border-b border-gray-200">
      <div className="flex items-center gap-2 min-w-0">
        {/* Column Color Indicator */}
        {column.color && (
          <div
            className="w-3 h-3 rounded-full flex-shrink-0"
            style={{ backgroundColor: column.color }}
          />
        )}

        {/* Column Name */}
        <h3 className="font-semibold text-gray-700 text-sm truncate">
          {column.name}
        </h3>

        {/* Task Count */}
        <span
          className={cn(
            'flex-shrink-0 text-xs font-medium px-2 py-0.5 rounded-full',
            isOverWipLimit
              ? 'bg-red-100 text-red-700'
              : 'bg-gray-200 text-gray-600'
          )}
        >
          {taskCount}
          {column.wip_limit && `/${column.wip_limit}`}
        </span>

        {/* WIP Limit Warning */}
        {isOverWipLimit && (
          <AlertCircle size={14} className="text-red-500 flex-shrink-0" />
        )}

        {/* Done Column Indicator */}
        {column.is_done_column && (
          <span className="text-xs text-green-600 bg-green-100 px-1.5 py-0.5 rounded">
            Done
          </span>
        )}
      </div>

      <div className="flex items-center gap-1">
        {/* Add Task Button */}
        <button
          onClick={onAddTask}
          className="p-1 rounded hover:bg-gray-200 text-gray-500 hover:text-gray-700 transition-colors"
          title="Add task"
        >
          <Plus size={16} />
        </button>

        {/* Menu Button */}
        <div className="relative">
          <button
            onClick={handleMenuToggle}
            className="p-1 rounded hover:bg-gray-200 text-gray-500 hover:text-gray-700 transition-colors"
          >
            <MoreHorizontal size={16} />
          </button>

          {/* Dropdown Menu */}
          {showMenu && (
            <>
              <div
                className="fixed inset-0 z-10"
                onClick={() => setShowMenu(false)}
              />
              <div className="absolute right-0 mt-1 w-36 bg-white rounded-lg shadow-lg border border-gray-200 py-1 z-20">
                <button
                  onClick={handleEdit}
                  className="w-full flex items-center gap-2 px-3 py-2 text-sm text-gray-700 hover:bg-gray-50"
                >
                  <Edit2 size={14} />
                  Edit column
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
    </div>
  );
});

// ============================================
// Add Task Inline Component
// ============================================

interface AddTaskInlineProps {
  onSubmit: (title: string) => void;
  onCancel: () => void;
  isLoading?: boolean;
}

const AddTaskInline = memo(function AddTaskInline({
  onSubmit,
  onCancel,
  isLoading,
}: AddTaskInlineProps) {
  const [title, setTitle] = useState('');

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (title.trim()) {
      onSubmit(title.trim());
      setTitle('');
    }
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Escape') {
      onCancel();
    }
  };

  return (
    <form onSubmit={handleSubmit} className="p-2">
      <textarea
        value={title}
        onChange={(e) => setTitle(e.target.value)}
        onKeyDown={handleKeyDown}
        placeholder="Enter task title..."
        className="w-full px-3 py-2 text-sm border border-gray-300 rounded-lg resize-none focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-transparent"
        rows={2}
        autoFocus
        disabled={isLoading}
      />
      <div className="flex items-center gap-2 mt-2">
        <Button
          type="submit"
          size="sm"
          disabled={!title.trim() || isLoading}
          isLoading={isLoading}
        >
          Add
        </Button>
        <Button
          type="button"
          variant="ghost"
          size="sm"
          onClick={onCancel}
          disabled={isLoading}
        >
          Cancel
        </Button>
      </div>
    </form>
  );
});

// ============================================
// Main Column Component
// ============================================

export interface KanbanColumnProps {
  column: KanbanColumnType & { tasks: KanbanTask[] };
  onTaskClick?: (task: KanbanTask) => void;
  onEditColumn?: (column: KanbanColumnType) => void;
  onDeleteColumn?: (column: KanbanColumnType) => void;
  onAddTask?: (columnId: number, title: string) => Promise<void>;
  className?: string;
}

const KanbanColumn = memo(function KanbanColumn({
  column,
  onTaskClick,
  onEditColumn,
  onDeleteColumn,
  onAddTask,
  className,
}: KanbanColumnProps) {
  const [isAddingTask, setIsAddingTask] = useState(false);
  const [isCreating, setIsCreating] = useState(false);

  // Make this column a drop target
  const { setNodeRef, isOver } = useDroppable({
    id: `column-${column.uuid}`,
    data: {
      type: 'column',
      column,
    },
  });

  const handleAddTaskClick = useCallback(() => {
    setIsAddingTask(true);
  }, []);

  const handleAddTaskSubmit = useCallback(
    async (title: string) => {
      if (onAddTask) {
        setIsCreating(true);
        try {
          await onAddTask(column.id, title);
          setIsAddingTask(false);
        } finally {
          setIsCreating(false);
        }
      }
    },
    [onAddTask, column.id]
  );

  const handleAddTaskCancel = useCallback(() => {
    setIsAddingTask(false);
  }, []);

  // Sort tasks by position
  const sortedTasks = [...column.tasks].sort((a, b) => a.position - b.position);

  // Get task IDs for sortable context
  const taskIds = sortedTasks.map((task) => task.uuid);

  return (
    <div
      className={cn(
        'flex flex-col w-72 min-w-72 bg-gray-100 rounded-lg',
        'max-h-full transition-all duration-200',
        isOver && 'ring-2 ring-primary-400 ring-opacity-50 bg-primary-50',
        className
      )}
    >
      {/* Column Header */}
      <ColumnHeader
        column={column}
        taskCount={column.tasks.length}
        onEdit={onEditColumn}
        onDelete={onDeleteColumn}
        onAddTask={handleAddTaskClick}
      />

      {/* Tasks Container with Droppable Area */}
      <div
        ref={setNodeRef}
        className={cn(
          'flex-1 overflow-y-auto p-2 space-y-2 min-h-[100px] transition-colors',
          isOver && 'bg-primary-50/50'
        )}
      >
        <SortableContext items={taskIds} strategy={verticalListSortingStrategy}>
          {sortedTasks.map((task) => (
            <KanbanTaskCard
              key={task.uuid}
              task={task}
              onClick={onTaskClick}
            />
          ))}
        </SortableContext>

        {/* Empty State */}
        {sortedTasks.length === 0 && !isAddingTask && (
          <div
            className={cn(
              'text-center py-8 text-gray-400 text-sm border-2 border-dashed border-gray-200 rounded-lg transition-colors',
              isOver && 'border-primary-300 bg-primary-50 text-primary-500'
            )}
          >
            {isOver ? 'Drop here' : 'No tasks yet'}
          </div>
        )}

        {/* Add Task Inline Form */}
        {isAddingTask && (
          <AddTaskInline
            onSubmit={handleAddTaskSubmit}
            onCancel={handleAddTaskCancel}
            isLoading={isCreating}
          />
        )}
      </div>

      {/* Add Task Footer */}
      {!isAddingTask && (
        <button
          onClick={handleAddTaskClick}
          className="flex items-center gap-2 px-3 py-2 text-sm text-gray-500 hover:text-gray-700 hover:bg-gray-200 rounded-b-lg transition-colors"
        >
          <Plus size={16} />
          Add a task
        </button>
      )}
    </div>
  );
});

export default KanbanColumn;

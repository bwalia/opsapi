'use client';

import React, { memo, useMemo, forwardRef } from 'react';
import {
  Calendar,
  MessageSquare,
  Paperclip,
  CheckSquare,
  Clock,
  AlertTriangle,
  ArrowUp,
  ArrowDown,
  Minus,
  Circle,
  User,
  GripVertical,
} from 'lucide-react';
import { useSortable } from '@dnd-kit/sortable';
import { CSS } from '@dnd-kit/utilities';
import { cn } from '@/lib/utils';
import type { KanbanTask, KanbanTaskPriority } from '@/types';
import {
  isTaskOverdue,
  getDaysUntilDue,
  formatTimeMinutes,
} from '@/services/kanban.service';

// ============================================
// Priority Icon Component
// ============================================

const PriorityIcon = memo(function PriorityIcon({
  priority,
  className,
}: {
  priority: KanbanTaskPriority;
  className?: string;
}) {
  const iconProps = { size: 14, className };

  switch (priority) {
    case 'critical':
      return <AlertTriangle {...iconProps} className={cn(iconProps.className, 'text-red-500')} />;
    case 'high':
      return <ArrowUp {...iconProps} className={cn(iconProps.className, 'text-orange-500')} />;
    case 'medium':
      return <Minus {...iconProps} className={cn(iconProps.className, 'text-yellow-500')} />;
    case 'low':
      return <ArrowDown {...iconProps} className={cn(iconProps.className, 'text-blue-500')} />;
    default:
      return <Circle {...iconProps} className={cn(iconProps.className, 'text-gray-400')} />;
  }
});

// ============================================
// Assignee Avatars Component
// ============================================

const AssigneeAvatars = memo(function AssigneeAvatars({
  assignees,
  maxDisplay = 3,
}: {
  assignees: KanbanTask['assignees'];
  maxDisplay?: number;
}) {
  if (!assignees || assignees.length === 0) return null;

  const displayed = assignees.slice(0, maxDisplay);
  const remaining = assignees.length - maxDisplay;

  return (
    <div className="flex -space-x-2">
      {displayed.map((assignee) => {
        const initials = assignee.user
          ? `${assignee.user.first_name?.[0] || ''}${assignee.user.last_name?.[0] || ''}`
          : '?';
        return (
          <div
            key={assignee.uuid}
            className="w-6 h-6 rounded-full bg-primary-100 text-primary-700 text-xs font-medium flex items-center justify-center border-2 border-white"
            title={assignee.user ? `${assignee.user.first_name} ${assignee.user.last_name}` : 'Unknown'}
          >
            {initials.toUpperCase()}
          </div>
        );
      })}
      {remaining > 0 && (
        <div className="w-6 h-6 rounded-full bg-gray-100 text-gray-600 text-xs font-medium flex items-center justify-center border-2 border-white">
          +{remaining}
        </div>
      )}
    </div>
  );
});

// ============================================
// Label Tags Component
// ============================================

const LabelTags = memo(function LabelTags({
  labels,
  maxDisplay = 3,
}: {
  labels: KanbanTask['labels'];
  maxDisplay?: number;
}) {
  if (!labels || labels.length === 0) return null;

  const displayed = labels.slice(0, maxDisplay);
  const remaining = labels.length - maxDisplay;

  return (
    <div className="flex flex-wrap gap-1">
      {displayed.map((label) => (
        <span
          key={label.uuid}
          className="inline-block px-2 py-0.5 text-xs font-medium rounded-full"
          style={{
            backgroundColor: `${label.color}20`,
            color: label.color,
          }}
        >
          {label.name}
        </span>
      ))}
      {remaining > 0 && (
        <span className="inline-block px-2 py-0.5 text-xs font-medium rounded-full bg-gray-100 text-gray-600">
          +{remaining}
        </span>
      )}
    </div>
  );
});

// ============================================
// Due Date Badge Component
// ============================================

const DueDateBadge = memo(function DueDateBadge({
  dueDate,
  status,
}: {
  dueDate: string;
  status: KanbanTask['status'];
}) {
  const isCompleted = status === 'completed' || status === 'cancelled';
  const daysUntil = getDaysUntilDue(dueDate);
  const overdue = !isCompleted && daysUntil < 0;
  const dueSoon = !isCompleted && daysUntil >= 0 && daysUntil <= 2;

  const formattedDate = new Date(dueDate).toLocaleDateString('en-US', {
    month: 'short',
    day: 'numeric',
  });

  return (
    <div
      className={cn(
        'flex items-center gap-1 text-xs',
        overdue && 'text-red-600',
        dueSoon && !overdue && 'text-orange-600',
        !overdue && !dueSoon && 'text-gray-500',
        isCompleted && 'text-gray-400 line-through'
      )}
    >
      <Calendar size={12} />
      <span>{formattedDate}</span>
      {overdue && <span className="font-medium">(Overdue)</span>}
    </div>
  );
});

// ============================================
// Task Metadata Component
// ============================================

const TaskMetadata = memo(function TaskMetadata({ task }: { task: KanbanTask }) {
  const showComments = task.comment_count > 0;
  const showAttachments = task.attachment_count > 0;
  const showChecklist = task.subtask_count > 0 || (task.checklists && task.checklists.length > 0);
  const showTimeEstimate = task.time_estimate_minutes && task.time_estimate_minutes > 0;

  const checklistProgress = useMemo(() => {
    if (task.subtask_count > 0) {
      return { completed: task.completed_subtask_count, total: task.subtask_count };
    }
    if (task.checklists && task.checklists.length > 0) {
      const total = task.checklists.reduce((sum, c) => sum + c.item_count, 0);
      const completed = task.checklists.reduce((sum, c) => sum + c.completed_item_count, 0);
      return { completed, total };
    }
    return null;
  }, [task]);

  if (!showComments && !showAttachments && !showChecklist && !showTimeEstimate) {
    return null;
  }

  return (
    <div className="flex items-center gap-3 text-xs text-gray-500">
      {showComments && (
        <div className="flex items-center gap-1" title={`${task.comment_count} comments`}>
          <MessageSquare size={12} />
          <span>{task.comment_count}</span>
        </div>
      )}
      {showAttachments && (
        <div className="flex items-center gap-1" title={`${task.attachment_count} attachments`}>
          <Paperclip size={12} />
          <span>{task.attachment_count}</span>
        </div>
      )}
      {showChecklist && checklistProgress && (
        <div
          className={cn(
            'flex items-center gap-1',
            checklistProgress.completed === checklistProgress.total && 'text-green-600'
          )}
          title={`${checklistProgress.completed}/${checklistProgress.total} completed`}
        >
          <CheckSquare size={12} />
          <span>
            {checklistProgress.completed}/{checklistProgress.total}
          </span>
        </div>
      )}
      {showTimeEstimate && (
        <div className="flex items-center gap-1" title="Time estimate">
          <Clock size={12} />
          <span>{formatTimeMinutes(task.time_estimate_minutes!)}</span>
        </div>
      )}
    </div>
  );
});

// ============================================
// Base Task Card Component (for drag overlay)
// ============================================

export interface KanbanTaskCardProps {
  task: KanbanTask;
  onClick?: (task: KanbanTask) => void;
  isDragging?: boolean;
  isOverlay?: boolean;
  className?: string;
}

export const BaseTaskCard = forwardRef<HTMLDivElement, KanbanTaskCardProps & {
  dragHandleProps?: React.HTMLAttributes<HTMLDivElement>;
  style?: React.CSSProperties;
}>(function BaseTaskCard(
  { task, onClick, isDragging = false, isOverlay = false, className, dragHandleProps, style },
  ref
) {
  const overdue = isTaskOverdue(task);

  const handleClick = (e: React.MouseEvent) => {
    // Don't trigger click when dragging
    if (isDragging) return;
    onClick?.(task);
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      onClick?.(task);
    }
  };

  const combinedStyle = task.cover_color
    ? { borderTopColor: task.cover_color, ...style }
    : style;

  return (
    <div
      ref={ref}
      role="button"
      tabIndex={0}
      onClick={handleClick}
      onKeyDown={handleKeyDown}
      style={combinedStyle}
      className={cn(
        'relative bg-white rounded-lg border shadow-sm p-3 cursor-pointer transition-all',
        'hover:shadow-md hover:border-primary-200',
        'focus:outline-none focus:ring-2 focus:ring-primary-500 focus:ring-offset-1',
        isDragging && 'shadow-lg opacity-50',
        isOverlay && 'shadow-2xl rotate-3 scale-105',
        overdue && 'border-l-4 border-l-red-500',
        task.cover_color && 'border-t-4',
        className
      )}
    >
      {/* Drag Handle */}
      <div
        {...dragHandleProps}
        className="absolute top-2 right-2 p-1 rounded opacity-0 hover:opacity-100 hover:bg-gray-100 cursor-grab active:cursor-grabbing transition-opacity"
      >
        <GripVertical size={14} className="text-gray-400" />
      </div>

      {/* Cover Image */}
      {task.cover_image_url && (
        <div className="relative -mx-3 -mt-3 mb-3 rounded-t-lg overflow-hidden">
          <img
            src={task.cover_image_url}
            alt=""
            className="w-full h-24 object-cover"
          />
        </div>
      )}

      {/* Labels */}
      <LabelTags labels={task.labels} />

      {/* Title */}
      <h4 className="font-medium text-gray-900 text-sm mt-2 line-clamp-2">
        {task.title}
      </h4>

      {/* Task Number & Priority */}
      <div className="flex items-center justify-between mt-2">
        <span className="text-xs text-gray-400 font-mono">#{task.task_number}</span>
        <PriorityIcon priority={task.priority} />
      </div>

      {/* Due Date */}
      {task.due_date && (
        <div className="mt-2">
          <DueDateBadge dueDate={task.due_date} status={task.status} />
        </div>
      )}

      {/* Metadata */}
      <div className="mt-2">
        <TaskMetadata task={task} />
      </div>

      {/* Footer: Assignees & Story Points */}
      <div className="flex items-center justify-between mt-3 pt-2 border-t border-gray-100">
        <AssigneeAvatars assignees={task.assignees} />
        {task.story_points && task.story_points > 0 && (
          <span className="text-xs font-medium text-gray-500 bg-gray-100 px-2 py-0.5 rounded">
            {task.story_points} pts
          </span>
        )}
        {!task.assignees?.length && !task.story_points && (
          <div className="flex items-center text-gray-400">
            <User size={14} />
          </div>
        )}
      </div>
    </div>
  );
});

// ============================================
// Sortable Task Card Component (with dnd-kit)
// ============================================

const SortableTaskCard = memo(function SortableTaskCard({
  task,
  onClick,
  className,
}: KanbanTaskCardProps) {
  const {
    attributes,
    listeners,
    setNodeRef,
    transform,
    transition,
    isDragging,
  } = useSortable({
    id: task.uuid,
    data: {
      type: 'task',
      task,
    },
  });

  const style = {
    transform: CSS.Transform.toString(transform),
    transition,
  };

  return (
    <BaseTaskCard
      ref={setNodeRef}
      task={task}
      onClick={onClick}
      isDragging={isDragging}
      className={className}
      style={style}
      dragHandleProps={{ ...attributes, ...listeners }}
    />
  );
});

// ============================================
// Main Task Card Component (wrapper)
// ============================================

const KanbanTaskCard = memo(function KanbanTaskCard(props: KanbanTaskCardProps) {
  // If isOverlay, render base card without sortable
  if (props.isOverlay) {
    return <BaseTaskCard {...props} />;
  }

  // Otherwise render sortable card
  return <SortableTaskCard {...props} />;
});

export default KanbanTaskCard;

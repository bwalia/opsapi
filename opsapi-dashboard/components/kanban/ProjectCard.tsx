'use client';

import React, { memo } from 'react';
import {
  Star,
  Users,
  Calendar,
  DollarSign,
  CheckCircle,
  Clock,
  MoreHorizontal,
  Edit2,
  Trash2,
  Archive,
  Settings,
} from 'lucide-react';
import { cn } from '@/lib/utils';
import type { KanbanProject } from '@/types';
import {
  formatBudget,
  getBudgetProgress,
  getProjectStatusColor,
  formatProjectStatus,
} from '@/services/kanban.service';

// ============================================
// Progress Bar Component
// ============================================

const ProgressBar = memo(function ProgressBar({
  completed,
  total,
  className,
}: {
  completed: number;
  total: number;
  className?: string;
}) {
  const percentage = total > 0 ? Math.round((completed / total) * 100) : 0;

  return (
    <div className={cn('space-y-1', className)}>
      <div className="flex items-center justify-between text-xs text-gray-500">
        <span>{completed} of {total} tasks</span>
        <span>{percentage}%</span>
      </div>
      <div className="h-1.5 bg-gray-200 rounded-full overflow-hidden">
        <div
          className={cn(
            'h-full rounded-full transition-all',
            percentage === 100 ? 'bg-green-500' : 'bg-primary-500'
          )}
          style={{ width: `${percentage}%` }}
        />
      </div>
    </div>
  );
});

// ============================================
// Budget Progress Component
// ============================================

const BudgetProgress = memo(function BudgetProgress({
  spent,
  total,
  currency,
}: {
  spent: number;
  total: number;
  currency: string;
}) {
  const percentage = getBudgetProgress(spent, total);
  const isOverBudget = spent > total;

  if (total <= 0) return null;

  return (
    <div className="space-y-1">
      <div className="flex items-center justify-between text-xs">
        <span className="text-gray-500 flex items-center gap-1">
          <DollarSign size={12} />
          Budget
        </span>
        <span className={cn(isOverBudget ? 'text-red-600' : 'text-gray-600')}>
          {formatBudget(spent, currency)} / {formatBudget(total, currency)}
        </span>
      </div>
      <div className="h-1.5 bg-gray-200 rounded-full overflow-hidden">
        <div
          className={cn(
            'h-full rounded-full transition-all',
            isOverBudget ? 'bg-red-500' : percentage > 80 ? 'bg-orange-500' : 'bg-green-500'
          )}
          style={{ width: `${Math.min(percentage, 100)}%` }}
        />
      </div>
    </div>
  );
});

// ============================================
// Project Card Menu Component
// ============================================

interface ProjectMenuProps {
  isOpen: boolean;
  onToggle: () => void;
  onEdit: () => void;
  onArchive: () => void;
  onSettings: () => void;
  onDelete: () => void;
}

const ProjectMenu = memo(function ProjectMenu({
  isOpen,
  onToggle,
  onEdit,
  onArchive,
  onSettings,
  onDelete,
}: ProjectMenuProps) {
  return (
    <div className="relative">
      <button
        onClick={(e) => {
          e.stopPropagation();
          onToggle();
        }}
        className="p-1 rounded hover:bg-gray-100 text-gray-400 hover:text-gray-600 transition-colors"
      >
        <MoreHorizontal size={18} />
      </button>

      {isOpen && (
        <>
          <div className="fixed inset-0 z-10" onClick={(e) => { e.stopPropagation(); onToggle(); }} />
          <div className="absolute right-0 mt-1 w-44 bg-white rounded-lg shadow-lg border border-gray-200 py-1 z-20">
            <button
              onClick={(e) => {
                e.stopPropagation();
                onEdit();
              }}
              className="w-full flex items-center gap-2 px-3 py-2 text-sm text-gray-700 hover:bg-gray-50"
            >
              <Edit2 size={14} />
              Edit project
            </button>
            <button
              onClick={(e) => {
                e.stopPropagation();
                onSettings();
              }}
              className="w-full flex items-center gap-2 px-3 py-2 text-sm text-gray-700 hover:bg-gray-50"
            >
              <Settings size={14} />
              Settings
            </button>
            <button
              onClick={(e) => {
                e.stopPropagation();
                onArchive();
              }}
              className="w-full flex items-center gap-2 px-3 py-2 text-sm text-gray-700 hover:bg-gray-50"
            >
              <Archive size={14} />
              Archive
            </button>
            <hr className="my-1" />
            <button
              onClick={(e) => {
                e.stopPropagation();
                onDelete();
              }}
              className="w-full flex items-center gap-2 px-3 py-2 text-sm text-red-600 hover:bg-red-50"
            >
              <Trash2 size={14} />
              Delete
            </button>
          </div>
        </>
      )}
    </div>
  );
});

// ============================================
// Main Project Card Component
// ============================================

export interface ProjectCardProps {
  project: KanbanProject;
  onClick?: (project: KanbanProject) => void;
  onStar?: (project: KanbanProject) => void;
  onEdit?: (project: KanbanProject) => void;
  onArchive?: (project: KanbanProject) => void;
  onSettings?: (project: KanbanProject) => void;
  onDelete?: (project: KanbanProject) => void;
  isStarred?: boolean;
  className?: string;
}

const ProjectCard = memo(function ProjectCard({
  project,
  onClick,
  onStar,
  onEdit,
  onArchive,
  onSettings,
  onDelete,
  isStarred = false,
  className,
}: ProjectCardProps) {
  const [menuOpen, setMenuOpen] = React.useState(false);

  const handleClick = () => {
    onClick?.(project);
  };

  const handleStarClick = (e: React.MouseEvent) => {
    e.stopPropagation();
    onStar?.(project);
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      onClick?.(project);
    }
  };

  const daysUntilDue = project.due_date
    ? Math.ceil(
        (new Date(project.due_date).getTime() - new Date().getTime()) /
          (1000 * 60 * 60 * 24)
      )
    : null;

  const isOverdue = daysUntilDue !== null && daysUntilDue < 0 && project.status !== 'completed';

  return (
    <div
      role="button"
      tabIndex={0}
      onClick={handleClick}
      onKeyDown={handleKeyDown}
      className={cn(
        'bg-white rounded-xl border shadow-sm p-5 cursor-pointer transition-all',
        'hover:shadow-md hover:border-primary-200',
        'focus:outline-none focus:ring-2 focus:ring-primary-500 focus:ring-offset-2',
        isOverdue && 'border-l-4 border-l-red-500',
        className
      )}
    >
      {/* Header */}
      <div className="flex items-start justify-between mb-3">
        <div className="flex items-center gap-3">
          {/* Project Color/Icon */}
          <div
            className="w-10 h-10 rounded-lg flex items-center justify-center text-white font-bold text-lg"
            style={{ backgroundColor: project.color || '#6366f1' }}
          >
            {project.icon || project.name[0].toUpperCase()}
          </div>

          <div>
            <h3 className="font-semibold text-gray-900">{project.name}</h3>
            <span
              className={cn(
                'inline-block text-xs px-2 py-0.5 rounded-full border mt-1',
                getProjectStatusColor(project.status)
              )}
            >
              {formatProjectStatus(project.status)}
            </span>
          </div>
        </div>

        <div className="flex items-center gap-1">
          {/* Star Button */}
          <button
            onClick={handleStarClick}
            className={cn(
              'p-1 rounded hover:bg-gray-100 transition-colors',
              isStarred ? 'text-yellow-500' : 'text-gray-400 hover:text-yellow-500'
            )}
          >
            <Star size={18} fill={isStarred ? 'currentColor' : 'none'} />
          </button>

          {/* Menu */}
          <ProjectMenu
            isOpen={menuOpen}
            onToggle={() => setMenuOpen(!menuOpen)}
            onEdit={() => {
              setMenuOpen(false);
              onEdit?.(project);
            }}
            onArchive={() => {
              setMenuOpen(false);
              onArchive?.(project);
            }}
            onSettings={() => {
              setMenuOpen(false);
              onSettings?.(project);
            }}
            onDelete={() => {
              setMenuOpen(false);
              onDelete?.(project);
            }}
          />
        </div>
      </div>

      {/* Description */}
      {project.description && (
        <p className="text-sm text-gray-500 line-clamp-2 mb-4">
          {project.description}
        </p>
      )}

      {/* Task Progress */}
      <ProgressBar
        completed={project.completed_task_count}
        total={project.task_count}
        className="mb-4"
      />

      {/* Budget Progress */}
      {project.budget > 0 && (
        <BudgetProgress
          spent={project.budget_spent}
          total={project.budget}
          currency={project.budget_currency}
        />
      )}

      {/* Footer */}
      <div className="flex items-center justify-between mt-4 pt-4 border-t border-gray-100">
        {/* Members */}
        <div className="flex items-center gap-1 text-sm text-gray-500">
          <Users size={14} />
          <span>{project.member_count} members</span>
        </div>

        {/* Due Date */}
        {project.due_date && (
          <div
            className={cn(
              'flex items-center gap-1 text-sm',
              isOverdue ? 'text-red-600' : 'text-gray-500'
            )}
          >
            <Calendar size={14} />
            <span>
              {new Date(project.due_date).toLocaleDateString('en-US', {
                month: 'short',
                day: 'numeric',
              })}
            </span>
          </div>
        )}
      </div>
    </div>
  );
});

export default ProjectCard;

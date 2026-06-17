'use client';

import React, { useEffect, useState, useCallback, useRef, useMemo } from 'react';
import { useParams, useRouter } from 'next/navigation';
import {
  ArrowLeft,
  Plus,
  ChevronDown,
  LayoutGrid,
  List,
  BarChart3,
  TrendingUp,
  Calendar,
  Target,
  Clock,
  CheckCircle2,
  XCircle,
  AlertTriangle,
  Search,
  Filter,
  GripVertical,
  MoreHorizontal,
  User,
  Loader2,
  Play,
  Square,
  ArrowRight,
  RefreshCw,
} from 'lucide-react';
import { toast } from 'react-hot-toast';
import Button from '@/components/ui/Button';
import Card from '@/components/ui/Card';
import { useKanbanStore } from '@/store/kanban.store';
import { sprintService, getSprintStatusColor, getSprintStatusLabel, calculateSprintProgress, calculateDaysRemaining, calculateSprintDuration, formatSprintDateRange } from '@/services/sprint.service';
import { kanbanService, getPriorityColor } from '@/services/kanban.service';
import type { KanbanSprint, KanbanTask, KanbanTaskPriority, KanbanLabel, KanbanProjectMember } from '@/types';
import { cn } from '@/lib/utils';

// ============================================
// Types
// ============================================

type ViewMode = 'board' | 'backlog' | 'burndown' | 'velocity';

interface SprintStats {
  total_tasks: number;
  completed_tasks: number;
  in_progress_tasks: number;
  total_points: number;
  completed_points: number;
  remaining_points: number;
  days_remaining: number;
  completion_rate: number;
}

interface BoardColumn {
  key: string;
  label: string;
  statuses: string[];
  color: string;
}

const BOARD_COLUMNS: BoardColumn[] = [
  { key: 'todo', label: 'To Do', statuses: ['open'], color: 'bg-secondary-400' },
  { key: 'in_progress', label: 'In Progress', statuses: ['in_progress'], color: 'bg-blue-500' },
  { key: 'in_review', label: 'In Review', statuses: ['review'], color: 'bg-purple-500' },
  { key: 'done', label: 'Done', statuses: ['completed'], color: 'bg-green-500' },
];

const FIBONACCI_POINTS = [1, 2, 3, 5, 8, 13];

const PRIORITY_DOT_COLORS: Record<string, string> = {
  critical: 'bg-red-500',
  high: 'bg-orange-500',
  medium: 'bg-yellow-500',
  low: 'bg-green-500',
  none: 'bg-secondary-400',
};

// ============================================
// Loading Skeleton
// ============================================

const LoadingSkeleton = () => (
  <div className="flex gap-4 p-6 animate-pulse">
    {[1, 2, 3, 4].map((i) => (
      <div key={i} className="w-72 flex-shrink-0">
        <div className="h-10 bg-secondary-200 rounded-lg mb-4" />
        <div className="space-y-3">
          {[1, 2, 3].map((j) => (
            <div key={j} className="h-28 bg-secondary-200 rounded-lg" />
          ))}
        </div>
      </div>
    ))}
  </div>
);

// ============================================
// Sprint Selector Component
// ============================================

interface SprintSelectorProps {
  sprints: KanbanSprint[];
  currentSprintUuid: string;
  onSprintChange: (uuid: string) => void;
}

const SprintSelector = React.memo(function SprintSelector({
  sprints,
  currentSprintUuid,
  onSprintChange,
}: SprintSelectorProps) {
  const [isOpen, setIsOpen] = useState(false);
  const currentSprint = sprints.find((s) => s.uuid === currentSprintUuid);

  return (
    <div className="relative">
      <button
        onClick={() => setIsOpen(!isOpen)}
        className="flex items-center gap-2 px-3 py-2 bg-surface border border-secondary-200 rounded-lg hover:bg-secondary-50 transition-colors"
      >
        <Target size={16} />
        <span className="font-medium text-sm">
          {currentSprint?.name || 'Select Sprint'}
        </span>
        {currentSprint && (
          <span className={cn('text-xs px-1.5 py-0.5 rounded-full', getSprintStatusColor(currentSprint.status))}>
            {getSprintStatusLabel(currentSprint.status)}
          </span>
        )}
        <ChevronDown size={16} />
      </button>

      {isOpen && (
        <>
          <div className="fixed inset-0 z-10" onClick={() => setIsOpen(false)} />
          <div className="absolute left-0 mt-1 w-72 bg-surface rounded-lg shadow-lg border border-secondary-200 py-1 z-20 max-h-80 overflow-y-auto">
            {sprints.length === 0 && (
              <div className="px-3 py-4 text-sm text-secondary-500 text-center">
                No sprints yet
              </div>
            )}
            {sprints.map((sprint) => (
              <button
                key={sprint.uuid}
                onClick={() => {
                  onSprintChange(sprint.uuid);
                  setIsOpen(false);
                }}
                className={cn(
                  'w-full flex items-center gap-2 px-3 py-2 text-sm hover:bg-secondary-50',
                  sprint.uuid === currentSprintUuid && 'bg-secondary-50 font-medium'
                )}
              >
                <Target size={14} />
                <span className="flex-1 text-left truncate">{sprint.name}</span>
                <span className={cn('text-xs px-1.5 py-0.5 rounded-full', getSprintStatusColor(sprint.status))}>
                  {getSprintStatusLabel(sprint.status)}
                </span>
              </button>
            ))}
          </div>
        </>
      )}
    </div>
  );
});

// ============================================
// View Toggle Component
// ============================================

interface ViewToggleProps {
  currentView: ViewMode;
  onChange: (view: ViewMode) => void;
}

const ViewToggle = React.memo(function ViewToggle({ currentView, onChange }: ViewToggleProps) {
  const views: { key: ViewMode; label: string; icon: React.ReactNode }[] = [
    { key: 'board', label: 'Board', icon: <LayoutGrid size={14} /> },
    { key: 'backlog', label: 'Backlog', icon: <List size={14} /> },
    { key: 'burndown', label: 'Burndown', icon: <BarChart3 size={14} /> },
    { key: 'velocity', label: 'Velocity', icon: <TrendingUp size={14} /> },
  ];

  return (
    <div className="flex items-center bg-secondary-100 rounded-lg p-0.5">
      {views.map((view) => (
        <button
          key={view.key}
          onClick={() => onChange(view.key)}
          className={cn(
            'flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium rounded-md transition-colors',
            currentView === view.key
              ? 'bg-surface text-secondary-900 shadow-sm'
              : 'text-secondary-600 hover:text-secondary-900'
          )}
        >
          {view.icon}
          {view.label}
        </button>
      ))}
    </div>
  );
});

// ============================================
// Task Card Component
// ============================================

interface TaskCardProps {
  task: KanbanTask;
  onDragStart: (e: React.DragEvent, task: KanbanTask) => void;
  onClick: (task: KanbanTask) => void;
}

const TaskCard = React.memo(function TaskCard({ task, onDragStart, onClick }: TaskCardProps) {
  return (
    <div
      draggable
      onDragStart={(e) => onDragStart(e, task)}
      onClick={() => onClick(task)}
      className="bg-surface border border-secondary-200 rounded-lg p-3 cursor-pointer hover:shadow-md transition-shadow group"
    >
      {/* Labels */}
      {task.labels && task.labels.length > 0 && (
        <div className="flex flex-wrap gap-1 mb-2">
          {task.labels.map((label) => (
            <span
              key={label.id}
              className="text-xs px-1.5 py-0.5 rounded-full text-white"
              style={{ backgroundColor: label.color || '#6b7280' }}
            >
              {label.name}
            </span>
          ))}
        </div>
      )}

      {/* Title */}
      <p className="text-sm font-medium text-secondary-900 mb-2 line-clamp-2">
        {task.title}
      </p>

      {/* Description snippet */}
      {task.description && (
        <p className="text-xs text-secondary-500 mb-2 line-clamp-1">
          {task.description}
        </p>
      )}

      {/* Bottom row */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          {/* Priority indicator */}
          <span
            className={cn('w-2 h-2 rounded-full', PRIORITY_DOT_COLORS[task.priority] || PRIORITY_DOT_COLORS.none)}
            title={task.priority}
          />

          {/* Story points badge */}
          {task.story_points != null && task.story_points > 0 && (
            <span className="text-xs bg-blue-100 text-blue-700 px-1.5 py-0.5 rounded font-medium">
              {task.story_points} SP
            </span>
          )}

          {/* Task number */}
          <span className="text-xs text-secondary-400">#{task.task_number}</span>
        </div>

        <div className="flex items-center gap-1">
          {/* Assignee avatar */}
          {task.assignees && task.assignees.length > 0 ? (
            <div className="flex -space-x-1">
              {task.assignees.slice(0, 2).map((assignee) => (
                <div
                  key={assignee.uuid || assignee.user_uuid}
                  className="w-6 h-6 rounded-full bg-primary-100 text-primary-700 flex items-center justify-center text-xs font-medium border-2 border-white"
                  title={`${assignee.user?.first_name || ''} ${assignee.user?.last_name || ''}`.trim()}
                >
                  {(assignee.user?.first_name?.[0] || assignee.user?.email?.[0] || 'U').toUpperCase()}
                </div>
              ))}
              {task.assignees.length > 2 && (
                <div className="w-6 h-6 rounded-full bg-secondary-200 text-secondary-600 flex items-center justify-center text-xs font-medium border-2 border-white">
                  +{task.assignees.length - 2}
                </div>
              )}
            </div>
          ) : (
            <User size={14} className="text-secondary-300" />
          )}
        </div>
      </div>
    </div>
  );
});

// ============================================
// Board Column Component
// ============================================

interface BoardColumnComponentProps {
  column: BoardColumn;
  tasks: KanbanTask[];
  onDragStart: (e: React.DragEvent, task: KanbanTask) => void;
  onDragOver: (e: React.DragEvent) => void;
  onDrop: (e: React.DragEvent, column: BoardColumn) => void;
  onTaskClick: (task: KanbanTask) => void;
  onAddTask: (status: string) => void;
}

const BoardColumnComponent = React.memo(function BoardColumnComponent({
  column,
  tasks,
  onDragStart,
  onDragOver,
  onDrop,
  onTaskClick,
  onAddTask,
}: BoardColumnComponentProps) {
  const totalPoints = tasks.reduce((sum, t) => sum + (t.story_points || 0), 0);

  return (
    <div
      className="flex-shrink-0 w-[280px] flex flex-col bg-secondary-50 rounded-lg"
      onDragOver={onDragOver}
      onDrop={(e) => onDrop(e, column)}
    >
      {/* Column header */}
      <div className="flex items-center justify-between px-3 py-2.5 border-b border-secondary-200">
        <div className="flex items-center gap-2">
          <div className={cn('w-2.5 h-2.5 rounded-full', column.color)} />
          <span className="text-sm font-semibold text-secondary-700">{column.label}</span>
          <span className="text-xs bg-secondary-200 text-secondary-600 px-1.5 py-0.5 rounded-full font-medium">
            {tasks.length}
          </span>
        </div>
        <div className="flex items-center gap-1">
          {totalPoints > 0 && (
            <span className="text-xs text-secondary-500">{totalPoints} pts</span>
          )}
          <button
            onClick={() => onAddTask(column.statuses[0])}
            className="p-1 rounded hover:bg-secondary-200 text-secondary-400 hover:text-secondary-600 transition-colors"
          >
            <Plus size={14} />
          </button>
        </div>
      </div>

      {/* Tasks */}
      <div className="flex-1 overflow-y-auto p-2 space-y-2 min-h-[200px]">
        {tasks.map((task) => (
          <TaskCard
            key={task.uuid}
            task={task}
            onDragStart={onDragStart}
            onClick={onTaskClick}
          />
        ))}
        {tasks.length === 0 && (
          <div className="flex items-center justify-center h-24 text-xs text-secondary-400">
            No tasks
          </div>
        )}
      </div>
    </div>
  );
});

// ============================================
// Sprint Info Banner
// ============================================

interface SprintInfoBannerProps {
  sprint: KanbanSprint;
  stats: SprintStats | null;
  onCompleteSprint: () => void;
  onCancelSprint: () => void;
  onStartSprint: () => void;
}

const SprintInfoBanner = React.memo(function SprintInfoBanner({
  sprint,
  stats,
  onCompleteSprint,
  onCancelSprint,
  onStartSprint,
}: SprintInfoBannerProps) {
  const daysRemaining = sprint.end_date ? calculateDaysRemaining(sprint.end_date) : 0;
  const totalDays = sprint.start_date && sprint.end_date
    ? calculateSprintDuration(sprint.start_date, sprint.end_date)
    : 0;
  const daysElapsed = totalDays - daysRemaining;
  const dayProgress = totalDays > 0 ? Math.min(100, Math.round((daysElapsed / totalDays) * 100)) : 0;
  const pointsProgress = stats ? calculateSprintProgress(stats.completed_points, stats.total_points) : 0;

  // Determine progress color
  let progressColor = 'bg-green-500';
  if (totalDays > 0 && stats) {
    const timeRatio = daysElapsed / totalDays;
    const pointsRatio = stats.total_points > 0 ? stats.completed_points / stats.total_points : 0;
    if (timeRatio > 0.5 && pointsRatio < timeRatio * 0.6) {
      progressColor = 'bg-red-500';
    } else if (timeRatio > 0.3 && pointsRatio < timeRatio * 0.8) {
      progressColor = 'bg-yellow-500';
    }
  }

  return (
    <Card className="mx-6 mt-4" padding="sm">
      <div className="flex flex-col lg:flex-row lg:items-center gap-4">
        {/* Sprint name and info */}
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 mb-1">
            <h2 className="text-base font-bold text-secondary-900 truncate">{sprint.name}</h2>
            <span className={cn('text-xs px-2 py-0.5 rounded-full font-medium', getSprintStatusColor(sprint.status))}>
              {getSprintStatusLabel(sprint.status)}
            </span>
          </div>
          {sprint.goal && (
            <p className="text-xs text-secondary-500 line-clamp-1 mb-2">{sprint.goal}</p>
          )}

          {/* Date range progress bar */}
          {sprint.start_date && sprint.end_date && (
            <div>
              <div className="flex items-center justify-between text-xs text-secondary-500 mb-1">
                <span>{formatSprintDateRange(sprint.start_date, sprint.end_date)}</span>
                <span>{daysElapsed} / {totalDays} days</span>
              </div>
              <div className="h-1.5 bg-secondary-200 rounded-full overflow-hidden">
                <div
                  className={cn('h-full rounded-full transition-all', progressColor)}
                  style={{ width: `${dayProgress}%` }}
                />
              </div>
            </div>
          )}
        </div>

        {/* Stats */}
        <div className="flex items-center gap-4 flex-shrink-0">
          <div className="text-center">
            <div className="text-lg font-bold text-secondary-900">
              {stats ? `${stats.completed_points}/${stats.total_points}` : '-'}
            </div>
            <div className="text-xs text-secondary-500">Story Points</div>
          </div>
          <div className="text-center">
            <div className="text-lg font-bold text-secondary-900">
              {stats ? `${stats.completed_tasks}/${stats.total_tasks}` : '-'}
            </div>
            <div className="text-xs text-secondary-500">Tasks</div>
          </div>
          <div className="text-center">
            <div className="text-lg font-bold text-secondary-900">{daysRemaining}</div>
            <div className="text-xs text-secondary-500">Days Left</div>
          </div>
          <div className="text-center">
            <div className="text-lg font-bold text-secondary-900">{pointsProgress}%</div>
            <div className="text-xs text-secondary-500">Complete</div>
          </div>
        </div>

        {/* Actions */}
        <div className="flex items-center gap-2 flex-shrink-0">
          {sprint.status === 'planned' && (
            <Button variant="primary" size="sm" onClick={onStartSprint}>
              <Play size={14} className="mr-1" />
              Start Sprint
            </Button>
          )}
          {sprint.status === 'active' && (
            <>
              <Button variant="primary" size="sm" onClick={onCompleteSprint}>
                <CheckCircle2 size={14} className="mr-1" />
                Complete
              </Button>
              <Button variant="ghost" size="sm" onClick={onCancelSprint}>
                <XCircle size={14} className="mr-1" />
                Cancel
              </Button>
            </>
          )}
        </div>
      </div>
    </Card>
  );
});

// ============================================
// Create Sprint Modal
// ============================================

interface CreateSprintModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSubmit: (data: { name: string; goal: string; start_date: string; end_date: string; capacity_points: number }) => void;
  isLoading: boolean;
}

const CreateSprintModal = React.memo(function CreateSprintModal({
  isOpen,
  onClose,
  onSubmit,
  isLoading,
}: CreateSprintModalProps) {
  const today = new Date();
  const twoWeeksLater = new Date(today);
  twoWeeksLater.setDate(twoWeeksLater.getDate() + 14);

  const [name, setName] = useState('');
  const [goal, setGoal] = useState('');
  const [startDate, setStartDate] = useState(today.toISOString().split('T')[0]);
  const [endDate, setEndDate] = useState(twoWeeksLater.toISOString().split('T')[0]);
  const [capacityPoints, setCapacityPoints] = useState(40);

  useEffect(() => {
    if (isOpen) {
      const now = new Date();
      const twoWeeks = new Date(now);
      twoWeeks.setDate(twoWeeks.getDate() + 14);
      setName('');
      setGoal('');
      setStartDate(now.toISOString().split('T')[0]);
      setEndDate(twoWeeks.toISOString().split('T')[0]);
      setCapacityPoints(40);
    }
  }, [isOpen]);

  const handleSubmit = useCallback((e: React.FormEvent) => {
    e.preventDefault();
    if (!name.trim()) {
      toast.error('Sprint name is required');
      return;
    }
    onSubmit({ name: name.trim(), goal: goal.trim(), start_date: startDate, end_date: endDate, capacity_points: capacityPoints });
  }, [name, goal, startDate, endDate, capacityPoints, onSubmit]);

  if (!isOpen) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      <div className="fixed inset-0 bg-black/50" onClick={onClose} />
      <div className="relative bg-surface rounded-xl shadow-xl w-full max-w-lg mx-4 p-6">
        <h2 className="text-lg font-bold text-secondary-900 mb-4">Create New Sprint</h2>
        <form onSubmit={handleSubmit} className="space-y-4">
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Sprint Name *</label>
            <input
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="e.g., Sprint 12"
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:ring-2 focus:ring-primary-500 focus:border-primary-500 outline-none"
              autoFocus
            />
          </div>

          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Goal</label>
            <textarea
              value={goal}
              onChange={(e) => setGoal(e.target.value)}
              placeholder="What do you want to achieve in this sprint?"
              rows={3}
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:ring-2 focus:ring-primary-500 focus:border-primary-500 outline-none resize-none"
            />
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">Start Date</label>
              <input
                type="date"
                value={startDate}
                onChange={(e) => setStartDate(e.target.value)}
                className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:ring-2 focus:ring-primary-500 focus:border-primary-500 outline-none"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">End Date</label>
              <input
                type="date"
                value={endDate}
                onChange={(e) => setEndDate(e.target.value)}
                className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:ring-2 focus:ring-primary-500 focus:border-primary-500 outline-none"
              />
            </div>
          </div>

          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Capacity (Story Points)</label>
            <input
              type="number"
              value={capacityPoints}
              onChange={(e) => setCapacityPoints(parseInt(e.target.value) || 0)}
              min={0}
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:ring-2 focus:ring-primary-500 focus:border-primary-500 outline-none"
            />
          </div>

          <div className="flex justify-end gap-2 pt-2">
            <Button variant="ghost" size="sm" type="button" onClick={onClose}>
              Cancel
            </Button>
            <Button variant="primary" size="sm" type="submit" isLoading={isLoading}>
              Create Sprint
            </Button>
          </div>
        </form>
      </div>
    </div>
  );
});

// ============================================
// Complete Sprint Modal
// ============================================

interface CompleteSprintModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSubmit: (data: { went_well: string; to_improve: string; action_items: string; move_remaining: 'next_sprint' | 'backlog' }) => void;
  sprint: KanbanSprint | null;
  stats: SprintStats | null;
  isLoading: boolean;
}

const CompleteSprintModal = React.memo(function CompleteSprintModal({
  isOpen,
  onClose,
  onSubmit,
  sprint,
  stats,
  isLoading,
}: CompleteSprintModalProps) {
  const [wentWell, setWentWell] = useState('');
  const [toImprove, setToImprove] = useState('');
  const [actionItems, setActionItems] = useState('');
  const [moveRemaining, setMoveRemaining] = useState<'next_sprint' | 'backlog'>('backlog');

  useEffect(() => {
    if (isOpen) {
      setWentWell('');
      setToImprove('');
      setActionItems('');
      setMoveRemaining('backlog');
    }
  }, [isOpen]);

  const handleSubmit = useCallback((e: React.FormEvent) => {
    e.preventDefault();
    onSubmit({ went_well: wentWell, to_improve: toImprove, action_items: actionItems, move_remaining: moveRemaining });
  }, [wentWell, toImprove, actionItems, moveRemaining, onSubmit]);

  if (!isOpen || !sprint) return null;

  const completedTasks = stats?.completed_tasks || 0;
  const remainingTasks = (stats?.total_tasks || 0) - completedTasks;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      <div className="fixed inset-0 bg-black/50" onClick={onClose} />
      <div className="relative bg-surface rounded-xl shadow-xl w-full max-w-lg mx-4 p-6 max-h-[90vh] overflow-y-auto">
        <h2 className="text-lg font-bold text-secondary-900 mb-4">Complete Sprint: {sprint.name}</h2>

        {/* Summary */}
        <div className="bg-secondary-50 rounded-lg p-4 mb-4">
          <h3 className="text-sm font-semibold text-secondary-700 mb-2">Sprint Summary</h3>
          <div className="grid grid-cols-2 gap-3 text-sm">
            <div>
              <span className="text-secondary-500">Completed:</span>
              <span className="ml-1 font-medium text-green-700">{completedTasks} tasks</span>
            </div>
            <div>
              <span className="text-secondary-500">Remaining:</span>
              <span className="ml-1 font-medium text-orange-700">{remainingTasks} tasks</span>
            </div>
            <div>
              <span className="text-secondary-500">Points Done:</span>
              <span className="ml-1 font-medium">{stats?.completed_points || 0}</span>
            </div>
            <div>
              <span className="text-secondary-500">Points Left:</span>
              <span className="ml-1 font-medium">{stats?.remaining_points || 0}</span>
            </div>
          </div>
        </div>

        {/* Remaining tasks handling */}
        {remainingTasks > 0 && (
          <div className="mb-4">
            <label className="block text-sm font-medium text-secondary-700 mb-2">
              Move {remainingTasks} remaining task{remainingTasks > 1 ? 's' : ''} to:
            </label>
            <div className="flex gap-3">
              <label className="flex items-center gap-2 cursor-pointer">
                <input
                  type="radio"
                  name="moveRemaining"
                  value="backlog"
                  checked={moveRemaining === 'backlog'}
                  onChange={() => setMoveRemaining('backlog')}
                  className="text-primary-500"
                />
                <span className="text-sm">Backlog</span>
              </label>
              <label className="flex items-center gap-2 cursor-pointer">
                <input
                  type="radio"
                  name="moveRemaining"
                  value="next_sprint"
                  checked={moveRemaining === 'next_sprint'}
                  onChange={() => setMoveRemaining('next_sprint')}
                  className="text-primary-500"
                />
                <span className="text-sm">Next Sprint</span>
              </label>
            </div>
          </div>
        )}

        <form onSubmit={handleSubmit} className="space-y-4">
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">What went well?</label>
            <textarea
              value={wentWell}
              onChange={(e) => setWentWell(e.target.value)}
              rows={3}
              placeholder="Team accomplishments, good practices..."
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:ring-2 focus:ring-primary-500 focus:border-primary-500 outline-none resize-none"
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">What to improve?</label>
            <textarea
              value={toImprove}
              onChange={(e) => setToImprove(e.target.value)}
              rows={3}
              placeholder="Blockers, issues encountered..."
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:ring-2 focus:ring-primary-500 focus:border-primary-500 outline-none resize-none"
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Action Items</label>
            <textarea
              value={actionItems}
              onChange={(e) => setActionItems(e.target.value)}
              rows={2}
              placeholder="Concrete steps for next sprint..."
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:ring-2 focus:ring-primary-500 focus:border-primary-500 outline-none resize-none"
            />
          </div>

          <div className="flex justify-end gap-2 pt-2">
            <Button variant="ghost" size="sm" type="button" onClick={onClose}>
              Cancel
            </Button>
            <Button variant="primary" size="sm" type="submit" isLoading={isLoading}>
              Complete Sprint
            </Button>
          </div>
        </form>
      </div>
    </div>
  );
});

// ============================================
// Backlog View Component
// ============================================

interface BacklogViewProps {
  backlogTasks: KanbanTask[];
  sprintTasks: KanbanTask[];
  sprint: KanbanSprint | null;
  stats: SprintStats | null;
  onAddToSprint: (taskUuids: string[]) => void;
  onRemoveFromSprint: (taskUuids: string[]) => void;
  onTaskClick: (task: KanbanTask) => void;
  searchValue: string;
  onSearchChange: (val: string) => void;
  priorityFilter: string;
  onPriorityFilterChange: (val: string) => void;
}

const BacklogView = React.memo(function BacklogView({
  backlogTasks,
  sprintTasks,
  sprint,
  stats,
  onAddToSprint,
  onRemoveFromSprint,
  onTaskClick,
  searchValue,
  onSearchChange,
  priorityFilter,
  onPriorityFilterChange,
}: BacklogViewProps) {
  const [selectedBacklog, setSelectedBacklog] = useState<Set<string>>(new Set());
  const [selectedSprint, setSelectedSprint] = useState<Set<string>>(new Set());

  const filteredBacklog = useMemo(() => {
    let tasks = backlogTasks;
    if (searchValue) {
      const search = searchValue.toLowerCase();
      tasks = tasks.filter((t) => t.title.toLowerCase().includes(search) || t.description?.toLowerCase().includes(search));
    }
    if (priorityFilter) {
      tasks = tasks.filter((t) => t.priority === priorityFilter);
    }
    return tasks;
  }, [backlogTasks, searchValue, priorityFilter]);

  const toggleBacklogSelection = useCallback((uuid: string) => {
    setSelectedBacklog((prev) => {
      const next = new Set(prev);
      if (next.has(uuid)) next.delete(uuid);
      else next.add(uuid);
      return next;
    });
  }, []);

  const toggleSprintSelection = useCallback((uuid: string) => {
    setSelectedSprint((prev) => {
      const next = new Set(prev);
      if (next.has(uuid)) next.delete(uuid);
      else next.add(uuid);
      return next;
    });
  }, []);

  const handleMoveToSprint = useCallback(() => {
    if (selectedBacklog.size === 0) return;
    onAddToSprint(Array.from(selectedBacklog));
    setSelectedBacklog(new Set());
  }, [selectedBacklog, onAddToSprint]);

  const handleRemoveFromSprint = useCallback(() => {
    if (selectedSprint.size === 0) return;
    onRemoveFromSprint(Array.from(selectedSprint));
    setSelectedSprint(new Set());
  }, [selectedSprint, onRemoveFromSprint]);

  const totalSprintPoints = sprintTasks.reduce((sum, t) => sum + (t.story_points || 0), 0);

  return (
    <div className="flex-1 flex gap-4 p-6 overflow-hidden">
      {/* Product Backlog */}
      <div className="flex-1 flex flex-col min-w-0 bg-surface rounded-lg border border-secondary-200">
        <div className="p-3 border-b border-secondary-200">
          <div className="flex items-center justify-between mb-2">
            <h3 className="text-sm font-bold text-secondary-900">Product Backlog</h3>
            <span className="text-xs text-secondary-500">{filteredBacklog.length} tasks</span>
          </div>
          <div className="flex gap-2">
            <div className="flex-1 relative">
              <Search size={14} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-secondary-400" />
              <input
                type="text"
                value={searchValue}
                onChange={(e) => onSearchChange(e.target.value)}
                placeholder="Search..."
                className="w-full pl-8 pr-3 py-1.5 text-xs border border-secondary-200 rounded-md focus:ring-1 focus:ring-primary-500 focus:border-primary-500 outline-none"
              />
            </div>
            <select
              value={priorityFilter}
              onChange={(e) => onPriorityFilterChange(e.target.value)}
              className="text-xs border border-secondary-200 rounded-md px-2 py-1.5 focus:ring-1 focus:ring-primary-500 outline-none"
            >
              <option value="">All priorities</option>
              <option value="critical">Critical</option>
              <option value="high">High</option>
              <option value="medium">Medium</option>
              <option value="low">Low</option>
            </select>
          </div>
          {selectedBacklog.size > 0 && sprint && (
            <Button variant="primary" size="sm" className="mt-2 w-full" onClick={handleMoveToSprint}>
              <ArrowRight size={14} className="mr-1" />
              Move {selectedBacklog.size} to Sprint
            </Button>
          )}
        </div>
        <div className="flex-1 overflow-y-auto">
          {filteredBacklog.length === 0 ? (
            <div className="flex items-center justify-center h-32 text-sm text-secondary-400">
              {backlogTasks.length === 0 ? 'No tasks in backlog' : 'No matching tasks'}
            </div>
          ) : (
            filteredBacklog.map((task) => (
              <div
                key={task.uuid}
                className={cn(
                  'flex items-center gap-3 px-3 py-2 border-b border-secondary-100 hover:bg-secondary-50 cursor-pointer text-sm',
                  selectedBacklog.has(task.uuid) && 'bg-primary-50'
                )}
              >
                <input
                  type="checkbox"
                  checked={selectedBacklog.has(task.uuid)}
                  onChange={() => toggleBacklogSelection(task.uuid)}
                  className="rounded border-secondary-300 text-primary-500"
                />
                <span className={cn('w-2 h-2 rounded-full flex-shrink-0', PRIORITY_DOT_COLORS[task.priority])} />
                <span
                  className="flex-1 truncate text-secondary-900"
                  onClick={() => onTaskClick(task)}
                >
                  {task.title}
                </span>
                <span className="text-xs text-secondary-500 flex-shrink-0">
                  {task.story_points != null ? `${task.story_points} SP` : '-'}
                </span>
              </div>
            ))
          )}
        </div>
      </div>

      {/* Transfer arrows */}
      <div className="flex flex-col items-center justify-center gap-2">
        <Button
          variant="outline"
          size="sm"
          onClick={handleMoveToSprint}
          disabled={selectedBacklog.size === 0 || !sprint}
          title="Move to Sprint"
        >
          <ArrowRight size={16} />
        </Button>
        <Button
          variant="outline"
          size="sm"
          onClick={handleRemoveFromSprint}
          disabled={selectedSprint.size === 0}
          title="Move to Backlog"
        >
          <ArrowLeft size={16} />
        </Button>
      </div>

      {/* Sprint Backlog */}
      <div className="flex-1 flex flex-col min-w-0 bg-surface rounded-lg border border-secondary-200">
        <div className="p-3 border-b border-secondary-200">
          <div className="flex items-center justify-between mb-1">
            <h3 className="text-sm font-bold text-secondary-900">
              Sprint Backlog {sprint ? `- ${sprint.name}` : ''}
            </h3>
            <span className="text-xs text-secondary-500">{sprintTasks.length} tasks</span>
          </div>
          {/* Capacity indicator */}
          <div className="flex items-center gap-2 text-xs text-secondary-500">
            <span>{totalSprintPoints} story points planned</span>
          </div>
          {selectedSprint.size > 0 && (
            <Button variant="ghost" size="sm" className="mt-2 w-full" onClick={handleRemoveFromSprint}>
              <ArrowLeft size={14} className="mr-1" />
              Remove {selectedSprint.size} from Sprint
            </Button>
          )}
        </div>
        <div className="flex-1 overflow-y-auto">
          {sprintTasks.length === 0 ? (
            <div className="flex flex-col items-center justify-center h-32 text-sm text-secondary-400">
              <Target size={24} className="mb-2 text-secondary-300" />
              {sprint ? 'No tasks in this sprint' : 'Select a sprint first'}
            </div>
          ) : (
            sprintTasks.map((task) => (
              <div
                key={task.uuid}
                className={cn(
                  'flex items-center gap-3 px-3 py-2 border-b border-secondary-100 hover:bg-secondary-50 cursor-pointer text-sm',
                  selectedSprint.has(task.uuid) && 'bg-primary-50'
                )}
              >
                <input
                  type="checkbox"
                  checked={selectedSprint.has(task.uuid)}
                  onChange={() => toggleSprintSelection(task.uuid)}
                  className="rounded border-secondary-300 text-primary-500"
                />
                <span className={cn('w-2 h-2 rounded-full flex-shrink-0', PRIORITY_DOT_COLORS[task.priority])} />
                <span
                  className="flex-1 truncate text-secondary-900"
                  onClick={() => onTaskClick(task)}
                >
                  {task.title}
                </span>
                <span className={cn(
                  'text-xs px-1.5 py-0.5 rounded-full flex-shrink-0',
                  task.status === 'completed' ? 'bg-green-100 text-green-700' :
                  task.status === 'in_progress' ? 'bg-blue-100 text-blue-700' :
                  'bg-secondary-100 text-secondary-600'
                )}>
                  {task.status === 'in_progress' ? 'In Progress' : task.status === 'completed' ? 'Done' : task.status === 'review' ? 'Review' : 'To Do'}
                </span>
                <span className="text-xs text-secondary-500 flex-shrink-0">
                  {task.story_points != null ? `${task.story_points} SP` : '-'}
                </span>
              </div>
            ))
          )}
        </div>
      </div>
    </div>
  );
});

// ============================================
// Main Scrum Board Page
// ============================================

export default function SprintBoardPage() {
  const params = useParams();
  const router = useRouter();
  const projectUuid = params.uuid as string;

  const {
    currentProject,
    projectLoading,
    boards,
    loadProject,
    loadBoards,
    loadLabels,
    loadMembers,
    labels,
    members,
  } = useKanbanStore();

  // Sprint state
  const [sprints, setSprints] = useState<KanbanSprint[]>([]);
  const [sprintsLoading, setSprintsLoading] = useState(true);
  const [currentSprintUuid, setCurrentSprintUuid] = useState('');
  const [sprintTasks, setSprintTasks] = useState<KanbanTask[]>([]);
  const [sprintTasksLoading, setSprintTasksLoading] = useState(false);
  const [sprintStats, setSprintStats] = useState<SprintStats | null>(null);
  const [backlogTasks, setBacklogTasks] = useState<KanbanTask[]>([]);
  const [backlogLoading, setBacklogLoading] = useState(false);

  // UI state
  const [viewMode, setViewMode] = useState<ViewMode>('board');
  const [isCreateSprintOpen, setIsCreateSprintOpen] = useState(false);
  const [isCreateSprintLoading, setIsCreateSprintLoading] = useState(false);
  const [isCompleteSprintOpen, setIsCompleteSprintOpen] = useState(false);
  const [isCompleteSprintLoading, setIsCompleteSprintLoading] = useState(false);
  const [backlogSearch, setBacklogSearch] = useState('');
  const [backlogPriorityFilter, setBacklogPriorityFilter] = useState('');

  // Drag state
  const draggedTaskRef = useRef<KanbanTask | null>(null);

  // Abort controller for preventing race conditions
  const abortControllerRef = useRef<AbortController | null>(null);

  const currentSprint = useMemo(
    () => sprints.find((s) => s.uuid === currentSprintUuid) || null,
    [sprints, currentSprintUuid]
  );

  // ============================================
  // Data Loading
  // ============================================

  // Load project data
  useEffect(() => {
    if (projectUuid) {
      loadProject(projectUuid);
      loadBoards(projectUuid);
      loadLabels(projectUuid);
      loadMembers(projectUuid);
    }
  }, [projectUuid, loadProject, loadBoards, loadLabels, loadMembers]);

  // Load sprints
  const loadSprints = useCallback(async () => {
    if (!projectUuid) return;
    setSprintsLoading(true);
    try {
      const response = await sprintService.getSprints(projectUuid);
      setSprints(response.data || []);
      // Auto-select active sprint if none selected
      if (!currentSprintUuid) {
        const active = (response.data || []).find((s) => s.status === 'active');
        if (active) {
          setCurrentSprintUuid(active.uuid);
        } else if (response.data && response.data.length > 0) {
          setCurrentSprintUuid(response.data[0].uuid);
        }
      }
    } catch (error) {
      console.error('Failed to load sprints:', error);
      toast.error('Failed to load sprints');
    } finally {
      setSprintsLoading(false);
    }
  }, [projectUuid, currentSprintUuid]);

  useEffect(() => {
    loadSprints();
  }, [loadSprints]);

  // Load sprint tasks when sprint changes
  const loadSprintTasks = useCallback(async () => {
    if (!currentSprintUuid) {
      setSprintTasks([]);
      setSprintStats(null);
      return;
    }

    // Cancel previous request
    if (abortControllerRef.current) {
      abortControllerRef.current.abort();
    }
    abortControllerRef.current = new AbortController();

    setSprintTasksLoading(true);
    try {
      const [statsResponse] = await Promise.all([
        sprintService.getSprintStats(currentSprintUuid),
      ]);

      // Get sprint object for task list - use the sprint detail endpoint
      const sprintDetail = await sprintService.getSprint(currentSprintUuid);

      // If the sprint has a board, load tasks from that board
      // Otherwise fall back to getting all tasks from the project's first board
      const boardUuid = sprintDetail.board_uuid || (boards.length > 0 ? boards[0].uuid : null);
      let tasks: KanbanTask[] = [];
      if (boardUuid) {
        const allTasks = await kanbanService.getTasks(boardUuid);
        tasks = allTasks.filter((t) => t.sprint_id === sprintDetail.id);
      }

      setSprintTasks(tasks);
      setSprintStats({
        total_tasks: statsResponse.total_tasks,
        completed_tasks: statsResponse.completed_tasks,
        in_progress_tasks: statsResponse.in_progress_tasks,
        total_points: statsResponse.total_points,
        completed_points: statsResponse.completed_points,
        remaining_points: statsResponse.remaining_points,
        days_remaining: statsResponse.days_remaining,
        completion_rate: statsResponse.completion_rate,
      });
    } catch (error: unknown) {
      if (error instanceof Error && error.name === 'AbortError') return;
      console.error('Failed to load sprint tasks:', error);
    } finally {
      setSprintTasksLoading(false);
    }
  }, [currentSprintUuid, boards]);

  useEffect(() => {
    loadSprintTasks();
  }, [loadSprintTasks]);

  // Load backlog tasks when in backlog view
  const loadBacklogTasks = useCallback(async () => {
    if (viewMode !== 'backlog' || boards.length === 0) return;
    setBacklogLoading(true);
    try {
      const boardUuid = boards[0].uuid;
      const allTasks = await kanbanService.getTasks(boardUuid);
      // Backlog = tasks with no sprint_id
      setBacklogTasks(allTasks.filter((t) => !t.sprint_id));
    } catch (error) {
      console.error('Failed to load backlog tasks:', error);
    } finally {
      setBacklogLoading(false);
    }
  }, [viewMode, boards]);

  useEffect(() => {
    loadBacklogTasks();
  }, [loadBacklogTasks]);

  // ============================================
  // Sprint Actions
  // ============================================

  const handleCreateSprint = useCallback(async (data: { name: string; goal: string; start_date: string; end_date: string; capacity_points: number }) => {
    if (!projectUuid) return;
    setIsCreateSprintLoading(true);
    try {
      const sprint = await sprintService.createSprint(projectUuid, {
        name: data.name,
        goal: data.goal,
        start_date: data.start_date,
        end_date: data.end_date,
        capacity_points: data.capacity_points,
      });
      toast.success('Sprint created');
      setIsCreateSprintOpen(false);
      setSprints((prev) => [sprint, ...prev]);
      setCurrentSprintUuid(sprint.uuid);
    } catch (error) {
      console.error('Failed to create sprint:', error);
      toast.error('Failed to create sprint');
    } finally {
      setIsCreateSprintLoading(false);
    }
  }, [projectUuid]);

  const handleStartSprint = useCallback(async () => {
    if (!currentSprintUuid) return;
    try {
      const updated = await sprintService.startSprint(currentSprintUuid);
      setSprints((prev) => prev.map((s) => (s.uuid === updated.uuid ? updated : s)));
      toast.success('Sprint started');
    } catch (error) {
      console.error('Failed to start sprint:', error);
      toast.error('Failed to start sprint');
    }
  }, [currentSprintUuid]);

  const handleCompleteSprint = useCallback(async (data: { went_well: string; to_improve: string; action_items: string; move_remaining: string }) => {
    if (!currentSprintUuid) return;
    setIsCompleteSprintLoading(true);
    try {
      const updated = await sprintService.completeSprint(currentSprintUuid, {
        went_well: data.went_well,
        to_improve: data.to_improve,
        action_items: data.action_items,
      });
      setSprints((prev) => prev.map((s) => (s.uuid === updated.uuid ? updated : s)));
      toast.success('Sprint completed');
      setIsCompleteSprintOpen(false);
      await loadSprintTasks();
    } catch (error) {
      console.error('Failed to complete sprint:', error);
      toast.error('Failed to complete sprint');
    } finally {
      setIsCompleteSprintLoading(false);
    }
  }, [currentSprintUuid, loadSprintTasks]);

  const handleCancelSprint = useCallback(async () => {
    if (!currentSprintUuid) return;
    if (!window.confirm('Are you sure you want to cancel this sprint?')) return;
    try {
      const updated = await sprintService.cancelSprint(currentSprintUuid);
      setSprints((prev) => prev.map((s) => (s.uuid === updated.uuid ? updated : s)));
      toast.success('Sprint cancelled');
    } catch (error) {
      console.error('Failed to cancel sprint:', error);
      toast.error('Failed to cancel sprint');
    }
  }, [currentSprintUuid]);

  // ============================================
  // Task/Sprint Actions
  // ============================================

  const handleAddToSprint = useCallback(async (taskUuids: string[]) => {
    if (!currentSprintUuid || taskUuids.length === 0) return;
    try {
      await sprintService.addTasksToSprint(currentSprintUuid, taskUuids);
      toast.success(`Added ${taskUuids.length} task(s) to sprint`);
      await loadSprintTasks();
      await loadBacklogTasks();
    } catch (error) {
      console.error('Failed to add tasks to sprint:', error);
      toast.error('Failed to add tasks to sprint');
    }
  }, [currentSprintUuid, loadSprintTasks, loadBacklogTasks]);

  const handleRemoveFromSprint = useCallback(async (taskUuids: string[]) => {
    if (!currentSprintUuid || taskUuids.length === 0) return;
    try {
      await sprintService.removeTasksFromSprint(currentSprintUuid, taskUuids);
      toast.success(`Removed ${taskUuids.length} task(s) from sprint`);
      await loadSprintTasks();
      await loadBacklogTasks();
    } catch (error) {
      console.error('Failed to remove tasks from sprint:', error);
      toast.error('Failed to remove tasks from sprint');
    }
  }, [currentSprintUuid, loadSprintTasks, loadBacklogTasks]);

  const handleTaskClick = useCallback((task: KanbanTask) => {
    // Could open a task detail modal - for now just navigate or show detail
    toast.success(`Task: ${task.title}`);
  }, []);

  // ============================================
  // Drag & Drop Handlers
  // ============================================

  const handleDragStart = useCallback((e: React.DragEvent, task: KanbanTask) => {
    draggedTaskRef.current = task;
    e.dataTransfer.effectAllowed = 'move';
    e.dataTransfer.setData('text/plain', task.uuid);
  }, []);

  const handleDragOver = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    e.dataTransfer.dropEffect = 'move';
  }, []);

  const handleDrop = useCallback(async (e: React.DragEvent, column: BoardColumn) => {
    e.preventDefault();
    const task = draggedTaskRef.current;
    if (!task) return;
    draggedTaskRef.current = null;

    const newStatus = column.statuses[0];
    if (task.status === newStatus) return;

    // Optimistic update
    setSprintTasks((prev) =>
      prev.map((t) => (t.uuid === task.uuid ? { ...t, status: newStatus as KanbanTask['status'] } : t))
    );

    try {
      await kanbanService.updateTask(task.uuid, { status: newStatus as KanbanTask['status'] });
      // Reload stats
      if (currentSprintUuid) {
        const statsResponse = await sprintService.getSprintStats(currentSprintUuid);
        setSprintStats({
          total_tasks: statsResponse.total_tasks,
          completed_tasks: statsResponse.completed_tasks,
          in_progress_tasks: statsResponse.in_progress_tasks,
          total_points: statsResponse.total_points,
          completed_points: statsResponse.completed_points,
          remaining_points: statsResponse.remaining_points,
          days_remaining: statsResponse.days_remaining,
          completion_rate: statsResponse.completion_rate,
        });
      }
    } catch (error) {
      console.error('Failed to update task status:', error);
      toast.error('Failed to move task');
      // Revert
      setSprintTasks((prev) =>
        prev.map((t) => (t.uuid === task.uuid ? { ...t, status: task.status } : t))
      );
    }
  }, [currentSprintUuid]);

  const handleAddTaskToColumn = useCallback((status: string) => {
    toast.error('Add task from the project board, then move it to the sprint via the backlog view');
  }, []);

  // ============================================
  // Board view grouped tasks
  // ============================================

  const boardColumnTasks = useMemo(() => {
    const grouped: Record<string, KanbanTask[]> = {};
    for (const col of BOARD_COLUMNS) {
      grouped[col.key] = sprintTasks.filter((t) => col.statuses.includes(t.status));
    }
    return grouped;
  }, [sprintTasks]);

  // ============================================
  // Render
  // ============================================

  const isLoading = sprintsLoading || projectLoading;

  return (
    <div className="h-full flex flex-col">
      {/* Top Bar */}
      <div className="flex items-center justify-between px-6 py-3 border-b border-secondary-200 bg-surface">
        <div className="flex items-center gap-3">
          <Button
            variant="ghost"
            size="sm"
            onClick={() => router.push(`/dashboard/projects/${projectUuid}`)}
          >
            <ArrowLeft size={18} />
          </Button>

          <div>
            <h1 className="text-lg font-bold text-secondary-900">
              {currentProject?.name || 'Loading...'}
            </h1>
            <p className="text-xs text-secondary-500">Sprint Board</p>
          </div>
        </div>

        <div className="flex items-center gap-3">
          {/* Sprint Selector */}
          {!sprintsLoading && (
            <SprintSelector
              sprints={sprints}
              currentSprintUuid={currentSprintUuid}
              onSprintChange={setCurrentSprintUuid}
            />
          )}

          {/* New Sprint Button */}
          <Button variant="primary" size="sm" onClick={() => setIsCreateSprintOpen(true)}>
            <Plus size={14} className="mr-1" />
            New Sprint
          </Button>

          {/* Refresh */}
          <Button
            variant="ghost"
            size="sm"
            onClick={() => { loadSprints(); loadSprintTasks(); }}
            disabled={sprintTasksLoading}
          >
            <RefreshCw size={16} className={sprintTasksLoading ? 'animate-spin' : ''} />
          </Button>

          {/* View Toggle */}
          <ViewToggle currentView={viewMode} onChange={setViewMode} />
        </div>
      </div>

      {/* Sprint Info Banner */}
      {currentSprint && (viewMode === 'board' || viewMode === 'backlog') && (
        <SprintInfoBanner
          sprint={currentSprint}
          stats={sprintStats}
          onCompleteSprint={() => setIsCompleteSprintOpen(true)}
          onCancelSprint={handleCancelSprint}
          onStartSprint={handleStartSprint}
        />
      )}

      {/* Content */}
      <div className="flex-1 overflow-hidden">
        {/* Loading state */}
        {isLoading && <LoadingSkeleton />}

        {/* No sprints empty state */}
        {!isLoading && sprints.length === 0 && (
          <div className="flex flex-col items-center justify-center h-full text-center px-6">
            <Target size={48} className="text-secondary-300 mb-4" />
            <h2 className="text-lg font-semibold text-secondary-900 mb-2">No Sprints Yet</h2>
            <p className="text-sm text-secondary-500 mb-4 max-w-md">
              Create your first sprint to start organizing your work into time-boxed iterations.
            </p>
            <Button variant="primary" size="sm" onClick={() => setIsCreateSprintOpen(true)}>
              <Plus size={14} className="mr-1" />
              Create First Sprint
            </Button>
          </div>
        )}

        {/* Board View */}
        {!isLoading && sprints.length > 0 && viewMode === 'board' && (
          <div className="h-full overflow-x-auto">
            {sprintTasksLoading && !sprintTasks.length ? (
              <LoadingSkeleton />
            ) : (
              <div className="flex gap-4 p-6 h-full">
                {BOARD_COLUMNS.map((column) => (
                  <BoardColumnComponent
                    key={column.key}
                    column={column}
                    tasks={boardColumnTasks[column.key] || []}
                    onDragStart={handleDragStart}
                    onDragOver={handleDragOver}
                    onDrop={handleDrop}
                    onTaskClick={handleTaskClick}
                    onAddTask={handleAddTaskToColumn}
                  />
                ))}
              </div>
            )}
          </div>
        )}

        {/* Backlog View */}
        {!isLoading && sprints.length > 0 && viewMode === 'backlog' && (
          <>
            {backlogLoading ? (
              <div className="flex items-center justify-center h-64">
                <Loader2 size={24} className="animate-spin text-secondary-400" />
              </div>
            ) : (
              <BacklogView
                backlogTasks={backlogTasks}
                sprintTasks={sprintTasks}
                sprint={currentSprint}
                stats={sprintStats}
                onAddToSprint={handleAddToSprint}
                onRemoveFromSprint={handleRemoveFromSprint}
                onTaskClick={handleTaskClick}
                searchValue={backlogSearch}
                onSearchChange={setBacklogSearch}
                priorityFilter={backlogPriorityFilter}
                onPriorityFilterChange={setBacklogPriorityFilter}
              />
            )}
          </>
        )}

        {/* Burndown View - redirect to dedicated page */}
        {!isLoading && sprints.length > 0 && (viewMode === 'burndown' || viewMode === 'velocity') && (
          <div className="flex flex-col items-center justify-center h-full text-center px-6">
            <BarChart3 size={48} className="text-secondary-300 mb-4" />
            <h2 className="text-lg font-semibold text-secondary-900 mb-2">
              {viewMode === 'burndown' ? 'Sprint Burndown Chart' : 'Velocity Chart'}
            </h2>
            <p className="text-sm text-secondary-500 mb-4">
              View detailed charts and analytics for your sprints.
            </p>
            <Button
              variant="primary"
              size="sm"
              onClick={() => router.push(`/dashboard/projects/${projectUuid}/sprints/burndown${currentSprintUuid ? `?sprint=${currentSprintUuid}` : ''}`)}
            >
              <BarChart3 size={14} className="mr-1" />
              View Charts
            </Button>
          </div>
        )}
      </div>

      {/* Create Sprint Modal */}
      <CreateSprintModal
        isOpen={isCreateSprintOpen}
        onClose={() => setIsCreateSprintOpen(false)}
        onSubmit={handleCreateSprint}
        isLoading={isCreateSprintLoading}
      />

      {/* Complete Sprint Modal */}
      <CompleteSprintModal
        isOpen={isCompleteSprintOpen}
        onClose={() => setIsCompleteSprintOpen(false)}
        onSubmit={handleCompleteSprint}
        sprint={currentSprint}
        stats={sprintStats}
        isLoading={isCompleteSprintLoading}
      />
    </div>
  );
}

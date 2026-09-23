'use client';

import React, { memo, useCallback, useState, useMemo } from 'react';
import { Plus, Settings, RefreshCw, Filter, Search, X } from 'lucide-react';
import {
  DndContext,
  DragOverlay,
  closestCorners,
  KeyboardSensor,
  PointerSensor,
  TouchSensor,
  useSensor,
  useSensors,
  type DragStartEvent,
  type DragEndEvent,
  type DragOverEvent,
  type UniqueIdentifier,
} from '@dnd-kit/core';
import { sortableKeyboardCoordinates } from '@dnd-kit/sortable';
import { cn } from '@/lib/utils';
import type {
  KanbanBoardFullResponse,
  KanbanTask,
  KanbanColumn as KanbanColumnType,
  KanbanEpic,
  CreateKanbanColumnDto,
} from '@/types';
import KanbanColumn from './KanbanColumn';
import KanbanTaskCard from './KanbanTaskCard';
import Button from '@/components/ui/Button';
import Input from '@/components/ui/Input';

// ============================================
// Board Header Component
// ============================================

interface BoardHeaderProps {
  boardName: string;
  projectName: string;
  taskCount: number;
  onRefresh?: () => void;
  onSettings?: () => void;
  onFilter?: () => void;
  isRefreshing?: boolean;
  searchValue?: string;
  onSearchChange?: (value: string) => void;
  epics?: KanbanEpic[];
  epicFilter?: number | null;
  onEpicFilterChange?: (epicId: number | null) => void;
}

const BoardHeader = memo(function BoardHeader({
  boardName,
  projectName,
  taskCount,
  onRefresh,
  onSettings,
  onFilter,
  isRefreshing,
  searchValue,
  onSearchChange,
  epics,
  epicFilter,
  onEpicFilterChange,
}: BoardHeaderProps) {
  const [showSearch, setShowSearch] = useState(false);

  return (
    <div className="flex items-center justify-between gap-2 px-3 md:px-6 py-3 md:py-4 bg-surface border-b border-secondary-200">
      <div className="flex items-center gap-2 md:gap-4 min-w-0">
        <div className="min-w-0">
          <h1 className="text-lg md:text-xl font-bold text-secondary-900 truncate">{boardName}</h1>
          <p className="text-xs md:text-sm text-secondary-500 truncate">{projectName}</p>
        </div>
        <span className="hidden sm:inline-block text-xs md:text-sm text-secondary-500 bg-secondary-100 px-2 py-1 rounded whitespace-nowrap">
          {taskCount} tasks
        </span>
      </div>

      <div className="flex items-center gap-1 md:gap-2 shrink-0">
        {/* Epic filter */}
        {epics && epics.length > 0 && (
          <select
            value={epicFilter ?? ''}
            onChange={(e) =>
              onEpicFilterChange?.(e.target.value ? parseInt(e.target.value, 10) : null)
            }
            aria-label="Filter by epic"
            className="hidden sm:block max-w-[10rem] px-2 py-1.5 text-sm border border-secondary-300 rounded-lg bg-surface focus:outline-none focus:ring-2 focus:ring-primary-500"
          >
            <option value="">All epics</option>
            {epics.map((epic) => (
              <option key={epic.uuid} value={epic.id}>
                {epic.name}
              </option>
            ))}
          </select>
        )}

        {/* Search */}
        {showSearch ? (
          <div className="flex items-center gap-1 md:gap-2">
            <Input
              type="text"
              placeholder="Search tasks..."
              value={searchValue || ''}
              onChange={(e) => onSearchChange?.(e.target.value)}
              className="w-40 md:w-64"
            />
            <button
              onClick={() => {
                setShowSearch(false);
                onSearchChange?.('');
              }}
              className="p-2 text-secondary-500 hover:text-secondary-700"
            >
              <X size={18} />
            </button>
          </div>
        ) : (
          <Button
            variant="ghost"
            size="sm"
            onClick={() => setShowSearch(true)}
          >
            <Search size={16} />
          </Button>
        )}

        {/* Filter */}
        <Button variant="ghost" size="sm" onClick={onFilter}>
          <Filter size={16} />
        </Button>

        {/* Refresh */}
        <Button
          variant="ghost"
          size="sm"
          onClick={onRefresh}
          disabled={isRefreshing}
        >
          <RefreshCw size={16} className={cn(isRefreshing && 'animate-spin')} />
        </Button>

        {/* Settings */}
        <Button variant="ghost" size="sm" onClick={onSettings}>
          <Settings size={16} />
        </Button>
      </div>
    </div>
  );
});

// ============================================
// Add Column Component
// ============================================

interface AddColumnProps {
  onAdd: (data: CreateKanbanColumnDto) => void;
  isLoading?: boolean;
}

const AddColumn = memo(function AddColumn({ onAdd, isLoading }: AddColumnProps) {
  const [isAdding, setIsAdding] = useState(false);
  const [name, setName] = useState('');

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (name.trim()) {
      onAdd({ name: name.trim() });
      setName('');
      setIsAdding(false);
    }
  };

  const handleCancel = () => {
    setIsAdding(false);
    setName('');
  };

  if (!isAdding) {
    return (
      <button
        onClick={() => setIsAdding(true)}
        className="flex-shrink-0 w-[85vw] max-w-[22rem] md:w-72 md:min-w-72 md:max-w-none snap-center h-fit p-4 bg-secondary-50 border-2 border-dashed border-secondary-300 rounded-lg text-secondary-500 hover:text-secondary-700 hover:border-secondary-400 hover:bg-secondary-100 transition-colors"
      >
        <div className="flex items-center justify-center gap-2">
          <Plus size={20} />
          <span className="font-medium">Add column</span>
        </div>
      </button>
    );
  }

  return (
    <div className="flex-shrink-0 w-[85vw] max-w-[22rem] md:w-72 md:min-w-72 md:max-w-none snap-center bg-secondary-50 border border-secondary-200 rounded-xl p-3">
      <form onSubmit={handleSubmit}>
        <input
          type="text"
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="Column name..."
          className="w-full px-3 py-2 text-sm border border-secondary-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-transparent"
          autoFocus
          disabled={isLoading}
        />
        <div className="flex items-center gap-2 mt-2">
          <Button
            type="submit"
            size="sm"
            disabled={!name.trim() || isLoading}
            isLoading={isLoading}
          >
            Add column
          </Button>
          <Button
            type="button"
            variant="ghost"
            size="sm"
            onClick={handleCancel}
            disabled={isLoading}
          >
            Cancel
          </Button>
        </div>
      </form>
    </div>
  );
});

// ============================================
// Empty State Component
// ============================================

const EmptyState = memo(function EmptyState({
  onAddColumn,
  canEdit = true,
}: {
  onAddColumn: () => void;
  canEdit?: boolean;
}) {
  return (
    <div className="flex flex-col items-center justify-center h-96 text-secondary-500">
      <div className="w-16 h-16 mb-4 rounded-full bg-secondary-100 flex items-center justify-center">
        <Plus size={32} className="text-secondary-400" />
      </div>
      <h3 className="text-lg font-medium mb-2">No columns yet</h3>
      <p className="text-sm text-secondary-400 mb-4">
        {canEdit
          ? 'Create your first column to start organizing tasks'
          : 'This board has no columns yet.'}
      </p>
      {canEdit && (
        <Button onClick={onAddColumn}>
          <Plus size={16} className="mr-2" />
          Add column
        </Button>
      )}
    </div>
  );
});

// ============================================
// Main Board Component
// ============================================

export interface KanbanBoardProps {
  data: KanbanBoardFullResponse;
  /** When false, the board is read-only: no drag, no add/edit/delete controls. */
  canEdit?: boolean;
  onTaskClick?: (task: KanbanTask) => void;
  onEditColumn?: (column: KanbanColumnType) => void;
  onDeleteColumn?: (column: KanbanColumnType) => void;
  onAddColumn?: (data: CreateKanbanColumnDto) => Promise<void>;
  onAddTask?: (columnId: number) => Promise<void>;
  onMoveTask?: (taskUuid: string, targetColumnId: number, position: number) => Promise<void>;
  onRefresh?: () => void;
  onSettings?: () => void;
  onFilter?: () => void;
  isRefreshing?: boolean;
  isAddingColumn?: boolean;
  searchValue?: string;
  onSearchChange?: (value: string) => void;
  /** Epics of this project; omit to hide the epic filter. */
  epics?: KanbanEpic[];
  epicFilter?: number | null;
  onEpicFilterChange?: (epicId: number | null) => void;
  className?: string;
}

const KanbanBoard = memo(function KanbanBoard({
  data,
  canEdit = true,
  onTaskClick,
  onEditColumn,
  onDeleteColumn,
  onAddColumn,
  onAddTask,
  onMoveTask,
  onRefresh,
  onSettings,
  onFilter,
  isRefreshing,
  isAddingColumn,
  searchValue,
  onSearchChange,
  epics,
  epicFilter,
  onEpicFilterChange,
  className,
}: KanbanBoardProps) {
  const { board, columns, project } = data;
  const [activeTask, setActiveTask] = useState<KanbanTask | null>(null);
  const [activeColumnId, setActiveColumnId] = useState<string | null>(null);

  // Configure sensors for drag detection
  const sensors = useSensors(
    useSensor(PointerSensor, {
      activationConstraint: {
        distance: 8, // 8px movement required before drag starts
      },
    }),
    // Long-press to drag on touch devices, so swipe-scrolling the board still works
    useSensor(TouchSensor, {
      activationConstraint: {
        delay: 200,
        tolerance: 8,
      },
    }),
    useSensor(KeyboardSensor, {
      coordinateGetter: sortableKeyboardCoordinates,
    })
  );

  // Sort columns by position
  const sortedColumns = useMemo(
    () => [...columns].sort((a, b) => a.position - b.position),
    [columns]
  );

  // Calculate total task count
  const totalTaskCount = columns.reduce((sum, col) => sum + col.tasks.length, 0);

  // Filter tasks by search and by epic
  const filteredColumns = useMemo(() => {
    if (!searchValue && epicFilter == null) return sortedColumns;

    const needle = searchValue?.toLowerCase();

    return sortedColumns.map((col) => ({
      ...col,
      tasks: col.tasks.filter((task) => {
        if (epicFilter != null && task.epic_id !== epicFilter) return false;
        if (!needle) return true;
        return (
          task.title.toLowerCase().includes(needle) ||
          task.description?.toLowerCase().includes(needle) ||
          task.task_number.toString().includes(needle)
        );
      }),
    }));
  }, [sortedColumns, searchValue, epicFilter]);

  // Create a map of task UUID to task for quick lookup
  const taskMap = useMemo(() => {
    const map = new Map<string, KanbanTask>();
    columns.forEach((col) => {
      col.tasks.forEach((task) => {
        map.set(task.uuid, task);
      });
    });
    return map;
  }, [columns]);

  // Find which column contains a task
  const findColumnByTaskId = useCallback(
    (taskId: UniqueIdentifier): KanbanColumnType & { tasks: KanbanTask[] } | undefined => {
      return columns.find((col) =>
        col.tasks.some((task) => task.uuid === taskId)
      );
    },
    [columns]
  );

  // Find column by droppable ID
  const findColumnById = useCallback(
    (id: UniqueIdentifier): KanbanColumnType & { tasks: KanbanTask[] } | undefined => {
      const columnUuid = String(id).replace('column-', '');
      return columns.find((col) => col.uuid === columnUuid);
    },
    [columns]
  );

  // Handle drag start
  const handleDragStart = useCallback(
    (event: DragStartEvent) => {
      if (!canEdit) return; // read-only board: ignore drags
      const { active } = event;
      const task = taskMap.get(String(active.id));
      if (task) {
        setActiveTask(task);
      }
    },
    [taskMap, canEdit]
  );

  // Handle drag over (for visual feedback during drag)
  const handleDragOver = useCallback(
    (event: DragOverEvent) => {
      const { over } = event;

      if (!over) {
        setActiveColumnId(null);
        return;
      }

      const overId = String(over.id);

      // If dropping on a column directly
      if (overId.startsWith('column-')) {
        setActiveColumnId(overId);
        return;
      }

      // If dropping on a task, find its column
      const column = findColumnByTaskId(overId);
      if (column) {
        setActiveColumnId(`column-${column.uuid}`);
      } else {
        setActiveColumnId(null);
      }
    },
    [findColumnByTaskId]
  );

  // Handle drag end
  const handleDragEnd = useCallback(
    async (event: DragEndEvent) => {
      setActiveTask(null);
      setActiveColumnId(null);
      if (!canEdit) return; // read-only board: never persist a move

      const { active, over } = event;
      if (!over) return;

      const activeId = String(active.id);
      const overId = String(over.id);

      // Find the source column
      const sourceColumn = findColumnByTaskId(activeId);
      if (!sourceColumn) return;

      // Determine target column
      let targetColumn: (KanbanColumnType & { tasks: KanbanTask[] }) | undefined;
      let targetIndex = 0;

      // Check if dropping on a column
      if (overId.startsWith('column-')) {
        targetColumn = findColumnById(overId);
        targetIndex = targetColumn?.tasks.length || 0;
      } else {
        // Dropping on another task - find its column
        targetColumn = findColumnByTaskId(overId);
        if (targetColumn) {
          const overTask = targetColumn.tasks.find((t) => t.uuid === overId);
          if (overTask) {
            targetIndex = targetColumn.tasks
              .sort((a, b) => a.position - b.position)
              .findIndex((t) => t.uuid === overId);
          }
        }
      }

      if (!targetColumn) return;

      // Only call API if column changed or position changed
      const isSameColumn = sourceColumn.uuid === targetColumn.uuid;

      if (!isSameColumn) {
        await onMoveTask?.(activeId, targetColumn.id, targetIndex);
      } else {
        // Task moved within same column
        const task = taskMap.get(activeId);
        if (task) {
          const sortedTasks = [...sourceColumn.tasks].sort((a, b) => a.position - b.position);
          const currentIndex = sortedTasks.findIndex((t) => t.uuid === activeId);
          if (currentIndex !== targetIndex) {
            await onMoveTask?.(activeId, targetColumn.id, targetIndex);
          }
        }
      }
    },
    [findColumnByTaskId, findColumnById, onMoveTask, taskMap, canEdit]
  );

  // Handle add column
  const handleAddColumn = useCallback(
    async (data: CreateKanbanColumnDto) => {
      await onAddColumn?.(data);
    },
    [onAddColumn]
  );

  return (
    <div className={cn('flex flex-col h-full bg-secondary-100', className)}>
      {/* Board Header */}
      <BoardHeader
        boardName={board.name}
        projectName={project.name}
        taskCount={totalTaskCount}
        onRefresh={onRefresh}
        onSettings={onSettings}
        onFilter={onFilter}
        isRefreshing={isRefreshing}
        searchValue={searchValue}
        epics={epics}
        epicFilter={epicFilter}
        onEpicFilterChange={onEpicFilterChange}
        onSearchChange={onSearchChange}
      />

      {/* Board Content with DnD Context */}
      <div className="flex-1 overflow-x-auto overflow-y-hidden p-3 md:p-6 snap-x snap-mandatory md:snap-none scroll-smooth">
        {sortedColumns.length === 0 ? (
          <EmptyState canEdit={canEdit} onAddColumn={() => handleAddColumn({ name: 'To Do' })} />
        ) : (
          <DndContext
            // The sensors array must keep a constant length across renders
            // (dnd-kit registers them in effects), so we always pass the same
            // sensors and instead gate dragging inside the handlers on canEdit.
            sensors={sensors}
            collisionDetection={closestCorners}
            onDragStart={handleDragStart}
            onDragOver={handleDragOver}
            onDragEnd={handleDragEnd}
          >
            <div className="flex gap-3 md:gap-4 h-full">
              {/* Columns */}
              {filteredColumns.map((column) => (
                <KanbanColumn
                  key={column.uuid}
                  column={column}
                  canEdit={canEdit}
                  onTaskClick={onTaskClick}
                  onEditColumn={onEditColumn}
                  onDeleteColumn={onDeleteColumn}
                  onAddTask={onAddTask}
                  isDragOver={activeColumnId === `column-${column.uuid}`}
                  isDragging={!!activeTask}
                />
              ))}

              {/* Add Column (editors only) */}
              {canEdit && <AddColumn onAdd={handleAddColumn} isLoading={isAddingColumn} />}
            </div>

            {/* Drag Overlay - Shows the task being dragged */}
            <DragOverlay
              dropAnimation={{
                duration: 250,
                easing: 'cubic-bezier(0.18, 0.67, 0.6, 1.22)',
              }}
            >
              {activeTask && (
                <KanbanTaskCard
                  task={activeTask}
                  isOverlay
                />
              )}
            </DragOverlay>
          </DndContext>
        )}
      </div>
    </div>
  );
});

export default KanbanBoard;

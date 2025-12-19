'use client';

import React, { useEffect, useState, useCallback } from 'react';
import { useParams, useRouter } from 'next/navigation';
import {
  ArrowLeft,
  Settings,
  Users,
  LayoutGrid,
  ChevronDown,
  Plus,
} from 'lucide-react';
import { toast } from 'react-hot-toast';
import Button from '@/components/ui/Button';
import Card from '@/components/ui/Card';
import {
  KanbanBoard,
  TaskDetailModal,
  CreateTaskModal,
} from '@/components/kanban';
import { useKanbanStore } from '@/store/kanban.store';
import { kanbanService } from '@/services/kanban.service';
import type {
  KanbanTask,
  KanbanColumn,
  CreateKanbanColumnDto,
  CreateKanbanTaskDto,
  UpdateKanbanTaskDto,
  KanbanBoard as KanbanBoardType,
} from '@/types';
import { cn } from '@/lib/utils';

// ============================================
// Board Selector Component
// ============================================

interface BoardSelectorProps {
  boards: KanbanBoardType[];
  currentBoardUuid: string;
  onBoardChange: (boardUuid: string) => void;
  onCreateBoard: () => void;
}

const BoardSelector = React.memo(function BoardSelector({
  boards,
  currentBoardUuid,
  onBoardChange,
  onCreateBoard,
}: BoardSelectorProps) {
  const [isOpen, setIsOpen] = useState(false);
  const currentBoard = boards.find((b) => b.uuid === currentBoardUuid);

  return (
    <div className="relative">
      <button
        onClick={() => setIsOpen(!isOpen)}
        className="flex items-center gap-2 px-3 py-2 bg-white border border-gray-200 rounded-lg hover:bg-gray-50 transition-colors"
      >
        <LayoutGrid size={16} />
        <span className="font-medium">{currentBoard?.name || 'Select Board'}</span>
        <ChevronDown size={16} />
      </button>

      {isOpen && (
        <>
          <div className="fixed inset-0 z-10" onClick={() => setIsOpen(false)} />
          <div className="absolute left-0 mt-1 w-56 bg-white rounded-lg shadow-lg border border-gray-200 py-1 z-20">
            {boards.map((board) => (
              <button
                key={board.uuid}
                onClick={() => {
                  onBoardChange(board.uuid);
                  setIsOpen(false);
                }}
                className={cn(
                  'w-full flex items-center gap-2 px-3 py-2 text-sm hover:bg-gray-50',
                  board.uuid === currentBoardUuid && 'bg-gray-50 font-medium'
                )}
              >
                <LayoutGrid size={14} />
                {board.name}
                {board.is_default && (
                  <span className="ml-auto text-xs text-gray-400">Default</span>
                )}
              </button>
            ))}
            <hr className="my-1" />
            <button
              onClick={() => {
                onCreateBoard();
                setIsOpen(false);
              }}
              className="w-full flex items-center gap-2 px-3 py-2 text-sm text-primary-600 hover:bg-gray-50"
            >
              <Plus size={14} />
              Create new board
            </button>
          </div>
        </>
      )}
    </div>
  );
});

// ============================================
// Loading Skeleton Component
// ============================================

const LoadingSkeleton = () => (
  <div className="flex gap-4 p-6 animate-pulse">
    {[1, 2, 3, 4].map((i) => (
      <div key={i} className="w-72 flex-shrink-0">
        <div className="h-10 bg-gray-200 rounded-lg mb-4" />
        <div className="space-y-3">
          {[1, 2, 3].map((j) => (
            <div key={j} className="h-24 bg-gray-200 rounded-lg" />
          ))}
        </div>
      </div>
    ))}
  </div>
);

// ============================================
// Main Project Detail Page Component
// ============================================

export default function ProjectDetailPage() {
  const params = useParams();
  const router = useRouter();
  const projectUuid = params.uuid as string;

  const {
    currentProject,
    projectLoading,
    boards,
    boardsLoading,
    boardData,
    boardDataLoading,
    boardDataError,
    selectedTask,
    selectedTaskLoading,
    labels,
    members,
    isCreatingColumn,
    isCreatingTask,
    loadProject,
    loadBoards,
    loadBoardFull,
    loadLabels,
    loadMembers,
    createColumn,
    updateColumn,
    deleteColumn,
    createTask,
    updateTask,
    deleteTask,
    loadTask,
    setSelectedTask,
    clearSelectedTask,
    addTaskAssignee,
    removeTaskAssignee,
    addTaskLabel,
    removeTaskLabel,
    refreshBoardData,
    moveTask,
    moveTaskOptimistic,
  } = useKanbanStore();

  const [currentBoardUuid, setCurrentBoardUuid] = useState<string>('');
  const [searchValue, setSearchValue] = useState('');
  const [isCreateTaskModalOpen, setIsCreateTaskModalOpen] = useState(false);
  const [createTaskColumnId, setCreateTaskColumnId] = useState<number | null>(null);
  const [isSubmittingTask, setIsSubmittingTask] = useState(false);

  // Load project data
  useEffect(() => {
    if (projectUuid) {
      loadProject(projectUuid);
      loadBoards(projectUuid);
      loadLabels(projectUuid);
      loadMembers(projectUuid);
    }
  }, [projectUuid, loadProject, loadBoards, loadLabels, loadMembers]);

  // Set default board when boards are loaded
  useEffect(() => {
    if (boards.length > 0 && !currentBoardUuid) {
      const defaultBoard = boards.find((b) => b.is_default) || boards[0];
      setCurrentBoardUuid(defaultBoard.uuid);
    }
  }, [boards, currentBoardUuid]);

  // Load board data when board changes
  useEffect(() => {
    if (currentBoardUuid) {
      loadBoardFull(currentBoardUuid);
    }
  }, [currentBoardUuid, loadBoardFull]);

  // Handlers
  const handleBoardChange = useCallback((boardUuid: string) => {
    setCurrentBoardUuid(boardUuid);
  }, []);

  const handleCreateBoard = useCallback(() => {
    // TODO: Implement create board modal
    toast.error('Create board modal coming soon');
  }, []);

  const handleTaskClick = useCallback(
    async (task: KanbanTask) => {
      await loadTask(task.uuid);
    },
    [loadTask]
  );

  const handleEditColumn = useCallback(
    async (column: KanbanColumn) => {
      const newName = window.prompt('Enter new column name:', column.name);
      if (newName && newName !== column.name) {
        const result = await updateColumn(column.uuid, { name: newName });
        if (result) {
          toast.success('Column updated');
        } else {
          toast.error('Failed to update column');
        }
      }
    },
    [updateColumn]
  );

  const handleDeleteColumn = useCallback(
    async (column: KanbanColumn) => {
      if (
        window.confirm(
          `Are you sure you want to delete "${column.name}"? All tasks in this column will be deleted.`
        )
      ) {
        const success = await deleteColumn(column.uuid);
        if (success) {
          toast.success('Column deleted');
        } else {
          toast.error('Failed to delete column');
        }
      }
    },
    [deleteColumn]
  );

  const handleAddColumn = useCallback(
    async (data: CreateKanbanColumnDto) => {
      if (!currentBoardUuid) return;
      const result = await createColumn(currentBoardUuid, data);
      if (result) {
        toast.success('Column created');
      } else {
        toast.error('Failed to create column');
      }
    },
    [createColumn, currentBoardUuid]
  );

  // Open Create Task Modal with the column preselected
  const handleAddTask = useCallback(
    async (columnId: number) => {
      setCreateTaskColumnId(columnId);
      setIsCreateTaskModalOpen(true);
    },
    []
  );

  // Handle task creation from modal
  const handleCreateTaskSubmit = useCallback(
    async (data: CreateKanbanTaskDto) => {
      if (!currentBoardUuid) return;
      setIsSubmittingTask(true);
      try {
        const result = await createTask(currentBoardUuid, data);
        if (result) {
          toast.success('Task created successfully');
          setIsCreateTaskModalOpen(false);
        } else {
          toast.error('Failed to create task');
        }
      } catch (error) {
        console.error('Failed to create task:', error);
        toast.error('Failed to create task');
      } finally {
        setIsSubmittingTask(false);
      }
    },
    [createTask, currentBoardUuid]
  );

  const handleUpdateTask = useCallback(
    async (uuid: string, data: UpdateKanbanTaskDto) => {
      const result = await updateTask(uuid, data);
      if (!result) {
        toast.error('Failed to update task');
      }
    },
    [updateTask]
  );

  const handleDeleteTask = useCallback(
    async (uuid: string) => {
      const success = await deleteTask(uuid);
      if (success) {
        toast.success('Task deleted');
        clearSelectedTask();
      } else {
        toast.error('Failed to delete task');
      }
    },
    [deleteTask, clearSelectedTask]
  );

  const handleAddAssignee = useCallback(
    async (taskUuid: string, userUuid: string) => {
      await addTaskAssignee(taskUuid, userUuid);
      toast.success('Assignee added');
    },
    [addTaskAssignee]
  );

  const handleRemoveAssignee = useCallback(
    async (taskUuid: string, userUuid: string) => {
      await removeTaskAssignee(taskUuid, userUuid);
      toast.success('Assignee removed');
    },
    [removeTaskAssignee]
  );

  const handleAddLabel = useCallback(
    async (taskUuid: string, labelId: number) => {
      await addTaskLabel(taskUuid, labelId);
    },
    [addTaskLabel]
  );

  const handleRemoveLabel = useCallback(
    async (taskUuid: string, labelId: number) => {
      await removeTaskLabel(taskUuid, labelId);
    },
    [removeTaskLabel]
  );

  const handleAddComment = useCallback(
    async (taskUuid: string, content: string) => {
      try {
        await kanbanService.addComment(taskUuid, { content });
        await loadTask(taskUuid);
        toast.success('Comment added');
      } catch {
        toast.error('Failed to add comment');
      }
    },
    [loadTask]
  );

  const handleDeleteComment = useCallback(
    async (commentUuid: string) => {
      try {
        await kanbanService.deleteComment(commentUuid);
        if (selectedTask) {
          await loadTask(selectedTask.uuid);
        }
        toast.success('Comment deleted');
      } catch {
        toast.error('Failed to delete comment');
      }
    },
    [loadTask, selectedTask]
  );

  const handleToggleChecklistItem = useCallback(
    async (itemUuid: string) => {
      try {
        await kanbanService.toggleChecklistItem(itemUuid);
        if (selectedTask) {
          await loadTask(selectedTask.uuid);
        }
      } catch {
        toast.error('Failed to toggle checklist item');
      }
    },
    [loadTask, selectedTask]
  );

  const handleAddChecklist = useCallback(
    async (taskUuid: string, name: string) => {
      try {
        await kanbanService.createChecklist(taskUuid, { name });
        await loadTask(taskUuid);
        toast.success('Checklist added');
      } catch {
        toast.error('Failed to add checklist');
      }
    },
    [loadTask]
  );

  const handleAddChecklistItem = useCallback(
    async (checklistUuid: string, content: string) => {
      try {
        await kanbanService.addChecklistItem(checklistUuid, { content });
        if (selectedTask) {
          await loadTask(selectedTask.uuid);
        }
      } catch {
        toast.error('Failed to add checklist item');
      }
    },
    [loadTask, selectedTask]
  );

  const handleMoveTask = useCallback(
    async (taskUuid: string, targetColumnId: number, position: number) => {
      // Find source column ID for optimistic update
      const sourceColumn = boardData?.columns.find((col) =>
        col.tasks.some((task) => task.uuid === taskUuid)
      );

      if (sourceColumn) {
        // Optimistic update for smooth UX
        moveTaskOptimistic(taskUuid, sourceColumn.id, targetColumnId, position);
      }

      // Call API
      const success = await moveTask(taskUuid, {
        column_id: targetColumnId,
        position,
      });

      if (!success) {
        toast.error('Failed to move task');
      }
    },
    [boardData, moveTask, moveTaskOptimistic]
  );

  const handleRefresh = useCallback(() => {
    refreshBoardData();
  }, [refreshBoardData]);

  const handleSettings = useCallback(() => {
    router.push(`/dashboard/projects/${projectUuid}/settings`);
  }, [router, projectUuid]);

  // Render
  return (
    <div className="h-full flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-gray-200 bg-white">
          <div className="flex items-center gap-4">
            <Button
              variant="ghost"
              size="sm"
              onClick={() => router.push('/dashboard/projects')}
            >
              <ArrowLeft size={18} />
            </Button>

            <div>
              <h1 className="text-xl font-bold text-gray-900">
                {currentProject?.name || 'Loading...'}
              </h1>
              {currentProject?.description && (
                <p className="text-sm text-gray-500 line-clamp-1">
                  {currentProject.description}
                </p>
              )}
            </div>
          </div>

          <div className="flex items-center gap-3">
            {/* Board Selector */}
            {!boardsLoading && boards.length > 0 && (
              <BoardSelector
                boards={boards}
                currentBoardUuid={currentBoardUuid}
                onBoardChange={handleBoardChange}
                onCreateBoard={handleCreateBoard}
              />
            )}

            {/* Members */}
            <Button variant="ghost" size="sm">
              <Users size={18} className="mr-2" />
              {currentProject?.member_count || 0}
            </Button>

            {/* Settings */}
            <Button variant="ghost" size="sm" onClick={handleSettings}>
              <Settings size={18} />
            </Button>
          </div>
        </div>

        {/* Board Content */}
        <div className="flex-1 overflow-hidden">
          {/* Loading */}
          {(projectLoading || boardDataLoading) && !boardData && <LoadingSkeleton />}

          {/* Error */}
          {boardDataError && (
            <Card className="m-6 bg-red-50 border-red-200 p-4">
              <p className="text-red-700">{boardDataError}</p>
              <Button
                variant="outline"
                size="sm"
                onClick={handleRefresh}
                className="mt-2"
              >
                Try Again
              </Button>
            </Card>
          )}

          {/* Board */}
          {boardData && (
            <KanbanBoard
              data={boardData}
              onTaskClick={handleTaskClick}
              onEditColumn={handleEditColumn}
              onDeleteColumn={handleDeleteColumn}
              onAddColumn={handleAddColumn}
              onAddTask={handleAddTask}
              onMoveTask={handleMoveTask}
              onRefresh={handleRefresh}
              onSettings={handleSettings}
              isRefreshing={boardDataLoading}
              isAddingColumn={isCreatingColumn}
              searchValue={searchValue}
              onSearchChange={setSearchValue}
            />
          )}
        </div>

        {/* Task Detail Modal */}
        <TaskDetailModal
          isOpen={!!selectedTask}
          onClose={clearSelectedTask}
          task={selectedTask}
          members={members}
          labels={labels}
          isLoading={selectedTaskLoading}
          onUpdate={handleUpdateTask}
          onDelete={handleDeleteTask}
          onAddAssignee={handleAddAssignee}
          onRemoveAssignee={handleRemoveAssignee}
          onAddLabel={handleAddLabel}
          onRemoveLabel={handleRemoveLabel}
          onAddComment={handleAddComment}
          onDeleteComment={handleDeleteComment}
          onToggleChecklistItem={handleToggleChecklistItem}
          onAddChecklist={handleAddChecklist}
          onAddChecklistItem={handleAddChecklistItem}
        />

        {/* Create Task Modal */}
        <CreateTaskModal
          isOpen={isCreateTaskModalOpen}
          onClose={() => setIsCreateTaskModalOpen(false)}
          onSubmit={handleCreateTaskSubmit}
          columnId={createTaskColumnId || (boardData?.columns?.[0]?.id ?? 0)}
          columns={boardData?.columns}
          members={members}
          labels={labels}
          isLoading={isSubmittingTask}
        />
    </div>
  );
}

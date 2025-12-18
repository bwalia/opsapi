import { create } from 'zustand';
import { persist } from 'zustand/middleware';
import type {
  KanbanProject,
  KanbanBoard,
  KanbanColumn,
  KanbanTask,
  KanbanLabel,
  KanbanProjectMember,
  KanbanBoardFullResponse,
  CreateKanbanProjectDto,
  UpdateKanbanProjectDto,
  CreateKanbanTaskDto,
  UpdateKanbanTaskDto,
  MoveKanbanTaskDto,
  CreateKanbanColumnDto,
  UpdateKanbanColumnDto,
  CreateKanbanBoardDto,
} from '@/types';
import { kanbanService } from '@/services/kanban.service';

// ============================================
// State Types
// ============================================

interface KanbanState {
  // Projects
  projects: KanbanProject[];
  projectsLoading: boolean;
  projectsError: string | null;
  currentProject: KanbanProject | null;
  projectLoading: boolean;

  // Boards
  boards: KanbanBoard[];
  boardsLoading: boolean;
  currentBoard: KanbanBoard | null;
  boardLoading: boolean;

  // Board Full View (columns + tasks)
  boardData: KanbanBoardFullResponse | null;
  boardDataLoading: boolean;
  boardDataError: string | null;

  // Labels (project-scoped)
  labels: KanbanLabel[];
  labelsLoading: boolean;

  // Members (project-scoped)
  members: KanbanProjectMember[];
  membersLoading: boolean;

  // Selected task for detail view
  selectedTask: KanbanTask | null;
  selectedTaskLoading: boolean;

  // UI State
  isCreatingProject: boolean;
  isCreatingTask: boolean;
  isCreatingColumn: boolean;

  // Filters
  taskFilters: {
    search?: string;
    priority?: string;
    assignee_uuid?: string;
    status?: string;
  };

  // Optimistic updates tracking
  pendingMoves: Map<string, { columnId: number; position: number }>;

  // Hydration
  _hasHydrated: boolean;
}

interface KanbanActions {
  // Hydration
  setHasHydrated: (state: boolean) => void;

  // Projects
  loadProjects: (params?: { search?: string; status?: string; starred?: boolean }) => Promise<void>;
  loadProject: (uuid: string) => Promise<void>;
  createProject: (data: CreateKanbanProjectDto) => Promise<KanbanProject | null>;
  updateProject: (uuid: string, data: UpdateKanbanProjectDto) => Promise<KanbanProject | null>;
  deleteProject: (uuid: string) => Promise<boolean>;
  toggleProjectStar: (uuid: string) => Promise<void>;
  setCurrentProject: (project: KanbanProject | null) => void;

  // Boards
  loadBoards: (projectUuid: string) => Promise<void>;
  loadBoard: (uuid: string) => Promise<void>;
  createBoard: (projectUuid: string, data: CreateKanbanBoardDto) => Promise<KanbanBoard | null>;
  setCurrentBoard: (board: KanbanBoard | null) => void;

  // Board Full View
  loadBoardFull: (uuid: string) => Promise<void>;
  refreshBoardData: () => Promise<void>;

  // Columns
  createColumn: (boardUuid: string, data: CreateKanbanColumnDto) => Promise<KanbanColumn | null>;
  updateColumn: (uuid: string, data: UpdateKanbanColumnDto) => Promise<KanbanColumn | null>;
  deleteColumn: (uuid: string) => Promise<boolean>;
  reorderColumns: (boardUuid: string, columnIds: number[]) => Promise<void>;

  // Tasks
  loadTask: (uuid: string) => Promise<void>;
  createTask: (boardUuid: string, data: CreateKanbanTaskDto) => Promise<KanbanTask | null>;
  updateTask: (uuid: string, data: UpdateKanbanTaskDto) => Promise<KanbanTask | null>;
  deleteTask: (uuid: string) => Promise<boolean>;
  moveTask: (uuid: string, data: MoveKanbanTaskDto) => Promise<boolean>;
  moveTaskOptimistic: (taskUuid: string, sourceColumnId: number, destColumnId: number, destPosition: number) => void;
  setSelectedTask: (task: KanbanTask | null) => void;
  clearSelectedTask: () => void;

  // Task Assignees
  addTaskAssignee: (taskUuid: string, userUuid: string) => Promise<void>;
  removeTaskAssignee: (taskUuid: string, userUuid: string) => Promise<void>;

  // Labels
  loadLabels: (projectUuid: string) => Promise<void>;
  addTaskLabel: (taskUuid: string, labelId: number) => Promise<void>;
  removeTaskLabel: (taskUuid: string, labelId: number) => Promise<void>;

  // Members
  loadMembers: (projectUuid: string) => Promise<void>;

  // Filters
  setTaskFilters: (filters: KanbanState['taskFilters']) => void;
  clearTaskFilters: () => void;

  // UI State
  setCreatingProject: (state: boolean) => void;
  setCreatingTask: (state: boolean) => void;
  setCreatingColumn: (state: boolean) => void;

  // Clear
  clearKanbanState: () => void;
  clearBoardData: () => void;
  clearErrors: () => void;
}

type KanbanStore = KanbanState & KanbanActions;

// ============================================
// Initial State
// ============================================

const initialState: KanbanState = {
  projects: [],
  projectsLoading: false,
  projectsError: null,
  currentProject: null,
  projectLoading: false,

  boards: [],
  boardsLoading: false,
  currentBoard: null,
  boardLoading: false,

  boardData: null,
  boardDataLoading: false,
  boardDataError: null,

  labels: [],
  labelsLoading: false,

  members: [],
  membersLoading: false,

  selectedTask: null,
  selectedTaskLoading: false,

  isCreatingProject: false,
  isCreatingTask: false,
  isCreatingColumn: false,

  taskFilters: {},

  pendingMoves: new Map(),

  _hasHydrated: false,
};

// ============================================
// Store
// ============================================

export const useKanbanStore = create<KanbanStore>()(
  persist(
    (set, get) => ({
      ...initialState,

      // ============================================
      // Hydration
      // ============================================

      setHasHydrated: (state: boolean) => {
        set({ _hasHydrated: state });
      },

      // ============================================
      // Projects
      // ============================================

      loadProjects: async (params) => {
        set({ projectsLoading: true, projectsError: null });
        try {
          const response = await kanbanService.getProjects({
            search: params?.search,
            status: params?.status as 'active' | 'on_hold' | 'completed' | 'archived' | 'cancelled' | undefined,
            starred: params?.starred,
          });
          set({ projects: response.data, projectsLoading: false });
        } catch (error) {
          const message = error instanceof Error ? error.message : 'Failed to load projects';
          set({ projectsError: message, projectsLoading: false });
        }
      },

      loadProject: async (uuid: string) => {
        set({ projectLoading: true });
        try {
          const project = await kanbanService.getProject(uuid);
          set({ currentProject: project, projectLoading: false });
        } catch (error) {
          console.error('Failed to load project:', error);
          set({ projectLoading: false });
        }
      },

      createProject: async (data: CreateKanbanProjectDto) => {
        set({ isCreatingProject: true });
        try {
          const project = await kanbanService.createProject(data);
          set((state) => ({
            projects: [project, ...state.projects],
            isCreatingProject: false,
          }));
          return project;
        } catch (error) {
          console.error('Failed to create project:', error);
          set({ isCreatingProject: false });
          return null;
        }
      },

      updateProject: async (uuid: string, data: UpdateKanbanProjectDto) => {
        try {
          const project = await kanbanService.updateProject(uuid, data);
          set((state) => ({
            projects: state.projects.map((p) => (p.uuid === uuid ? project : p)),
            currentProject: state.currentProject?.uuid === uuid ? project : state.currentProject,
          }));
          return project;
        } catch (error) {
          console.error('Failed to update project:', error);
          return null;
        }
      },

      deleteProject: async (uuid: string) => {
        try {
          await kanbanService.deleteProject(uuid);
          set((state) => ({
            projects: state.projects.filter((p) => p.uuid !== uuid),
            currentProject: state.currentProject?.uuid === uuid ? null : state.currentProject,
          }));
          return true;
        } catch (error) {
          console.error('Failed to delete project:', error);
          return false;
        }
      },

      toggleProjectStar: async (uuid: string) => {
        try {
          const result = await kanbanService.toggleProjectStar(uuid);
          set((state) => ({
            projects: state.projects.map((p) =>
              p.uuid === uuid ? { ...p, is_starred: result.is_starred } : p
            ),
          }));
        } catch (error) {
          console.error('Failed to toggle star:', error);
        }
      },

      setCurrentProject: (project: KanbanProject | null) => {
        set({ currentProject: project });
      },

      // ============================================
      // Boards
      // ============================================

      loadBoards: async (projectUuid: string) => {
        set({ boardsLoading: true });
        try {
          const boards = await kanbanService.getBoards(projectUuid);
          set({ boards, boardsLoading: false });
        } catch (error) {
          console.error('Failed to load boards:', error);
          set({ boardsLoading: false });
        }
      },

      loadBoard: async (uuid: string) => {
        set({ boardLoading: true });
        try {
          const board = await kanbanService.getBoard(uuid);
          set({ currentBoard: board, boardLoading: false });
        } catch (error) {
          console.error('Failed to load board:', error);
          set({ boardLoading: false });
        }
      },

      createBoard: async (projectUuid: string, data: CreateKanbanBoardDto) => {
        try {
          const board = await kanbanService.createBoard(projectUuid, data);
          set((state) => ({
            boards: [...state.boards, board],
          }));
          return board;
        } catch (error) {
          console.error('Failed to create board:', error);
          return null;
        }
      },

      setCurrentBoard: (board: KanbanBoard | null) => {
        set({ currentBoard: board });
      },

      // ============================================
      // Board Full View
      // ============================================

      loadBoardFull: async (uuid: string) => {
        set({ boardDataLoading: true, boardDataError: null });
        try {
          const data = await kanbanService.getBoardFull(uuid);
          set({
            boardData: data,
            currentBoard: data.board,
            currentProject: data.project,
            boardDataLoading: false,
          });
        } catch (error) {
          const message = error instanceof Error ? error.message : 'Failed to load board';
          set({ boardDataError: message, boardDataLoading: false });
        }
      },

      refreshBoardData: async () => {
        const { currentBoard } = get();
        if (currentBoard) {
          await get().loadBoardFull(currentBoard.uuid);
        }
      },

      // ============================================
      // Columns
      // ============================================

      createColumn: async (boardUuid: string, data: CreateKanbanColumnDto) => {
        set({ isCreatingColumn: true });
        try {
          const column = await kanbanService.createColumn(boardUuid, data);
          // Refresh board data to get updated columns
          await get().refreshBoardData();
          set({ isCreatingColumn: false });
          return column;
        } catch (error) {
          console.error('Failed to create column:', error);
          set({ isCreatingColumn: false });
          return null;
        }
      },

      updateColumn: async (uuid: string, data: UpdateKanbanColumnDto) => {
        try {
          const column = await kanbanService.updateColumn(uuid, data);
          // Update in boardData
          set((state) => {
            if (!state.boardData) return state;
            return {
              boardData: {
                ...state.boardData,
                columns: state.boardData.columns.map((c) =>
                  c.uuid === uuid ? { ...c, ...column } : c
                ),
              },
            };
          });
          return column;
        } catch (error) {
          console.error('Failed to update column:', error);
          return null;
        }
      },

      deleteColumn: async (uuid: string) => {
        try {
          await kanbanService.deleteColumn(uuid);
          // Update boardData
          set((state) => {
            if (!state.boardData) return state;
            return {
              boardData: {
                ...state.boardData,
                columns: state.boardData.columns.filter((c) => c.uuid !== uuid),
              },
            };
          });
          return true;
        } catch (error) {
          console.error('Failed to delete column:', error);
          return false;
        }
      },

      reorderColumns: async (boardUuid: string, columnIds: number[]) => {
        // Optimistic update
        set((state) => {
          if (!state.boardData) return state;
          const reorderedColumns = columnIds
            .map((id) => state.boardData!.columns.find((c) => c.id === id))
            .filter(Boolean) as typeof state.boardData.columns;
          return {
            boardData: {
              ...state.boardData,
              columns: reorderedColumns.map((c, i) => ({ ...c, position: i })),
            },
          };
        });

        try {
          await kanbanService.reorderColumns(boardUuid, { column_ids: columnIds });
        } catch (error) {
          console.error('Failed to reorder columns:', error);
          // Revert on error
          await get().refreshBoardData();
        }
      },

      // ============================================
      // Tasks
      // ============================================

      loadTask: async (uuid: string) => {
        set({ selectedTaskLoading: true });
        try {
          const task = await kanbanService.getTask(uuid);
          set({ selectedTask: task, selectedTaskLoading: false });
        } catch (error) {
          console.error('Failed to load task:', error);
          set({ selectedTaskLoading: false });
        }
      },

      createTask: async (boardUuid: string, data: CreateKanbanTaskDto) => {
        set({ isCreatingTask: true });
        try {
          const task = await kanbanService.createTask(boardUuid, data);
          // Add task to the appropriate column in boardData
          set((state) => {
            if (!state.boardData) return { isCreatingTask: false };
            return {
              isCreatingTask: false,
              boardData: {
                ...state.boardData,
                columns: state.boardData.columns.map((col) => {
                  if (col.id === task.column_id) {
                    return {
                      ...col,
                      tasks: [...col.tasks, task],
                      task_count: col.task_count + 1,
                    };
                  }
                  return col;
                }),
              },
            };
          });
          return task;
        } catch (error) {
          console.error('Failed to create task:', error);
          set({ isCreatingTask: false });
          return null;
        }
      },

      updateTask: async (uuid: string, data: UpdateKanbanTaskDto) => {
        try {
          const task = await kanbanService.updateTask(uuid, data);
          // Update in boardData
          set((state) => {
            if (!state.boardData) return state;
            return {
              selectedTask: state.selectedTask?.uuid === uuid ? task : state.selectedTask,
              boardData: {
                ...state.boardData,
                columns: state.boardData.columns.map((col) => ({
                  ...col,
                  tasks: col.tasks.map((t) => (t.uuid === uuid ? task : t)),
                })),
              },
            };
          });
          return task;
        } catch (error) {
          console.error('Failed to update task:', error);
          return null;
        }
      },

      deleteTask: async (uuid: string) => {
        try {
          await kanbanService.deleteTask(uuid);
          // Remove from boardData
          set((state) => {
            if (!state.boardData) return state;
            return {
              selectedTask: state.selectedTask?.uuid === uuid ? null : state.selectedTask,
              boardData: {
                ...state.boardData,
                columns: state.boardData.columns.map((col) => ({
                  ...col,
                  tasks: col.tasks.filter((t) => t.uuid !== uuid),
                  task_count: col.tasks.some((t) => t.uuid === uuid)
                    ? col.task_count - 1
                    : col.task_count,
                })),
              },
            };
          });
          return true;
        } catch (error) {
          console.error('Failed to delete task:', error);
          return false;
        }
      },

      moveTask: async (uuid: string, data: MoveKanbanTaskDto) => {
        try {
          await kanbanService.moveTask(uuid, data);
          return true;
        } catch (error) {
          console.error('Failed to move task:', error);
          // Revert optimistic update
          await get().refreshBoardData();
          return false;
        }
      },

      moveTaskOptimistic: (taskUuid: string, sourceColumnId: number, destColumnId: number, destPosition: number) => {
        set((state) => {
          if (!state.boardData) return state;

          let movedTask: KanbanTask | null = null;

          // Find and remove task from source column
          const updatedColumns = state.boardData.columns.map((col) => {
            if (col.id === sourceColumnId) {
              const taskIndex = col.tasks.findIndex((t) => t.uuid === taskUuid);
              if (taskIndex > -1) {
                movedTask = { ...col.tasks[taskIndex] };
                return {
                  ...col,
                  tasks: col.tasks.filter((t) => t.uuid !== taskUuid),
                  task_count: col.task_count - 1,
                };
              }
            }
            return col;
          });

          // Add task to destination column
          if (movedTask) {
            const finalColumns = updatedColumns.map((col) => {
              if (col.id === destColumnId) {
                const newTasks = [...col.tasks];
                movedTask!.column_id = destColumnId;
                movedTask!.position = destPosition;
                newTasks.splice(destPosition, 0, movedTask!);
                // Update positions
                newTasks.forEach((t, i) => {
                  t.position = i;
                });
                return {
                  ...col,
                  tasks: newTasks,
                  task_count: col.task_count + 1,
                };
              }
              return col;
            });

            return {
              boardData: {
                ...state.boardData,
                columns: finalColumns,
              },
            };
          }

          return state;
        });
      },

      setSelectedTask: (task: KanbanTask | null) => {
        set({ selectedTask: task });
      },

      clearSelectedTask: () => {
        set({ selectedTask: null });
      },

      // ============================================
      // Task Assignees
      // ============================================

      addTaskAssignee: async (taskUuid: string, userUuid: string) => {
        try {
          await kanbanService.addTaskAssignee(taskUuid, userUuid);
          // Refresh task if selected
          const { selectedTask } = get();
          if (selectedTask?.uuid === taskUuid) {
            await get().loadTask(taskUuid);
          }
          await get().refreshBoardData();
        } catch (error) {
          console.error('Failed to add assignee:', error);
        }
      },

      removeTaskAssignee: async (taskUuid: string, userUuid: string) => {
        try {
          await kanbanService.removeTaskAssignee(taskUuid, userUuid);
          // Refresh task if selected
          const { selectedTask } = get();
          if (selectedTask?.uuid === taskUuid) {
            await get().loadTask(taskUuid);
          }
          await get().refreshBoardData();
        } catch (error) {
          console.error('Failed to remove assignee:', error);
        }
      },

      // ============================================
      // Labels
      // ============================================

      loadLabels: async (projectUuid: string) => {
        set({ labelsLoading: true });
        try {
          const labels = await kanbanService.getLabels(projectUuid);
          set({ labels, labelsLoading: false });
        } catch (error) {
          console.error('Failed to load labels:', error);
          set({ labelsLoading: false });
        }
      },

      addTaskLabel: async (taskUuid: string, labelId: number) => {
        try {
          await kanbanService.addTaskLabel(taskUuid, labelId);
          // Refresh task if selected
          const { selectedTask } = get();
          if (selectedTask?.uuid === taskUuid) {
            await get().loadTask(taskUuid);
          }
        } catch (error) {
          console.error('Failed to add label:', error);
        }
      },

      removeTaskLabel: async (taskUuid: string, labelId: number) => {
        try {
          await kanbanService.removeTaskLabel(taskUuid, labelId);
          // Refresh task if selected
          const { selectedTask } = get();
          if (selectedTask?.uuid === taskUuid) {
            await get().loadTask(taskUuid);
          }
        } catch (error) {
          console.error('Failed to remove label:', error);
        }
      },

      // ============================================
      // Members
      // ============================================

      loadMembers: async (projectUuid: string) => {
        set({ membersLoading: true });
        try {
          const members = await kanbanService.getProjectMembers(projectUuid);
          set({ members, membersLoading: false });
        } catch (error) {
          console.error('Failed to load members:', error);
          set({ membersLoading: false });
        }
      },

      // ============================================
      // Filters
      // ============================================

      setTaskFilters: (filters) => {
        set({ taskFilters: filters });
      },

      clearTaskFilters: () => {
        set({ taskFilters: {} });
      },

      // ============================================
      // UI State
      // ============================================

      setCreatingProject: (state: boolean) => {
        set({ isCreatingProject: state });
      },

      setCreatingTask: (state: boolean) => {
        set({ isCreatingTask: state });
      },

      setCreatingColumn: (state: boolean) => {
        set({ isCreatingColumn: state });
      },

      // ============================================
      // Clear
      // ============================================

      clearKanbanState: () => {
        set(initialState);
      },

      clearBoardData: () => {
        set({
          boardData: null,
          currentBoard: null,
          selectedTask: null,
        });
      },

      clearErrors: () => {
        set({
          projectsError: null,
          boardDataError: null,
        });
      },
    }),
    {
      name: 'kanban-storage',
      partialize: (state) => ({
        // Only persist minimal UI state
        taskFilters: state.taskFilters,
      }),
      onRehydrateStorage: () => (state) => {
        state?.setHasHydrated(true);
      },
    }
  )
);

export default useKanbanStore;

import { apiClient, buildQueryString, toFormData } from '@/lib/api-client';
import type {
  KanbanEpic,
  KanbanEpicStatus,
  KanbanTask,
  CreateKanbanEpicDto,
  UpdateKanbanEpicDto,
  PaginationParams,
} from '@/types';

// ============================================
// Request Parameter Types
// ============================================

interface EpicListParams extends PaginationParams {
  status?: KanbanEpicStatus;
}

// ============================================
// Response Types
// ============================================

interface ApiDataResponse<T> {
  data: T;
  message?: string;
}

interface ApiListResponse<T> {
  data: T[];
  meta: {
    total: number;
    page: number;
    perPage: number;
    totalPages: number;
  };
}

// ============================================
// Epic Service
// ============================================

/**
 * Epic Service
 * Handles epic API calls for the kanban system.
 *
 * An epic is a project-level container that groups tasks and reports rollup
 * progress (story points + task counts). One level only: epic -> task.
 * Subtasks stay beneath tasks and are unaffected.
 *
 * Bodies are form-encoded, matching every other kanban service here — the
 * kanban routes read `ngx.req.get_post_args()`.
 */
export const epicService = {
  // ============================================
  // Epic CRUD
  // ============================================

  /**
   * Get epics for a project, each with its rollups
   */
  async getEpics(projectUuid: string, params?: EpicListParams): Promise<ApiListResponse<KanbanEpic>> {
    const queryString = buildQueryString({
      page: params?.page,
      perPage: params?.perPage,
      status: params?.status,
    });
    const response = await apiClient.get<ApiListResponse<KanbanEpic>>(
      `/api/v2/kanban/projects/${projectUuid}/epics${queryString}`
    );
    return response.data;
  },

  /**
   * Get a single epic
   */
  async getEpic(uuid: string): Promise<KanbanEpic> {
    const response = await apiClient.get<ApiDataResponse<KanbanEpic>>(
      `/api/v2/kanban/epics/${uuid}`
    );
    return response.data.data;
  },

  /**
   * Create an epic in a project
   */
  async createEpic(projectUuid: string, data: CreateKanbanEpicDto): Promise<KanbanEpic> {
    const response = await apiClient.post<ApiDataResponse<KanbanEpic>>(
      `/api/v2/kanban/projects/${projectUuid}/epics`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Update an epic
   */
  async updateEpic(uuid: string, data: UpdateKanbanEpicDto): Promise<KanbanEpic> {
    const response = await apiClient.put<ApiDataResponse<KanbanEpic>>(
      `/api/v2/kanban/epics/${uuid}`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Delete an epic (soft). Its tasks are detached, not deleted.
   */
  async deleteEpic(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/kanban/epics/${uuid}`);
  },

  // ============================================
  // Epic Tasks
  // ============================================

  /**
   * Get the tasks in an epic
   */
  async getEpicTasks(uuid: string, params?: PaginationParams): Promise<ApiListResponse<KanbanTask>> {
    const queryString = buildQueryString({
      page: params?.page,
      perPage: params?.perPage,
    });
    const response = await apiClient.get<ApiListResponse<KanbanTask>>(
      `/api/v2/kanban/epics/${uuid}/tasks${queryString}`
    );
    return response.data;
  },

  /**
   * Attach tasks to an epic.
   * Tasks outside the epic's project are ignored server-side.
   */
  async addTasks(uuid: string, taskUuids: string[]): Promise<{ attached_count: number }> {
    const response = await apiClient.post<ApiDataResponse<{ attached_count: number }>>(
      `/api/v2/kanban/epics/${uuid}/tasks`,
      toFormData({ task_uuids: JSON.stringify(taskUuids) })
    );
    return response.data.data;
  },

  /**
   * Detach tasks from an epic
   */
  async removeTasks(uuid: string, taskUuids: string[]): Promise<{ detached_count: number }> {
    const response = await apiClient.delete<ApiDataResponse<{ detached_count: number }>>(
      `/api/v2/kanban/epics/${uuid}/tasks`,
      { data: toFormData({ task_uuids: JSON.stringify(taskUuids) }) }
    );
    return response.data.data;
  },
};

// ============================================
// Helpers
// ============================================

/**
 * Wire value for a task's epic_id.
 *
 * toFormData drops null/undefined entirely, so "detach" has to travel as an
 * empty string — which the backend normalises to SQL NULL. Sending 0 instead
 * would violate the epic foreign key.
 */
export function epicIdForWire(epicId: number | null | undefined): number | string {
  return epicId ?? '';
}

/** Tailwind classes for an epic status pill */
export function getEpicStatusColor(status: KanbanEpicStatus): string {
  switch (status) {
    case 'in_progress':
      return 'bg-blue-100 text-blue-800 dark:bg-blue-900/40 dark:text-blue-300';
    case 'done':
      return 'bg-green-100 text-green-800 dark:bg-green-900/40 dark:text-green-300';
    case 'cancelled':
      return 'bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-400';
    default:
      return 'bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-300';
  }
}

/** Human label for an epic status */
export function getEpicStatusLabel(status: KanbanEpicStatus): string {
  switch (status) {
    case 'in_progress':
      return 'In progress';
    case 'done':
      return 'Done';
    case 'cancelled':
      return 'Cancelled';
    default:
      return 'Open';
  }
}

export default epicService;

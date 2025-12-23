import { apiClient, buildQueryString, toFormData } from '@/lib/api-client';
import type {
  KanbanSprint,
  KanbanSprintEnhanced,
  SprintBurndownPoint,
  VelocityHistory,
  PaginationParams,
} from '@/types';

// ============================================
// Request Parameter Types
// ============================================

interface SprintListParams extends PaginationParams {
  project_uuid?: string;
  status?: 'planning' | 'active' | 'completed' | 'cancelled';
}

interface CreateSprintDto {
  name: string;
  goal?: string;
  start_date: string;
  end_date: string;
  capacity_points?: number;
  capacity_hours?: number;
}

interface UpdateSprintDto {
  name?: string;
  goal?: string;
  start_date?: string;
  end_date?: string;
  capacity_points?: number;
  capacity_hours?: number;
  status?: 'planning' | 'active' | 'completed' | 'cancelled';
}

interface SprintRetrospectiveDto {
  went_well?: string;
  to_improve?: string;
  action_items?: string;
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
  total: number;
  page: number;
  per_page: number;
}

interface SprintStatsResponse {
  total_tasks: number;
  completed_tasks: number;
  in_progress_tasks: number;
  total_points: number;
  completed_points: number;
  remaining_points: number;
  total_hours_logged: number;
  days_remaining: number;
  completion_rate: number;
  velocity: number;
  burndown_ideal: number[];
  burndown_actual: number[];
}

// ============================================
// Sprint Service
// ============================================

/**
 * Sprint Service
 * Handles all sprint-related API calls for the kanban system
 *
 * FEATURES:
 * - Sprint CRUD operations
 * - Sprint lifecycle management (planning -> active -> completed)
 * - Burndown chart data
 * - Velocity tracking
 * - Sprint retrospectives
 */
export const sprintService = {
  // ============================================
  // Sprint CRUD
  // ============================================

  /**
   * Get sprints for a project
   */
  async getSprints(projectUuid: string, params?: SprintListParams): Promise<ApiListResponse<KanbanSprint>> {
    const queryString = buildQueryString({
      page: params?.page,
      per_page: params?.perPage,
      limit: params?.perPage,
      status: params?.status,
    });
    const response = await apiClient.get<ApiListResponse<KanbanSprint>>(
      `/api/v2/kanban/projects/${projectUuid}/sprints${queryString}`
    );
    return response.data;
  },

  /**
   * Get a single sprint with enhanced data
   */
  async getSprint(uuid: string): Promise<KanbanSprintEnhanced> {
    const response = await apiClient.get<ApiDataResponse<KanbanSprintEnhanced>>(
      `/api/v2/kanban/sprints/${uuid}`
    );
    return response.data.data;
  },

  /**
   * Get the active sprint for a project
   */
  async getActiveSprint(projectUuid: string): Promise<KanbanSprintEnhanced | null> {
    const response = await apiClient.get<ApiDataResponse<KanbanSprintEnhanced | null>>(
      `/api/v2/kanban/projects/${projectUuid}/sprints/active`
    );
    return response.data.data;
  },

  /**
   * Create a new sprint
   */
  async createSprint(projectUuid: string, data: CreateSprintDto): Promise<KanbanSprint> {
    const response = await apiClient.post<ApiDataResponse<KanbanSprint>>(
      `/api/v2/kanban/projects/${projectUuid}/sprints`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Update a sprint
   */
  async updateSprint(uuid: string, data: UpdateSprintDto): Promise<KanbanSprint> {
    const response = await apiClient.put<ApiDataResponse<KanbanSprint>>(
      `/api/v2/kanban/sprints/${uuid}`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Delete a sprint
   */
  async deleteSprint(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/kanban/sprints/${uuid}`);
  },

  // ============================================
  // Sprint Lifecycle
  // ============================================

  /**
   * Start a sprint
   */
  async startSprint(uuid: string): Promise<KanbanSprint> {
    const response = await apiClient.post<ApiDataResponse<KanbanSprint>>(
      `/api/v2/kanban/sprints/${uuid}/start`
    );
    return response.data.data;
  },

  /**
   * Complete a sprint
   */
  async completeSprint(uuid: string, retrospective?: SprintRetrospectiveDto): Promise<KanbanSprint> {
    const data = retrospective || {};
    const response = await apiClient.post<ApiDataResponse<KanbanSprint>>(
      `/api/v2/kanban/sprints/${uuid}/complete`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Cancel a sprint
   */
  async cancelSprint(uuid: string, reason?: string): Promise<KanbanSprint> {
    const data: Record<string, unknown> = {};
    if (reason) data.reason = reason;

    const response = await apiClient.post<ApiDataResponse<KanbanSprint>>(
      `/api/v2/kanban/sprints/${uuid}/cancel`,
      toFormData(data)
    );
    return response.data.data;
  },

  // ============================================
  // Sprint Tasks
  // ============================================

  /**
   * Add tasks to a sprint
   */
  async addTasksToSprint(uuid: string, taskUuids: string[]): Promise<{ count: number }> {
    const response = await apiClient.post<ApiDataResponse<{ count: number }>>(
      `/api/v2/kanban/sprints/${uuid}/tasks`,
      toFormData({ task_uuids: JSON.stringify(taskUuids) })
    );
    return response.data.data;
  },

  /**
   * Remove tasks from a sprint
   */
  async removeTasksFromSprint(uuid: string, taskUuids: string[]): Promise<{ count: number }> {
    const response = await apiClient.delete<ApiDataResponse<{ count: number }>>(
      `/api/v2/kanban/sprints/${uuid}/tasks`,
      { data: toFormData({ task_uuids: JSON.stringify(taskUuids) }) }
    );
    return response.data.data;
  },

  // ============================================
  // Sprint Analytics
  // ============================================

  /**
   * Get sprint statistics
   */
  async getSprintStats(uuid: string): Promise<SprintStatsResponse> {
    const response = await apiClient.get<ApiDataResponse<SprintStatsResponse>>(
      `/api/v2/kanban/sprints/${uuid}/stats`
    );
    return response.data.data;
  },

  /**
   * Get burndown chart data
   */
  async getBurndown(uuid: string): Promise<SprintBurndownPoint[]> {
    const response = await apiClient.get<ApiDataResponse<SprintBurndownPoint[]>>(
      `/api/v2/kanban/sprints/${uuid}/burndown`
    );
    return response.data.data;
  },

  /**
   * Get velocity history for a project
   */
  async getVelocityHistory(projectUuid: string, limit?: number): Promise<VelocityHistory[]> {
    const queryString = limit ? `?limit=${limit}` : '';
    const response = await apiClient.get<ApiDataResponse<VelocityHistory[]>>(
      `/api/v2/kanban/projects/${projectUuid}/velocity${queryString}`
    );
    return response.data.data;
  },

  /**
   * Save sprint retrospective
   */
  async saveRetrospective(uuid: string, data: SprintRetrospectiveDto): Promise<KanbanSprint> {
    const response = await apiClient.put<ApiDataResponse<KanbanSprint>>(
      `/api/v2/kanban/sprints/${uuid}/retrospective`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },
};

// ============================================
// Helper Functions
// ============================================

/**
 * Get sprint status color
 */
export function getSprintStatusColor(status: string): string {
  const colors: Record<string, string> = {
    planning: 'bg-blue-100 text-blue-700',
    active: 'bg-green-100 text-green-700',
    completed: 'bg-gray-100 text-gray-700',
    cancelled: 'bg-red-100 text-red-700',
  };
  return colors[status] || colors.planning;
}

/**
 * Get sprint status label
 */
export function getSprintStatusLabel(status: string): string {
  const labels: Record<string, string> = {
    planning: 'Planning',
    active: 'Active',
    completed: 'Completed',
    cancelled: 'Cancelled',
  };
  return labels[status] || status;
}

/**
 * Calculate sprint progress percentage
 */
export function calculateSprintProgress(completedPoints: number, totalPoints: number): number {
  if (totalPoints <= 0) return 0;
  return Math.min(100, Math.round((completedPoints / totalPoints) * 100));
}

/**
 * Calculate days remaining in sprint
 */
export function calculateDaysRemaining(endDate: string): number {
  const end = new Date(endDate);
  const now = new Date();
  now.setHours(0, 0, 0, 0);
  end.setHours(0, 0, 0, 0);

  const diffTime = end.getTime() - now.getTime();
  const diffDays = Math.ceil(diffTime / (1000 * 60 * 60 * 24));
  return Math.max(0, diffDays);
}

/**
 * Calculate sprint duration in days
 */
export function calculateSprintDuration(startDate: string, endDate: string): number {
  const start = new Date(startDate);
  const end = new Date(endDate);
  const diffTime = end.getTime() - start.getTime();
  return Math.ceil(diffTime / (1000 * 60 * 60 * 24)) + 1;
}

/**
 * Format sprint date range
 */
export function formatSprintDateRange(startDate: string, endDate: string): string {
  const start = new Date(startDate);
  const end = new Date(endDate);

  const startStr = start.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
  const endStr = end.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });

  const sameYear = start.getFullYear() === end.getFullYear();
  const sameMonth = start.getMonth() === end.getMonth();

  if (sameYear && sameMonth) {
    return `${start.toLocaleDateString('en-US', { month: 'short' })} ${start.getDate()}-${end.getDate()}`;
  }

  return `${startStr} - ${endStr}`;
}

/**
 * Get ideal burndown line data points
 */
export function calculateIdealBurndown(totalPoints: number, durationDays: number): number[] {
  const pointsPerDay = totalPoints / durationDays;
  const idealLine: number[] = [];

  for (let i = 0; i <= durationDays; i++) {
    idealLine.push(Math.max(0, totalPoints - (pointsPerDay * i)));
  }

  return idealLine;
}

/**
 * Calculate velocity from sprint history
 */
export function calculateAverageVelocity(velocityHistory: VelocityHistory): number {
  if (!velocityHistory || velocityHistory.sprints.length === 0) return 0;

  const completedSprints = velocityHistory.sprints.filter(v => v.status === 'completed');
  if (completedSprints.length === 0) return 0;

  const totalPoints = completedSprints.reduce((sum, v) => sum + v.completed_points, 0);
  return Math.round(totalPoints / completedSprints.length);
}

/**
 * Predict sprint completion based on current velocity
 */
export function predictSprintCompletion(
  remainingPoints: number,
  daysRemaining: number,
  averageVelocityPerDay: number
): 'on-track' | 'at-risk' | 'behind' {
  if (daysRemaining <= 0) {
    return remainingPoints <= 0 ? 'on-track' : 'behind';
  }

  const requiredVelocity = remainingPoints / daysRemaining;

  if (requiredVelocity <= averageVelocityPerDay * 0.8) {
    return 'on-track';
  } else if (requiredVelocity <= averageVelocityPerDay * 1.2) {
    return 'at-risk';
  } else {
    return 'behind';
  }
}

export default sprintService;

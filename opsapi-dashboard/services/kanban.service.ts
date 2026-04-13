import { apiClient, buildQueryString, toFormData } from '@/lib/api-client';
import type {
  KanbanProject,
  KanbanBoard,
  KanbanColumn,
  KanbanTask,
  KanbanLabel,
  KanbanComment,
  KanbanChecklist,
  KanbanChecklistItem,
  KanbanAttachment,
  KanbanActivity,
  KanbanProjectMember,
  KanbanProjectStats,
  KanbanProjectsResponse,
  KanbanBoardFullResponse,
  KanbanMyTasksResponse,
  CreateKanbanProjectDto,
  UpdateKanbanProjectDto,
  CreateKanbanBoardDto,
  UpdateKanbanBoardDto,
  CreateKanbanColumnDto,
  UpdateKanbanColumnDto,
  CreateKanbanTaskDto,
  UpdateKanbanTaskDto,
  MoveKanbanTaskDto,
  CreateKanbanLabelDto,
  UpdateKanbanLabelDto,
  CreateKanbanCommentDto,
  UpdateKanbanCommentDto,
  CreateKanbanChecklistDto,
  UpdateKanbanChecklistDto,
  CreateKanbanChecklistItemDto,
  UpdateKanbanChecklistItemDto,
  AddKanbanMemberDto,
  UpdateKanbanMemberDto,
  ReorderColumnsDto,
  PaginationParams,
  KanbanTaskStatus,
  KanbanTaskPriority,
  KanbanProjectStatus,
} from '@/types';

// ============================================
// Request Parameter Types
// ============================================

interface ProjectListParams extends PaginationParams {
  status?: KanbanProjectStatus;
  search?: string;
  starred?: boolean;
}

interface TaskListParams extends PaginationParams {
  status?: KanbanTaskStatus;
  priority?: KanbanTaskPriority;
  assignee_uuid?: string;
  search?: string;
  due_date_from?: string;
  due_date_to?: string;
  overdue?: boolean;
}

interface MyTasksParams extends PaginationParams {
  status?: KanbanTaskStatus;
  priority?: KanbanTaskPriority;
  project_uuid?: string;
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

// ============================================
// Kanban Service
// ============================================

/**
 * Kanban Service
 * Handles all kanban-related API calls for project management
 *
 * ARCHITECTURE:
 * - Projects are namespace-scoped (multi-tenant)
 * - Each project has boards (e.g., Sprint 1, Sprint 2)
 * - Each board has columns (e.g., Backlog, To Do, In Progress, Done)
 * - Tasks belong to columns and can be moved between them
 * - Task assignments auto-create chat channels for collaboration
 */
export const kanbanService = {
  // ============================================
  // Projects
  // ============================================

  /**
   * Get all projects for the current namespace
   */
  async getProjects(params?: ProjectListParams): Promise<KanbanProjectsResponse> {
    const queryString = buildQueryString({
      page: params?.page,
      per_page: params?.perPage,
      limit: params?.perPage,
      status: params?.status,
      search: params?.search,
      starred: params?.starred,
      order_by: params?.orderBy,
      order_dir: params?.orderDir,
    });
    const response = await apiClient.get<KanbanProjectsResponse>(
      `/api/v2/kanban/projects${queryString}`
    );
    return response.data;
  },

  /**
   * Get a single project with details
   */
  async getProject(uuid: string): Promise<KanbanProject> {
    const response = await apiClient.get<ApiDataResponse<KanbanProject>>(
      `/api/v2/kanban/projects/${uuid}`
    );
    return response.data.data;
  },

  /**
   * Create a new project
   */
  async createProject(data: CreateKanbanProjectDto): Promise<KanbanProject> {
    const response = await apiClient.post<ApiDataResponse<KanbanProject>>(
      '/api/v2/kanban/projects',
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Update a project
   */
  async updateProject(uuid: string, data: UpdateKanbanProjectDto): Promise<KanbanProject> {
    const response = await apiClient.put<ApiDataResponse<KanbanProject>>(
      `/api/v2/kanban/projects/${uuid}`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Delete a project (soft delete)
   */
  async deleteProject(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/kanban/projects/${uuid}`);
  },

  /**
   * Get project statistics
   */
  async getProjectStats(uuid: string): Promise<KanbanProjectStats> {
    const response = await apiClient.get<ApiDataResponse<KanbanProjectStats>>(
      `/api/v2/kanban/projects/${uuid}/stats`
    );
    return response.data.data;
  },

  /**
   * Toggle project starred status
   */
  async toggleProjectStar(uuid: string): Promise<{ is_starred: boolean }> {
    const response = await apiClient.post<ApiDataResponse<{ is_starred: boolean }>>(
      `/api/v2/kanban/projects/${uuid}/star`
    );
    return response.data.data;
  },

  // ============================================
  // Project Members
  // ============================================

  /**
   * Get project members
   */
  async getProjectMembers(projectUuid: string): Promise<KanbanProjectMember[]> {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const response = await apiClient.get<ApiListResponse<any>>(
      `/api/v2/kanban/projects/${projectUuid}/members`
    );
    // Transform flat member data to nested user structure expected by frontend
    // Backend returns: { id, uuid, user_uuid, first_name, last_name, email, username, ... }
    // Frontend expects: { id, uuid, user_uuid, user: { first_name, last_name, email, ... }, ... }
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    return response.data.data.map((member: any) => {
      const transformed: KanbanProjectMember = {
        id: member.id,
        uuid: member.uuid,
        project_id: member.project_id,
        user_uuid: member.user_uuid,
        role: member.role,
        permissions: member.permissions,
        joined_at: member.joined_at,
        invited_by: member.invited_by,
        is_starred: member.is_starred || false,
        notification_preference: member.notification_preference || 'all',
        last_accessed_at: member.last_accessed_at,
        created_at: member.created_at,
        updated_at: member.updated_at,
        left_at: member.left_at,
        deleted_at: member.deleted_at,
        user: {
          uuid: member.user_uuid,
          first_name: member.first_name || '',
          last_name: member.last_name || '',
          email: member.email || '',
        },
      };
      return transformed;
    });
  },

  /**
   * Add a member to project
   */
  async addProjectMember(
    projectUuid: string,
    data: AddKanbanMemberDto
  ): Promise<KanbanProjectMember> {
    const response = await apiClient.post<ApiDataResponse<KanbanProjectMember>>(
      `/api/v2/kanban/projects/${projectUuid}/members`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Update a project member's role
   */
  async updateProjectMember(
    projectUuid: string,
    userUuid: string,
    data: UpdateKanbanMemberDto
  ): Promise<KanbanProjectMember> {
    const response = await apiClient.put<ApiDataResponse<KanbanProjectMember>>(
      `/api/v2/kanban/projects/${projectUuid}/members/${userUuid}/role`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Remove a member from project
   */
  async removeProjectMember(projectUuid: string, userUuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/kanban/projects/${projectUuid}/members/${userUuid}`);
  },

  // ============================================
  // Boards
  // ============================================

  /**
   * Get all boards for a project
   */
  async getBoards(projectUuid: string): Promise<KanbanBoard[]> {
    const response = await apiClient.get<ApiListResponse<KanbanBoard>>(
      `/api/v2/kanban/projects/${projectUuid}/boards`
    );
    return response.data.data;
  },

  /**
   * Get a single board with columns
   */
  async getBoard(uuid: string): Promise<KanbanBoard> {
    const response = await apiClient.get<ApiDataResponse<KanbanBoard>>(
      `/api/v2/kanban/boards/${uuid}`
    );
    return response.data.data;
  },

  /**
   * Get full board with columns and tasks (main board view)
   */
  async getBoardFull(uuid: string): Promise<KanbanBoardFullResponse> {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const response = await apiClient.get<ApiDataResponse<any>>(
      `/api/v2/kanban/boards/${uuid}/full`
    );

    // Transform the API response to match the expected KanbanBoardFullResponse structure
    // The API returns a flat structure with board fields + columns + project fields mixed together
    const rawData = response.data.data;

    // Extract board data
    const board: KanbanBoard = {
      id: rawData.id,
      uuid: rawData.uuid,
      project_id: rawData.project_id,
      name: rawData.name,
      description: rawData.description,
      position: rawData.position,
      is_default: rawData.is_default,
      wip_limit: rawData.wip_limit,
      settings: rawData.settings || {},
      column_count: rawData.column_count || rawData.columns?.length || 0,
      task_count: rawData.task_count || 0,
      created_by: rawData.created_by,
      created_at: rawData.created_at,
      updated_at: rawData.updated_at,
    };

    // Extract project data from the flat response
    const project: KanbanProject = {
      id: rawData.project_id,
      uuid: rawData.project_uuid,
      namespace_id: rawData.namespace_id,
      name: rawData.project_name,
      slug: '',
      status: 'active',
      visibility: 'private',
      task_count: 0,
      completed_task_count: 0,
      member_count: 1,
      board_count: 1,
      budget: 0,
      budget_spent: 0,
      budget_currency: 'USD',
      owner_user_uuid: rawData.created_by || '',
      settings: {},
      metadata: {},
      created_at: rawData.created_at,
      updated_at: rawData.updated_at,
    };

    // Columns are already in the correct format with tasks embedded
    const columns = Array.isArray(rawData.columns) ? rawData.columns : [];

    return {
      board,
      columns,
      project,
    };
  },

  /**
   * Create a new board
   */
  async createBoard(projectUuid: string, data: CreateKanbanBoardDto): Promise<KanbanBoard> {
    const response = await apiClient.post<ApiDataResponse<KanbanBoard>>(
      `/api/v2/kanban/projects/${projectUuid}/boards`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Update a board
   */
  async updateBoard(uuid: string, data: UpdateKanbanBoardDto): Promise<KanbanBoard> {
    const response = await apiClient.put<ApiDataResponse<KanbanBoard>>(
      `/api/v2/kanban/boards/${uuid}`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Delete a board
   */
  async deleteBoard(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/kanban/boards/${uuid}`);
  },

  // ============================================
  // Columns
  // ============================================

  /**
   * Get all columns for a board
   */
  async getColumns(boardUuid: string): Promise<KanbanColumn[]> {
    const response = await apiClient.get<ApiListResponse<KanbanColumn>>(
      `/api/v2/kanban/boards/${boardUuid}/columns`
    );
    return response.data.data;
  },

  /**
   * Create a new column
   */
  async createColumn(boardUuid: string, data: CreateKanbanColumnDto): Promise<KanbanColumn> {
    const response = await apiClient.post<ApiDataResponse<KanbanColumn>>(
      `/api/v2/kanban/boards/${boardUuid}/columns`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Update a column
   */
  async updateColumn(uuid: string, data: UpdateKanbanColumnDto): Promise<KanbanColumn> {
    const response = await apiClient.put<ApiDataResponse<KanbanColumn>>(
      `/api/v2/kanban/columns/${uuid}`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Delete a column
   */
  async deleteColumn(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/kanban/columns/${uuid}`);
  },

  /**
   * Reorder columns in a board
   */
  async reorderColumns(boardUuid: string, data: ReorderColumnsDto): Promise<void> {
    await apiClient.put(
      `/api/v2/kanban/boards/${boardUuid}/columns/reorder`,
      toFormData({ column_ids: JSON.stringify(data.column_ids) })
    );
  },

  // ============================================
  // Tasks
  // ============================================

  /**
   * Get tasks for a board (optionally filtered by column)
   */
  async getTasks(boardUuid: string, params?: TaskListParams): Promise<KanbanTask[]> {
    const queryString = buildQueryString({
      page: params?.page,
      per_page: params?.perPage,
      limit: params?.perPage,
      status: params?.status,
      priority: params?.priority,
      assignee_uuid: params?.assignee_uuid,
      search: params?.search,
      due_date_from: params?.due_date_from,
      due_date_to: params?.due_date_to,
      overdue: params?.overdue,
    });
    const response = await apiClient.get<ApiListResponse<KanbanTask>>(
      `/api/v2/kanban/boards/${boardUuid}/tasks${queryString}`
    );
    return response.data.data;
  },

  /**
   * Get a single task with full details
   */
  async getTask(uuid: string): Promise<KanbanTask> {
    const response = await apiClient.get<ApiDataResponse<KanbanTask>>(
      `/api/v2/kanban/tasks/${uuid}`
    );
    return response.data.data;
  },

  /**
   * Create a new task
   */
  async createTask(boardUuid: string, data: CreateKanbanTaskDto): Promise<KanbanTask> {
    const formData: Record<string, unknown> = { ...data };
    if (data.assignee_uuids) {
      formData.assignee_uuids = JSON.stringify(data.assignee_uuids);
    }
    if (data.label_ids) {
      formData.label_ids = JSON.stringify(data.label_ids);
    }
    const response = await apiClient.post<ApiDataResponse<KanbanTask>>(
      `/api/v2/kanban/boards/${boardUuid}/tasks`,
      toFormData(formData)
    );
    return response.data.data;
  },

  /**
   * Update a task
   */
  async updateTask(uuid: string, data: UpdateKanbanTaskDto): Promise<KanbanTask> {
    const formData: Record<string, unknown> = { ...data };
    if (data.assignee_uuids) {
      formData.assignee_uuids = JSON.stringify(data.assignee_uuids);
    }
    if (data.label_ids) {
      formData.label_ids = JSON.stringify(data.label_ids);
    }
    const response = await apiClient.put<ApiDataResponse<KanbanTask>>(
      `/api/v2/kanban/tasks/${uuid}`,
      toFormData(formData)
    );
    return response.data.data;
  },

  /**
   * Delete a task (soft delete)
   */
  async deleteTask(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/kanban/tasks/${uuid}`);
  },

  /**
   * Move a task to a different column/position
   */
  async moveTask(uuid: string, data: MoveKanbanTaskDto): Promise<KanbanTask> {
    const response = await apiClient.put<ApiDataResponse<KanbanTask>>(
      `/api/v2/kanban/tasks/${uuid}/move`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Get my assigned tasks across all projects
   */
  async getMyTasks(params?: MyTasksParams): Promise<KanbanMyTasksResponse> {
    const queryString = buildQueryString({
      page: params?.page,
      per_page: params?.perPage,
      limit: params?.perPage,
      status: params?.status,
      priority: params?.priority,
      project_uuid: params?.project_uuid,
    });
    const response = await apiClient.get<KanbanMyTasksResponse>(
      `/api/v2/kanban/my-tasks${queryString}`
    );
    return response.data;
  },

  // ============================================
  // Task Assignees
  // ============================================

  /**
   * Add an assignee to a task (auto-creates chat channel)
   */
  async addTaskAssignee(
    taskUuid: string,
    userUuid: string
  ): Promise<{ assignment: { uuid: string }; chat_channel_uuid?: string }> {
    const response = await apiClient.post<
      ApiDataResponse<{ assignment: { uuid: string }; chat_channel_uuid?: string }>
    >(
      `/api/v2/kanban/tasks/${taskUuid}/assignees`,
      toFormData({ user_uuid: userUuid })
    );
    return response.data.data;
  },

  /**
   * Remove an assignee from a task
   */
  async removeTaskAssignee(taskUuid: string, userUuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/kanban/tasks/${taskUuid}/assignees/${userUuid}`);
  },

  // ============================================
  // Labels
  // ============================================

  /**
   * Get all labels for a project
   */
  async getLabels(projectUuid: string): Promise<KanbanLabel[]> {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const response = await apiClient.get<any>(
      `/api/v2/kanban/projects/${projectUuid}/labels`
    );
    // Handle both response formats:
    // Standard API: { success: true, data: [...] }
    // Paginated API: { data: [...], total, page, per_page }
    const data = response.data?.data || response.data || [];
    return Array.isArray(data) ? data : [];
  },

  /**
   * Create a new label
   */
  async createLabel(projectUuid: string, data: CreateKanbanLabelDto): Promise<KanbanLabel> {
    const response = await apiClient.post<ApiDataResponse<KanbanLabel>>(
      `/api/v2/kanban/projects/${projectUuid}/labels`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Update a label
   */
  async updateLabel(uuid: string, data: UpdateKanbanLabelDto): Promise<KanbanLabel> {
    const response = await apiClient.put<ApiDataResponse<KanbanLabel>>(
      `/api/v2/kanban/labels/${uuid}`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Delete a label
   */
  async deleteLabel(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/kanban/labels/${uuid}`);
  },

  /**
   * Add a label to a task
   */
  async addTaskLabel(taskUuid: string, labelId: number): Promise<void> {
    await apiClient.post(
      `/api/v2/kanban/tasks/${taskUuid}/labels`,
      toFormData({ label_id: labelId })
    );
  },

  /**
   * Remove a label from a task
   */
  async removeTaskLabel(taskUuid: string, labelId: number): Promise<void> {
    await apiClient.delete(`/api/v2/kanban/tasks/${taskUuid}/labels/${labelId}`);
  },

  // ============================================
  // Comments
  // ============================================

  /**
   * Get comments for a task
   */
  async getComments(taskUuid: string): Promise<KanbanComment[]> {
    const response = await apiClient.get<ApiListResponse<KanbanComment>>(
      `/api/v2/kanban/tasks/${taskUuid}/comments`
    );
    return response.data.data;
  },

  /**
   * Add a comment to a task
   */
  async addComment(taskUuid: string, data: CreateKanbanCommentDto): Promise<KanbanComment> {
    const response = await apiClient.post<ApiDataResponse<KanbanComment>>(
      `/api/v2/kanban/tasks/${taskUuid}/comments`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Update a comment
   */
  async updateComment(uuid: string, data: UpdateKanbanCommentDto): Promise<KanbanComment> {
    const response = await apiClient.put<ApiDataResponse<KanbanComment>>(
      `/api/v2/kanban/comments/${uuid}`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Delete a comment
   */
  async deleteComment(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/kanban/comments/${uuid}`);
  },

  // ============================================
  // Checklists
  // ============================================

  /**
   * Get checklists for a task
   */
  async getChecklists(taskUuid: string): Promise<KanbanChecklist[]> {
    const response = await apiClient.get<ApiListResponse<KanbanChecklist>>(
      `/api/v2/kanban/tasks/${taskUuid}/checklists`
    );
    return response.data.data;
  },

  /**
   * Create a checklist
   */
  async createChecklist(taskUuid: string, data: CreateKanbanChecklistDto): Promise<KanbanChecklist> {
    const response = await apiClient.post<ApiDataResponse<KanbanChecklist>>(
      `/api/v2/kanban/tasks/${taskUuid}/checklists`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Update a checklist
   */
  async updateChecklist(uuid: string, data: UpdateKanbanChecklistDto): Promise<KanbanChecklist> {
    const response = await apiClient.put<ApiDataResponse<KanbanChecklist>>(
      `/api/v2/kanban/checklists/${uuid}`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Delete a checklist
   */
  async deleteChecklist(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/kanban/checklists/${uuid}`);
  },

  /**
   * Add an item to a checklist
   */
  async addChecklistItem(
    checklistUuid: string,
    data: CreateKanbanChecklistItemDto
  ): Promise<KanbanChecklistItem> {
    const response = await apiClient.post<ApiDataResponse<KanbanChecklistItem>>(
      `/api/v2/kanban/checklists/${checklistUuid}/items`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Update a checklist item
   */
  async updateChecklistItem(
    uuid: string,
    data: UpdateKanbanChecklistItemDto
  ): Promise<KanbanChecklistItem> {
    const response = await apiClient.put<ApiDataResponse<KanbanChecklistItem>>(
      `/api/v2/kanban/checklist-items/${uuid}`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Delete a checklist item
   */
  async deleteChecklistItem(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/kanban/checklist-items/${uuid}`);
  },

  /**
   * Toggle checklist item completion
   */
  async toggleChecklistItem(uuid: string): Promise<KanbanChecklistItem> {
    const response = await apiClient.post<ApiDataResponse<KanbanChecklistItem>>(
      `/api/v2/kanban/checklist-items/${uuid}/toggle`
    );
    return response.data.data;
  },

  // ============================================
  // Attachments
  // ============================================

  /**
   * Get attachments for a task
   */
  async getAttachments(taskUuid: string): Promise<KanbanAttachment[]> {
    const response = await apiClient.get<ApiListResponse<KanbanAttachment>>(
      `/api/v2/kanban/tasks/${taskUuid}/attachments`
    );
    return response.data.data;
  },

  /**
   * Upload an attachment
   */
  async uploadAttachment(taskUuid: string, file: File): Promise<KanbanAttachment> {
    const formData = new FormData();
    formData.append('file', file);

    const response = await apiClient.post<ApiDataResponse<KanbanAttachment>>(
      `/api/v2/kanban/tasks/${taskUuid}/attachments`,
      formData,
      {
        headers: {
          'Content-Type': 'multipart/form-data',
        },
      }
    );
    return response.data.data;
  },

  /**
   * Delete an attachment
   */
  async deleteAttachment(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/kanban/attachments/${uuid}`);
  },

  // ============================================
  // Activity
  // ============================================

  /**
   * Get activity log for a task
   */
  async getTaskActivity(taskUuid: string, params?: PaginationParams): Promise<KanbanActivity[]> {
    const queryString = buildQueryString({
      page: params?.page,
      per_page: params?.perPage,
      limit: params?.perPage,
    });
    const response = await apiClient.get<ApiListResponse<KanbanActivity>>(
      `/api/v2/kanban/tasks/${taskUuid}/activities${queryString}`
    );
    return response.data.data;
  },
};

// ============================================
// Helper Functions
// ============================================

/**
 * Get color classes for task priority
 */
export function getPriorityColor(priority: KanbanTaskPriority): string {
  const colors: Record<KanbanTaskPriority, string> = {
    critical: 'bg-red-100 text-red-700 border-red-200',
    high: 'bg-orange-100 text-orange-700 border-orange-200',
    medium: 'bg-yellow-100 text-yellow-700 border-yellow-200',
    low: 'bg-blue-100 text-blue-700 border-blue-200',
    none: 'bg-gray-100 text-gray-700 border-gray-200',
  };
  return colors[priority] || colors.medium;
}

/**
 * Get color classes for task status
 */
export function getTaskStatusColor(status: KanbanTaskStatus): string {
  const colors: Record<KanbanTaskStatus, string> = {
    open: 'bg-gray-100 text-gray-700 border-gray-200',
    in_progress: 'bg-blue-100 text-blue-700 border-blue-200',
    blocked: 'bg-red-100 text-red-700 border-red-200',
    review: 'bg-purple-100 text-purple-700 border-purple-200',
    completed: 'bg-green-100 text-green-700 border-green-200',
    cancelled: 'bg-gray-100 text-gray-500 border-gray-200',
  };
  return colors[status] || colors.open;
}

/**
 * Get color classes for project status
 */
export function getProjectStatusColor(status: KanbanProjectStatus): string {
  const colors: Record<KanbanProjectStatus, string> = {
    active: 'bg-green-100 text-green-700 border-green-200',
    on_hold: 'bg-yellow-100 text-yellow-700 border-yellow-200',
    completed: 'bg-blue-100 text-blue-700 border-blue-200',
    archived: 'bg-gray-100 text-gray-500 border-gray-200',
    cancelled: 'bg-red-100 text-red-700 border-red-200',
  };
  return colors[status] || colors.active;
}

/**
 * Format priority for display
 */
export function formatPriority(priority: KanbanTaskPriority): string {
  const labels: Record<KanbanTaskPriority, string> = {
    critical: 'Critical',
    high: 'High',
    medium: 'Medium',
    low: 'Low',
    none: 'None',
  };
  return labels[priority] || priority;
}

/**
 * Format task status for display
 */
export function formatTaskStatus(status: KanbanTaskStatus): string {
  const labels: Record<KanbanTaskStatus, string> = {
    open: 'Open',
    in_progress: 'In Progress',
    blocked: 'Blocked',
    review: 'In Review',
    completed: 'Completed',
    cancelled: 'Cancelled',
  };
  return labels[status] || status;
}

/**
 * Format project status for display
 */
export function formatProjectStatus(status: KanbanProjectStatus): string {
  const labels: Record<KanbanProjectStatus, string> = {
    active: 'Active',
    on_hold: 'On Hold',
    completed: 'Completed',
    archived: 'Archived',
    cancelled: 'Cancelled',
  };
  return labels[status] || status;
}

/**
 * Get priority icon name (for Lucide icons)
 */
export function getPriorityIcon(priority: KanbanTaskPriority): string {
  const icons: Record<KanbanTaskPriority, string> = {
    critical: 'AlertTriangle',
    high: 'ArrowUp',
    medium: 'Minus',
    low: 'ArrowDown',
    none: 'Circle',
  };
  return icons[priority] || icons.medium;
}

/**
 * Format budget amount
 */
export function formatBudget(amount: number, currency: string): string {
  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency: currency,
  }).format(amount);
}

/**
 * Calculate budget progress percentage
 */
export function getBudgetProgress(spent: number, total: number): number {
  if (total <= 0) return 0;
  return Math.min(100, Math.round((spent / total) * 100));
}

/**
 * Format time in minutes to human readable
 */
export function formatTimeMinutes(minutes: number): string {
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  const mins = minutes % 60;
  if (hours < 24) return mins > 0 ? `${hours}h ${mins}m` : `${hours}h`;
  const days = Math.floor(hours / 24);
  const remainingHours = hours % 24;
  return remainingHours > 0 ? `${days}d ${remainingHours}h` : `${days}d`;
}

/**
 * Check if a task is overdue
 */
export function isTaskOverdue(task: KanbanTask): boolean {
  if (!task.due_date) return false;
  if (task.status === 'completed' || task.status === 'cancelled') return false;
  return new Date(task.due_date) < new Date();
}

/**
 * Get days until due date (negative if overdue)
 */
export function getDaysUntilDue(dueDate: string): number {
  const due = new Date(dueDate);
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  due.setHours(0, 0, 0, 0);
  const diffTime = due.getTime() - today.getTime();
  return Math.ceil(diffTime / (1000 * 60 * 60 * 24));
}

/**
 * Default label colors for creation
 */
export const DEFAULT_LABEL_COLORS = [
  '#ef4444', // red
  '#f97316', // orange
  '#eab308', // yellow
  '#22c55e', // green
  '#14b8a6', // teal
  '#3b82f6', // blue
  '#8b5cf6', // violet
  '#ec4899', // pink
  '#6b7280', // gray
  '#1f2937', // dark gray
];

/**
 * Default column colors
 */
export const DEFAULT_COLUMN_COLORS = [
  '#6b7280', // gray (backlog)
  '#3b82f6', // blue (to do)
  '#f59e0b', // amber (in progress)
  '#8b5cf6', // purple (review)
  '#22c55e', // green (done)
];

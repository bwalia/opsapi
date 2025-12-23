import { apiClient, buildQueryString, toFormData } from '@/lib/api-client';
import type {
  KanbanNotification,
  NotificationPreferences,
  NotificationType,
  PaginationParams,
} from '@/types';

// ============================================
// Request Parameter Types
// ============================================

interface NotificationListParams extends PaginationParams {
  unread_only?: boolean;
  type?: NotificationType;
  project_id?: number;
}

interface UpdatePreferencesParams {
  email_enabled?: boolean;
  push_enabled?: boolean;
  in_app_enabled?: boolean;
  digest_frequency?: 'instant' | 'hourly' | 'daily' | 'weekly' | 'none';
  preferences?: Record<NotificationType, boolean>;
}

// ============================================
// Response Types
// ============================================

interface ApiDataResponse<T> {
  data: T;
  message?: string;
}

interface NotificationListResponse {
  data: KanbanNotification[];
  total: number;
  unread_count: number;
  page: number;
  per_page: number;
}

// ============================================
// Notification Service
// ============================================

/**
 * Notification Service
 * Handles all notification-related API calls for the kanban system
 *
 * FEATURES:
 * - Real-time in-app notifications
 * - User notification preferences
 * - Mark as read/unread
 * - Batch operations
 * - Project-specific notification settings
 */
export const notificationService = {
  // ============================================
  // Notifications
  // ============================================

  /**
   * Get notifications for the current user
   */
  async getNotifications(params?: NotificationListParams): Promise<NotificationListResponse> {
    const queryString = buildQueryString({
      page: params?.page,
      per_page: params?.perPage,
      limit: params?.perPage,
      unread_only: params?.unread_only,
      type: params?.type,
      project_id: params?.project_id,
    });
    const response = await apiClient.get<NotificationListResponse>(
      `/api/v2/kanban/notifications${queryString}`
    );
    return response.data;
  },

  /**
   * Get unread notification count
   */
  async getUnreadCount(): Promise<number> {
    const response = await apiClient.get<ApiDataResponse<{ count: number }>>(
      '/api/v2/kanban/notifications/unread-count'
    );
    return response.data.data.count;
  },

  /**
   * Mark a single notification as read
   */
  async markAsRead(uuid: string): Promise<void> {
    await apiClient.put(`/api/v2/kanban/notifications/${uuid}/read`);
  },

  /**
   * Mark all notifications as read
   */
  async markAllAsRead(projectId?: number): Promise<{ count: number }> {
    const data: Record<string, unknown> = {};
    if (projectId) {
      data.project_id = projectId;
    }
    const response = await apiClient.put<ApiDataResponse<{ count: number }>>(
      '/api/v2/kanban/notifications/read-all',
      toFormData(data)
    );
    return response.data.data;
  },

  /**
   * Delete a notification
   */
  async deleteNotification(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/kanban/notifications/${uuid}`);
  },

  /**
   * Delete all read notifications
   */
  async deleteAllRead(): Promise<{ count: number }> {
    const response = await apiClient.delete<ApiDataResponse<{ count: number }>>(
      '/api/v2/kanban/notifications/clear-read'
    );
    return response.data.data;
  },

  // ============================================
  // Preferences
  // ============================================

  /**
   * Get user notification preferences
   */
  async getPreferences(projectId?: number): Promise<NotificationPreferences> {
    const queryString = projectId ? `?project_id=${projectId}` : '';
    const response = await apiClient.get<ApiDataResponse<NotificationPreferences>>(
      `/api/v2/kanban/notifications/preferences${queryString}`
    );
    return response.data.data;
  },

  /**
   * Update user notification preferences
   */
  async updatePreferences(
    params: UpdatePreferencesParams,
    projectId?: number
  ): Promise<NotificationPreferences> {
    const data: Record<string, unknown> = { ...params };
    if (projectId) {
      data.project_id = projectId;
    }
    if (params.preferences) {
      data.preferences = JSON.stringify(params.preferences);
    }
    const response = await apiClient.put<ApiDataResponse<NotificationPreferences>>(
      '/api/v2/kanban/notifications/preferences',
      toFormData(data)
    );
    return response.data.data;
  },
};

// ============================================
// Helper Functions
// ============================================

/**
 * Get notification type display name
 */
export function getNotificationTypeLabel(type: NotificationType): string {
  const labels: Record<NotificationType, string> = {
    task_assigned: 'Task Assigned',
    task_unassigned: 'Task Unassigned',
    task_commented: 'New Comment',
    task_mentioned: 'Mentioned',
    task_completed: 'Task Completed',
    task_status_changed: 'Status Changed',
    task_due_soon: 'Due Soon',
    task_overdue: 'Overdue',
    project_invited: 'Project Invitation',
    project_removed: 'Removed from Project',
    project_role_changed: 'Role Changed',
    sprint_started: 'Sprint Started',
    sprint_ended: 'Sprint Ended',
    checklist_completed: 'Checklist Completed',
    comment_reply: 'Comment Reply',
    comment_mentioned: 'Mentioned in Comment',
    general: 'Notification',
  };
  return labels[type] || type;
}

/**
 * Get notification priority color classes
 */
export function getNotificationPriorityColor(priority: string): string {
  const colors: Record<string, string> = {
    urgent: 'bg-red-100 text-red-700 border-red-200',
    high: 'bg-orange-100 text-orange-700 border-orange-200',
    normal: 'bg-blue-100 text-blue-700 border-blue-200',
    low: 'bg-gray-100 text-gray-700 border-gray-200',
  };
  return colors[priority] || colors.normal;
}

/**
 * Get notification icon name based on type
 */
export function getNotificationIcon(type: NotificationType): string {
  const icons: Record<NotificationType, string> = {
    task_assigned: 'UserPlus',
    task_unassigned: 'UserMinus',
    task_commented: 'MessageSquare',
    task_mentioned: 'AtSign',
    task_completed: 'CheckCircle',
    task_status_changed: 'RefreshCw',
    task_due_soon: 'Clock',
    task_overdue: 'AlertTriangle',
    project_invited: 'UserPlus',
    project_removed: 'UserMinus',
    project_role_changed: 'Shield',
    sprint_started: 'Play',
    sprint_ended: 'Square',
    checklist_completed: 'CheckSquare',
    comment_reply: 'Reply',
    comment_mentioned: 'AtSign',
    general: 'Bell',
  };
  return icons[type] || 'Bell';
}

/**
 * Format notification time for display
 */
export function formatNotificationTime(dateString: string): string {
  const date = new Date(dateString);
  const now = new Date();
  const diffMs = now.getTime() - date.getTime();
  const diffMins = Math.floor(diffMs / 60000);
  const diffHours = Math.floor(diffMs / 3600000);
  const diffDays = Math.floor(diffMs / 86400000);

  if (diffMins < 1) return 'Just now';
  if (diffMins < 60) return `${diffMins}m ago`;
  if (diffHours < 24) return `${diffHours}h ago`;
  if (diffDays < 7) return `${diffDays}d ago`;

  return date.toLocaleDateString('en-US', {
    month: 'short',
    day: 'numeric',
    year: date.getFullYear() !== now.getFullYear() ? 'numeric' : undefined,
  });
}

/**
 * Group notifications by date
 */
export function groupNotificationsByDate(
  notifications: KanbanNotification[]
): Map<string, KanbanNotification[]> {
  const groups = new Map<string, KanbanNotification[]>();
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const yesterday = new Date(today);
  yesterday.setDate(yesterday.getDate() - 1);

  for (const notification of notifications) {
    const date = new Date(notification.created_at);
    date.setHours(0, 0, 0, 0);

    let key: string;
    if (date.getTime() === today.getTime()) {
      key = 'Today';
    } else if (date.getTime() === yesterday.getTime()) {
      key = 'Yesterday';
    } else {
      key = date.toLocaleDateString('en-US', { month: 'long', day: 'numeric' });
    }

    const existing = groups.get(key) || [];
    existing.push(notification);
    groups.set(key, existing);
  }

  return groups;
}

export default notificationService;

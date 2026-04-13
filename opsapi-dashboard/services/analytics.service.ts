import { apiClient, buildQueryString } from '@/lib/api-client';
import type {
  ProjectAnalyticsStats,
  CompletionTrendPoint,
  TeamWorkloadMember,
  CycleTimeByColumn,
  ActivitySummary,
} from '@/types';

// ============================================
// Request Parameter Types
// ============================================

interface AnalyticsDateRange {
  date_from?: string;
  date_to?: string;
}

interface TrendParams extends AnalyticsDateRange {
  interval?: 'day' | 'week' | 'month';
}

interface ActivityFeedParams {
  page?: number;
  per_page?: number;
  action_types?: string[];
  user_uuid?: string;
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

interface ActivityFeedItem {
  id: number;
  uuid: string;
  action_type: string;
  entity_type: string;
  entity_id: number;
  entity_name?: string;
  user_uuid: string;
  user_name: string;
  old_values?: Record<string, unknown>;
  new_values?: Record<string, unknown>;
  metadata?: Record<string, unknown>;
  created_at: string;
}

interface ProjectHealthScore {
  overall_score: number;
  velocity_score: number;
  quality_score: number;
  deadline_score: number;
  team_score: number;
  risks: string[];
  recommendations: string[];
}

// ============================================
// Analytics Service
// ============================================

/**
 * Analytics Service
 * Handles all analytics and reporting API calls for the kanban system
 *
 * FEATURES:
 * - Project statistics and metrics
 * - Completion trends
 * - Team workload analysis
 * - Cycle time tracking
 * - Activity feeds
 * - Health scores
 */
export const analyticsService = {
  // ============================================
  // Project Analytics
  // ============================================

  /**
   * Get comprehensive project statistics
   */
  async getProjectStats(projectUuid: string, params?: AnalyticsDateRange): Promise<ProjectAnalyticsStats> {
    const queryString = buildQueryString({
      date_from: params?.date_from,
      date_to: params?.date_to,
    });
    const response = await apiClient.get<ApiDataResponse<ProjectAnalyticsStats>>(
      `/api/v2/kanban/analytics/projects/${projectUuid}/stats${queryString}`
    );
    return response.data.data;
  },

  /**
   * Get task completion trends over time
   */
  async getCompletionTrends(
    projectUuid: string,
    params?: TrendParams
  ): Promise<CompletionTrendPoint[]> {
    const queryString = buildQueryString({
      date_from: params?.date_from,
      date_to: params?.date_to,
      interval: params?.interval || 'day',
    });
    const response = await apiClient.get<ApiDataResponse<CompletionTrendPoint[]>>(
      `/api/v2/kanban/analytics/projects/${projectUuid}/completion-trends${queryString}`
    );
    return response.data.data;
  },

  /**
   * Get team workload distribution
   */
  async getTeamWorkload(projectUuid: string): Promise<TeamWorkloadMember[]> {
    const response = await apiClient.get<ApiDataResponse<TeamWorkloadMember[]>>(
      `/api/v2/kanban/analytics/projects/${projectUuid}/team-workload`
    );
    return response.data.data;
  },

  /**
   * Get cycle time by column
   */
  async getCycleTimeByColumn(
    projectUuid: string,
    params?: AnalyticsDateRange
  ): Promise<CycleTimeByColumn[]> {
    const queryString = buildQueryString({
      date_from: params?.date_from,
      date_to: params?.date_to,
    });
    const response = await apiClient.get<ApiDataResponse<CycleTimeByColumn[]>>(
      `/api/v2/kanban/analytics/projects/${projectUuid}/cycle-time${queryString}`
    );
    return response.data.data;
  },

  /**
   * Get activity summary
   */
  async getActivitySummary(
    projectUuid: string,
    params?: AnalyticsDateRange
  ): Promise<ActivitySummary> {
    const queryString = buildQueryString({
      date_from: params?.date_from,
      date_to: params?.date_to,
    });
    const response = await apiClient.get<ApiDataResponse<ActivitySummary>>(
      `/api/v2/kanban/analytics/projects/${projectUuid}/activity-summary${queryString}`
    );
    return response.data.data;
  },

  /**
   * Get project health score
   */
  async getProjectHealthScore(projectUuid: string): Promise<ProjectHealthScore> {
    const response = await apiClient.get<ApiDataResponse<ProjectHealthScore>>(
      `/api/v2/kanban/analytics/projects/${projectUuid}/health`
    );
    return response.data.data;
  },

  // ============================================
  // Activity Feed
  // ============================================

  /**
   * Get project activity feed
   */
  async getActivityFeed(
    projectUuid: string,
    params?: ActivityFeedParams
  ): Promise<ApiListResponse<ActivityFeedItem>> {
    const queryString = buildQueryString({
      page: params?.page,
      per_page: params?.per_page,
      user_uuid: params?.user_uuid,
      action_types: params?.action_types ? JSON.stringify(params.action_types) : undefined,
    });
    const response = await apiClient.get<ApiListResponse<ActivityFeedItem>>(
      `/api/v2/kanban/analytics/projects/${projectUuid}/activity${queryString}`
    );
    return response.data;
  },

  // ============================================
  // Namespace-wide Analytics
  // ============================================

  /**
   * Get all projects summary
   */
  async getProjectsSummary(params?: AnalyticsDateRange): Promise<{
    total_projects: number;
    active_projects: number;
    total_tasks: number;
    completed_tasks: number;
    overdue_tasks: number;
    avg_completion_rate: number;
  }> {
    const queryString = buildQueryString({
      date_from: params?.date_from,
      date_to: params?.date_to,
    });
    const response = await apiClient.get<ApiDataResponse<{
      total_projects: number;
      active_projects: number;
      total_tasks: number;
      completed_tasks: number;
      overdue_tasks: number;
      avg_completion_rate: number;
    }>>(
      `/api/v2/kanban/analytics/summary${queryString}`
    );
    return response.data.data;
  },

  /**
   * Get namespace-wide team performance
   */
  async getTeamPerformance(params?: AnalyticsDateRange): Promise<{
    members: Array<{
      user_uuid: string;
      user_name: string;
      tasks_completed: number;
      points_completed: number;
      hours_logged: number;
      avg_task_time_minutes: number;
    }>;
  }> {
    const queryString = buildQueryString({
      date_from: params?.date_from,
      date_to: params?.date_to,
    });
    const response = await apiClient.get<ApiDataResponse<{
      members: Array<{
        user_uuid: string;
        user_name: string;
        tasks_completed: number;
        points_completed: number;
        hours_logged: number;
        avg_task_time_minutes: number;
      }>;
    }>>(
      `/api/v2/kanban/analytics/team-performance${queryString}`
    );
    return response.data.data;
  },
};

// ============================================
// Helper Functions
// ============================================

/**
 * Format percentage for display
 */
export function formatPercentage(value: number, decimals: number = 0): string {
  return `${value.toFixed(decimals)}%`;
}

/**
 * Format large numbers with K/M suffixes
 */
export function formatNumber(num: number): string {
  if (num >= 1000000) {
    return `${(num / 1000000).toFixed(1)}M`;
  }
  if (num >= 1000) {
    return `${(num / 1000).toFixed(1)}K`;
  }
  return num.toString();
}

/**
 * Get trend direction and color
 */
export function getTrendIndicator(
  current: number,
  previous: number
): { direction: 'up' | 'down' | 'neutral'; percentage: number; color: string } {
  if (previous === 0) {
    return { direction: 'neutral', percentage: 0, color: 'text-gray-500' };
  }

  const percentage = ((current - previous) / previous) * 100;

  if (percentage > 0) {
    return { direction: 'up', percentage, color: 'text-green-600' };
  } else if (percentage < 0) {
    return { direction: 'down', percentage: Math.abs(percentage), color: 'text-red-600' };
  }
  return { direction: 'neutral', percentage: 0, color: 'text-gray-500' };
}

/**
 * Get health score color
 */
export function getHealthScoreColor(score: number): string {
  if (score >= 80) return 'text-green-600';
  if (score >= 60) return 'text-yellow-600';
  if (score >= 40) return 'text-orange-600';
  return 'text-red-600';
}

/**
 * Get health score label
 */
export function getHealthScoreLabel(score: number): string {
  if (score >= 80) return 'Excellent';
  if (score >= 60) return 'Good';
  if (score >= 40) return 'Needs Attention';
  return 'Critical';
}

/**
 * Format activity action type for display
 */
export function formatActivityAction(actionType: string): string {
  const actions: Record<string, string> = {
    task_created: 'created task',
    task_updated: 'updated task',
    task_moved: 'moved task',
    task_completed: 'completed task',
    task_assigned: 'assigned',
    comment_added: 'commented on',
    checklist_completed: 'completed checklist',
    label_added: 'added label to',
    label_removed: 'removed label from',
    sprint_started: 'started sprint',
    sprint_completed: 'completed sprint',
    member_added: 'added member',
    member_removed: 'removed member',
  };
  return actions[actionType] || actionType;
}

/**
 * Get date range for common periods
 */
export function getDateRange(
  period: 'today' | 'week' | 'month' | 'quarter' | 'year'
): { date_from: string; date_to: string } {
  const now = new Date();
  const date_to = now.toISOString().split('T')[0];
  let date_from: string;

  switch (period) {
    case 'today':
      date_from = date_to;
      break;
    case 'week':
      const weekStart = new Date(now);
      weekStart.setDate(now.getDate() - 7);
      date_from = weekStart.toISOString().split('T')[0];
      break;
    case 'month':
      const monthStart = new Date(now);
      monthStart.setMonth(now.getMonth() - 1);
      date_from = monthStart.toISOString().split('T')[0];
      break;
    case 'quarter':
      const quarterStart = new Date(now);
      quarterStart.setMonth(now.getMonth() - 3);
      date_from = quarterStart.toISOString().split('T')[0];
      break;
    case 'year':
      const yearStart = new Date(now);
      yearStart.setFullYear(now.getFullYear() - 1);
      date_from = yearStart.toISOString().split('T')[0];
      break;
    default:
      date_from = date_to;
  }

  return { date_from, date_to };
}

/**
 * Calculate average cycle time
 */
export function calculateAverageCycleTime(cycleTimeData: CycleTimeByColumn[]): number {
  if (cycleTimeData.length === 0) return 0;

  const totalMinutes = cycleTimeData.reduce((sum, col) => sum + col.avg_time_minutes, 0);
  return Math.round(totalMinutes);
}

/**
 * Get workload level label
 */
export function getWorkloadLevel(
  assignedTasks: number,
  avgTeamTasks: number
): { level: 'low' | 'normal' | 'high' | 'overloaded'; color: string } {
  const ratio = assignedTasks / avgTeamTasks;

  if (ratio < 0.5) {
    return { level: 'low', color: 'text-blue-600' };
  } else if (ratio < 1.2) {
    return { level: 'normal', color: 'text-green-600' };
  } else if (ratio < 1.5) {
    return { level: 'high', color: 'text-yellow-600' };
  }
  return { level: 'overloaded', color: 'text-red-600' };
}

export default analyticsService;

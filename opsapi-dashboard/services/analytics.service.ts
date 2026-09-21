import { apiClient } from '@/lib/api-client';
import type {
  ProjectAnalyticsStats,
  CompletionTrendResponse,
  PriorityDistribution,
  TeamWorkloadMember,
  CycleTimeResponse,
} from '@/types';

// ============================================
// Response Types
// ============================================

interface ApiDataResponse<T> {
  data: T;
  message?: string;
}

// ============================================
// Analytics Service
// ============================================

/**
 * Kanban analytics service.
 *
 * Every method maps to a real, already-computed backend endpoint under
 * `/api/v2/kanban/projects/:uuid/...` (see routes/kanban-analytics.lua). No
 * date-range params: the endpoints either aggregate the whole project or take
 * their own window param (completion-trend takes `days`).
 */
export const analyticsService = {
  /** Comprehensive project stats — task counts by status, points, time, budget. */
  async getProjectStats(projectUuid: string): Promise<ProjectAnalyticsStats> {
    const response = await apiClient.get<ApiDataResponse<ProjectAnalyticsStats>>(
      `/api/v2/kanban/projects/${projectUuid}/analytics`
    );
    return response.data.data;
  },

  /** Created-vs-completed counts per day for the last `days` days. */
  async getCompletionTrend(projectUuid: string, days = 30): Promise<CompletionTrendResponse> {
    const response = await apiClient.get<ApiDataResponse<CompletionTrendResponse>>(
      `/api/v2/kanban/projects/${projectUuid}/completion-trend?days=${days}`
    );
    return response.data.data;
  },

  /** Task counts grouped by priority (critical → low). */
  async getPriorityDistribution(projectUuid: string): Promise<PriorityDistribution[]> {
    const response = await apiClient.get<ApiDataResponse<PriorityDistribution[]>>(
      `/api/v2/kanban/projects/${projectUuid}/priority-distribution`
    );
    return response.data.data;
  },

  /** Per-assignee workload: assigned / active / completed / overdue + points. */
  async getTeamWorkload(projectUuid: string): Promise<TeamWorkloadMember[]> {
    const response = await apiClient.get<ApiDataResponse<TeamWorkloadMember[]>>(
      `/api/v2/kanban/projects/${projectUuid}/team-workload`
    );
    return response.data.data;
  },

  /** Cycle/lead time (completed − created) by column and by priority. */
  async getCycleTime(projectUuid: string): Promise<CycleTimeResponse> {
    const response = await apiClient.get<ApiDataResponse<CycleTimeResponse>>(
      `/api/v2/kanban/projects/${projectUuid}/cycle-time`
    );
    return response.data.data;
  },
};

// ============================================
// Helper Functions
// ============================================

/** Format a percentage for display. */
export function formatPercentage(value: number, decimals = 0): string {
  return `${(value ?? 0).toFixed(decimals)}%`;
}

/** Format large numbers with K/M suffixes. */
export function formatNumber(num: number): string {
  if (num >= 1_000_000) return `${(num / 1_000_000).toFixed(1)}M`;
  if (num >= 1_000) return `${(num / 1_000).toFixed(1)}K`;
  return String(num ?? 0);
}

/** Direction + colour for a value vs. its previous value. */
export function getTrendIndicator(
  current: number,
  previous: number
): { direction: 'up' | 'down' | 'neutral'; percentage: number; color: string } {
  if (!previous) return { direction: 'neutral', percentage: 0, color: 'text-secondary-500' };
  const percentage = ((current - previous) / previous) * 100;
  if (percentage > 0) return { direction: 'up', percentage, color: 'text-green-600' };
  if (percentage < 0) return { direction: 'down', percentage: Math.abs(percentage), color: 'text-red-600' };
  return { direction: 'neutral', percentage: 0, color: 'text-secondary-500' };
}

/** Classify a member's load relative to the team average. */
export function getWorkloadLevel(
  assignedTasks: number,
  avgTeamTasks: number
): { level: 'low' | 'normal' | 'high' | 'overloaded'; color: string } {
  if (!avgTeamTasks) return { level: 'normal', color: 'text-green-600' };
  const ratio = assignedTasks / avgTeamTasks;
  if (ratio < 0.5) return { level: 'low', color: 'text-blue-600' };
  if (ratio < 1.2) return { level: 'normal', color: 'text-green-600' };
  if (ratio < 1.5) return { level: 'high', color: 'text-yellow-600' };
  return { level: 'overloaded', color: 'text-red-600' };
}

export default analyticsService;

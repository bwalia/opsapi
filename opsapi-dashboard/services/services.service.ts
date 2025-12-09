import { apiClient, buildQueryString, toFormData } from '@/lib/api-client';
import type {
  NamespaceService,
  ServiceSecret,
  ServiceVariable,
  ServiceDeployment,
  GithubIntegration,
  ServiceStats,
  CreateServiceDto,
  UpdateServiceDto,
  CreateSecretDto,
  UpdateSecretDto,
  CreateVariableDto,
  UpdateVariableDto,
  CreateGithubIntegrationDto,
  UpdateGithubIntegrationDto,
  TriggerDeploymentDto,
  DeploymentResponse,
  PaginationParams,
} from '@/types';

interface ServiceListParams extends PaginationParams {
  status?: string;
  search?: string;
}

interface DeploymentListParams extends PaginationParams {
  status?: string;
}

interface PaginatedServicesResponse {
  data: NamespaceService[];
  total: number;
  page: number;
  per_page: number;
  total_pages: number;
}

interface PaginatedDeploymentsResponse {
  data: ServiceDeployment[];
  total: number;
  page: number;
  per_page: number;
  total_pages: number;
}

/**
 * Services Service
 * Handles all service-related API calls for GitHub workflow integration
 *
 * SECURITY NOTES:
 * - Secrets are NEVER exposed in API responses (always masked as "********")
 * - Secrets are encrypted at rest on the server
 * - Secrets are only decrypted server-side when triggering GitHub workflows
 */
export const servicesService = {
  // ============================================
  // Service Statistics
  // ============================================

  /**
   * Get service statistics for the current namespace
   */
  async getStats(): Promise<ServiceStats> {
    const response = await apiClient.get<{ data: ServiceStats }>(
      '/api/v2/namespace/services/stats'
    );
    return response.data.data;
  },

  // ============================================
  // GitHub Integrations
  // ============================================

  /**
   * Get all GitHub integrations for the current namespace
   */
  async getGithubIntegrations(): Promise<GithubIntegration[]> {
    const response = await apiClient.get<{ data: GithubIntegration[]; total: number }>(
      '/api/v2/namespace/github-integrations'
    );
    return response.data.data;
  },

  /**
   * Get a single GitHub integration
   */
  async getGithubIntegration(id: string): Promise<GithubIntegration> {
    const response = await apiClient.get<{ data: GithubIntegration }>(
      `/api/v2/namespace/github-integrations/${id}`
    );
    return response.data.data;
  },

  /**
   * Create a new GitHub integration
   */
  async createGithubIntegration(data: CreateGithubIntegrationDto): Promise<GithubIntegration> {
    const response = await apiClient.post<{ data: GithubIntegration; message: string }>(
      '/api/v2/namespace/github-integrations',
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Update a GitHub integration
   */
  async updateGithubIntegration(
    id: string,
    data: UpdateGithubIntegrationDto
  ): Promise<GithubIntegration> {
    const response = await apiClient.put<{ data: GithubIntegration; message: string }>(
      `/api/v2/namespace/github-integrations/${id}`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Delete a GitHub integration
   */
  async deleteGithubIntegration(id: string): Promise<void> {
    await apiClient.delete(`/api/v2/namespace/github-integrations/${id}`);
  },

  // ============================================
  // Services CRUD
  // ============================================

  /**
   * Get all services for the current namespace
   */
  async getServices(params?: ServiceListParams): Promise<PaginatedServicesResponse> {
    const queryString = buildQueryString({
      page: params?.page,
      per_page: params?.perPage,
      limit: params?.perPage,
      status: params?.status,
      search: params?.search,
      order_by: params?.orderBy,
      order_dir: params?.orderDir,
    });
    const response = await apiClient.get<PaginatedServicesResponse>(
      `/api/v2/namespace/services${queryString}`
    );
    return response.data;
  },

  /**
   * Get a single service with full details (secrets, variables, deployments)
   */
  async getService(id: string): Promise<NamespaceService> {
    const response = await apiClient.get<{ data: NamespaceService }>(
      `/api/v2/namespace/services/${id}`
    );
    return response.data.data;
  },

  /**
   * Create a new service
   */
  async createService(data: CreateServiceDto): Promise<NamespaceService> {
    const response = await apiClient.post<{ data: NamespaceService; message: string }>(
      '/api/v2/namespace/services',
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Update a service
   */
  async updateService(id: string, data: UpdateServiceDto): Promise<NamespaceService> {
    const response = await apiClient.put<{ data: NamespaceService; message: string }>(
      `/api/v2/namespace/services/${id}`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Delete a service
   */
  async deleteService(id: string): Promise<void> {
    await apiClient.delete(`/api/v2/namespace/services/${id}`);
  },

  // ============================================
  // Secrets Management
  // ============================================

  /**
   * Get all secrets for a service (values are always masked)
   */
  async getSecrets(serviceId: string): Promise<ServiceSecret[]> {
    const response = await apiClient.get<{ data: ServiceSecret[]; total: number }>(
      `/api/v2/namespace/services/${serviceId}/secrets`
    );
    return response.data.data;
  },

  /**
   * Add a secret to a service
   * Note: The value will be encrypted server-side
   */
  async addSecret(serviceId: string, data: CreateSecretDto): Promise<ServiceSecret> {
    const response = await apiClient.post<{ data: ServiceSecret; message: string }>(
      `/api/v2/namespace/services/${serviceId}/secrets`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Update a secret
   * Note: Pass the actual value to update, or "********" to keep existing
   */
  async updateSecret(
    serviceId: string,
    secretId: string,
    data: UpdateSecretDto
  ): Promise<ServiceSecret> {
    const response = await apiClient.put<{ data: ServiceSecret; message: string }>(
      `/api/v2/namespace/services/${serviceId}/secrets/${secretId}`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Delete a secret
   */
  async deleteSecret(serviceId: string, secretId: string): Promise<void> {
    await apiClient.delete(`/api/v2/namespace/services/${serviceId}/secrets/${secretId}`);
  },

  // ============================================
  // Variables Management
  // ============================================

  /**
   * Get all variables for a service
   */
  async getVariables(serviceId: string): Promise<ServiceVariable[]> {
    const response = await apiClient.get<{ data: ServiceVariable[]; total: number }>(
      `/api/v2/namespace/services/${serviceId}/variables`
    );
    return response.data.data;
  },

  /**
   * Add a variable to a service
   */
  async addVariable(serviceId: string, data: CreateVariableDto): Promise<ServiceVariable> {
    const response = await apiClient.post<{ data: ServiceVariable; message: string }>(
      `/api/v2/namespace/services/${serviceId}/variables`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Update a variable
   */
  async updateVariable(
    serviceId: string,
    variableId: string,
    data: UpdateVariableDto
  ): Promise<ServiceVariable> {
    const response = await apiClient.put<{ data: ServiceVariable; message: string }>(
      `/api/v2/namespace/services/${serviceId}/variables/${variableId}`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return response.data.data;
  },

  /**
   * Delete a variable
   */
  async deleteVariable(serviceId: string, variableId: string): Promise<void> {
    await apiClient.delete(`/api/v2/namespace/services/${serviceId}/variables/${variableId}`);
  },

  // ============================================
  // Deployment Management
  // ============================================

  /**
   * Trigger a deployment (run GitHub workflow)
   * This is the main action - it triggers the GitHub workflow with all configured
   * secrets and variables, plus any custom inputs provided
   */
  async triggerDeployment(
    serviceId: string,
    data?: TriggerDeploymentDto
  ): Promise<DeploymentResponse> {
    const formData = data?.inputs
      ? toFormData({ inputs: JSON.stringify(data.inputs) })
      : new FormData();

    const response = await apiClient.post<DeploymentResponse>(
      `/api/v2/namespace/services/${serviceId}/deploy`,
      formData
    );
    return response.data;
  },

  /**
   * Get deployment history for a service
   */
  async getDeployments(
    serviceId: string,
    params?: DeploymentListParams
  ): Promise<PaginatedDeploymentsResponse> {
    const queryString = buildQueryString({
      page: params?.page,
      per_page: params?.perPage,
      limit: params?.perPage,
      status: params?.status,
    });
    const response = await apiClient.get<PaginatedDeploymentsResponse>(
      `/api/v2/namespace/services/${serviceId}/deployments${queryString}`
    );
    return response.data;
  },

  /**
   * Get a single deployment
   */
  async getDeployment(serviceId: string, deploymentId: string): Promise<ServiceDeployment> {
    const response = await apiClient.get<{ data: ServiceDeployment }>(
      `/api/v2/namespace/services/${serviceId}/deployments/${deploymentId}`
    );
    return response.data.data;
  },

  // ============================================
  // Deployment Status Sync
  // ============================================

  /**
   * Sync a single deployment status from GitHub
   * This queries GitHub API to get the latest workflow run status
   */
  async syncDeploymentStatus(
    serviceId: string,
    deploymentId: string
  ): Promise<{ data: ServiceDeployment; message: string }> {
    const response = await apiClient.post<{ data: ServiceDeployment; message: string }>(
      `/api/v2/namespace/services/${serviceId}/deployments/${deploymentId}/sync`
    );
    return response.data;
  },

  /**
   * Sync all pending deployments for the current namespace
   * This will update all deployments that are in triggered/pending/running state
   */
  async syncAllPendingDeployments(): Promise<{
    data: { total: number; updated: number; errors: number };
    message: string;
  }> {
    const response = await apiClient.post<{
      data: { total: number; updated: number; errors: number };
      message: string;
    }>('/api/v2/namespace/services/sync-deployments');
    return response.data;
  },
};

// ============================================
// Helper Functions
// ============================================

/**
 * Get color classes for service status
 */
export function getServiceStatusColor(status: string): string {
  const colors: Record<string, string> = {
    active: 'bg-success-100 text-success-700 border-success-200',
    inactive: 'bg-warning-100 text-warning-700 border-warning-200',
    archived: 'bg-secondary-100 text-secondary-700 border-secondary-200',
  };
  return colors[status] || colors.inactive;
}

/**
 * Get color classes for deployment status
 */
export function getDeploymentStatusColor(status: string): string {
  const colors: Record<string, string> = {
    pending: 'bg-secondary-100 text-secondary-700 border-secondary-200',
    triggered: 'bg-info-100 text-info-700 border-info-200',
    running: 'bg-primary-100 text-primary-700 border-primary-200',
    success: 'bg-success-100 text-success-700 border-success-200',
    failure: 'bg-error-100 text-error-700 border-error-200',
    cancelled: 'bg-warning-100 text-warning-700 border-warning-200',
    error: 'bg-error-100 text-error-700 border-error-200',
  };
  return colors[status] || colors.pending;
}

/**
 * Get icon name for service icon field
 */
export function getServiceIcon(icon?: string): string {
  const validIcons = [
    'server',
    'cloud',
    'database',
    'code',
    'globe',
    'shield',
    'zap',
    'box',
    'cpu',
    'hard-drive',
    'terminal',
    'package',
    'layers',
    'git-branch',
    'rocket',
  ];
  return validIcons.includes(icon || '') ? icon! : 'server';
}

/**
 * Get color class for service color field
 */
export function getServiceColorClass(color?: string): string {
  const colors: Record<string, string> = {
    blue: 'bg-blue-500',
    green: 'bg-green-500',
    purple: 'bg-purple-500',
    orange: 'bg-orange-500',
    red: 'bg-red-500',
    cyan: 'bg-cyan-500',
    pink: 'bg-pink-500',
    indigo: 'bg-indigo-500',
    yellow: 'bg-yellow-500',
    teal: 'bg-teal-500',
  };
  return colors[color || ''] || colors.blue;
}

/**
 * Format deployment status for display
 */
export function formatDeploymentStatus(status: string): string {
  const labels: Record<string, string> = {
    pending: 'Pending',
    triggered: 'Triggered',
    running: 'Running',
    success: 'Success',
    failure: 'Failed',
    cancelled: 'Cancelled',
    error: 'Error',
  };
  return labels[status] || status;
}

/**
 * Format service status for display
 */
export function formatServiceStatus(status: string): string {
  const labels: Record<string, string> = {
    active: 'Active',
    inactive: 'Inactive',
    archived: 'Archived',
  };
  return labels[status] || status;
}

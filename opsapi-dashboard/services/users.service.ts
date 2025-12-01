import apiClient, { toFormData } from "@/lib/api-client";
import type { User, PaginatedResponse, PaginationParams } from "@/types";

export interface UserFilters extends PaginationParams {
  status?: string;
  role?: string;
}

export const usersService = {
  async getUsers(params: UserFilters = {}): Promise<PaginatedResponse<User>> {
    const queryParams: Record<string, number | string> = {};

    if (params.page) queryParams.offset = ((params.page - 1) * (params.perPage || 10));
    if (params.perPage) queryParams.limit = params.perPage;
    if (params.status) queryParams.status = params.status;

    const response = await apiClient.get('/api/v2/users', { params: queryParams });

    // Handle the API response format: { data: [], total: number }
    return {
      data: response.data?.data || [],
      total: response.data?.total || 0,
      page: params.page || 1,
      perPage: params.perPage || 10,
      totalPages: Math.ceil((response.data?.total || 0) / (params.perPage || 10)),
    };
  },

  async getUser(uuid: string): Promise<User> {
    const response = await apiClient.get(`/api/v2/users/${uuid}`);
    return response.data;
  },

  async createUser(data: Partial<User>): Promise<User> {
    const response = await apiClient.post(
      '/api/v2/users',
      toFormData(data as Record<string, unknown>)
    );
    return response.data;
  },

  async updateUser(uuid: string, data: Partial<User>): Promise<User> {
    const response = await apiClient.put(
      `/api/v2/users/${uuid}`,
      toFormData(data as Record<string, unknown>)
    );
    return response.data;
  },

  async deleteUser(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/users/${uuid}`);
  },
};

export default usersService;

import apiClient, { toFormData } from '@/lib/api-client';
import type {
  Hospital,
  CreateHospitalDto,
  PaginatedResponse,
  PaginationParams,
} from '@/types';

export interface HospitalFilters extends PaginationParams {
  type?: string;
  status?: string;
  city?: string;
}

export const hospitalsService = {
  async getHospitals(params: HospitalFilters = {}): Promise<PaginatedResponse<Hospital>> {
    const queryParams: Record<string, number | string> = {};

    if (params.page) queryParams.page = params.page;
    if (params.perPage) queryParams.perPage = params.perPage;
    if (params.orderBy) queryParams.orderBy = params.orderBy;
    if (params.orderDir) queryParams.orderDir = params.orderDir;
    if (params.type) queryParams.type = params.type;
    if (params.status) queryParams.status = params.status;
    if (params.city) queryParams.city = params.city;

    const response = await apiClient.get('/api/v2/hospitals', { params: queryParams });

    const hospitals = Array.isArray(response.data) ? response.data : response.data?.data || [];
    const total = response.data?.total || hospitals.length;
    const perPage = params.perPage || 10;

    return {
      data: hospitals,
      total,
      page: params.page || 1,
      perPage,
      totalPages: Math.ceil(total / perPage),
    };
  },

  async getHospital(uuid: string): Promise<Hospital> {
    const response = await apiClient.get(`/api/v2/hospitals/${uuid}`);
    return response.data?.data || response.data;
  },

  async createHospital(data: CreateHospitalDto): Promise<Hospital> {
    const formData: Record<string, unknown> = { ...data };
    if (data.specialties) formData.specialties = JSON.stringify(data.specialties);
    if (data.services) formData.services = JSON.stringify(data.services);
    if (data.facilities) formData.facilities = JSON.stringify(data.facilities);
    if (data.operating_hours) formData.operating_hours = JSON.stringify(data.operating_hours);

    const response = await apiClient.post('/api/v2/hospitals', toFormData(formData));
    return response.data?.data || response.data;
  },

  async updateHospital(uuid: string, data: Partial<CreateHospitalDto>): Promise<Hospital> {
    const formData: Record<string, unknown> = { ...data };
    if (data.specialties) formData.specialties = JSON.stringify(data.specialties);
    if (data.services) formData.services = JSON.stringify(data.services);
    if (data.facilities) formData.facilities = JSON.stringify(data.facilities);
    if (data.operating_hours) formData.operating_hours = JSON.stringify(data.operating_hours);

    const response = await apiClient.put(`/api/v2/hospitals/${uuid}`, toFormData(formData));
    return response.data?.data || response.data;
  },

  async deleteHospital(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/hospitals/${uuid}`);
  },

  async getHospitalStatistics(uuid: string): Promise<Record<string, number>> {
    const response = await apiClient.get(`/api/v2/hospitals/${uuid}/statistics`);
    return response.data?.data || response.data || {};
  },
};

export default hospitalsService;

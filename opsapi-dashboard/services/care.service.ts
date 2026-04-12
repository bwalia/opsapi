/**
 * Care Service - Unified service for all patient care resources
 *
 * Consolidates API access for: care plans, care logs, medications, daily logs
 */
import apiClient, { toFormData } from '@/lib/api-client';
import type {
  CarePlan,
  CreateCarePlanDto,
  CareLog,
  CreateCareLogDto,
  Medication,
  CreateMedicationDto,
  DailyLog,
  CreateDailyLogDto,
  PaginatedResponse,
} from '@/types';

function paginate<T>(response: { data: unknown }, page: number, perPage: number): PaginatedResponse<T> {
  const body = response.data as { data?: T[]; total?: number } | T[];
  const data = Array.isArray(body) ? body : body?.data || [];
  const total = (Array.isArray(body) ? data.length : body?.total) || data.length;
  return {
    data,
    total,
    page,
    perPage,
    totalPages: Math.ceil(total / perPage),
  };
}

// =============================================================================
// CARE PLANS
// =============================================================================
export const carePlansService = {
  async list(patientUuid: string, params: { page?: number; perPage?: number; status?: string } = {}): Promise<PaginatedResponse<CarePlan>> {
    const response = await apiClient.get(`/api/v2/patients/${patientUuid}/care-plans`, { params });
    return paginate<CarePlan>(response, params.page || 1, params.perPage || 10);
  },

  async get(patientUuid: string, id: string): Promise<CarePlan> {
    const response = await apiClient.get(`/api/v2/patients/${patientUuid}/care-plans/${id}`);
    return response.data?.data || response.data;
  },

  async create(patientUuid: string, data: CreateCarePlanDto): Promise<CarePlan> {
    const formData: Record<string, unknown> = { ...data };
    if (data.goals) formData.goals = JSON.stringify(data.goals);
    if (data.interventions) formData.interventions = JSON.stringify(data.interventions);

    const response = await apiClient.post(`/api/v2/patients/${patientUuid}/care-plans`, toFormData(formData));
    return response.data?.data || response.data;
  },

  async update(patientUuid: string, id: string, data: Partial<CreateCarePlanDto>): Promise<CarePlan> {
    const formData: Record<string, unknown> = { ...data };
    if (data.goals) formData.goals = JSON.stringify(data.goals);
    if (data.interventions) formData.interventions = JSON.stringify(data.interventions);

    const response = await apiClient.put(`/api/v2/patients/${patientUuid}/care-plans/${id}`, toFormData(formData));
    return response.data?.data || response.data;
  },

  async remove(patientUuid: string, id: string): Promise<void> {
    await apiClient.delete(`/api/v2/patients/${patientUuid}/care-plans/${id}`);
  },

  async dueForReview(): Promise<CarePlan[]> {
    const response = await apiClient.get('/api/v2/care-plans/due-for-review');
    return response.data?.data || [];
  },
};

// =============================================================================
// CARE LOGS
// =============================================================================
export const careLogsService = {
  async list(patientUuid: string, params: { page?: number; perPage?: number; log_type?: string; shift?: string } = {}): Promise<PaginatedResponse<CareLog>> {
    const response = await apiClient.get(`/api/v2/patients/${patientUuid}/care-logs`, { params });
    return paginate<CareLog>(response, params.page || 1, params.perPage || 10);
  },

  async get(patientUuid: string, id: string): Promise<CareLog> {
    const response = await apiClient.get(`/api/v2/patients/${patientUuid}/care-logs/${id}`);
    return response.data?.data || response.data;
  },

  async create(patientUuid: string, data: CreateCareLogDto): Promise<CareLog> {
    const response = await apiClient.post(`/api/v2/patients/${patientUuid}/care-logs`, toFormData({ ...data }));
    return response.data?.data || response.data;
  },

  async update(patientUuid: string, id: string, data: Partial<CreateCareLogDto>): Promise<CareLog> {
    const response = await apiClient.put(`/api/v2/patients/${patientUuid}/care-logs/${id}`, toFormData({ ...data }));
    return response.data?.data || response.data;
  },

  async remove(patientUuid: string, id: string): Promise<void> {
    await apiClient.delete(`/api/v2/patients/${patientUuid}/care-logs/${id}`);
  },

  async incidents(patientUuid: string): Promise<CareLog[]> {
    const response = await apiClient.get(`/api/v2/patients/${patientUuid}/care-logs/incidents`);
    return response.data?.data || [];
  },
};

// =============================================================================
// MEDICATIONS
// =============================================================================
export const medicationsService = {
  async list(patientUuid: string, params: { page?: number; perPage?: number; status?: string } = {}): Promise<PaginatedResponse<Medication>> {
    const response = await apiClient.get(`/api/v2/patients/${patientUuid}/medications`, { params });
    return paginate<Medication>(response, params.page || 1, params.perPage || 10);
  },

  async get(patientUuid: string, id: string): Promise<Medication> {
    const response = await apiClient.get(`/api/v2/patients/${patientUuid}/medications/${id}`);
    return response.data?.data || response.data;
  },

  async active(patientUuid: string): Promise<Medication[]> {
    const response = await apiClient.get(`/api/v2/patients/${patientUuid}/medications/active`);
    return response.data?.data || [];
  },

  async create(patientUuid: string, data: CreateMedicationDto): Promise<Medication> {
    const formData: Record<string, unknown> = { ...data };
    if (data.schedule_times) formData.schedule_times = JSON.stringify(data.schedule_times);

    const response = await apiClient.post(`/api/v2/patients/${patientUuid}/medications`, toFormData(formData));
    return response.data?.data || response.data;
  },

  async update(patientUuid: string, id: string, data: Partial<CreateMedicationDto>): Promise<Medication> {
    const formData: Record<string, unknown> = { ...data };
    if (data.schedule_times) formData.schedule_times = JSON.stringify(data.schedule_times);

    const response = await apiClient.put(`/api/v2/patients/${patientUuid}/medications/${id}`, toFormData(formData));
    return response.data?.data || response.data;
  },

  async remove(patientUuid: string, id: string): Promise<void> {
    await apiClient.delete(`/api/v2/patients/${patientUuid}/medications/${id}`);
  },
};

// =============================================================================
// DAILY LOGS
// =============================================================================
export const dailyLogsService = {
  async list(patientUuid: string, params: { page?: number; perPage?: number; log_date?: string; shift?: string } = {}): Promise<PaginatedResponse<DailyLog>> {
    const response = await apiClient.get(`/api/v2/patients/${patientUuid}/daily-logs`, { params });
    return paginate<DailyLog>(response, params.page || 1, params.perPage || 10);
  },

  async get(patientUuid: string, id: string): Promise<DailyLog> {
    const response = await apiClient.get(`/api/v2/patients/${patientUuid}/daily-logs/${id}`);
    return response.data?.data || response.data;
  },

  async today(patientUuid: string): Promise<DailyLog[]> {
    const response = await apiClient.get(`/api/v2/patients/${patientUuid}/daily-logs/today`);
    return response.data?.data || [];
  },

  async create(patientUuid: string, data: CreateDailyLogDto): Promise<DailyLog> {
    const response = await apiClient.post(`/api/v2/patients/${patientUuid}/daily-logs`, toFormData({ ...data }));
    return response.data?.data || response.data;
  },

  async update(patientUuid: string, id: string, data: Partial<CreateDailyLogDto>): Promise<DailyLog> {
    const response = await apiClient.put(`/api/v2/patients/${patientUuid}/daily-logs/${id}`, toFormData({ ...data }));
    return response.data?.data || response.data;
  },

  async remove(patientUuid: string, id: string): Promise<void> {
    await apiClient.delete(`/api/v2/patients/${patientUuid}/daily-logs/${id}`);
  },
};

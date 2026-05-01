import apiClient, { toFormData } from '@/lib/api-client';
import type {
  Patient,
  CreatePatientDto,
  PaginatedResponse,
  PaginationParams,
} from '@/types';

export interface PatientFilters extends PaginationParams {
  hospital_id?: number | string;
  status?: string;
  first_name?: string;
  last_name?: string;
  room_number?: string;
}

export const patientsService = {
  async getPatients(params: PatientFilters = {}): Promise<PaginatedResponse<Patient>> {
    const queryParams: Record<string, number | string> = {};

    if (params.page) queryParams.page = params.page;
    if (params.perPage) queryParams.perPage = params.perPage;
    if (params.orderBy) queryParams.orderBy = params.orderBy;
    if (params.orderDir) queryParams.orderDir = params.orderDir;
    if (params.hospital_id) queryParams.hospital_id = params.hospital_id;
    if (params.status) queryParams.status = params.status;
    if (params.first_name) queryParams.first_name = params.first_name;
    if (params.last_name) queryParams.last_name = params.last_name;
    if (params.room_number) queryParams.room_number = params.room_number;

    const response = await apiClient.get('/api/v2/patients', { params: queryParams });

    const patients = Array.isArray(response.data) ? response.data : response.data?.data || [];
    const total = response.data?.total || patients.length;
    const perPage = params.perPage || 10;

    return {
      data: patients,
      total,
      page: params.page || 1,
      perPage,
      totalPages: Math.ceil(total / perPage),
    };
  },

  async getPatient(uuid: string): Promise<Patient> {
    const response = await apiClient.get(`/api/v2/patients/${uuid}`);
    return response.data?.data || response.data;
  },

  async createPatient(data: CreatePatientDto): Promise<Patient> {
    const formData: Record<string, unknown> = { ...data };
    if (data.allergies) formData.allergies = JSON.stringify(data.allergies);
    if (data.medical_conditions) formData.medical_conditions = JSON.stringify(data.medical_conditions);
    if (data.medications) formData.medications = JSON.stringify(data.medications);

    const response = await apiClient.post('/api/v2/patients', toFormData(formData));
    return response.data?.data || response.data;
  },

  async updatePatient(uuid: string, data: Partial<CreatePatientDto>): Promise<Patient> {
    const formData: Record<string, unknown> = { ...data };
    if (data.allergies) formData.allergies = JSON.stringify(data.allergies);
    if (data.medical_conditions) formData.medical_conditions = JSON.stringify(data.medical_conditions);
    if (data.medications) formData.medications = JSON.stringify(data.medications);

    const response = await apiClient.put(`/api/v2/patients/${uuid}`, toFormData(formData));
    return response.data?.data || response.data;
  },

  async deletePatient(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/patients/${uuid}`);
  },
};

export default patientsService;

/**
 * Family & Access Service - Family members, patient access controls, and alerts
 */
import apiClient, { toFormData } from '@/lib/api-client';
import type {
  FamilyMember,
  CreateFamilyMemberDto,
  PatientAccessControl,
  CreateAccessControlDto,
  PatientAlert,
  CreateAlertDto,
  DementiaAssessment,
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
// FAMILY MEMBERS
// =============================================================================
export const familyMembersService = {
  async list(patientUuid: string, params: { page?: number; perPage?: number } = {}): Promise<PaginatedResponse<FamilyMember>> {
    const response = await apiClient.get(`/api/v2/patients/${patientUuid}/family-members`, { params });
    return paginate<FamilyMember>(response, params.page || 1, params.perPage || 10);
  },

  async get(patientUuid: string, id: string): Promise<FamilyMember> {
    const response = await apiClient.get(`/api/v2/patients/${patientUuid}/family-members/${id}`);
    return response.data?.data || response.data;
  },

  async create(patientUuid: string, data: CreateFamilyMemberDto): Promise<FamilyMember> {
    const response = await apiClient.post(`/api/v2/patients/${patientUuid}/family-members`, toFormData({ ...data }));
    return response.data?.data || response.data;
  },

  async update(patientUuid: string, id: string, data: Partial<CreateFamilyMemberDto>): Promise<FamilyMember> {
    const response = await apiClient.put(`/api/v2/patients/${patientUuid}/family-members/${id}`, toFormData({ ...data }));
    return response.data?.data || response.data;
  },

  async remove(patientUuid: string, id: string): Promise<void> {
    await apiClient.delete(`/api/v2/patients/${patientUuid}/family-members/${id}`);
  },

  async nextOfKin(patientUuid: string): Promise<FamilyMember[]> {
    const response = await apiClient.get(`/api/v2/patients/${patientUuid}/family-members/next-of-kin`);
    return response.data?.data || [];
  },
};

// =============================================================================
// PATIENT ACCESS CONTROLS (Patient-controlled data sharing)
// =============================================================================
export const accessControlsService = {
  async list(patientUuid: string, params: { page?: number; perPage?: number; status?: string } = {}): Promise<PaginatedResponse<PatientAccessControl>> {
    const response = await apiClient.get(`/api/v2/patients/${patientUuid}/access-controls`, { params });
    return paginate<PatientAccessControl>(response, params.page || 1, params.perPage || 10);
  },

  async get(patientUuid: string, id: string): Promise<PatientAccessControl> {
    const response = await apiClient.get(`/api/v2/patients/${patientUuid}/access-controls/${id}`);
    return response.data?.data || response.data;
  },

  async grant(patientUuid: string, data: CreateAccessControlDto): Promise<PatientAccessControl> {
    const formData: Record<string, unknown> = { ...data };
    if (data.scope) formData.scope = JSON.stringify(data.scope);

    const response = await apiClient.post(`/api/v2/patients/${patientUuid}/access-controls`, toFormData(formData));
    return response.data?.data || response.data;
  },

  async update(patientUuid: string, id: string, data: Partial<CreateAccessControlDto>): Promise<PatientAccessControl> {
    const formData: Record<string, unknown> = { ...data };
    if (data.scope) formData.scope = JSON.stringify(data.scope);

    const response = await apiClient.put(`/api/v2/patients/${patientUuid}/access-controls/${id}`, toFormData(formData));
    return response.data?.data || response.data;
  },

  async revoke(patientUuid: string, id: string, reason?: string): Promise<void> {
    await apiClient.post(
      `/api/v2/patients/${patientUuid}/access-controls/${id}/revoke`,
      toFormData({ reason: reason || 'Revoked by patient' })
    );
  },

  async remove(patientUuid: string, id: string): Promise<void> {
    await apiClient.delete(`/api/v2/patients/${patientUuid}/access-controls/${id}`);
  },

  async myPatients(): Promise<PatientAccessControl[]> {
    const response = await apiClient.get('/api/v2/access/my-patients');
    return response.data?.data || [];
  },
};

// =============================================================================
// PATIENT ALERTS
// =============================================================================
export const alertsService = {
  async list(patientUuid: string, params: { page?: number; perPage?: number; severity?: string; status?: string } = {}): Promise<PaginatedResponse<PatientAlert>> {
    const response = await apiClient.get(`/api/v2/patients/${patientUuid}/alerts`, { params });
    return paginate<PatientAlert>(response, params.page || 1, params.perPage || 10);
  },

  async create(patientUuid: string, data: CreateAlertDto): Promise<PatientAlert> {
    const response = await apiClient.post(`/api/v2/patients/${patientUuid}/alerts`, toFormData({ ...data }));
    return response.data?.data || response.data;
  },

  async acknowledge(patientUuid: string, id: string): Promise<PatientAlert> {
    const response = await apiClient.post(`/api/v2/patients/${patientUuid}/alerts/${id}/acknowledge`, toFormData({}));
    return response.data?.data || response.data;
  },

  async resolve(patientUuid: string, id: string, notes?: string): Promise<PatientAlert> {
    const response = await apiClient.post(
      `/api/v2/patients/${patientUuid}/alerts/${id}/resolve`,
      toFormData({ resolution_notes: notes || '' })
    );
    return response.data?.data || response.data;
  },

  async remove(patientUuid: string, id: string): Promise<void> {
    await apiClient.delete(`/api/v2/patients/${patientUuid}/alerts/${id}`);
  },

  async activeForHospital(hospitalUuid: string): Promise<PatientAlert[]> {
    const response = await apiClient.get(`/api/v2/hospitals/${hospitalUuid}/alerts/active`);
    return response.data?.data || [];
  },

  async criticalForHospital(hospitalUuid: string): Promise<PatientAlert[]> {
    const response = await apiClient.get(`/api/v2/hospitals/${hospitalUuid}/alerts/critical`);
    return response.data?.data || [];
  },
};

// =============================================================================
// DEMENTIA ASSESSMENTS (for care-home dashboard)
// =============================================================================
export const dementiaService = {
  async highRiskWandering(): Promise<DementiaAssessment[]> {
    const response = await apiClient.get('/api/v2/dementia/high-risk-wandering');
    return response.data?.data || [];
  },

  async dueForReassessment(): Promise<DementiaAssessment[]> {
    const response = await apiClient.get('/api/v2/dementia/due-for-reassessment');
    return response.data?.data || [];
  },

  async list(patientUuid: string): Promise<DementiaAssessment[]> {
    const response = await apiClient.get(`/api/v2/patients/${patientUuid}/dementia-assessments`);
    return response.data?.data || [];
  },

  async latest(patientUuid: string): Promise<DementiaAssessment | null> {
    const response = await apiClient.get(`/api/v2/patients/${patientUuid}/dementia-assessments/latest`);
    return response.data?.data || null;
  },
};

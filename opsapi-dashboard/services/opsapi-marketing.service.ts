import { apiClient } from '@/lib/api-client';

const BASE = '/api/v2/opsapi-marketing';

export const marketingService = {
  listCampaigns: (params?: Record<string, unknown>) =>
    apiClient.get(`${BASE}/campaigns`, { params }),
  getCampaign: (id: string) => apiClient.get(`${BASE}/campaigns/${id}`),
  createCampaign: (body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/campaigns`, body),
  updateCampaign: (id: string, body: Record<string, unknown>) =>
    apiClient.put(`${BASE}/campaigns/${id}`, body),
  scheduleCampaign: (id: string, body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/campaigns/${id}/schedule`, body),
  validateCampaign: (id: string, body?: Record<string, unknown>) =>
    apiClient.post(`${BASE}/campaigns/${id}/validate`, body || {}),
  audiencePreview: (id: string, body?: Record<string, unknown>) =>
    apiClient.post(`${BASE}/campaigns/${id}/audience-preview`, body || {}),
  requestApproval: (id: string, body?: Record<string, unknown>) =>
    apiClient.post(`${BASE}/campaigns/${id}/request-approval`, body || {}),
  approveCampaign: (id: string) => apiClient.post(`${BASE}/campaigns/${id}/approve`, {}),
  rejectCampaign: (id: string, body?: Record<string, unknown>) =>
    apiClient.post(`${BASE}/campaigns/${id}/reject`, body || {}),
  pauseCampaign: (id: string) => apiClient.post(`${BASE}/campaigns/${id}/pause`),
  resumeCampaign: (id: string) => apiClient.post(`${BASE}/campaigns/${id}/resume`),
  cancelCampaign: (id: string) => apiClient.post(`${BASE}/campaigns/${id}/cancel`),
  duplicateCampaign: (id: string, body?: Record<string, unknown>) =>
    apiClient.post(`${BASE}/campaigns/${id}/duplicate`, body || {}),
  setAbConfig: (id: string, body: Record<string, unknown>) =>
    apiClient.put(`${BASE}/campaigns/${id}/ab-config`, body),
  campaignStats: (id: string) => apiClient.get(`${BASE}/campaigns/${id}/stats`),
  checkEligibility: (id: string, body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/campaigns/${id}/eligibility`, body),
  testSend: (id: string, body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/campaigns/${id}/test-send`, body),

  listLists: (params?: Record<string, unknown>) =>
    apiClient.get(`${BASE}/lists`, { params }),
  createList: (body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/lists`, body),
  addListMember: (id: string, contact_uuid: string) =>
    apiClient.post(`${BASE}/lists/${id}/members`, { contact_uuid }),
  listMembers: (id: string) => apiClient.get(`${BASE}/lists/${id}/members`),

  listTemplates: (params?: Record<string, unknown>) =>
    apiClient.get(`${BASE}/templates`, { params }),
  createTemplate: (body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/templates`, body),
  previewTemplate: (body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/templates/preview`, body),
  analyseTemplate: (body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/templates/analyse`, body),
  seedTemplates: () => apiClient.post(`${BASE}/templates/seed`, {}),
  publishTemplate: (id: string) => apiClient.post(`${BASE}/templates/${id}/publish`, {}),
  cloneTemplate: (id: string, body?: Record<string, unknown>) =>
    apiClient.post(`${BASE}/templates/${id}/clone`, body || {}),
  saveStudio: (id: string, body: Record<string, unknown>) =>
    apiClient.put(`${BASE}/templates/${id}/studio`, body),

  listMergeFields: () => apiClient.get(`${BASE}/merge-fields`),
  createMergeField: (body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/merge-fields`, body),
  validateMergeFields: (body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/merge-fields/validate`, body),

  previewSegment: (body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/segments/preview`, body),
  segmentFields: () => apiClient.get(`${BASE}/segments/fields`),
  setListSegment: (id: string, body: Record<string, unknown>) =>
    apiClient.put(`${BASE}/lists/${id}/segment`, body),
  syncList: (id: string) => apiClient.post(`${BASE}/lists/${id}/sync`, {}),
  importListCsv: (id: string, body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/lists/${id}/import`, body),

  listSuppressions: (params?: Record<string, unknown>) =>
    apiClient.get(`${BASE}/suppressions`, { params }),
  optIn: (body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/consent/opt-in`, body),
  optOut: (body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/consent/opt-out`, body),
  getConsent: (contactUuid: string) =>
    apiClient.get(`${BASE}/consent/${contactUuid}`),

  listChannels: () => apiClient.get(`${BASE}/channels`),

  analyticsOverview: () => apiClient.get(`${BASE}/analytics/overview`),
  campaignAnalytics: (id: string) => apiClient.get(`${BASE}/analytics/campaigns/${id}`),
  contactTimeline: (contactUuid: string, params?: Record<string, unknown>) =>
    apiClient.get(`${BASE}/analytics/contacts/${contactUuid}`, { params }),

  listReplies: (params?: Record<string, unknown>) =>
    apiClient.get(`${BASE}/replies`, { params }),
  getReply: (id: string) => apiClient.get(`${BASE}/replies/${id}`),
  ingestReply: (body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/replies/ingest`, body),
  classifyPreview: (body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/replies/classify-preview`, body),
};

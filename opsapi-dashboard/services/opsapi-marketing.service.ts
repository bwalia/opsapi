import { apiClient } from '@/lib/api-client';

const BASE = '/api/v2/opsapi-marketing';

/** Plugin SDK (sdk.body) requires a JSON object — not the apiClient default form encoding. */
const JSON_BODY = { headers: { 'Content-Type': 'application/json' } } as const;
/** Lifecycle actions (send, approve, cancel…) must fail when offline, never be queued and run later. */
const ACTION = { ...JSON_BODY, _noOutbox: true } as const;

export const marketingService = {
  listCampaigns: (params?: Record<string, unknown>) =>
    apiClient.get(`${BASE}/campaigns`, { params }),
  getCampaign: (id: string) => apiClient.get(`${BASE}/campaigns/${id}`),
  createCampaign: (body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/campaigns`, body, JSON_BODY),
  updateCampaign: (id: string, body: Record<string, unknown>) =>
    apiClient.put(`${BASE}/campaigns/${id}`, body, JSON_BODY),
  // Send now builds the whole audience inside this request, which can take longer than 30s.
  scheduleCampaign: (id: string, body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/campaigns/${id}/schedule`, body, { ...ACTION, timeout: 120000 }),
  validateCampaign: (id: string, body?: Record<string, unknown>) =>
    apiClient.post(`${BASE}/campaigns/${id}/validate`, body || {}, ACTION),
  audiencePreview: (id: string, body?: Record<string, unknown>) =>
    apiClient.post(`${BASE}/campaigns/${id}/audience-preview`, body || {}, JSON_BODY),
  requestApproval: (id: string, body?: Record<string, unknown>) =>
    apiClient.post(`${BASE}/campaigns/${id}/request-approval`, body || {}, ACTION),
  approveCampaign: (id: string) =>
    apiClient.post(`${BASE}/campaigns/${id}/approve`, {}, ACTION),
  rejectCampaign: (id: string, body?: Record<string, unknown>) =>
    apiClient.post(`${BASE}/campaigns/${id}/reject`, body || {}, ACTION),
  pauseCampaign: (id: string) => apiClient.post(`${BASE}/campaigns/${id}/pause`, {}, ACTION),
  resumeCampaign: (id: string) => apiClient.post(`${BASE}/campaigns/${id}/resume`, {}, ACTION),
  cancelCampaign: (id: string) => apiClient.post(`${BASE}/campaigns/${id}/cancel`, {}, ACTION),
  duplicateCampaign: (id: string, body?: Record<string, unknown>) =>
    apiClient.post(`${BASE}/campaigns/${id}/duplicate`, body || {}, ACTION),
  setAbConfig: (id: string, body: Record<string, unknown>) =>
    apiClient.put(`${BASE}/campaigns/${id}/ab-config`, body, JSON_BODY),
  campaignStats: (id: string) => apiClient.get(`${BASE}/campaigns/${id}/stats`),
  checkEligibility: (id: string, body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/campaigns/${id}/eligibility`, body, JSON_BODY),
  testSend: (id: string, body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/campaigns/${id}/test-send`, body, ACTION),

  listLists: (params?: Record<string, unknown>) =>
    apiClient.get(`${BASE}/lists`, { params }),
  createList: (body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/lists`, body, JSON_BODY),
  addListMember: (id: string, contact_uuid: string) =>
    apiClient.post(`${BASE}/lists/${id}/members`, { contact_uuid }, JSON_BODY),
  listMembers: (id: string) => apiClient.get(`${BASE}/lists/${id}/members`),
  removeListMember: (id: string, contactUuid: string) =>
    apiClient.delete(`${BASE}/lists/${id}/members/${contactUuid}`),
  deleteList: (id: string) => apiClient.delete(`${BASE}/lists/${id}`),

  listTemplates: (params?: Record<string, unknown>) =>
    apiClient.get(`${BASE}/templates`, { params }),
  createTemplate: (body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/templates`, body, JSON_BODY),
  previewTemplate: (body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/templates/preview`, body, JSON_BODY),
  analyseTemplate: (body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/templates/analyse`, body, JSON_BODY),
  seedTemplates: () => apiClient.post(`${BASE}/templates/seed`, {}, JSON_BODY),
  publishTemplate: (id: string) =>
    apiClient.post(`${BASE}/templates/${id}/publish`, {}, JSON_BODY),
  cloneTemplate: (id: string, body?: Record<string, unknown>) =>
    apiClient.post(`${BASE}/templates/${id}/clone`, body || {}, JSON_BODY),
  saveStudio: (id: string, body: Record<string, unknown>) =>
    apiClient.put(`${BASE}/templates/${id}/studio`, body, JSON_BODY),

  listMergeFields: () => apiClient.get(`${BASE}/merge-fields`),
  createMergeField: (body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/merge-fields`, body, JSON_BODY),
  validateMergeFields: (body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/merge-fields/validate`, body, JSON_BODY),

  previewSegment: (body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/segments/preview`, body, JSON_BODY),
  segmentFields: () => apiClient.get(`${BASE}/segments/fields`),
  setListSegment: (id: string, body: Record<string, unknown>) =>
    apiClient.put(`${BASE}/lists/${id}/segment`, body, JSON_BODY),
  syncList: (id: string) => apiClient.post(`${BASE}/lists/${id}/sync`, {}, JSON_BODY),
  importListCsv: (id: string, body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/lists/${id}/import`, body, JSON_BODY),
  // A CSV / XLSX / PDF of contacts (base64): commit=false previews, commit=true imports.
  // Large files take a while to read; never queued offline.
  importContactsFile: (id: string, body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/lists/${id}/prospects`, body, { ...ACTION, timeout: 120000 }),

  listSuppressions: (params?: Record<string, unknown>) =>
    apiClient.get(`${BASE}/suppressions`, { params }),
  optIn: (body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/consent/opt-in`, body, JSON_BODY),
  optOut: (body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/consent/opt-out`, body, JSON_BODY),
  getConsent: (contactUuid: string) =>
    apiClient.get(`${BASE}/consent/${contactUuid}`),

  listChannels: () => apiClient.get(`${BASE}/channels`),

  analyticsOverview: () => apiClient.get(`${BASE}/analytics/overview`),
  campaignAnalytics: (id: string) => apiClient.get(`${BASE}/analytics/campaigns/${id}`),
  contactTimeline: (contactUuid: string, params?: Record<string, unknown>) =>
    apiClient.get(`${BASE}/analytics/contacts/${contactUuid}`, { params }),

  attribution: (params?: { days?: number }) => apiClient.get(`${BASE}/analytics/attribution`, { params }),

  listPixels: () => apiClient.get(`${BASE}/pixels`),
  getPixel: (id: string) => apiClient.get(`${BASE}/pixels/${id}`),
  createPixel: (body: { name: string; allowed_domains?: string[]; attribution_window_days?: number }) =>
    apiClient.post(`${BASE}/pixels`, body, JSON_BODY),
  updatePixel: (
    id: string,
    body: { name?: string; allowed_domains?: string[]; attribution_window_days?: number; is_active?: boolean },
  ) => apiClient.put(`${BASE}/pixels/${id}`, body, JSON_BODY),
  deletePixel: (id: string) => apiClient.delete(`${BASE}/pixels/${id}`),
  rotatePixelKey: (id: string) => apiClient.post(`${BASE}/pixels/${id}/rotate-key`, {}, JSON_BODY),
  pixelSnippet: (id: string) => apiClient.get(`${BASE}/pixels/${id}/snippet`),
  pixelEvents: (id: string, params?: { limit?: number; after_id?: number }) =>
    apiClient.get(`${BASE}/pixels/${id}/events`, { params }),
  pixelTestEvent: (id: string, body?: { event?: string; url?: string }) =>
    apiClient.post(`${BASE}/pixels/${id}/test-event`, body || {}, JSON_BODY),
  pixelStats: (id: string, params?: { days?: number }) => apiClient.get(`${BASE}/pixels/${id}/stats`, { params }),
  pixelForwards: (params?: { limit?: number }) => apiClient.get(`${BASE}/pixel-forwards`, { params }),

  listReplies: (params?: Record<string, unknown>) =>
    apiClient.get(`${BASE}/replies`, { params }),
  getReply: (id: string) => apiClient.get(`${BASE}/replies/${id}`),
  ingestReply: (body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/replies/ingest`, body, JSON_BODY),
  classifyPreview: (body: Record<string, unknown>) =>
    apiClient.post(`${BASE}/replies/classify-preview`, body, JSON_BODY),
};

import apiClient, { toFormData, buildQueryString } from '@/lib/api-client';

// ============================================================
// Types
// ============================================================

export type CourseLevel = 'beginner' | 'intermediate' | 'advanced';
export type CourseStatus = 'draft' | 'published' | 'archived';
export type LessonStatus = 'draft' | 'published';

export interface AcademyCourse {
  uuid: string;
  title: string;
  slug: string;
  description?: string;
  instructor?: string;
  thumbnail_url?: string;
  category?: string;
  level: CourseLevel;
  is_free: boolean;
  price: number;
  currency: string;
  rating?: number;
  rating_count?: number;
  duration_minutes?: number;
  lesson_count?: number;
  status: CourseStatus;
  owner_user_uuid?: string;
  created_at: string;
  updated_at: string;
}

export interface AcademyLesson {
  uuid: string;
  course_id?: number;
  title: string;
  description?: string;
  position?: number;
  duration_seconds?: number;
  is_preview?: boolean;
  s3_key?: string;
  content_html?: string;
  content_json?: string;
  status: LessonStatus;
  created_at: string;
  updated_at: string;
}

export interface CourseWithLessons {
  course: AcademyCourse;
  lessons: AcademyLesson[];
}

export interface InstructorNamespace {
  id: number;
  uuid: string;
  slug: string;
  name: string;
}

export interface InstructorStatus {
  is_instructor: boolean;
  is_owner: boolean;
  namespace: InstructorNamespace;
}

export interface CourseListParams {
  page?: number;
  perPage?: number;
  search?: string;
  status?: string;
  category?: string;
  level?: string;
}

export interface CoursePagination {
  page: number;
  perPage: number;
  total: number;
}

export interface CourseListResult {
  data: AcademyCourse[];
  pagination: CoursePagination;
}

export interface CourseInput {
  title: string;
  slug?: string;
  description?: string;
  instructor?: string;
  thumbnail_url?: string;
  category?: string;
  level?: CourseLevel;
  is_free?: boolean;
  price?: number;
  currency?: string;
  status?: CourseStatus;
}

export interface LessonInput {
  title: string;
  description?: string;
  position?: number;
  duration_seconds?: number;
  is_preview?: boolean;
  s3_key?: string;
  content_html?: string;
  content_json?: string;
  status?: LessonStatus;
}

export interface CommunityPlan {
  amount: number; // minor units (e.g. 999 = $9.99)
  currency: string;
  interval: string; // month|year
}

export interface CreatorBank {
  account_holder_name?: string;
  bank_name?: string;
  account_number?: string;
  routing_number?: string;
  sort_code?: string;
  iban?: string;
  swift_bic?: string;
  bank_country?: string;
  payout_email?: string;
}

export interface CreatorEarnings {
  total_net: number;
  owed: number;
  paid: number;
  currency: string;
  sales: number;
}

export interface CreatorAccount {
  bank: CreatorBank;
  bank_details_complete: boolean;
  fee_pct: number; // effective cut % applied to this creator
  plan?: CommunityPlan | null;
  earnings: CreatorEarnings;
}

export interface PayoutRow {
  namespace_id: number;
  namespace_name: string;
  namespace_slug: string;
  owed: number;
  currency: string;
  sales: number;
  bank?: (CreatorBank & { complete?: boolean }) | null;
}

export interface SubscriptionPlanInput {
  amount: number; // minor units
  interval: 'month' | 'year';
  currency?: string;
}

// ============================================================
// Helpers
// ============================================================

function unwrap<T>(response: { data: unknown }): T {
  const d = response.data as Record<string, unknown>;
  return (d?.data ?? d) as T;
}

function buildCourseParams(params: CourseListParams): Record<string, unknown> {
  const q: Record<string, unknown> = {};
  if (params.page) q.page = params.page;
  if (params.perPage) q.perPage = params.perPage;
  if (params.search) q.search = params.search;
  if (params.status && params.status !== 'all') q.status = params.status;
  if (params.category && params.category !== 'all') q.category = params.category;
  if (params.level && params.level !== 'all') q.level = params.level;
  return q;
}

// ============================================================
// Service
// ============================================================

export const academyService = {
  // ----------------------------------------------------------
  // Courses
  // ----------------------------------------------------------

  async getCourses(params: CourseListParams = {}): Promise<CourseListResult> {
    const qs = buildQueryString(buildCourseParams(params));
    const response = await apiClient.get(`/api/v2/academy/courses${qs}`);
    const body = response.data as Record<string, unknown>;
    const pagination = (body?.pagination as CoursePagination) ?? {
      page: 1,
      perPage: 50,
      total: 0,
    };
    return {
      data: Array.isArray(body?.data) ? (body.data as AcademyCourse[]) : [],
      pagination,
    };
  },

  async getCourse(uuid: string): Promise<CourseWithLessons> {
    const response = await apiClient.get(`/api/v2/academy/courses/${uuid}`);
    return unwrap<CourseWithLessons>(response);
  },

  async createCourse(data: CourseInput): Promise<AcademyCourse> {
    const response = await apiClient.post(
      '/api/v2/academy/courses',
      toFormData(data as unknown as Record<string, unknown>)
    );
    return unwrap<AcademyCourse>(response);
  },

  async updateCourse(uuid: string, data: Partial<CourseInput>): Promise<AcademyCourse> {
    const response = await apiClient.put(
      `/api/v2/academy/courses/${uuid}`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return unwrap<AcademyCourse>(response);
  },

  async deleteCourse(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/academy/courses/${uuid}`);
  },

  // ----------------------------------------------------------
  // Lessons
  // ----------------------------------------------------------

  async getLessons(courseUuid: string): Promise<AcademyLesson[]> {
    const response = await apiClient.get(`/api/v2/academy/courses/${courseUuid}/lessons`);
    const data = unwrap<AcademyLesson[]>(response);
    return Array.isArray(data) ? data : [];
  },

  async getLesson(uuid: string): Promise<AcademyLesson> {
    const response = await apiClient.get(`/api/v2/academy/lessons/${uuid}`);
    return unwrap<AcademyLesson>(response);
  },

  async createLesson(courseUuid: string, data: LessonInput): Promise<AcademyLesson> {
    const response = await apiClient.post(
      `/api/v2/academy/courses/${courseUuid}/lessons`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return unwrap<AcademyLesson>(response);
  },

  async updateLesson(uuid: string, data: Partial<LessonInput>): Promise<AcademyLesson> {
    const response = await apiClient.put(
      `/api/v2/academy/lessons/${uuid}`,
      toFormData(data as unknown as Record<string, unknown>)
    );
    return unwrap<AcademyLesson>(response);
  },

  async deleteLesson(uuid: string): Promise<void> {
    await apiClient.delete(`/api/v2/academy/lessons/${uuid}`);
  },

  // ----------------------------------------------------------
  // Creator monetization (bank details + community subscription).
  // The platform is the merchant; creators are paid out manually.
  // These endpoints return flat shapes (not the {success,data} envelope).
  // ----------------------------------------------------------

  async getCreatorAccount(): Promise<CreatorAccount> {
    const response = await apiClient.get('/api/v2/academy/creator/account');
    return response.data as CreatorAccount;
  },

  async saveBankDetails(bank: CreatorBank): Promise<{ bank_details_complete: boolean }> {
    const response = await apiClient.put(
      '/api/v2/academy/creator/account',
      toFormData(bank as Record<string, unknown>),
    );
    return response.data as { bank_details_complete: boolean };
  },

  async setSubscriptionPlan(
    input: SubscriptionPlanInput,
  ): Promise<CommunityPlan> {
    const response = await apiClient.put(
      '/api/v2/academy/creator/subscription-plan',
      toFormData(input as unknown as Record<string, unknown>),
    );
    return response.data as CommunityPlan;
  },

  // ----------------------------------------------------------
  // Super-admin (platform "administrative" role)
  // ----------------------------------------------------------

  async getDefaultFeePct(): Promise<number> {
    const response = await apiClient.get('/api/v2/academy/admin/settings');
    return Number(response.data?.default_fee_pct ?? 0);
  },

  async setDefaultFeePct(pct: number): Promise<number> {
    const response = await apiClient.put(
      '/api/v2/academy/admin/settings',
      toFormData({ default_fee_pct: pct }),
    );
    return Number(response.data?.default_fee_pct ?? pct);
  },

  async setCreatorFeeOverride(namespaceId: number, pct: number | null): Promise<void> {
    await apiClient.put(
      `/api/v2/academy/admin/creators/${namespaceId}/fee`,
      toFormData({ fee_pct: pct ?? '' }),
    );
  },

  async getPayouts(): Promise<PayoutRow[]> {
    const response = await apiClient.get('/api/v2/academy/admin/payouts');
    return Array.isArray(response.data?.payouts) ? (response.data.payouts as PayoutRow[]) : [];
  },

  async markPayoutPaid(
    namespaceId: number,
    reference: string,
  ): Promise<{ paid: boolean; amount: number; currency: string }> {
    const response = await apiClient.post(
      `/api/v2/academy/admin/payouts/${namespaceId}/mark-paid`,
      toFormData({ reference }),
    );
    return response.data as { paid: boolean; amount: number; currency: string };
  },

  // ----------------------------------------------------------
  // Instructor self-service (role inside the single academy namespace)
  // ----------------------------------------------------------

  async getInstructorStatus(): Promise<InstructorStatus> {
    const response = await apiClient.get('/api/v2/academy/instructor/status');
    return unwrap<InstructorStatus>(response);
  },

  async registerInstructor(): Promise<InstructorStatus> {
    const response = await apiClient.post('/api/v2/academy/instructor/register');
    return unwrap<InstructorStatus>(response);
  },
};

// ============================================================
// Presentation helpers
// ============================================================

export function getCourseStatusVariant(
  status: CourseStatus
): 'success' | 'warning' | 'secondary' {
  switch (status) {
    case 'published':
      return 'success';
    case 'draft':
      return 'warning';
    default:
      return 'secondary';
  }
}

export function formatCourseDuration(minutes?: number): string {
  if (!minutes || minutes <= 0) return '—';
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

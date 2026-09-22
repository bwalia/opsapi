import apiClient, { buildQueryString } from '@/lib/api-client';
import type {
  FsEmployee,
  FsEmployeeListParams,
  FsPaginated,
  FsPageMeta,
  FsPayload,
} from './field-service.service';

/**
 * Employees API client — a generic staff directory (team members, their
 * workspace logins, roles and skills). This is a CORE module: available to any
 * namespace, independent of field service. Backed by lapis/routes/employees.lua
 * (`/api/v2/employees*`).
 *
 * The row/param/response types are shared with the field-service client (the
 * same `employees` table underlies both) and re-exported here under neutral
 * names so callers don't import from field-service.
 */

export type Employee = FsEmployee;
export type EmployeeListParams = FsEmployeeListParams;
/** A workspace member offered in the "add employee" picker. */
export interface EmployeeCandidate {
  uuid: string;
  email: string;
  name: string;
  /** The member's workspace role (e.g. "Service Manager", "Owner"). */
  role?: string | null;
}
export type { FsEmployee, FsEmployeeListParams, FsPaginated, FsPayload };

const JSON_BODY = { headers: { 'Content-Type': 'application/json' } } as const;
const BASE = '/api/v2/employees';

function unwrap<T>(response: { data: unknown }): T {
  const body = response.data as { data?: T };
  return (body?.data ?? body) as T;
}

function paginated<T>(response: { data: unknown }): FsPaginated<T> {
  const body = response.data as { data?: T[]; meta?: FsPageMeta };
  return {
    data: Array.isArray(body?.data) ? body.data : [],
    meta: body?.meta ?? { total: 0, page: 1, per_page: 20, total_pages: 0 },
  };
}

function qs(params: object): string {
  const q: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(params)) {
    if (v === undefined || v === null || v === '' || v === 'all') continue;
    q[k] = typeof v === 'boolean' ? (v ? 'true' : undefined) : v;
  }
  return buildQueryString(q);
}

export const employeeService = {
  async getEmployees(params: EmployeeListParams = {}): Promise<FsPaginated<Employee>> {
    // qs() drops boolean false, so stringify the flag filters — otherwise
    // "inactive only" (is_active=false) would send nothing and return all.
    const q: Record<string, unknown> = { ...params };
    if (typeof params.is_engineer === 'boolean') q.is_engineer = String(params.is_engineer);
    if (typeof params.is_active === 'boolean') q.is_active = String(params.is_active);
    return paginated<Employee>(await apiClient.get(`${BASE}${qs(q)}`));
  },

  async getEmployee(uuid: string): Promise<Employee> {
    return unwrap<Employee>(await apiClient.get(`${BASE}/${uuid}`));
  },

  async createEmployee(data: FsPayload): Promise<Employee> {
    return unwrap<Employee>(await apiClient.post(`${BASE}`, data, JSON_BODY));
  },

  async updateEmployee(uuid: string, data: FsPayload): Promise<Employee> {
    return unwrap<Employee>(await apiClient.put(`${BASE}/${uuid}`, data, JSON_BODY));
  },

  async deleteEmployee(uuid: string): Promise<void> {
    await apiClient.delete(`${BASE}/${uuid}`);
  },

  /** Active workspace members for the "add employee" picker. */
  async getCandidates(search?: string): Promise<EmployeeCandidate[]> {
    return unwrap<EmployeeCandidate[]>(await apiClient.get(`${BASE}/candidates${qs({ search })}`)) || [];
  },

  // One-step onboarding: create login + workspace membership + role (+ profile).
  // Returns the temp password for the admin to hand over.
  async createTeamMember(data: FsPayload): Promise<{
    email: string; name: string; role: string; temp_password: string; user_uuid: string;
  }> {
    return unwrap(await apiClient.post(`${BASE}/team-members`, data, JSON_BODY));
  },
};

export default employeeService;

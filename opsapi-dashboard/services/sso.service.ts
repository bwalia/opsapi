import apiClient from '@/lib/api-client';

/**
 * SAML single sign-on: a workspace's identity providers (Okta, Entra ID,
 * Google Workspace, …). Backed by lapis/routes/saml.lua (/api/v2/sso/saml).
 */

export interface SamlProvider {
  id: number;
  uuid: string;
  name: string;
  idp_entity_id: string;
  idp_sso_url: string;
  idp_x509_cert: string;
  email_domains: string[];
  default_role?: string | null;
  auto_provision: boolean;
  allow_idp_initiated: boolean;
  attribute_mapping: { email?: string; first_name?: string; last_name?: string };
  is_enabled: boolean;
  last_login_at?: string | null;
  login_count: number;
  created_at: string;
  updated_at: string;
  /** What to give the IdP: our entity ID, ACS URL and metadata URL. */
  sp: { sp_entity_id: string; acs_url: string; login_url: string };
}

export interface SamlProviderInput {
  name?: string;
  idp_entity_id?: string;
  idp_sso_url?: string;
  idp_x509_cert?: string;
  email_domains?: string;
  default_role?: string;
  auto_provision?: boolean;
  allow_idp_initiated?: boolean;
  attribute_mapping?: { email?: string; first_name?: string; last_name?: string };
  is_enabled?: boolean;
}

const BASE = '/api/v2/sso/saml';

function unwrap<T>(response: { data: unknown }): T {
  const body = response.data as { data?: T };
  return (body?.data ?? body) as T;
}

export const ssoService = {
  async list(): Promise<SamlProvider[]> {
    const data = unwrap<SamlProvider[]>(await apiClient.get(`${BASE}/providers`));
    return Array.isArray(data) ? data : [];
  },
  async create(input: SamlProviderInput): Promise<SamlProvider> {
    return unwrap<SamlProvider>(await apiClient.post(`${BASE}/providers`, input));
  },
  async update(uuid: string, input: SamlProviderInput): Promise<SamlProvider> {
    return unwrap<SamlProvider>(await apiClient.put(`${BASE}/providers/${uuid}`, input));
  },
  async remove(uuid: string): Promise<void> {
    await apiClient.delete(`${BASE}/providers/${uuid}`);
  },
  /** Read entity ID, sign-in URL and certificate out of IdP metadata XML. */
  async parseMetadata(xml: string): Promise<Pick<SamlProvider, 'idp_entity_id' | 'idp_sso_url' | 'idp_x509_cert'>> {
    return unwrap(await apiClient.post(`${BASE}/metadata/parse`, { xml }));
  },
};

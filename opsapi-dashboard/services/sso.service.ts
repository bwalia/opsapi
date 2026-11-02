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
  /** Each email domain and whether the workspace has proved it owns it. */
  domains: SamlDomain[];
}

/** An email domain and the DNS TXT record proving the workspace owns it. */
export interface SamlDomain {
  domain: string;
  verified: boolean;
  verified_at?: string | null;
  txt_name: string;
  txt_value: string;
  /** Why it isn't verified yet, after a check. */
  message?: string;
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
// The SAML routes read JSON bodies (sdk.body); apiClient's default is form-encoded.
const JSON_BODY = { headers: { 'Content-Type': 'application/json' } } as const;

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
    return unwrap<SamlProvider>(await apiClient.post(`${BASE}/providers`, input, JSON_BODY));
  },
  async update(uuid: string, input: SamlProviderInput): Promise<SamlProvider> {
    return unwrap<SamlProvider>(await apiClient.put(`${BASE}/providers/${uuid}`, input, JSON_BODY));
  },
  async remove(uuid: string): Promise<void> {
    await apiClient.delete(`${BASE}/providers/${uuid}`);
  },
  /** Look the domain's TXT record up now; verified once it's there. */
  async verifyDomain(domain: string): Promise<SamlDomain> {
    return unwrap<SamlDomain>(await apiClient.post(`${BASE}/domains/verify`, { domain }, JSON_BODY));
  },
  /** Read entity ID, sign-in URL and certificate out of IdP metadata XML. */
  async parseMetadata(xml: string): Promise<Pick<SamlProvider, 'idp_entity_id' | 'idp_sso_url' | 'idp_x509_cert'>> {
    return unwrap(await apiClient.post(`${BASE}/metadata/parse`, { xml }, JSON_BODY));
  },
};

/**
 * Workspace email: the workspace's own SMTP accounts, which account sends
 * which kind of email, and its versions of the built-in email templates
 * (RBAC `namespace`).
 */
import apiClient from '@/lib/api-client';

export interface MailSettings {
  configured: boolean;
  enabled?: boolean;
  host?: string;
  port?: number;
  security?: 'starttls' | 'ssl' | 'none';
  username?: string | null;
  has_password?: boolean;
  from_email?: string;
  from_name?: string | null;
  reply_to?: string | null;
  last_tested_at?: string | null;
  last_error?: string | null;
}

export interface MailSettingsInput {
  host: string;
  port: number;
  security: 'starttls' | 'ssl' | 'none';
  username?: string;
  /** Omit to keep the stored password; "" removes it. */
  password?: string;
  from_email: string;
  from_name?: string;
  reply_to?: string;
  enabled?: boolean;
}

export type MailSecurity = 'starttls' | 'ssl' | 'none';

/** One of the workspace's SMTP accounts (the password is never returned). */
export interface MailAccount {
  uuid: string;
  name: string;
  is_default: boolean;
  enabled: boolean;
  host: string;
  port: number;
  security: MailSecurity;
  username?: string | null;
  has_password: boolean;
  from_email: string;
  from_name?: string | null;
  reply_to?: string | null;
  last_tested_at?: string | null;
  last_error?: string | null;
  updated_at?: string;
}

export interface MailAccountInput {
  name: string;
  host: string;
  port: number;
  security: MailSecurity;
  username?: string;
  /** Omit to keep the stored password; "" removes it. */
  password?: string;
  from_email: string;
  from_name?: string;
  reply_to?: string;
  enabled?: boolean;
  is_default?: boolean;
}

/** A kind of email and the account that sends it (null = the default account; for "default", the platform). */
export interface MailRoute {
  key: string;
  name: string;
  /** Where it's listed on the page: "Leads and customers", "Sales", a plugin's name, "Other"… */
  group: string;
  description: string;
  account_uuid: string | null;
}

export interface MailAccountsOverview {
  accounts: MailAccount[];
  routing: MailRoute[];
  platform: { host: string; from_email: string; from_name: string; configured: boolean };
  /** Emails the platform always sends itself, whatever is set here. */
  platform_only?: string[];
}

export interface EmailTemplate {
  key: string;
  name: string;
  variables: string[];
  default_subject: string;
  customised: boolean;
  subject: string;
  html?: string | null;
  updated_at?: string | null;
}

const data = <T>(res: { data: { data: T } }): T => res.data.data;
const enc = encodeURIComponent;
/** These routes read a JSON body (apiClient defaults to form encoding, which they reject). */
const JSON_HDR = { headers: { 'Content-Type': 'application/json' } };

export const namespaceMailService = {
  overview: async () => data<MailAccountsOverview>(await apiClient.get('/api/v2/namespace/mail-accounts')),
  createAccount: async (input: MailAccountInput) =>
    data<MailAccount>(await apiClient.post('/api/v2/namespace/mail-accounts', input, JSON_HDR)),
  updateAccount: async (uuid: string, input: Partial<MailAccountInput>) =>
    data<MailAccount>(await apiClient.put(`/api/v2/namespace/mail-accounts/${enc(uuid)}`, input, JSON_HDR)),
  deleteAccount: async (uuid: string) => apiClient.delete(`/api/v2/namespace/mail-accounts/${enc(uuid)}`),
  makeDefault: async (uuid: string) =>
    data<MailAccount>(await apiClient.post(`/api/v2/namespace/mail-accounts/${enc(uuid)}/default`, {}, JSON_HDR)),
  testAccount: async (uuid: string, to: string) =>
    apiClient.post(`/api/v2/namespace/mail-accounts/${enc(uuid)}/test`, { to }, JSON_HDR),
  /** routes: { [purpose]: account uuid, or null for the default account (for "default": the platform server) }. */
  saveRouting: async (routes: Record<string, string | null>) =>
    data<MailRoute[]>(await apiClient.put('/api/v2/namespace/mail-routing', { routes }, JSON_HDR)),
  // Single-server API (acts on the default account).
  getSettings: async () => data<MailSettings>(await apiClient.get('/api/v2/namespace/mail-settings')),
  saveSettings: async (input: MailSettingsInput) =>
    data<MailSettings>(await apiClient.put('/api/v2/namespace/mail-settings', input, JSON_HDR)),
  removeSettings: async () => apiClient.delete('/api/v2/namespace/mail-settings'),
  test: async (to: string) => apiClient.post('/api/v2/namespace/mail-settings/test', { to }, JSON_HDR),
  listTemplates: async () => data<EmailTemplate[]>(await apiClient.get('/api/v2/namespace/email-templates')),
  saveTemplate: async (key: string, subject: string, html: string) =>
    apiClient.put(`/api/v2/namespace/email-templates/${enc(key)}`, { subject, html }, JSON_HDR),
  resetTemplate: async (key: string) => apiClient.delete(`/api/v2/namespace/email-templates/${enc(key)}`),
  preview: async (key: string, draft?: { subject?: string; html?: string }) =>
    data<{ subject: string; html: string }>(
      await apiClient.post(`/api/v2/namespace/email-templates/${enc(key)}/preview`, draft || {}, JSON_HDR)
    ),
};

/**
 * Workspace email: the workspace's own SMTP server and its versions of the
 * built-in email templates (RBAC `namespace`).
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

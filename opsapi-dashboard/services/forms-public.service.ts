/**
 * Public form + invitation API: no dashboard login, no workspace header, and no
 * axios client (its 401 handler would redirect visitors to /login).
 */

import type { FormField } from './forms.service';

const API = (process.env.NEXT_PUBLIC_API_URL || 'http://127.0.0.1:4010').replace(/\/+$/, '');

export class PublicFormError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly code?: string,
    readonly errors?: Record<string, string>,
    readonly title?: string
  ) {
    super(message);
  }
}

async function call<T>(method: string, path: string, body?: unknown, headers: Record<string, string> = {}): Promise<T> {
  const h: Record<string, string> = { Accept: 'application/json', ...headers };
  if (body !== undefined) h['Content-Type'] = 'application/json';
  const res = await fetch(API + path, { method, headers: h, body: body === undefined ? undefined : JSON.stringify(body) });
  const json = (await res.json().catch(() => ({}))) as {
    data?: T; error?: string; code?: string; errors?: Record<string, string>; title?: string; message?: string;
    redirect_url?: string;
  };
  if (!res.ok) {
    throw new PublicFormError(json.error || `Request failed (${res.status})`, res.status, json.code, json.errors, json.title);
  }
  return (json.data ?? json) as T;
}

export interface FormTheme {
  primary_color?: string;
  background?: string;
  logo_url?: string;
  submit_label?: string;
  hide_branding?: boolean;
}

export interface PublicForm {
  title: string;
  description?: string;
  version: number;
  fields: FormField[];
  workspace: { name: string; logo_url?: string };
  render_token: string;
  theme?: FormTheme;
  /** The owner's "I'm not a robot" check (Cloudflare Turnstile). */
  captcha?: { provider: 'turnstile'; site_key: string };
}

export interface UploadedFile {
  id: string;
  name: string;
  size: number;
  type: string;
}

export interface SubmitResult {
  success: boolean;
  message: string;
  redirect_url?: string;
}

export interface PublicInvitation {
  email: string;
  workspace: { name: string; logo_url?: string };
  role?: string;
  invited_by?: string;
  message?: string;
  expires_at: string;
  account_exists: boolean;
}

export const formsPublic = {
  form(publicId: string) {
    return call<PublicForm>('GET', `/api/v2/public/forms/${encodeURIComponent(publicId)}`);
  },
  submit(
    publicId: string,
    payload: {
      answers: Record<string, unknown>; render_token: string; _hp: string; context: Record<string, unknown>;
      captcha_token?: string;
    },
    idempotencyKey: string
  ) {
    return call<SubmitResult>('POST', `/api/v2/public/forms/${encodeURIComponent(publicId)}/submissions`, payload, {
      'Idempotency-Key': idempotencyKey,
    });
  },
  /** Analytics, best effort: never throws, never blocks the visitor. */
  event(publicId: string, type: 'start' | 'step', step?: number) {
    fetch(`${API}/api/v2/public/forms/${encodeURIComponent(publicId)}/events`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ type, step }), keepalive: true,
    }).catch(() => undefined);
  },
  /** One file for a file question; the answer is then the returned id. */
  async upload(publicId: string, field: string, file: File, renderToken: string): Promise<UploadedFile> {
    const body = new FormData();
    body.append('file', file);
    const res = await fetch(`${API}/api/v2/public/forms/${encodeURIComponent(publicId)}/uploads?field=${encodeURIComponent(field)}`, {
      method: 'POST', headers: { 'X-Render-Token': renderToken }, body,
    });
    const json = (await res.json().catch(() => ({}))) as { data?: UploadedFile; error?: string };
    if (!res.ok || !json.data) throw new PublicFormError(json.error || `Upload failed (${res.status})`, res.status);
    return json.data;
  },
  invitation(token: string) {
    return call<PublicInvitation>('GET', `/api/v2/public/invitations/${encodeURIComponent(token)}`);
  },
  acceptInvitation(token: string, body: { first_name: string; last_name: string; password: string }) {
    return call<{ email: string; message: string }>(
      'POST', `/api/v2/public/invitations/${encodeURIComponent(token)}/accept`, body);
  },
};

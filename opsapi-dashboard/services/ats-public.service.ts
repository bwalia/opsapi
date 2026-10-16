/**
 * Candidate interview API: no dashboard login and no axios client (its 401
 * handler would send candidates to /login). lapis/routes/ats-public.lua.
 */

const API = (process.env.NEXT_PUBLIC_API_URL || 'http://127.0.0.1:4010').replace(/\/+$/, '');

export class InterviewError extends Error {
  constructor(message: string, readonly status: number, readonly code?: string) {
    super(message);
  }
}

export interface CandidateTurn { id: string; role: 'interviewer' | 'candidate'; text: string; kind: string }

export interface CandidateView {
  state: 'invited' | 'in_progress' | 'paused' | 'completed' | 'human_requested' | 'abandoned' | 'expired' | 'withdrawn';
  role_title: string;
  /** The invite has an interview pack: it can be taken in the Snazzy Pro app. */
  has_pack?: boolean;
  organisation: string;
  interviewer_name: string;
  minutes: number;
  allow_pause: boolean;
  allowed_adjustments: string[];
  notice: string;
  notice_hash: string;
  next_steps: string;
  turns: CandidateTurn[];
  choices?: string[] | null;
  progress: number;
  seconds_left?: number | null;
  question_count: number;
  self_id?: { id: string; label: string; options: string[] }[] | null;
}

async function call<T>(method: string, path: string, body?: unknown): Promise<T> {
  const res = await fetch(`${API}/api/v2/public/ats/interviews/${path}`, {
    method,
    headers: { Accept: 'application/json', ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const json = (await res.json().catch(() => ({}))) as { data?: T; error?: string; code?: string };
  if (!res.ok) throw new InterviewError(json.error || `Request failed (${res.status})`, res.status, json.code);
  return json.data as T;
}

export const interviewPublic = {
  view: (token: string) => call<CandidateView>('GET', encodeURIComponent(token)),
  start: (token: string, notice_hash: string, adjustments: string[]) =>
    call<CandidateView>('POST', `${encodeURIComponent(token)}/start`, { notice_hash, adjustments }),
  answer: (token: string, text: string, input: 'typed' | 'pasted') =>
    call<CandidateView>('POST', `${encodeURIComponent(token)}/answer`, { text, input }),
  event: (token: string, type: 'repeat' | 'rephrase' | 'pause' | 'resume' | 'person' | 'withdraw' | 'adjustment', text?: string) =>
    call<CandidateView>('POST', `${encodeURIComponent(token)}/event`, { type, text }),
  selfId: (token: string, answers: Record<string, string>) =>
    call<{ saved: boolean }>('POST', `${encodeURIComponent(token)}/self-id`, { answers }),
};

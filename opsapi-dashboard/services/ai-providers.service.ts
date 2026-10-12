/**
 * Workspace AI providers (core: lapis/routes/namespace-ai-providers.lua). Keys go in, never out:
 * responses carry has_secret + secret_hint. Read = namespace.read; add/edit/delete/test = namespace.update.
 * A provider with options.assistant = true drives this workspace's AI assistant (chat-agent.lua).
 */
import apiClient from '@/lib/api-client';

const BASE = '/api/v2/namespace/ai-providers';
const JSON_HDR = { headers: { 'Content-Type': 'application/json' } };

export interface AiProvider {
  uuid: string;
  name: string;
  provider_type: 'platform' | 'anthropic' | 'openai' | 'gemini' | 'azure_openai' | 'mistral' | 'openai_compatible' | 'ollama' | 'jobshout';
  base_url?: string;
  default_model?: string;
  models?: string[];
  has_secret: boolean;
  secret_hint?: string;
  username?: string;
  options?: Record<string, unknown>;
  is_local?: boolean;
  enabled?: boolean;
  input_cost_per_mtok?: number;
  output_cost_per_mtok?: number;
  last_tested_at?: string;
  last_error?: string;
}

/** The provider's options as an object (an empty Lua table arrives as []). */
export function providerOptions(p: Pick<AiProvider, 'options'>): Record<string, unknown> {
  return p.options && !Array.isArray(p.options) ? p.options : {};
}

type Env<T> = { data: T };

export const aiProvidersService = {
  async list() {
    return (await apiClient.get<Env<AiProvider[]>>(BASE)).data.data || [];
  },
  /** Create (no uuid) or update: on update only the fields sent change; `options` is replaced whole. */
  async save(body: Record<string, unknown>, uuid?: string) {
    const res = uuid
      ? await apiClient.put<Env<AiProvider>>(`${BASE}/${uuid}`, body, JSON_HDR)
      : await apiClient.post<Env<AiProvider>>(BASE, body, JSON_HDR);
    return res.data.data;
  },
  async remove(uuid: string) {
    await apiClient.delete(`${BASE}/${uuid}`);
  },
  async test(uuid: string) {
    return (await apiClient.post<Env<Record<string, unknown>>>(`${BASE}/${uuid}/test`, {}, JSON_HDR)).data.data;
  },
  async jobshoutAgents(uuid: string) {
    return (await apiClient.get<Env<{ id: string; name: string }[]>>(`${BASE}/${uuid}/agents`)).data.data;
  },
};

export default aiProvidersService;

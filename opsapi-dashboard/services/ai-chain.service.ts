/**
 * Platform AI fallback chain (platform admins). Backend: lapis/routes/ai-chain-admin.lua.
 *
 * Per AI feature ("scope"), the order in which the platform's models are tried. Keys and endpoints
 * never pass through here: they stay in the environment / Vault (AI_PROVIDER, BEDROCK_*,
 * ANTHROPIC_API_KEY, AI_HOPS …). A model shows up in `catalogue` once it is in the environment;
 * this page only places it in a chain, picks its model, and switches hops on or off.
 */
import apiClient from '@/lib/api-client';

const BASE = '/api/v2/admin/ai-chain';
const JSON_HDR = { headers: { 'Content-Type': 'application/json' } };

/** One entry of a chain as stored: a model name from the catalogue, optionally another model id. */
export interface ChainHop {
  name: string;
  model?: string | null;
  enabled: boolean;
}

/** A model the platform can call, as operators see it (never a key). */
export interface ChainModel {
  name: string;
  provider: string;
  label?: string;
  model?: string;
  host?: string;
  configured: boolean;
  /** Why it isn't configured (e.g. "no API key"). */
  reason?: string;
  tools: boolean;
  enabled: boolean;
  /** Down right now: skipped until its circuit closes. */
  circuit_open: boolean;
  is_main?: boolean;
  position?: number;
}

export interface ChainScope {
  key: string;
  label: string;
  description: string;
  /** Every model here must read images. */
  vision: boolean;
  /** Models that can't call tools are skipped. */
  tools: boolean;
  /** True when a chain is saved for this scope; false = the environment's order. */
  saved: boolean;
  hops: ChainHop[];
  env_hops: ChainHop[];
  /** "saved:<scope>" or "env". */
  source: string;
  /** AI_FALLBACK_CHAIN_BY_FEATURE sets this feature's chain (beats the saved "All AI features" chain). */
  env_feature_chain: boolean;
  /** What a call tries right now, in order (configured, enabled hops only). */
  effective: ChainModel[];
  updated_by?: string;
  updated_at?: string;
}

export interface ChainOverview {
  scopes: ChainScope[];
  catalogue: ChainModel[];
  main: string;
  vision: string;
  breaker_seconds: number;
}

export interface ChainTestResult {
  serving: string | null;
  results: {
    name: string;
    model?: string;
    label?: string;
    position: number;
    ok?: boolean;
    latency_ms?: number;
    reply?: string;
    error?: string;
    status?: number;
    skipped?: string;
  }[];
}

type Env<T> = { data: T };

export const aiChainService = {
  async overview() {
    return (await apiClient.get<Env<ChainOverview>>(`${BASE}/config`)).data.data;
  },
  async save(scope: string, hops: ChainHop[]) {
    return (await apiClient.put<Env<ChainOverview>>(`${BASE}/config/${encodeURIComponent(scope)}`, { hops }, JSON_HDR))
      .data.data;
  },
  /** Forget the saved chain: the scope goes back to the environment's order. */
  async reset(scope: string) {
    return (await apiClient.delete<Env<ChainOverview>>(`${BASE}/config/${encodeURIComponent(scope)}`)).data.data;
  },
  /** Try the hops in order (a tiny prompt each) until one answers. hops omitted = the saved / env order. */
  async test(scope: string, hops?: ChainHop[]) {
    return (await apiClient.post<Env<ChainTestResult>>(`${BASE}/test`, { scope, hops }, { ...JSON_HDR, timeout: 300000 }))
      .data.data;
  },
};

export default aiChainService;

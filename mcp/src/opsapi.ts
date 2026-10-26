/**
 * Thin OpsAPI REST client shared by both transports. One instance = one
 * caller: it carries that caller's personal `opsk_…` key (and optional
 * namespace), so in HTTP mode every request builds its own client.
 */

export interface OpsApiConfig {
  /** OpsAPI base URL, e.g. https://int-opsapi.workstation.co.uk */
  baseUrl: string;
  /** Personal API key (opsk_…); it both authenticates and identifies the user. */
  apiKey: string;
  /** Sent as X-Namespace-Id: the numeric id or the uuid (a slug gets 403). */
  namespace?: string;
  /** Dashboard origin used to turn task paths into full links (optional). */
  dashboardUrl?: string;
  /** Per-call timeout for OpsAPI requests (default 20 s). */
  timeoutMs?: number;
}

export interface HouseResponse<T = unknown> {
  success?: boolean;
  data?: T;
  meta?: Record<string, unknown>;
  error?: string;
}

// OpsAPI routes parse bodies as application/x-www-form-urlencoded first (the
// dashboard sends the same), and nested values (like the jsonb `metadata`) go
// as JSON strings. Sending JSON instead is mis-parsed on PUT, so we mirror the
// dashboard and form-encode every write.
export function encodeForm(body: Record<string, unknown>): string {
  const params = new URLSearchParams();
  for (const [k, v] of Object.entries(body)) {
    if (v === undefined || v === null) continue;
    params.set(k, typeof v === "object" ? JSON.stringify(v) : String(v));
  }
  return params.toString();
}

// kanban_tasks.metadata is JSONB; the API may hand it back as an object or a
// JSON string. Normalise to an object so we can merge without clobbering.
export function parseMetadata(raw: unknown): Record<string, unknown> {
  if (!raw) return {};
  if (typeof raw === "object") return raw as Record<string, unknown>;
  if (typeof raw === "string") {
    try {
      const o = JSON.parse(raw);
      return o && typeof o === "object" ? o : {};
    } catch {
      return {};
    }
  }
  return {};
}

export class OpsApi {
  readonly baseUrl: string;
  readonly dashboardUrl: string;

  constructor(private readonly cfg: OpsApiConfig) {
    this.baseUrl = cfg.baseUrl.replace(/\/+$/, "");
    this.dashboardUrl = (cfg.dashboardUrl || "").replace(/\/+$/, "");
  }

  async request<T = unknown>(
    method: string,
    path: string,
    body?: Record<string, unknown> | FormData
  ): Promise<HouseResponse<T>> {
    const headers: Record<string, string> = {
      Authorization: `Bearer ${this.cfg.apiKey}`,
      Accept: "application/json",
    };
    if (this.cfg.namespace) headers["X-Namespace-Id"] = this.cfg.namespace;
    let payload: string | FormData | undefined;
    if (body instanceof FormData) {
      payload = body; // multipart: fetch sets the Content-Type with its boundary
    } else if (body !== undefined) {
      headers["Content-Type"] = "application/x-www-form-urlencoded";
      payload = encodeForm(body);
    }

    const timeoutMs = this.cfg.timeoutMs ?? 20_000;
    let res: Response;
    try {
      res = await fetch(`${this.baseUrl}${path}`, {
        method,
        headers,
        body: payload,
        signal: AbortSignal.timeout(timeoutMs),
      });
    } catch (e) {
      const why =
        e instanceof Error && e.name === "TimeoutError"
          ? `no answer within ${timeoutMs / 1000}s`
          : e instanceof Error
            ? e.message
            : String(e);
      throw new Error(`OpsAPI unreachable on ${method} ${path}: ${why}`);
    }

    const text = await res.text();
    let json: HouseResponse<T> | string;
    try {
      json = text ? JSON.parse(text) : {};
    } catch {
      json = text;
    }

    if (!res.ok) {
      const detail = typeof json === "string" ? json : json.error || JSON.stringify(json);
      throw new Error(`OpsAPI ${res.status} on ${method} ${path}: ${detail}`);
    }
    return typeof json === "string" ? { data: json as unknown as T } : json;
  }

  /** GET with a query string; undefined/empty values are left out. */
  get<T = unknown>(path: string, query: Record<string, string | number | undefined> = {}) {
    const qs = new URLSearchParams();
    for (const [k, v] of Object.entries(query)) {
      if (v !== undefined && v !== "") qs.set(k, String(v));
    }
    const s = qs.toString();
    return this.request<T>("GET", s ? `${path}?${s}` : path);
  }

  /** A dashboard path → full link when OPSAPI_DASHBOARD_URL is set. */
  link(path: string): string {
    return this.dashboardUrl && path.startsWith("/") ? this.dashboardUrl + path : path;
  }
}

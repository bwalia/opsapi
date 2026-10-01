/** A non-2xx answer from OpsAPI (or a request that never got one: status 0). */
export class OpsApiError extends Error {
  override readonly name = 'OpsApiError';
  /** HTTP status; 0 for network errors and timeouts. */
  readonly status: number;
  /** The parsed JSON body, when there was one. */
  readonly body: unknown;
  /** Validation errors (422): field -> message. */
  readonly details?: Record<string, string>;
  readonly method?: string;
  readonly url?: string;

  constructor(
    message: string,
    init: { status: number; body?: unknown; method?: string; url?: string; cause?: unknown },
  ) {
    super(message, init.cause !== undefined ? { cause: init.cause } : undefined);
    this.status = init.status;
    this.body = init.body;
    this.method = init.method;
    this.url = init.url;
    const details = (init.body as { details?: unknown } | undefined)?.details;
    if (details && typeof details === 'object' && !Array.isArray(details)) {
      this.details = details as Record<string, string>;
    }
  }

  /** 401: no or invalid credentials. */
  get isUnauthorized() {
    return this.status === 401;
  }
  /** 403: signed in, but the role lacks the permission (or not a member). */
  get isForbidden() {
    return this.status === 403;
  }
  /** 404: missing, or not in this workspace. */
  get isNotFound() {
    return this.status === 404;
  }
  /** 422: validation failed; see `details`. */
  get isValidation() {
    return this.status === 422;
  }
}

/** The human message in an OpsAPI error body ({ error }, { error: { message } } or { message }). */
export function messageOf(body: unknown): string | undefined {
  if (!body || typeof body !== 'object') return undefined;
  const b = body as { error?: unknown; message?: unknown };
  if (typeof b.error === 'string') return b.error;
  if (b.error && typeof b.error === 'object') {
    const m = (b.error as { message?: unknown }).message;
    if (typeof m === 'string') return m;
  }
  return typeof b.message === 'string' ? b.message : undefined;
}

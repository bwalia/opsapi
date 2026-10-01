/**
 * Verify and parse OpsAPI workspace webhooks (WEBHOOKS.md in the opsapi repo).
 * Uses Web Crypto, so it runs in Node 20+, browsers, Deno, Bun and edge runtimes.
 */

export interface WebhookEvent<TObject = Record<string, unknown>> {
  /** Event id: the same on every retry — use it to ignore duplicates. */
  id: string;
  /** e.g. "invoice.paid", "crm.deal.won", "helpdesk.ticket.created" */
  type: string;
  created_at: string;
  namespace: { id: string; slug?: string };
  data: {
    /** The record after the change (before it, for *.deleted). */
    object: TObject;
    /** On updates (and business events caused by one): field -> { from, to }. */
    changes?: Record<string, { from: unknown; to: unknown }>;
  };
}

export class WebhookVerificationError extends Error {
  override readonly name = 'WebhookVerificationError';
}

export interface VerifyWebhookOptions {
  /** The webhook's signing secret (shown once when it was created or rotated). */
  secret: string;
  /** Reject deliveries older than this (replay protection). Default 300 seconds. */
  toleranceSeconds?: number;
  /** Current time in seconds (tests). */
  now?: () => number;
}

type HeaderSource = Headers | Record<string, string | string[] | undefined>;

function header(headers: HeaderSource, name: string): string | undefined {
  if (typeof (headers as Headers).get === 'function') return (headers as Headers).get(name) ?? undefined;
  const wanted = name.toLowerCase();
  for (const [k, v] of Object.entries(headers as Record<string, string | string[] | undefined>)) {
    if (k.toLowerCase() === wanted) return Array.isArray(v) ? v[0] : v;
  }
  return undefined;
}

const encoder = new TextEncoder();

function toHex(buf: ArrayBuffer): string {
  return Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, '0')).join('');
}

function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** The `sha256=<hex>` signature OpsAPI puts in X-Opsapi-Signature-256. */
export async function signWebhook(secret: string, timestamp: string, rawBody: string | Uint8Array): Promise<string> {
  const key = await crypto.subtle.importKey('raw', encoder.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, [
    'sign',
  ]);
  const body = typeof rawBody === 'string' ? encoder.encode(rawBody) : rawBody;
  const prefix = encoder.encode(`${timestamp}.`);
  const message = new Uint8Array(prefix.length + body.length);
  message.set(prefix);
  message.set(body, prefix.length);
  return `sha256=${toHex(await crypto.subtle.sign('HMAC', key, message))}`;
}

/**
 * Check a delivery's signature and age, then parse it. Pass the RAW request
 * body (before any JSON parsing) and the request headers. Throws
 * WebhookVerificationError when the delivery isn't genuine or is too old.
 *
 *   // Next.js route handler
 *   const event = await verifyWebhook(await req.text(), req.headers, { secret: process.env.OPSAPI_WEBHOOK_SECRET! });
 */
export async function verifyWebhook<TObject = Record<string, unknown>>(
  rawBody: string | Uint8Array,
  headers: HeaderSource,
  options: VerifyWebhookOptions,
): Promise<WebhookEvent<TObject>> {
  if (!options.secret) throw new WebhookVerificationError('No webhook secret configured');
  const timestamp = header(headers, 'x-opsapi-timestamp');
  const given = header(headers, 'x-opsapi-signature-256');
  if (!timestamp || !/^\d+$/.test(timestamp) || !given) {
    throw new WebhookVerificationError('Missing X-Opsapi-Timestamp or X-Opsapi-Signature-256 header');
  }
  const expected = await signWebhook(options.secret, timestamp, rawBody);
  if (!safeEqual(given, expected)) throw new WebhookVerificationError('Signature does not match');
  const now = options.now ? options.now() : Date.now() / 1000;
  if (Math.abs(now - Number(timestamp)) > (options.toleranceSeconds ?? 300)) {
    throw new WebhookVerificationError('Delivery is too old (or the clocks disagree)');
  }
  const text = typeof rawBody === 'string' ? rawBody : new TextDecoder().decode(rawBody);
  try {
    return JSON.parse(text) as WebhookEvent<TObject>;
  } catch {
    throw new WebhookVerificationError('Body is not JSON');
  }
}

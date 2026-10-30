// Verify an OpsAPI webhook in Node (no dependencies beyond `crypto`).
//
// Two signing schemes exist (see ../reference.md):
//   CMS "Website update" webhooks:  HMAC_SHA256(secret, rawBody)
//   Workspace event webhooks:       HMAC_SHA256(secret, X-Opsapi-Timestamp + "." + rawBody)
// verifyOpsapiWebhook picks the scheme by whether X-Opsapi-Timestamp is present.
//
// ALWAYS pass the raw request body (string or Buffer), never re-serialised JSON.

const crypto = require('crypto');

const MAX_AGE_MS = 5 * 60 * 1000;

function safeEqual(a, b) {
  const ab = Buffer.from(a), bb = Buffer.from(b);
  return ab.length === bb.length && crypto.timingSafeEqual(ab, bb);
}

/**
 * @param {string|Buffer} rawBody
 * @param {(name: string) => string|undefined|null} getHeader  case-insensitive header lookup
 * @param {string} secret
 * @returns {{ ok: true, payload: object } | { ok: false, reason: string }}
 */
function verifyOpsapiWebhook(rawBody, getHeader, secret) {
  if (!secret) return { ok: false, reason: 'no secret configured' };
  const raw = Buffer.isBuffer(rawBody) ? rawBody.toString('utf8') : String(rawBody);
  const given = getHeader('x-opsapi-signature-256') || '';
  const ts = getHeader('x-opsapi-timestamp');

  const signed = ts ? `${ts}.${raw}` : raw;
  const expected = 'sha256=' + crypto.createHmac('sha256', secret).update(signed).digest('hex');
  if (!safeEqual(given, expected)) return { ok: false, reason: 'bad signature' };

  let payload;
  try { payload = JSON.parse(raw); } catch { return { ok: false, reason: 'invalid JSON' }; }

  // Replay window: header timestamp (event webhooks) or body timestamp (CMS webhooks).
  const when = ts ? (/^\d+$/.test(ts) ? Number(ts) * 1000 : Date.parse(ts))
                  : Date.parse(payload.timestamp);
  if (!Number.isFinite(when) || Math.abs(Date.now() - when) > MAX_AGE_MS) {
    return { ok: false, reason: 'stale or missing timestamp' };
  }
  return { ok: true, payload };
}

module.exports = { verifyOpsapiWebhook };

// ---------------------------------------------------------------------------
// Express — mount with a RAW body parser on this route only:
//
//   const express = require('express');
//   const { verifyOpsapiWebhook } = require('./verify_webhook');
//   const app = express();
//   app.post('/api/opsapi-update', express.raw({ type: 'application/json' }), (req, res) => {
//     const v = verifyOpsapiWebhook(req.body, (h) => req.get(h), process.env.OPSAPI_WEBHOOK_SECRET);
//     if (!v.ok) return res.status(401).send(v.reason);
//     // v.payload.event / v.payload.data.slug → rebuild or purge cache here
//     res.json({ ok: true });
//   });
//
// ---------------------------------------------------------------------------
// Next.js App Router — app/api/opsapi-update/route.js:
//
//   import { revalidatePath } from 'next/cache';
//   import { verifyOpsapiWebhook } from '@/lib/verify_webhook';
//   export const runtime = 'nodejs'; // needs node:crypto
//   export async function POST(req) {
//     const raw = await req.text();
//     const v = verifyOpsapiWebhook(raw, (h) => req.headers.get(h), process.env.OPSAPI_WEBHOOK_SECRET);
//     if (!v.ok) return new Response(v.reason, { status: 401 });
//     revalidatePath('/blog');
//     const slug = v.payload?.data?.slug;
//     if (slug) revalidatePath(`/blog/${slug}`);
//     return Response.json({ ok: true });
//   }

// ---------------------------------------------------------------------------
// Self-test: `node verify_webhook.js`
if (require.main === module) {
  const assert = require('assert');
  const secret = 'test-secret';
  const body = JSON.stringify({ event: 'post.updated', namespace_id: 1, data: { slug: 'hi' },
    timestamp: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z') });

  const cmsSig = 'sha256=' + crypto.createHmac('sha256', secret).update(body).digest('hex');
  const cmsHeaders = { 'x-opsapi-signature-256': cmsSig };
  assert.ok(verifyOpsapiWebhook(body, (h) => cmsHeaders[h], secret).ok, 'CMS scheme');
  assert.ok(!verifyOpsapiWebhook(body + ' ', (h) => cmsHeaders[h], secret).ok, 'tampered body');

  const ts = String(Math.floor(Date.now() / 1000));
  const evSig = 'sha256=' + crypto.createHmac('sha256', secret).update(`${ts}.${body}`).digest('hex');
  const evHeaders = { 'x-opsapi-signature-256': evSig, 'x-opsapi-timestamp': ts };
  assert.ok(verifyOpsapiWebhook(body, (h) => evHeaders[h], secret).ok, 'event scheme');
  assert.ok(!verifyOpsapiWebhook(body, (h) => evHeaders[h], 'wrong').ok, 'wrong secret');
  console.log('ok');
}

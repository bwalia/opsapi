// Verify an OpsAPI webhook (Node, no dependencies). Copy `verify()` into your receiver.
//
// The signature is the whole security of a webhook receiver: a valid one is the only proof the request came from
// OpsAPI. Check it over the RAW body (before JSON.parse) and reject stale timestamps (replay).
//
// Self-test:  node verify_webhook.js
const crypto = require('crypto');

/**
 * Returns the parsed payload if the request is genuine, else throws.
 * @param {Buffer|string} rawBody  the body EXACTLY as received, before JSON.parse
 * @param {string} signatureHeader the X-Opsapi-Signature-256 header ("sha256=...")
 * @param {string} secret          the webhook secret (from an env var, e.g. OPSAPI_WEBHOOK_SECRET)
 * @param {number} maxAgeSeconds   reject a timestamp older than this (default 300)
 */
function verify(rawBody, signatureHeader, secret, maxAgeSeconds = 300) {
  const raw = Buffer.isBuffer(rawBody) ? rawBody : Buffer.from(rawBody);
  const expected = 'sha256=' + crypto.createHmac('sha256', secret).update(raw).digest('hex');
  const given = signatureHeader || '';
  if (given.length !== expected.length ||
      !crypto.timingSafeEqual(Buffer.from(given), Buffer.from(expected))) {
    throw new Error('bad signature');
  }
  const payload = JSON.parse(raw.toString('utf8'));
  if (Math.abs(Date.now() - Date.parse(payload.timestamp)) > maxAgeSeconds * 1000) {
    throw new Error('timestamp too old (possible replay)');
  }
  return payload;
}

module.exports = { verify };

// ---- Express example (delete if you don't use Express) -------------------------------------------------------
// app.post('/opsapi-update', express.raw({ type: 'application/json' }), (req, res) => {
//   try {
//     const payload = verify(req.body, req.get('X-Opsapi-Signature-256'), process.env.OPSAPI_WEBHOOK_SECRET);
//     // rebuild / revalidate the pages for payload.data.slug
//     res.json({ ok: true });
//   } catch (e) { res.status(401).send(e.message); }
// });

// ---- Next.js App Router example ------------------------------------------------------------------------------
// export async function POST(req) {
//   const raw = await req.text();
//   try {
//     const payload = verify(raw, req.headers.get('x-opsapi-signature-256'), process.env.OPSAPI_WEBHOOK_SECRET);
//     // revalidatePath('/blog'); if (payload.data?.slug) revalidatePath('/blog/' + payload.data.slug);
//     return Response.json({ ok: true });
//   } catch (e) { return new Response(e.message, { status: 401 }); }
// }

if (require.main === module) {
  const secret = 'test-secret';
  const body = JSON.stringify({
    event: 'post.published', namespace_id: 12, data: { slug: 'hello' }, timestamp: new Date().toISOString(),
  });
  const sign = (b, s = secret) => 'sha256=' + crypto.createHmac('sha256', s).update(b).digest('hex');

  if (verify(body, sign(body), secret).data.slug !== 'hello') throw new Error('genuine request must pass');

  const rejected = (fn) => { try { fn(); return false; } catch { return true; } };
  const stale = JSON.stringify({ timestamp: '2000-01-01T00:00:00Z', data: {} });
  const cases = {
    'wrong secret': () => verify(body, sign(body), 'other-secret'),
    'tampered body': () => verify(body + ' ', sign(body), secret),
    'no signature': () => verify(body, '', secret),
    'stale timestamp': () => verify(stale, sign(stale), secret),
  };
  for (const [name, fn] of Object.entries(cases)) {
    if (!rejected(fn)) throw new Error(`FAIL: ${name} should have been rejected`);
  }
  console.log('ok: genuine request accepted; wrong secret, tampered body, missing signature and replay all rejected');
}

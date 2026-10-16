'use client';

/**
 * Plain-language help for Content → Website updates (webhooks): how it works, the setup screen shown after a
 * webhook is added (its secret key, where that goes, a test), a message to hand a developer, and what a failed
 * delivery means. Delivery is manual (lib/webhook-dispatcher.lua): OpsAPI POSTs {event, namespace_id, data, timestamp}
 * with X-Opsapi-Signature-256 = "sha256=" + HMAC-SHA256(secret, raw body).
 */
import React, { useState } from 'react';
import toast from 'react-hot-toast';
import { Check, Copy, Eye, EyeOff, Globe, KeyRound, Link2, Loader2, Send, Code2, CircleCheck, CircleAlert } from 'lucide-react';
import { Button, Modal } from '@/components/ui';
import { cmsService, type CmsWebhook } from '@/services/cms.service';

export const SECRET_ENV = 'OPSAPI_WEBHOOK_SECRET';

/** What a delivery result means, for someone who isn't a developer. */
export function explainDelivery(status?: number | null, error?: string | null): { ok: boolean; text: string } {
  if (status && status >= 200 && status < 300) return { ok: true, text: 'Your website received the update.' };
  if (status === 401 || status === 403) {
    return { ok: false, text: `Your website refused it (HTTP ${status}). The secret key saved on your website doesn't match this one: copy it again from the setup guide.` };
  }
  if (status === 404) return { ok: false, text: 'Nothing was found at that address (HTTP 404). Check the website address with your developer.' };
  if (status === 405) return { ok: false, text: "That address doesn't accept updates (HTTP 405). Check the address with your developer." };
  if (status && status >= 500) return { ok: false, text: `Your website had an error while updating (HTTP ${status}). Try again; if it keeps happening, tell your developer.` };
  if (status && status >= 400) return { ok: false, text: `Your website refused it (HTTP ${status}). Ask your developer to check its logs.` };
  if (error && /public|private|internal|not allowed/i.test(error)) {
    return { ok: false, text: "That address can't be used: it must be a public website address (https://…)." };
  }
  return { ok: false, text: "Couldn't reach your website. Check the address and that the site is online." };
}

async function copyText(text: string, what: string) {
  try {
    await navigator.clipboard.writeText(text);
    toast.success(`${what} copied`);
  } catch {
    toast.error('Could not copy: select the text and copy it manually');
  }
}

const STEPS = [
  { icon: Link2, title: 'Get your website’s update address', text: 'Your developer gives you one, or your host does: Vercel, Netlify and Cloudflare Pages call it a “Deploy Hook”.' },
  { icon: Globe, title: 'Add it here', text: 'Press “Add website”. OpsAPI creates a secret key for it.' },
  { icon: KeyRound, title: 'Put the secret key on your website', text: `Your developer saves it where the website runs, as ${SECRET_ENV}. It proves the update really came from you. A host’s Deploy Hook doesn’t need it.` },
  { icon: Send, title: 'Publish, then update', text: 'After you publish a post, OpsAPI asks whether to update your website now. Nothing is sent by itself, so you can finish several edits first.' },
];

/** The four steps. Open by default until the first website is added. */
export function HowItWorks({ defaultOpen }: { defaultOpen: boolean }) {
  return (
    <details open={defaultOpen} className="group rounded-xl border border-primary-100 bg-primary-50/40 p-4">
      <summary className="cursor-pointer select-none list-none text-sm font-semibold text-secondary-900">
        <span className="inline-flex items-center gap-2">
          <Globe className="h-4 w-4 text-primary-600" aria-hidden />
          How website updates work
          <span className="text-xs font-normal text-primary-700 group-open:hidden">Show</span>
          <span className="hidden text-xs font-normal text-primary-700 group-open:inline">Hide</span>
        </span>
      </summary>
      <p className="mt-2 text-sm text-secondary-600">
        Your website keeps its own copy of your posts and pages. When you change them here, your website has to be told
        so it can refresh. A webhook is that message: OpsAPI sends it to your website’s update address when you ask.
      </p>
      <ol className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {STEPS.map((s, i) => (
          <li key={s.title} className="rounded-lg bg-white p-3 shadow-sm ring-1 ring-secondary-100">
            <div className="flex items-center gap-2">
              <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-primary-600 text-xs font-semibold text-white">{i + 1}</span>
              <s.icon className="h-4 w-4 text-primary-600" aria-hidden />
            </div>
            <p className="mt-2 text-sm font-medium text-secondary-900">{s.title}</p>
            <p className="mt-1 text-xs leading-relaxed text-secondary-600">{s.text}</p>
          </li>
        ))}
      </ol>
    </details>
  );
}

const SAMPLE_BODY = `{
  "event": "post.published",
  "namespace_id": 12,
  "data": { "uuid": "…", "slug": "my-first-post", "status": "published" },
  "timestamp": "2026-10-16T09:30:00Z"
}`;

const CODE: Record<'next' | 'node' | 'python', { label: string; code: string }> = {
  next: {
    label: 'Next.js',
    code: `// app/api/opsapi-update/route.ts
import crypto from 'crypto';
import { revalidatePath } from 'next/cache';

export async function POST(req: Request) {
  const body = await req.text(); // the raw body, before JSON.parse
  const expected = 'sha256=' + crypto
    .createHmac('sha256', process.env.${SECRET_ENV}!)
    .update(body)
    .digest('hex');
  const given = req.headers.get('x-opsapi-signature-256') ?? '';
  if (given.length !== expected.length ||
      !crypto.timingSafeEqual(Buffer.from(given), Buffer.from(expected))) {
    return new Response('Invalid signature', { status: 401 });
  }
  const { data, timestamp } = JSON.parse(body);
  if (Math.abs(Date.now() - Date.parse(timestamp)) > 5 * 60 * 1000) {
    return new Response('Too old', { status: 401 }); // a replayed request
  }
  revalidatePath('/blog');
  if (data?.slug) revalidatePath('/blog/' + data.slug);
  return Response.json({ ok: true });
}`,
  },
  node: {
    label: 'Node.js (Express)',
    code: `const crypto = require('crypto');

app.post('/opsapi-update', express.raw({ type: 'application/json' }), (req, res) => {
  const expected = 'sha256=' + crypto
    .createHmac('sha256', process.env.${SECRET_ENV})
    .update(req.body) // the raw body
    .digest('hex');
  const given = req.get('X-Opsapi-Signature-256') || '';
  if (given.length !== expected.length ||
      !crypto.timingSafeEqual(Buffer.from(given), Buffer.from(expected))) {
    return res.status(401).send('Invalid signature');
  }
  const { data, timestamp } = JSON.parse(req.body);
  if (Math.abs(Date.now() - Date.parse(timestamp)) > 5 * 60 * 1000) return res.status(401).send('Too old');
  // rebuild or refresh the pages for data.slug here
  res.json({ ok: true });
});`,
  },
  python: {
    label: 'Python (Flask)',
    code: `import hmac, hashlib, os, json
from datetime import datetime, timezone

@app.post("/opsapi-update")
def opsapi_update():
    body = request.get_data()  # the raw body
    expected = "sha256=" + hmac.new(os.environ["${SECRET_ENV}"].encode(), body, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, request.headers.get("X-Opsapi-Signature-256", "")):
        return "Invalid signature", 401
    payload = json.loads(body)
    sent = datetime.fromisoformat(payload["timestamp"].replace("Z", "+00:00"))
    if abs((datetime.now(timezone.utc) - sent).total_seconds()) > 300:
        return "Too old", 401
    # rebuild or refresh the pages for payload["data"]["slug"] here
    return {"ok": True}`,
  },
};

/** A message to send a developer: everything but the secret key, which should travel separately. */
function developerMessage(w: CmsWebhook) {
  return `Hi, please connect our website to OpsAPI so it refreshes when we publish content.

1. When we press "Update website", OpsAPI sends a POST request to:
   ${w.url}
2. The body is JSON, for example:
${SAMPLE_BODY}
3. Each request has the header X-Opsapi-Signature-256: "sha256=" followed by the HMAC-SHA256 (hex) of the raw request body, made with a secret key. I'll send you the key separately. Please save it as the environment variable ${SECRET_ENV} where the website runs.
4. Please reject a request whose signature doesn't match (answer 401), and one whose "timestamp" is more than 5 minutes old.
5. Then refresh the content (rebuild, or revalidate the blog pages; "data.slug" is the post that changed) and answer with any 2xx status.

Code samples for Next.js, Express and Flask are in OpsAPI under Content → Website updates → Setup guide.`;
}

/** Shown right after a website is added, and from its card's "Setup guide". */
export function WebhookSetupModal({ webhook, justCreated, onClose, onTested }: {
  webhook: CmsWebhook | null;
  justCreated?: boolean;
  onClose: () => void;
  onTested?: () => void;
}) {
  const [shown, setShown] = useState(false);
  const [testing, setTesting] = useState(false);
  const [result, setResult] = useState<{ ok: boolean; text: string } | null>(null);
  const [lang, setLang] = useState<keyof typeof CODE>('next');

  const close = () => {
    setShown(false);
    setResult(null);
    onClose();
  };

  const test = async () => {
    if (!webhook) return;
    setTesting(true);
    setResult(null);
    try {
      const res = await cmsService.triggerWebhook(webhook.uuid, { event: 'manual.trigger' });
      setResult(res.success ? explainDelivery(res.status ?? 200) : explainDelivery(res.status, res.error));
      onTested?.();
    } catch {
      setResult({ ok: false, text: 'The test could not be sent. Try again in a moment.' });
    } finally {
      setTesting(false);
    }
  };

  if (!webhook) return null;
  const secret = webhook.secret || '';
  return (
    <Modal
      isOpen={!!webhook}
      onClose={close}
      title={justCreated ? `${webhook.name || 'Website'} added: two steps left` : `Set up ${webhook.name || 'this website'}`}
      description="Follow these once. After that, you update your website from here or when you publish a post."
      size="2xl"
      footer={<div className="flex justify-end"><Button onClick={close}>Done</Button></div>}
    >
      <div className="space-y-5">
        <section aria-labelledby="step-key" className="rounded-xl border border-secondary-200 p-4">
          <h3 id="step-key" className="flex items-center gap-2 text-sm font-semibold text-secondary-900">
            <span className="flex h-6 w-6 items-center justify-center rounded-full bg-primary-600 text-xs text-white">1</span>
            Give your website its secret key
          </h3>
          <p className="mt-2 text-sm text-secondary-600">
            This key lets your website check that an update really came from you, so nobody else can make it refresh.
            Treat it like a password: send it to your developer on its own (not in the same message as the address),
            and they save it on the website as <code className="rounded bg-secondary-100 px-1 text-xs">{SECRET_ENV}</code>.
          </p>
          <div className="mt-3 flex items-center gap-2">
            <code className="min-w-0 flex-1 truncate rounded-lg bg-secondary-100 px-3 py-2.5 font-mono text-sm text-secondary-900" aria-label="Secret key">
              {shown ? secret : '•'.repeat(Math.min(secret.length, 32))}
            </code>
            <Button variant="outline" onClick={() => setShown((s) => !s)} aria-label={shown ? 'Hide secret key' : 'Show secret key'}
              leftIcon={shown ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}>
              {shown ? 'Hide' : 'Show'}
            </Button>
            <Button variant="outline" onClick={() => copyText(secret, 'Secret key')} leftIcon={<Copy className="h-4 w-4" />}>
              Copy key
            </Button>
          </div>
          <div className="mt-3 flex flex-wrap items-center gap-2">
            <Button variant="secondary" size="sm" onClick={() => copyText(developerMessage(webhook), 'Message for your developer')}
              leftIcon={<Copy className="h-4 w-4" />}>
              Copy a message for your developer
            </Button>
            <span className="text-xs text-secondary-500">Everything they need except the key.</span>
          </div>
          <p className="mt-3 rounded-lg bg-secondary-50 p-3 text-xs text-secondary-600">
            <strong className="text-secondary-800">Using a Deploy Hook from Vercel, Netlify or Cloudflare Pages?</strong>{' '}
            Skip this step: those addresses are secret themselves and ignore the key. Go straight to the test.
          </p>
        </section>

        <section aria-labelledby="step-test" className="rounded-xl border border-secondary-200 p-4">
          <h3 id="step-test" className="flex items-center gap-2 text-sm font-semibold text-secondary-900">
            <span className="flex h-6 w-6 items-center justify-center rounded-full bg-primary-600 text-xs text-white">2</span>
            Send a test
          </h3>
          <p className="mt-2 text-sm text-secondary-600">
            Once the key is saved on your website, send a test update to check everything is connected.
          </p>
          <div className="mt-3 flex flex-wrap items-center gap-3">
            <Button onClick={test} disabled={testing} leftIcon={testing ? <Loader2 className="h-4 w-4 animate-spin" /> : <Send className="h-4 w-4" />}>
              {testing ? 'Sending…' : 'Send a test update'}
            </Button>
            {result && (
              <p role="status" className={`flex items-start gap-1.5 text-sm ${result.ok ? 'text-success-600' : 'text-error-600'}`}>
                {result.ok ? <CircleCheck className="mt-0.5 h-4 w-4 shrink-0" aria-hidden /> : <CircleAlert className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />}
                {result.text}
              </p>
            )}
          </div>
        </section>

        <details className="rounded-xl border border-secondary-200 p-4">
          <summary className="flex cursor-pointer select-none items-center gap-2 text-sm font-semibold text-secondary-900">
            <Code2 className="h-4 w-4 text-secondary-500" aria-hidden /> For developers: what OpsAPI sends and how to check it
          </summary>
          <div className="mt-3 space-y-3 text-sm text-secondary-600">
            <p>
              {'A '}<code className="text-xs">POST</code>{' to '}<code className="break-all text-xs">{webhook.url}</code>
              {' with '}<code className="text-xs">Content-Type: application/json</code>{', '}
              <code className="text-xs">X-Opsapi-Event</code>{' and '}<code className="text-xs">X-Opsapi-Signature-256</code>
              {': "sha256=" + the HMAC-SHA256 (hex) of the raw body with the secret key. Reject a mismatch with 401, and a '}
              <code className="text-xs">timestamp</code>{' older than 5 minutes. Answer 2xx when done.'}
            </p>
            <pre className="overflow-x-auto rounded-lg bg-secondary-900 p-3 text-xs leading-relaxed text-secondary-100">{SAMPLE_BODY}</pre>
            <div className="flex gap-1" role="tablist" aria-label="Code sample">
              {(Object.keys(CODE) as (keyof typeof CODE)[]).map((k) => (
                <button key={k} type="button" role="tab" aria-selected={lang === k} onClick={() => setLang(k)}
                  className={`rounded-md px-3 py-1 text-xs font-medium ${lang === k ? 'bg-primary-50 text-primary-700' : 'text-secondary-500 hover:bg-secondary-100'}`}>
                  {CODE[k].label}
                </button>
              ))}
            </div>
            <div className="relative">
              <pre className="overflow-x-auto rounded-lg bg-secondary-900 p-3 text-xs leading-relaxed text-secondary-100">{CODE[lang].code}</pre>
              <button type="button" onClick={() => copyText(CODE[lang].code, 'Code')} aria-label="Copy code"
                className="absolute right-2 top-2 rounded-md bg-secondary-700 p-1.5 text-secondary-100 hover:bg-secondary-600">
                <Copy className="h-3.5 w-3.5" />
              </button>
            </div>
          </div>
        </details>
      </div>
    </Modal>
  );
}

/** The card's one-line delivery status. */
export function DeliveryStatus({ webhook }: { webhook: CmsWebhook }) {
  if (!webhook.last_triggered_at) return <span className="text-secondary-500">Not sent yet: send a test from the setup guide</span>;
  const r = explainDelivery(webhook.last_status, null);
  const when = new Date(webhook.last_triggered_at).toLocaleString();
  return r.ok ? (
    <span className="inline-flex items-center gap-1 text-success-600"><Check className="h-3.5 w-3.5" aria-hidden /> Last update worked · {when}</span>
  ) : (
    <span className="text-error-600" title={r.text}>
      <span className="inline-flex items-center gap-1"><CircleAlert className="h-3.5 w-3.5" aria-hidden /> Last update failed · {when}</span>
      <span className="mt-0.5 block text-secondary-600">{r.text}</span>
    </span>
  );
}

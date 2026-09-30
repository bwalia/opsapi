'use client';

/**
 * Shows a webhook's signing secret once (after create / rotate) with how to
 * verify requests. The secret can't be retrieved again, only rotated.
 */

import React, { useState } from 'react';
import toast from 'react-hot-toast';
import { Check, Copy, ShieldCheck } from 'lucide-react';
import { Modal, Button } from '@/components/ui';

const NODE = `const crypto = require('crypto');

// rawBody: the request body exactly as received (before JSON.parse)
const ts = req.headers['x-opsapi-timestamp'];
const expected = 'sha256=' + crypto
  .createHmac('sha256', process.env.OPSAPI_WEBHOOK_SECRET)
  .update(ts + '.' + rawBody)
  .digest('hex');
const given = req.headers['x-opsapi-signature-256'] || '';
const valid = given.length === expected.length &&
  crypto.timingSafeEqual(Buffer.from(given), Buffer.from(expected)) &&
  Math.abs(Date.now() / 1000 - Number(ts)) < 300;   // reject replays`;

const PYTHON = `import hmac, hashlib, os, time

ts = request.headers["X-Opsapi-Timestamp"]
expected = "sha256=" + hmac.new(
    os.environ["OPSAPI_WEBHOOK_SECRET"].encode(),
    (ts + "." + raw_body).encode(),
    hashlib.sha256,
).hexdigest()
valid = hmac.compare_digest(expected, request.headers.get("X-Opsapi-Signature-256", "")) \\
    and abs(time.time() - int(ts)) < 300`;

export default function WebhookSecretModal({
  secret,
  onClose,
}: {
  /** null = closed */
  secret: string | null;
  onClose: () => void;
}) {
  const [copied, setCopied] = useState(false);
  const [lang, setLang] = useState<'node' | 'python'>('node');

  const copy = async () => {
    if (!secret) return;
    try {
      await navigator.clipboard.writeText(secret);
      setCopied(true);
      toast.success('Secret copied');
    } catch {
      toast.error('Could not copy — select the secret and copy it manually');
    }
  };

  return (
    <Modal
      isOpen={!!secret}
      onClose={() => {
        setCopied(false);
        onClose();
      }}
      title="Signing secret"
      description="Copy it now: for security it is shown only once. Rotate it any time to get a new one."
      size="xl"
    >
      <div className="space-y-5">
        <div className="flex items-center gap-2">
          <code className="flex-1 min-w-0 truncate rounded-lg bg-secondary-100 px-3 py-2.5 font-mono text-sm text-secondary-900 select-all">
            {secret}
          </code>
          <Button
            variant="outline"
            onClick={copy}
            leftIcon={copied ? <Check className="w-4 h-4" /> : <Copy className="w-4 h-4" />}
          >
            {copied ? 'Copied' : 'Copy'}
          </Button>
        </div>

        <div className="rounded-lg border border-secondary-200 p-4 space-y-3">
          <p className="flex items-center gap-2 text-sm font-medium text-secondary-900">
            <ShieldCheck className="w-4 h-4 text-success-600" /> Verify every request
          </p>
          {/* Explicit strings: the JSX build drops the space after an inline <code>
              when a text run spans lines ("bodywith"). */}
          <p className="text-sm text-secondary-600">
            {'Each request carries '}
            <code className="text-xs">X-Opsapi-Timestamp</code>
            {' and '}
            <code className="text-xs">X-Opsapi-Signature-256</code>
            {': an HMAC-SHA256 of '}
            <code className="text-xs">timestamp + &quot;.&quot; + body</code>
            {" with this secret. Reject requests whose signature doesn't match or whose timestamp is older than " +
              "5 minutes. Deliveries can repeat: use the payload's "}
            <code className="text-xs">id</code>
            {" to skip ones you've already processed."}
          </p>
          <div className="flex gap-1" role="tablist" aria-label="Code sample language">
            {(['node', 'python'] as const).map((l) => (
              <button
                key={l}
                type="button"
                role="tab"
                aria-selected={lang === l}
                onClick={() => setLang(l)}
                className={`px-3 py-1 rounded-md text-xs font-medium ${
                  lang === l ? 'bg-primary-50 text-primary-700' : 'text-secondary-500 hover:bg-secondary-100'
                }`}
              >
                {l === 'node' ? 'Node.js' : 'Python'}
              </button>
            ))}
          </div>
          <pre className="overflow-x-auto rounded-lg bg-secondary-900 p-3 text-xs leading-relaxed text-secondary-100">
            {lang === 'node' ? NODE : PYTHON}
          </pre>
        </div>

        <div className="flex justify-end">
          <Button onClick={onClose}>Done</Button>
        </div>
      </div>
    </Modal>
  );
}

'use client';

import React, { useEffect, useState } from 'react';
import { Loader2 } from 'lucide-react';
import { marketingService } from '@/services/opsapi-marketing.service';
import { CodeBlock } from './CodeBlock';
import { apiErrorMessage, unwrap, type Pixel, type PixelSnippet } from './shared';

export function InstallTab({ pixel }: { pixel: Pixel }) {
  // Result is tagged with the key it was fetched for; a mismatch means a fetch is pending.
  const reqKey = `${pixel.uuid}:${pixel.public_key}`;
  const [result, setResult] = useState<{ key: string; snippet: PixelSnippet | null; error: string | null } | null>(
    null,
  );

  useEffect(() => {
    let cancelled = false;
    marketingService
      .pixelSnippet(pixel.uuid)
      .then((res) => {
        if (!cancelled) setResult({ key: reqKey, snippet: unwrap<PixelSnippet>(res), error: null });
      })
      .catch((e: unknown) => {
        if (!cancelled) {
          setResult({ key: reqKey, snippet: null, error: apiErrorMessage(e, 'Failed to load install snippet') });
        }
      });
    return () => {
      cancelled = true;
    };
    // reqKey includes public_key: re-fetch after a key rotation since the snippet embeds it.
  }, [pixel.uuid, reqKey]);

  const loading = result?.key !== reqKey;
  const snippet = result?.snippet ?? null;
  const error = result?.error ?? null;

  if (loading) {
    return (
      <p className="flex items-center gap-2 text-sm text-secondary-500" role="status">
        <Loader2 className="h-4 w-4 animate-spin" /> Loading snippet…
      </p>
    );
  }
  if (error || !snippet) {
    return <p className="text-sm text-error-600">{error || 'Snippet unavailable'}</p>;
  }

  const examples = snippet.examples || {};

  return (
    <div className="space-y-6">
      <section className="space-y-3 rounded-lg border border-secondary-200 p-4" aria-labelledby="install-step-1">
        <h3 id="install-step-1" className="text-sm font-medium">
          1. Paste this snippet before <code className="font-mono">&lt;/head&gt;</code> on every page
        </h3>
        <CodeBlock code={snippet.html} title="Install snippet" label="Copy snippet" />
        <p className="text-xs text-secondary-500">
          <strong>Google Tag Manager:</strong> create a <em>Custom HTML</em> tag, paste the snippet, and set it to fire
          on <em>All Pages</em>.
        </p>
        <p className="text-xs text-secondary-500">
          Public key: <code className="font-mono">{snippet.public_key}</code>
          {pixel.allowed_domains.length > 0 && (
            <> · Accepts events only from: {pixel.allowed_domains.join(', ')}</>
          )}
        </p>
      </section>

      <section className="space-y-3 rounded-lg border border-secondary-200 p-4" aria-labelledby="install-step-2">
        <h3 id="install-step-2" className="text-sm font-medium">
          2. Track conversions with{' '}
          <code className="font-mono">mkt(&apos;track&apos;, &apos;purchase&apos;, {'{'}value, currency, order_id{'}'})</code>
        </h3>
        <p className="text-xs text-secondary-500">
          Conversions are attributed to the campaign that brought the visitor within the {pixel.attribution_window_days}
          -day attribution window. Passing <code className="font-mono">order_id</code> de-duplicates repeat fires.
        </p>
        {examples.purchase && <CodeBlock code={examples.purchase} title="Purchase" />}
        {examples.lead && <CodeBlock code={examples.lead} title="Lead" />}
      </section>

      <section className="space-y-3 rounded-lg border border-secondary-200 p-4" aria-labelledby="install-step-3">
        <h3 id="install-step-3" className="text-sm font-medium">
          3. Optionally identify visitors with{' '}
          <code className="font-mono">mkt(&apos;identify&apos;, {'{'}email{'}'})</code> after login or sign-up
        </h3>
        <p className="text-xs text-secondary-500">
          Identified visitors are matched to CRM contacts, so their earlier anonymous visits are credited too.
        </p>
        {examples.identify && <CodeBlock code={examples.identify} title="Identify" />}
      </section>

      <section className="space-y-3 rounded-lg border border-secondary-200 p-4" aria-labelledby="install-step-4">
        <h3 id="install-step-4" className="text-sm font-medium">
          4. Respect consent with <code className="font-mono">mkt(&apos;consent&apos;, false)</code> /{' '}
          <code className="font-mono">mkt(&apos;consent&apos;, true)</code>
        </h3>
        {examples.consent && <CodeBlock code={examples.consent} title="Consent" />}
      </section>

      <section className="space-y-2 rounded-lg border border-secondary-200 p-4" aria-labelledby="install-behaviour">
        <h3 id="install-behaviour" className="text-sm font-medium">
          What the pixel does automatically
        </h3>
        <ul className="list-disc space-y-1 pl-5 text-sm text-secondary-500">
          <li>
            Honours Global Privacy Control and Do Not Track by going cookieless — events are still counted but not
            linked across visits.
          </li>
          <li>Uses first-party cookies only — no third-party tracking.</li>
          <li>
            Captures the <code className="font-mono">_mkt</code> click-through token from campaign emails, then strips it
            from the address bar.
          </li>
          <li>Tracks single-page-app navigations (history push/replace and back/forward) as page views.</li>
          <li>
            Fires events from <code className="font-mono">data-mkt-event</code> attributes on clickable elements.
          </li>
        </ul>
      </section>

      {examples.declarative && (
        <section className="space-y-2 rounded-lg border border-secondary-200 p-4" aria-labelledby="install-declarative">
          <h3 id="install-declarative" className="text-sm font-medium">
            No-code tracking with data attributes
          </h3>
          <p className="text-xs text-secondary-500">
            Add <code className="font-mono">data-mkt-event</code> (and optional JSON{' '}
            <code className="font-mono">data-mkt-props</code>) to any clickable element.
          </p>
          <CodeBlock code={examples.declarative} title="Declarative event" />
        </section>
      )}

      {(snippet.gif_url || snippet.script_url || snippet.events_url) && (
        <section className="space-y-3 rounded-lg border border-secondary-200 p-4" aria-labelledby="install-endpoints">
          <h3 id="install-endpoints" className="text-sm font-medium">
            Endpoints
          </h3>
          {snippet.gif_url && (
            <p className="text-xs text-secondary-500">
              The snippet already includes a <code className="font-mono">&lt;noscript&gt;</code> image fallback, so page
              views are still counted when JavaScript is disabled. For email-safe or server-rendered tracking, request
              the GIF URL with <code className="font-mono">&amp;e=&lt;event_name&gt;</code> appended.
            </p>
          )}
          <dl className="grid gap-x-4 gap-y-1 text-xs sm:grid-cols-[auto_1fr]">
            {snippet.script_url && (
              <>
                <dt className="text-secondary-500">Script</dt>
                <dd className="font-mono break-all">{snippet.script_url}</dd>
              </>
            )}
            {snippet.events_url && (
              <>
                <dt className="text-secondary-500">Events API</dt>
                <dd className="font-mono break-all">{snippet.events_url}</dd>
              </>
            )}
            {snippet.gif_url && (
              <>
                <dt className="text-secondary-500">Pixel GIF</dt>
                <dd className="font-mono break-all">{snippet.gif_url}</dd>
              </>
            )}
          </dl>
        </section>
      )}
    </div>
  );
}

'use client';

/** The Share tab: the public link and its state. */

import React, { useState } from 'react';
import { Check, Copy, ExternalLink, Globe, Lock } from 'lucide-react';
import { Card } from '@/components/ui';
import { shareUrl, type Form } from '@/services/forms.service';

export default function FormSharePanel({ form }: { form: Form }) {
  const [copied, setCopied] = useState(false);
  const url = shareUrl(form);
  const live = form.status === 'published';

  const copy = async () => {
    await navigator.clipboard.writeText(url);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  };

  return (
    <div className="mx-auto max-w-3xl space-y-5">
      <Card padding="md">
        <div className="flex items-start gap-3">
          <span className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-xl ${live ? 'bg-success-500/10 text-success-600' : 'bg-secondary-100 text-secondary-500'}`}>
            {live ? <Globe className="h-5 w-5" /> : <Lock className="h-5 w-5" />}
          </span>
          <div className="min-w-0 flex-1">
            <h2 className="text-base font-semibold text-secondary-900">
              {live ? 'Your form is live' : form.status === 'closed' ? 'This form is closed' : 'Not published yet'}
            </h2>
            <p className="mt-0.5 text-sm text-secondary-500">
              {live
                ? 'Anyone with this link can fill it in.'
                : form.status === 'closed'
                  ? 'Visitors see your closed message. Reopen it to take responses again.'
                  : 'Publish the form first; until then the link shows "not available".'}
            </p>
            <div className="mt-4 flex flex-col gap-2 sm:flex-row">
              <input readOnly value={url} aria-label="Public link" onFocus={(e) => e.target.select()}
                className="h-11 min-w-0 flex-1 rounded-lg border border-secondary-300 bg-secondary-50 px-3 font-mono text-sm text-secondary-800" />
              <button type="button" onClick={copy}
                className="inline-flex h-11 items-center justify-center gap-2 rounded-lg bg-primary-500 px-4 text-sm font-semibold text-white hover:bg-primary-600">
                {copied ? <Check className="h-4 w-4" /> : <Copy className="h-4 w-4" />}
                {copied ? 'Copied' : 'Copy link'}
              </button>
              <a href={url} target="_blank" rel="noopener noreferrer"
                className="inline-flex h-11 items-center justify-center gap-2 rounded-lg border border-secondary-300 px-4 text-sm font-medium text-secondary-700 hover:bg-secondary-50">
                <ExternalLink className="h-4 w-4" /> Open
              </a>
            </div>
          </div>
        </div>
      </Card>
      <Card padding="md">
        <h2 className="text-base font-semibold text-secondary-900">Track where responses come from</h2>
        <p className="mt-1 text-sm text-secondary-600">
          Add UTM tags to the link and they are saved with each response (and on leads it creates):
        </p>
        <code className="mt-3 block overflow-x-auto rounded-lg bg-secondary-50 px-3 py-2 text-xs text-secondary-700">
          {url}?utm_source=newsletter&amp;utm_campaign=autumn
        </code>
        <p className="mt-3 text-sm text-secondary-600">
          A <strong>Hidden</strong> field reads any other link parameter you name, e.g. <code>?ref=partner42</code>.
        </p>
      </Card>
    </div>
  );
}

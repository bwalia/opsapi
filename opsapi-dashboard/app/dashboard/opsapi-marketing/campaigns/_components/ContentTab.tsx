'use client';

import React, { useEffect, useMemo, useRef, useState } from 'react';
import { Monitor, Smartphone, Save, Braces } from 'lucide-react';
import { Button } from '@/components/ui';
import { marketingService } from '@/services/opsapi-marketing.service';
import {
  type Campaign,
  INPUT_CLASS,
  Notice,
  apiErrorMessage,
  unwrap,
  unwrapArray,
} from './shared';

type MergeField = { key: string; label: string; field_type?: string };

type Rendered = { subject?: string; html?: string; text?: string; warnings?: string[] };

type FormState = {
  subject: string;
  preview_text: string;
  from_name: string;
  from_email: string;
  reply_to: string;
  body_html: string;
  body_text: string;
};

type InsertTarget = 'subject' | 'body_html' | 'body_text';

const FIELDS: (keyof FormState)[] = [
  'subject',
  'preview_text',
  'from_name',
  'from_email',
  'reply_to',
  'body_html',
  'body_text',
];

function fromCampaign(c: Campaign): FormState {
  return {
    subject: c.subject ?? '',
    preview_text: c.preview_text ?? '',
    from_name: c.from_name ?? '',
    from_email: c.from_email ?? '',
    reply_to: c.reply_to ?? '',
    body_html: c.body_html ?? '',
    body_text: c.body_text ?? '',
  };
}

function preheaderHint(len: number): { text: string; tone: 'ok' | 'warn' } {
  if (len === 0) return { text: 'Empty — inboxes will show the first line of the body instead.', tone: 'warn' };
  if (len < 40) return { text: 'A little short — aim for 40–130 characters.', tone: 'warn' };
  if (len > 130) return { text: 'Long — most inboxes truncate after ~130 characters.', tone: 'warn' };
  return { text: 'Good length.', tone: 'ok' };
}

export default function ContentTab({
  campaign,
  editable,
  onSaved,
}: {
  campaign: Campaign;
  editable: boolean;
  onSaved: (c: Campaign, message: string) => void;
}) {
  const [form, setForm] = useState<FormState>(() => fromCampaign(campaign));
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [mergeFields, setMergeFields] = useState<MergeField[]>([]);
  const [target, setTarget] = useState<InsertTarget>('body_html');
  const [device, setDevice] = useState<'desktop' | 'mobile'>('desktop');
  const [rendered, setRendered] = useState<Rendered | null>(null);
  const [previewError, setPreviewError] = useState<string | null>(null);

  const subjectRef = useRef<HTMLInputElement>(null);
  const htmlRef = useRef<HTMLTextAreaElement>(null);
  const textRef = useRef<HTMLTextAreaElement>(null);

  const saved = useMemo(() => fromCampaign(campaign), [campaign]);
  const dirty = FIELDS.some((k) => form[k] !== saved[k]);
  const isEmail = campaign.channel === 'email';

  useEffect(() => {
    let cancelled = false;
    marketingService
      .listMergeFields()
      .then((res) => {
        if (!cancelled) setMergeFields(unwrapArray<MergeField>(res));
      })
      .catch(() => {
        /* picker is optional — the backend still validates merge keys on Validate */
      });
    return () => {
      cancelled = true;
    };
  }, []);

  // Debounced live render through the same pipeline the sender uses.
  useEffect(() => {
    const handle = window.setTimeout(() => {
      marketingService
        .previewTemplate({
          template: {
            channel: campaign.channel,
            subject: form.subject,
            body_html: form.body_html,
            body_text: form.body_text,
          },
        })
        .then((res) => {
          setRendered(unwrap<Rendered>(res));
          setPreviewError(null);
        })
        .catch((e: unknown) => setPreviewError(apiErrorMessage(e, 'Preview failed')));
    }, 500);
    return () => window.clearTimeout(handle);
  }, [campaign.channel, form.subject, form.body_html, form.body_text]);

  const set = (k: keyof FormState, v: string) => setForm((f) => ({ ...f, [k]: v }));

  const insertMerge = (key: string) => {
    if (!key) return;
    const token = `{{${key}}}`;
    const el = target === 'subject' ? subjectRef.current : target === 'body_html' ? htmlRef.current : textRef.current;
    const current = form[target];
    const start = el?.selectionStart ?? current.length;
    const end = el?.selectionEnd ?? current.length;
    set(target, current.slice(0, start) + token + current.slice(end));
    requestAnimationFrame(() => {
      if (!el) return;
      el.focus();
      const pos = start + token.length;
      el.setSelectionRange(pos, pos);
    });
  };

  const save = async () => {
    setSaving(true);
    setError(null);
    const patch: Record<string, string> = {};
    for (const k of FIELDS) {
      if (form[k] !== saved[k]) patch[k] = form[k];
    }
    try {
      const res = await marketingService.updateCampaign(campaign.uuid, patch);
      const row = unwrap<Campaign>(res);
      const demoted = campaign.status !== 'draft' && row.status === 'draft';
      onSaved(
        row,
        demoted
          ? 'Content saved. The campaign went back to draft — validate it again before sending.'
          : 'Content saved.',
      );
    } catch (e: unknown) {
      setError(apiErrorMessage(e, 'Save failed'));
    } finally {
      setSaving(false);
    }
  };

  const preheader = preheaderHint(form.preview_text.length);
  const hasUnsub = /\{\{\s*unsubscribe_url\s*\}\}/.test(form.body_html + form.body_text);

  return (
    <div className="space-y-4">
      {!editable && (
        <Notice tone="warn">
          Content is locked while the campaign is {campaign.status.replace(/_/g, ' ')}. Pause it to make changes (it
          then goes back to draft and needs validating, and approving, again), or duplicate it to start a new draft.
        </Notice>
      )}
      {editable && campaign.status !== 'draft' && (
        <Notice tone="info">
          Saving content changes sends this campaign back to draft: validate it (and get it approved) again.
        </Notice>
      )}
      {error && <Notice tone="error">{error}</Notice>}

      <div className="grid gap-6 xl:grid-cols-2">
        <fieldset disabled={!editable} className="min-w-0 space-y-4">
          <legend className="sr-only">Message content</legend>

          <div className="flex flex-wrap items-end gap-2 rounded-lg border border-secondary-200 bg-secondary-50 p-3">
            <Braces className="mb-2 h-4 w-4 text-secondary-500" aria-hidden="true" />
            <label className="text-xs">
              <span className="block text-secondary-500">Insert merge field into</span>
              <select
                className={`${INPUT_CLASS} mt-1`}
                value={target}
                onChange={(e) => setTarget(e.target.value as InsertTarget)}
              >
                <option value="subject">Subject</option>
                <option value="body_html">HTML body</option>
                <option value="body_text">Plain-text body</option>
              </select>
            </label>
            <label className="text-xs">
              <span className="block text-secondary-500">Field</span>
              <select
                className={`${INPUT_CLASS} mt-1`}
                value=""
                onChange={(e) => insertMerge(e.target.value)}
                aria-label="Merge field to insert at the cursor"
              >
                <option value="">Choose…</option>
                {mergeFields.map((m) => (
                  <option key={m.key} value={m.key}>
                    {m.label} — {`{{${m.key}}}`}
                  </option>
                ))}
              </select>
            </label>
            <p className="basis-full text-xs text-secondary-500">
              Inserts at the cursor. <code>{'{{unsubscribe_url}}'}</code> is supported; if your email has no unsubscribe
              link, one is added automatically.
            </p>
          </div>

          {isEmail && (
            <>
              <div>
                <div className="flex items-baseline justify-between">
                  <label htmlFor="c-subject" className="text-sm font-medium">
                    Subject
                  </label>
                  <span className="text-xs tabular-nums text-secondary-500">{form.subject.length} chars</span>
                </div>
                <input
                  id="c-subject"
                  ref={subjectRef}
                  className={`${INPUT_CLASS} mt-1 w-full`}
                  value={form.subject}
                  onFocus={() => setTarget('subject')}
                  onChange={(e) => set('subject', e.target.value)}
                  maxLength={998}
                />
                {form.subject.length > 60 && (
                  <p className="mt-1 text-xs text-amber-700 dark:text-amber-300">
                    Subjects over ~60 characters are often cut off on mobile.
                  </p>
                )}
              </div>

              <div>
                <div className="flex items-baseline justify-between">
                  <label htmlFor="c-preview" className="text-sm font-medium">
                    Preview text <span className="font-normal text-secondary-500">(inbox preheader)</span>
                  </label>
                  <span className="text-xs tabular-nums text-secondary-500">{form.preview_text.length} chars</span>
                </div>
                <input
                  id="c-preview"
                  className={`${INPUT_CLASS} mt-1 w-full`}
                  value={form.preview_text}
                  onChange={(e) => set('preview_text', e.target.value)}
                  maxLength={255}
                  aria-describedby="c-preview-hint"
                />
                <p
                  id="c-preview-hint"
                  className={`mt-1 text-xs ${
                    preheader.tone === 'ok'
                      ? 'text-green-700 dark:text-green-400'
                      : 'text-amber-700 dark:text-amber-300'
                  }`}
                >
                  {preheader.text}
                </p>
              </div>

              <div className="grid gap-3 sm:grid-cols-3">
                <label className="block text-sm">
                  <span className="font-medium">From name</span>
                  <input
                    className={`${INPUT_CLASS} mt-1 w-full`}
                    value={form.from_name}
                    onChange={(e) => set('from_name', e.target.value)}
                    autoComplete="off"
                  />
                </label>
                <label className="block text-sm">
                  <span className="font-medium">From email</span>
                  <input
                    type="email"
                    className={`${INPUT_CLASS} mt-1 w-full`}
                    value={form.from_email}
                    onChange={(e) => set('from_email', e.target.value)}
                    placeholder="Default sender"
                    autoComplete="off"
                  />
                </label>
                <label className="block text-sm">
                  <span className="font-medium">Reply-to</span>
                  <input
                    type="email"
                    className={`${INPUT_CLASS} mt-1 w-full`}
                    value={form.reply_to}
                    onChange={(e) => set('reply_to', e.target.value)}
                    autoComplete="off"
                  />
                </label>
              </div>

              <div>
                <label htmlFor="c-html" className="text-sm font-medium">
                  HTML body
                </label>
                <textarea
                  id="c-html"
                  ref={htmlRef}
                  className={`${INPUT_CLASS} mt-1 h-72 w-full font-mono text-xs`}
                  value={form.body_html}
                  onFocus={() => setTarget('body_html')}
                  onChange={(e) => set('body_html', e.target.value)}
                  spellCheck={false}
                />
              </div>
            </>
          )}

          <div>
            <label htmlFor="c-text" className="text-sm font-medium">
              {isEmail ? 'Plain-text body' : 'Message'}
            </label>
            <textarea
              id="c-text"
              ref={textRef}
              className={`${INPUT_CLASS} mt-1 h-32 w-full font-mono text-xs`}
              value={form.body_text}
              onFocus={() => setTarget('body_text')}
              onChange={(e) => set('body_text', e.target.value)}
            />
            {isEmail && (
              <p className="mt-1 text-xs text-secondary-500">
                Shown by clients that block HTML; also improves deliverability.
              </p>
            )}
          </div>

          <div className="flex items-center gap-3">
            <Button
              leftIcon={<Save className="h-4 w-4" />}
              onClick={() => void save()}
              isLoading={saving}
              disabled={!editable || !dirty}
            >
              Save content
            </Button>
            <span className="text-xs text-secondary-500" aria-live="polite">
              {dirty ? 'Unsaved changes' : 'All changes saved'}
            </span>
          </div>
        </fieldset>

        <section aria-labelledby="c-preview-title" className="min-w-0 space-y-3">
          <div className="flex items-center justify-between">
            <h2 id="c-preview-title" className="text-sm font-medium">
              Live preview <span className="font-normal text-secondary-500">(sample contact “Alex”)</span>
            </h2>
            {isEmail && (
              <div className="inline-flex rounded border border-secondary-200" role="group" aria-label="Preview width">
                <button
                  type="button"
                  className={`px-2 py-1 ${device === 'desktop' ? 'bg-secondary-100' : ''}`}
                  aria-pressed={device === 'desktop'}
                  onClick={() => setDevice('desktop')}
                  title="Desktop"
                >
                  <Monitor className="h-4 w-4" aria-hidden="true" />
                  <span className="sr-only">Desktop</span>
                </button>
                <button
                  type="button"
                  className={`border-l border-secondary-200 px-2 py-1 ${device === 'mobile' ? 'bg-secondary-100' : ''}`}
                  aria-pressed={device === 'mobile'}
                  onClick={() => setDevice('mobile')}
                  title="Mobile"
                >
                  <Smartphone className="h-4 w-4" aria-hidden="true" />
                  <span className="sr-only">Mobile</span>
                </button>
              </div>
            )}
          </div>
          {previewError && <Notice tone="error">{previewError}</Notice>}
          {isEmail ? (
            <div className="rounded-lg border border-secondary-200 bg-secondary-50 p-3">
              <div className="mb-3 rounded border border-secondary-200 bg-surface p-3 text-sm">
                <div className="truncate font-semibold">{rendered?.subject || form.subject || '(no subject)'}</div>
                <div className="truncate text-xs text-secondary-500">
                  {form.from_name || 'Default sender'} — {form.preview_text || 'No preview text'}
                </div>
              </div>
              <div className="flex justify-center">
                <iframe
                  title="Rendered email preview"
                  sandbox=""
                  srcDoc={rendered?.html ?? ''}
                  className="h-[560px] rounded border border-secondary-200 bg-white transition-[width]"
                  style={{ width: device === 'mobile' ? 375 : '100%' }}
                />
              </div>
              {!hasUnsub && (
                <p className="mt-2 text-xs text-secondary-500">
                  No <code>{'{{unsubscribe_url}}'}</code> found — an unsubscribe footer will be appended on send.
                </p>
              )}
            </div>
          ) : (
            <pre className="whitespace-pre-wrap rounded-lg border border-secondary-200 bg-secondary-50 p-3 text-sm">
              {rendered?.text ?? form.body_text}
            </pre>
          )}
          {rendered?.warnings && rendered.warnings.length > 0 && (
            <Notice tone="warn">
              <span className="font-medium">Content warnings:</span>{' '}
              {rendered.warnings.map((w) => w.replace(/_/g, ' ')).join(', ')}
            </Notice>
          )}
        </section>
      </div>
    </div>
  );
}

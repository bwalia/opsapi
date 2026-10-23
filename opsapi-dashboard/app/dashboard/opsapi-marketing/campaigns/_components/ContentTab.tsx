'use client';

import React, { useEffect, useMemo, useRef, useState } from 'react';
import { Monitor, Smartphone, Save, Braces, ImagePlus, Loader2 } from 'lucide-react';
import { Button, confirmDialog } from '@/components/ui';
import { marketingService } from '@/services/opsapi-marketing.service';
import {
  EMAIL_IMAGE_TYPES,
  EmailStudioEditor,
  uploadEmailImage,
  madeWithCode,
} from '@/components/opsapi-marketing/EmailStudioEditor';
import { EditorModeSwitch, acceptPastedHtml } from '@/components/opsapi-marketing/EditorModeSwitch';
import { DesignGallery, type Design } from '@/components/opsapi-marketing/DesignGallery';
import { type Campaign, INPUT_CLASS, Notice, apiErrorMessage, unwrap, unwrapArray } from './shared';

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

/** Designs made with tables or full HTML pages lose their layout in the easy editor. */

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
  const [galleryOpen, setGalleryOpen] = useState(false);
  const [target, setTarget] = useState<InsertTarget>('body_html');
  const [device, setDevice] = useState<'desktop' | 'mobile'>('desktop');
  const [rendered, setRendered] = useState<Rendered | null>(null);
  const [previewError, setPreviewError] = useState<string | null>(null);
  const [uploading, setUploading] = useState(false);
  const [easy, setEasy] = useState(() => !madeWithCode(campaign.body_html ?? ''));

  const subjectRef = useRef<HTMLInputElement>(null);
  const htmlRef = useRef<HTMLTextAreaElement>(null);
  const textRef = useRef<HTMLTextAreaElement>(null);
  const imageRef = useRef<HTMLInputElement>(null);

  const saved = useMemo(() => fromCampaign(campaign), [campaign]);
  const dirty = FIELDS.some((k) => form[k] !== saved[k]);
  const isEmail = campaign.channel === 'email';

  const switchEditor = async (toEasy: boolean) => {
    if (
      toEasy &&
      madeWithCode(form.body_html) &&
      !(await confirmDialog({
        title: 'Open in the easy editor?',
        message: 'This email was designed with code. The easy editor may change its layout.',
        confirmText: 'Open easy editor',
      }))
    )
      return;
    setEasy(toEasy);
  };

  // A whole HTML email pasted into the easy editor: keep it as HTML (the easy editor would lose parts of it).
  const pasteHtml = async (html: string) => {
    if (!(await acceptPastedHtml(form.body_html))) return;
    set('body_html', html);
    setEasy(false);
  };

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
  }, [campaign.channel]);

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

  /** Put text at the cursor of a field (or at its end). */
  const insertInto = (field: InsertTarget, token: string) => {
    const el = field === 'subject' ? subjectRef.current : field === 'body_html' ? htmlRef.current : textRef.current;
    const current = form[field];
    const start = el?.selectionStart ?? current.length;
    const end = el?.selectionEnd ?? current.length;
    set(field, current.slice(0, start) + token + current.slice(end));
    requestAnimationFrame(() => {
      if (!el) return;
      el.focus();
      const pos = start + token.length;
      el.setSelectionRange(pos, pos);
    });
  };

  const insertMerge = (key: string) => {
    if (key) insertInto(target, `{{${key}}}`);
  };

  /** Copy a design's words and look into this email (it can then be edited freely). */
  const applyTemplate = async (t: Design) => {
    setGalleryOpen(false);
    const hasContent = (form.body_html + form.body_text).trim() !== '';
    if (
      hasContent &&
      !(await confirmDialog({
        title: `Use the design “${t.name}”?`,
        message: 'It replaces this email’s subject and words. You can still change anything afterwards.',
        confirmText: 'Use this design',
      }))
    )
      return;
    setForm((f) => ({
      ...f,
      subject: t.subject ?? f.subject,
      preview_text: t.preview_text ?? f.preview_text,
      body_html: t.body_html ?? '',
      body_text: t.body_text ?? '',
    }));
  };

  const uploadImage = async (file: File | undefined) => {
    if (!file) return;
    setUploading(true);
    setError(null);
    try {
      const src = await uploadEmailImage(file);
      insertInto(
        'body_html',
        `<img src="${src}" alt="" width="600" style="max-width:100%;height:auto;display:block;border:0" />`,
      );
    } catch (e: unknown) {
      setError(apiErrorMessage(e, 'Image upload failed'));
    } finally {
      setUploading(false);
      if (imageRef.current) imageRef.current.value = '';
    }
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
          {campaign.status === 'completed' || campaign.status === 'cancelled'
            ? 'This email has been sent, so it can’t be changed. To send something similar, use More → Make a copy.'
            : 'This email is being sent, so it can’t be changed right now. Press “Pause” to edit it (then press “Check it” again), or use More → Make a copy.'}
        </Notice>
      )}
      {editable && campaign.status !== 'draft' && (
        <Notice tone="info">If you change and save the email, press “Check it” again before sending.</Notice>
      )}
      {error && <Notice tone="error">{error}</Notice>}

      <div className="grid gap-6 xl:grid-cols-2">
        <div className="min-w-0 space-y-4">
          {/* Locked when sent: inputs are disabled, but the email can still be viewed both ways. */}
          <fieldset disabled={!editable} className="min-w-0 space-y-4">
            <legend className="sr-only">Message content</legend>

            <div className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-primary-200 bg-primary-50 p-3 text-sm dark:bg-primary-900/30">
              <span>
                <span className="font-medium">Start from a ready-made design</span>
                <span className="block text-xs text-secondary-600">
                  Welcome, newsletter, special offer, event invitation and more — then change the words.
                </span>
              </span>
              <Button type="button" size="sm" variant="outline" onClick={() => setGalleryOpen(true)}>
                Choose a design
              </Button>
            </div>
            {galleryOpen && (
              <DesignGallery
                channel={campaign.channel}
                onClose={() => setGalleryOpen(false)}
                onPick={(d) => void applyTemplate(d)}
              />
            )}

            {!isEmail && (
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
                  Inserts at the cursor. <code>{'{{unsubscribe_url}}'}</code> is supported; if your email has no
                  unsubscribe link, one is added automatically.
                </p>
              </div>
            )}

            {isEmail && (
              <>
                <div>
                  <div className="flex items-baseline justify-between">
                    <label htmlFor="c-subject" className="text-sm font-medium">
                      Subject{' '}
                      <span className="font-normal text-secondary-500">(the line people see in their inbox)</span>
                    </label>
                    <button
                      type="button"
                      className="shrink-0 text-xs font-medium text-primary-700 underline underline-offset-2 dark:text-primary-300"
                      onClick={() => insertInto('subject', '{{contact.first_name}}')}
                    >
                      + First name
                    </button>
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
              </>
            )}
          </fieldset>

          {isEmail && (
            <>
              <div>
                <div className="flex items-center justify-between">
                  <span className="text-sm font-medium">Your email</span>
                  <EditorModeSwitch easy={easy} onChange={(v) => void switchEditor(v)} />
                </div>
                {easy ? (
                  <div className="mt-1">
                    <EmailStudioEditor
                      value={form.body_html}
                      onChange={(h) => set('body_html', h)}
                      placeholder="Write your email here…"
                      mergeFields={mergeFields}
                      readOnly={!editable}
                      onPasteHtml={(h) => void pasteHtml(h)}
                    />
                    <p className="mt-1 text-xs text-secondary-500">
                      Type like a normal document. Use the picture button for photos and “Personalise” to greet each
                      person by name. The unsubscribe link and your address are added for you.
                    </p>
                  </div>
                ) : (
                  <>
                    <div className="mt-1 flex justify-end">
                      <Button
                        type="button"
                        variant="ghost"
                        size="sm"
                        disabled={uploading || !editable}
                        onClick={() => imageRef.current?.click()}
                      >
                        {uploading ? (
                          <Loader2 className="mr-1.5 h-4 w-4 animate-spin" aria-hidden />
                        ) : (
                          <ImagePlus className="mr-1.5 h-4 w-4" aria-hidden />
                        )}
                        {uploading ? 'Uploading…' : 'Upload image'}
                      </Button>
                      <input
                        ref={imageRef}
                        type="file"
                        accept={EMAIL_IMAGE_TYPES}
                        className="hidden"
                        aria-label="Upload image"
                        onChange={(e) => void uploadImage(e.target.files?.[0])}
                      />
                    </div>
                    <textarea
                      id="c-html"
                      ref={htmlRef}
                      className={`${INPUT_CLASS} mt-1 h-72 w-full font-mono text-xs`}
                      value={form.body_html}
                      onFocus={() => setTarget('body_html')}
                      onChange={(e) => set('body_html', e.target.value)}
                      readOnly={!editable}
                      spellCheck={false}
                    />
                  </>
                )}
              </div>
            </>
          )}

          <fieldset disabled={!editable} className="min-w-0 space-y-4">
            {isEmail && (
              <>
                <details className="group rounded-lg border border-secondary-200 p-3">
                  <summary className="cursor-pointer select-none text-sm font-medium">
                    More options{' '}
                    <span className="font-normal text-secondary-500">
                      (optional — inbox preview line, sender, plain-text version)
                    </span>
                  </summary>
                  <div className="mt-3 space-y-4">
                    <div>
                      <div className="flex items-baseline justify-between">
                        <label htmlFor="c-preview" className="text-sm font-medium">
                          Preview text <span className="font-normal text-secondary-500">(inbox preheader)</span>
                        </label>
                        <span className="text-xs tabular-nums text-secondary-500">
                          {form.preview_text.length} chars
                        </span>
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
                        Inserts at the cursor. <code>{'{{unsubscribe_url}}'}</code> is supported; if your email has no
                        unsubscribe link, one is added automatically.
                      </p>
                    </div>

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
                  </div>
                </details>
              </>
            )}

            {!isEmail && (
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
            )}

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
        </div>

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

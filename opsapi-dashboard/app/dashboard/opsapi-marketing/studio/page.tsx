'use client';

import React, { useCallback, useEffect, useRef, useState } from 'react';
import { isAxiosError } from 'axios';
import { Palette, Save, Eye, Sparkles, Send } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button } from '@/components/ui';
import { EmailStudioEditor } from '@/components/opsapi-marketing/EmailStudioEditor';
import { marketingService } from '@/services/opsapi-marketing.service';
import { HelpLink } from '@/components/opsapi-marketing/GettingStarted';

type MergeField = { key: string; label: string; field_type?: string };
type Template = {
  uuid: string;
  name: string;
  channel: string;
  subject?: string;
  preview_text?: string;
  body_html?: string;
  body_text?: string;
  status?: string;
};

type Preview = {
  subject?: string;
  html?: string;
  text?: string;
  warnings?: string[];
  opens_estimated?: boolean;
};

function apiErrorMessage(e: unknown, fallback: string): string {
  if (isAxiosError(e)) {
    const data = e.response?.data as { error?: string; message?: string; details?: unknown } | undefined;
    if (data?.error) return String(data.error);
    if (data?.message) return String(data.message);
    if (e.message) return e.message;
  }
  if (e instanceof Error) return e.message;
  return fallback;
}

function unwrapPreview(res: { data?: unknown }): Preview {
  const root = res?.data as { data?: Preview } | Preview | undefined;
  if (root && typeof root === 'object' && 'data' in root && root.data && typeof root.data === 'object') {
    return root.data as Preview;
  }
  return (root || {}) as Preview;
}

export default function MarketingStudioPage() {
  const [templates, setTemplates] = useState<Template[]>([]);
  const [mergeFields, setMergeFields] = useState<MergeField[]>([]);
  const [selected, setSelected] = useState<Template | null>(null);
  const [channel, setChannel] = useState<'email' | 'sms'>('email');
  const [name, setName] = useState('Untitled');
  const [subject, setSubject] = useState('');
  const [previewText, setPreviewText] = useState('');
  const [html, setHtml] = useState('<p>Hi {{contact.first_name}},</p>');
  const [text, setText] = useState('Hi {{contact.first_name}},');
  const [preview, setPreview] = useState<Preview | null>(null);
  const [warnings, setWarnings] = useState<string[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const previewRef = useRef<HTMLDivElement>(null);

  const load = useCallback(async () => {
    setError(null);
    try {
      const [tRes, mRes] = await Promise.all([
        marketingService.listTemplates({ per_page: 50 }),
        marketingService.listMergeFields(),
      ]);
      const tData = tRes.data?.data ?? tRes.data ?? [];
      setTemplates(Array.isArray(tData) ? tData : tData.items || []);
      const mData = mRes.data?.data ?? mRes.data ?? [];
      setMergeFields(Array.isArray(mData) ? mData : []);
    } catch (e: unknown) {
      setError(apiErrorMessage(e, 'Failed to load studio'));
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const selectTemplate = (t: Template) => {
    setSelected(t);
    setChannel((t.channel === 'sms' ? 'sms' : 'email') as 'email' | 'sms');
    setName(t.name);
    setSubject(t.subject || '');
    setPreviewText(t.preview_text || '');
    setHtml(t.body_html || '<p></p>');
    setText(t.body_text || '');
    setPreview(null);
    setWarnings([]);
  };

  const insertMerge = (key: string) => {
    const token = `{{${key}}}`;
    if (channel === 'sms') setText((v) => v + token);
    else setHtml((v) => v.replace(/<\/p>\s*$/i, ` ${token}</p>`) || v + token);
  };

  const runPreview = async () => {
    setBusy(true);
    setError(null);
    try {
      const res = await marketingService.previewTemplate({
        channel,
        subject,
        body_html: channel === 'email' ? html : undefined,
        body_text: text,
        name,
      });
      const data = unwrapPreview(res);
      if (!data.html && !data.text && !data.subject) {
        setError('Preview returned empty content — try Save draft, then Preview again');
        setPreview(null);
        return;
      }
      setPreview(data);
      setWarnings(data.warnings || []);
      requestAnimationFrame(() => {
        previewRef.current?.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
      });
    } catch (e: unknown) {
      setPreview(null);
      setError(apiErrorMessage(e, 'Preview failed'));
    } finally {
      setBusy(false);
    }
  };

  const save = async () => {
    setBusy(true);
    setError(null);
    try {
      if (selected?.uuid) {
        await marketingService.saveStudio(selected.uuid, {
          name,
          channel,
          subject,
          preview_text: previewText,
          body_html: channel === 'email' ? html : null,
          body_text: text,
          status: 'draft',
        });
      } else {
        const res = await marketingService.createTemplate({
          name,
          channel,
          subject,
          preview_text: previewText,
          body_html: channel === 'email' ? html : null,
          body_text: text,
          status: 'draft',
        });
        const created = (res.data?.data ?? res.data) as Template;
        setSelected(created);
      }
      await load();
    } catch (e: unknown) {
      setError(apiErrorMessage(e, 'Save failed'));
    } finally {
      setBusy(false);
    }
  };

  const publish = async () => {
    if (!selected?.uuid) {
      await save();
      return;
    }
    setBusy(true);
    try {
      await marketingService.saveStudio(selected.uuid, {
        name,
        channel,
        subject,
        preview_text: previewText,
        body_html: channel === 'email' ? html : null,
        body_text: text,
      });
      await marketingService.publishTemplate(selected.uuid);
      await load();
    } catch (e: unknown) {
      setError(apiErrorMessage(e, 'Publish failed'));
    } finally {
      setBusy(false);
    }
  };

  const seed = async () => {
    setBusy(true);
    try {
      await marketingService.seedTemplates();
      await load();
    } catch (e: unknown) {
      setError(apiErrorMessage(e, 'Could not add the ready-made templates'));
    } finally {
      setBusy(false);
    }
  };

  const newDraft = () => {
    setSelected(null);
    setName('Untitled');
    setSubject('');
    setPreviewText('');
    setHtml('<p>Hi {{contact.first_name}},</p><p></p>');
    setText('Hi {{contact.first_name}},');
    setPreview(null);
    setWarnings([]);
  };

  return (
    <div className="space-y-4 p-6">
      <PageHeader
        title="Message studio"
        description="Design email templates you can reuse. Change the words like a normal document, add pictures, then Publish."
        icon={<Palette className="h-6 w-6" />}
        actions={
          <>
            <HelpLink topic="templates" />
            <Button variant="outline" leftIcon={<Sparkles className="h-4 w-4" />} onClick={() => void seed()} disabled={busy}>
              Add ready-made templates
            </Button>
            <Button variant="outline" leftIcon={<Eye className="h-4 w-4" />} onClick={() => void runPreview()} disabled={busy}>
              Preview
            </Button>
            <Button variant="outline" leftIcon={<Save className="h-4 w-4" />} onClick={() => void save()} disabled={busy}>
              Save draft
            </Button>
            <Button leftIcon={<Send className="h-4 w-4" />} onClick={() => void publish()} disabled={busy}>
              Publish
            </Button>
          </>
        }
      />

      {error && <p className="text-sm text-error-600">{error}</p>}
      {warnings.length > 0 && (
        <ul className="rounded-lg border border-amber-200 bg-amber-50 px-4 py-2 text-sm text-amber-900 dark:border-amber-900 dark:bg-amber-950/40 dark:text-amber-100">
          {warnings.map((w) => (
            <li key={w}>{w.replace(/_/g, ' ')}</li>
          ))}
        </ul>
      )}

      <div className="grid gap-4 lg:grid-cols-[220px_1fr_280px]">
        <aside className="space-y-2">
          <div className="flex items-center justify-between">
            <h2 className="text-sm font-medium">Templates</h2>
            <button type="button" className="text-xs text-secondary-500 underline" onClick={newDraft}>
              New
            </button>
          </div>
          <ul className="max-h-[60vh] space-y-1 overflow-y-auto text-sm">
            {templates.map((t) => (
              <li key={t.uuid}>
                <button
                  type="button"
                  onClick={() => selectTemplate(t)}
                  className={`w-full rounded px-2 py-1.5 text-left hover:bg-secondary-100 ${
                    selected?.uuid === t.uuid ? 'bg-secondary-100 font-medium' : ''
                  }`}
                >
                  <span className="block truncate">{t.name}</span>
                  <span className="text-xs text-secondary-500">
                    {t.channel} · {t.status || 'draft'}
                  </span>
                </button>
              </li>
            ))}
            {templates.length === 0 && (
              <li className="text-xs text-secondary-500">No templates yet. Press “Add ready-made templates” to get some.</li>
            )}
          </ul>
        </aside>

        <main className="space-y-3">
          <div className="flex flex-wrap gap-3">
            <label className="text-sm">
              Channel
              <select
                className="ml-2 rounded border border-secondary-200 bg-surface px-2 py-1"
                value={channel}
                onChange={(e) => setChannel(e.target.value as 'email' | 'sms')}
              >
                <option value="email">Email</option>
                <option value="sms">SMS</option>
              </select>
            </label>
            <label className="flex-1 text-sm">
              Name
              <input
                className="mt-1 w-full rounded border border-secondary-200 bg-surface px-3 py-1.5"
                value={name}
                onChange={(e) => setName(e.target.value)}
              />
            </label>
          </div>

          {channel === 'email' && (
            <>
              <label className="block text-sm">
                Subject
                <input
                  className="mt-1 w-full rounded border border-secondary-200 bg-surface px-3 py-1.5"
                  value={subject}
                  onChange={(e) => setSubject(e.target.value)}
                  placeholder="{{contact.first_name}}, your update"
                />
              </label>
              <label className="block text-sm">
                Preview text
                <input
                  className="mt-1 w-full rounded border border-secondary-200 bg-surface px-3 py-1.5"
                  value={previewText}
                  onChange={(e) => setPreviewText(e.target.value)}
                />
              </label>
              <EmailStudioEditor value={html} onChange={setHtml} />
              <label className="block text-sm">
                Plain-text alternative
                <textarea
                  className="mt-1 w-full rounded border border-secondary-200 bg-surface px-3 py-2 font-mono text-xs"
                  rows={3}
                  value={text}
                  onChange={(e) => setText(e.target.value)}
                />
              </label>
            </>
          )}

          {channel === 'sms' && (
            <label className="block text-sm">
              SMS body ({text.length}/1600)
              <textarea
                className="mt-1 w-full rounded border border-secondary-200 bg-surface px-3 py-2 font-mono text-sm"
                rows={6}
                maxLength={1600}
                value={text}
                onChange={(e) => setText(e.target.value)}
                placeholder="Hi {{contact.first_name}}… Reply STOP to opt out."
              />
              {text.length > 160 && (
                <span className="text-xs text-amber-700">Multipart SMS (over 160 chars)</span>
              )}
            </label>
          )}

          {preview && (
            <div
              ref={previewRef}
              className="rounded-lg border border-secondary-200 bg-secondary-100/20 p-4"
              data-testid="marketing-studio-preview"
            >
              <h3 className="mb-1 text-sm font-medium">
                Preview{preview.opens_estimated ? ' · opens estimated' : ''}
              </h3>
              <p className="mb-3 text-xs text-secondary-500">
                Sample recipient: Alex Example · merge fields filled with demo data (not sent).
              </p>
              <p className="mb-2 text-sm font-medium">
                Subject:{' '}
                {preview.subject?.trim() ? (
                  preview.subject
                ) : (
                  <span className="font-normal text-secondary-500">(none)</span>
                )}
              </p>
              {preview.html ? (
                <div
                  className="prose prose-sm max-w-none rounded bg-white p-3 text-black shadow-sm"
                  dangerouslySetInnerHTML={{ __html: preview.html }}
                />
              ) : (
                <pre className="whitespace-pre-wrap rounded bg-white p-3 text-sm text-black shadow-sm">
                  {preview.text || '(empty)'}
                </pre>
              )}
            </div>
          )}
        </main>

        <aside className="space-y-3">
          <h2 className="text-sm font-medium">Merge fields</h2>
          <p className="text-xs text-secondary-500">
            Only registry keys are allowed. Values are HTML-escaped unless marked rich.
          </p>
          <ul className="max-h-[40vh] space-y-1 overflow-y-auto text-sm">
            {mergeFields.map((f) => (
              <li key={f.key}>
                <button
                  type="button"
                  className="w-full rounded border border-transparent px-2 py-1 text-left hover:border-secondary-200 hover:bg-secondary-100"
                  onClick={() => insertMerge(f.key)}
                  title={f.key}
                >
                  <span className="font-medium">{f.label}</span>
                  <span className="block font-mono text-xs text-secondary-500">{`{{${f.key}}}`}</span>
                </button>
              </li>
            ))}
          </ul>
        </aside>
      </div>
    </div>
  );
}

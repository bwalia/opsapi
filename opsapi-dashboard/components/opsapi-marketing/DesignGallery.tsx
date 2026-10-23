'use client';

import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import toast from 'react-hot-toast';
import { isAxiosError } from 'axios';
import { ArrowLeft, RotateCw, Save, Sparkles, Wand2 } from 'lucide-react';
import { Button, Modal } from '@/components/ui';
import { marketingService } from '@/services/opsapi-marketing.service';

export type Design = {
  uuid?: string;
  name: string;
  channel?: string;
  subject?: string | null;
  preview_text?: string | null;
  body_html?: string | null;
  body_text?: string | null;
};

/** What the design looks like for someone called Alex (links go nowhere in the preview). */
const sample = (s: string) =>
  s.replace(/\{\{\s*contact\.first_name\s*\}\}/g, 'Alex').replace(/\{\{\s*[\w.]+\s*\}\}/g, '#');

const unwrapList = (res: { data?: unknown }): Design[] => {
  const d = (res.data as { data?: unknown })?.data ?? res.data;
  if (Array.isArray(d)) return d as Design[];
  const items = (d as { items?: unknown })?.items;
  return Array.isArray(items) ? (items as Design[]) : [];
};

const errorText = (e: unknown, fallback: string) => {
  if (isAxiosError(e)) {
    if (!e.response) return 'Can’t reach the server. Check your internet connection and try again.';
    if (e.response.status === 429)
      return (e.response.data as { error?: string })?.error || 'Today’s AI limit is used up.';
    return (e.response.data as { error?: string })?.error || fallback;
  }
  return fallback;
};

const TONES: [string, string][] = [
  ['friendly', 'Friendly'],
  ['professional', 'Professional'],
  ['excited', 'Exciting'],
  ['formal', 'Formal'],
];

const IDEAS = [
  '20% off all garden furniture this weekend only, code GARDEN20',
  'Invite customers to our shop’s 10th birthday on Saturday 14 June, free cake and prizes',
  'Introduce our website design service to local restaurants, ask them to book a free call',
  'Thank customers for their order and ask them to leave a Google review',
];

function Preview({ html, height }: { html: string; height: number }) {
  return (
    <iframe
      title="Preview"
      sandbox=""
      tabIndex={-1}
      srcDoc={`<!doctype html><html><body style="margin:16px;background:#f4f5f7">${sample(html)}</body></html>`}
      style={{ width: '100%', height, border: 0, borderRadius: 12, background: '#f4f5f7' }}
    />
  );
}

/** Ask the AI for a design: describe it, pick a tone, see it, use it or save it. */
function AiDesigner({ onBack, onPick }: { onBack: () => void; onPick: (d: Design) => void }) {
  const [brief, setBrief] = useState('');
  const [tone, setTone] = useState('friendly');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [design, setDesign] = useState<Design | null>(null);
  const [saving, setSaving] = useState(false);

  const create = async () => {
    if (brief.trim().length < 8) {
      setError('Say what the email is about in a sentence or two.');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const res = await marketingService.aiDesign({ brief: brief.trim(), tone });
      setDesign((res.data?.data ?? res.data) as Design);
    } catch (e: unknown) {
      setError(errorText(e, 'The AI couldn’t write it this time. Please try again.'));
    } finally {
      setBusy(false);
    }
  };

  const save = async () => {
    if (!design) return;
    setSaving(true);
    try {
      await marketingService.createTemplate({
        name: design.name,
        channel: 'email',
        subject: design.subject,
        preview_text: design.preview_text,
        body_html: design.body_html,
        body_text: design.body_text,
        status: 'draft',
      });
      toast.success(`Saved as “${design.name}” — it’s in your designs now`);
    } catch (e: unknown) {
      toast.error(errorText(e, 'Could not save the design'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="space-y-4">
      <button
        type="button"
        onClick={design ? () => setDesign(null) : onBack}
        className="inline-flex items-center gap-1.5 text-sm text-secondary-600 hover:text-secondary-900"
      >
        <ArrowLeft className="h-4 w-4" aria-hidden="true" />
        {design ? 'Change the description' : 'All designs'}
      </button>

      {!design && (
        <form
          className="space-y-4"
          onSubmit={(e) => {
            e.preventDefault();
            void create();
          }}
        >
          <label className="block">
            <span className="text-base font-medium text-secondary-900">What’s the email about?</span>
            <span className="block text-sm text-secondary-600">
              Say who it’s for and what you want them to do. Mention any offer, date, price or link.
            </span>
            <textarea
              className="mt-2 h-28 w-full rounded-lg border border-secondary-300 bg-surface px-3 py-2.5 text-base focus:border-primary-500 focus:outline-none focus:ring-2 focus:ring-primary-500/20"
              value={brief}
              onChange={(e) => setBrief(e.target.value)}
              placeholder="e.g. 20% off all garden furniture this weekend only, code GARDEN20"
              maxLength={2000}
              disabled={busy}
            />
          </label>
          <div className="flex flex-wrap gap-2" aria-label="Ideas">
            {IDEAS.map((idea) => (
              <button
                key={idea}
                type="button"
                disabled={busy}
                onClick={() => setBrief(idea)}
                className="rounded-full border border-secondary-200 px-3 py-1 text-xs text-secondary-700 hover:border-primary-400 hover:text-primary-700 dark:text-secondary-300"
              >
                {idea}
              </button>
            ))}
          </div>
          <label className="flex flex-wrap items-center gap-2 text-sm text-secondary-800">
            Tone
            <select
              className="rounded-lg border border-secondary-300 bg-surface px-2.5 py-2 text-sm"
              value={tone}
              onChange={(e) => setTone(e.target.value)}
              disabled={busy}
            >
              {TONES.map(([v, l]) => (
                <option key={v} value={v}>
                  {l}
                </option>
              ))}
            </select>
          </label>
          {error && <p className="rounded-lg bg-error-500/10 p-3 text-sm text-error-600">{error}</p>}
          <div className="flex flex-wrap items-center gap-3">
            <Button type="submit" leftIcon={<Wand2 className="h-4 w-4" />} isLoading={busy}>
              {busy ? 'Writing your email…' : 'Create my design'}
            </Button>
            {busy && <span className="text-sm text-secondary-500">This can take up to a minute.</span>}
          </div>
        </form>
      )}

      {design && (
        <div className="space-y-3">
          <p className="text-sm text-secondary-600">
            <span className="font-medium text-secondary-900">Subject:</span> {sample(design.subject || '')}
          </p>
          <Preview html={design.body_html || ''} height={520} />
          {error && <p className="rounded-lg bg-error-500/10 p-3 text-sm text-error-600">{error}</p>}
          <div className="flex flex-wrap gap-2">
            <Button onClick={() => onPick(design)}>Use this design</Button>
            <Button
              variant="outline"
              leftIcon={<Save className="h-4 w-4" />}
              isLoading={saving}
              onClick={() => void save()}
            >
              Save as a design
            </Button>
            <Button
              variant="ghost"
              leftIcon={<RotateCw className="h-4 w-4" />}
              isLoading={busy}
              onClick={() => void create()}
            >
              Try again
            </Button>
          </div>
          <p className="text-xs text-secondary-500">
            Anything in [square brackets] is for you to fill in. You can change every word, picture and button after.
          </p>
        </div>
      )}
    </div>
  );
}

/** Pick a ready-made design (or one saved in the Studio), or have the AI write one. Mount when open. */
export function DesignGallery({
  channel,
  onClose,
  onPick,
}: {
  channel: string;
  onClose: () => void;
  onPick: (d: Design) => void;
}) {
  const [designs, setDesigns] = useState<Design[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);
  const [reload, setReload] = useState(0);
  const [ai, setAi] = useState(false);

  useEffect(() => {
    let cancelled = false;
    marketingService
      .listTemplates({ channel, per_page: 100 })
      .then((res) => {
        if (!cancelled) setDesigns(unwrapList(res));
      })
      .catch(() => {
        if (!cancelled) {
          setDesigns([]);
          setError('Could not load the designs. Please try again.');
        }
      });
    return () => {
      cancelled = true;
    };
  }, [channel, reload]);

  const addReadyMade = async () => {
    setAdding(true);
    setError(null);
    try {
      const res = await marketingService.seedTemplates();
      const n = (res.data?.data ?? res.data)?.count ?? 0;
      toast.success(
        n > 0 ? `${n} new design${n === 1 ? '' : 's'} added` : 'You already have all the ready-made designs',
      );
      setReload((r) => r + 1);
    } catch {
      setError('Could not add the ready-made designs. Please try again.');
    } finally {
      setAdding(false);
    }
  };

  const isEmail = channel === 'email';

  return (
    <Modal
      isOpen
      onClose={onClose}
      title={ai ? 'Create a design with AI' : 'Choose a design'}
      description={
        ai
          ? 'Describe the email; the AI writes it in a ready-made style you can change.'
          : 'Pick one, then change the words, pictures and buttons. It replaces what’s in this email now.'
      }
      size="3xl"
      footer={
        ai ? undefined : (
          <>
            <Link
              href="/dashboard/opsapi-marketing/studio"
              className="mr-auto text-sm text-secondary-600 underline underline-offset-2 hover:text-secondary-900"
            >
              Design your own in the Studio
            </Link>
            <Button
              variant="ghost"
              leftIcon={<Sparkles className="h-4 w-4" />}
              isLoading={adding}
              onClick={() => void addReadyMade()}
            >
              Add the latest ready-made designs
            </Button>
          </>
        )
      }
    >
      {ai ? (
        <AiDesigner onBack={() => setAi(false)} onPick={onPick} />
      ) : (
        <>
          {error && <p className="mb-3 rounded-lg bg-error-500/10 p-3 text-sm text-error-600">{error}</p>}
          <ul className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            {isEmail && (
              <li>
                <button
                  type="button"
                  onClick={() => setAi(true)}
                  className="flex h-full min-h-72 w-full flex-col items-center justify-center gap-3 rounded-xl border-2 border-dashed border-primary-300 bg-linear-to-br from-primary-50 to-transparent p-6 text-center transition hover:border-primary-500 hover:shadow-md focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-500 dark:from-primary-900/30"
                >
                  <span className="flex h-12 w-12 items-center justify-center rounded-full bg-primary-600 text-white">
                    <Wand2 className="h-6 w-6" aria-hidden="true" />
                  </span>
                  <span className="text-base font-semibold text-secondary-900">Create one with AI</span>
                  <span className="text-sm text-secondary-600">Describe your email and get a custom design.</span>
                </button>
              </li>
            )}
            {designs === null &&
              [0, 1].map((i) => (
                <li
                  key={i}
                  className="h-72 animate-pulse rounded-xl bg-secondary-100 dark:bg-secondary-800"
                  aria-hidden="true"
                />
              ))}
            {designs?.map((d) => (
              <li key={d.uuid}>
                <button
                  type="button"
                  onClick={() => onPick(d)}
                  className="group flex w-full flex-col overflow-hidden rounded-xl border border-secondary-200 text-left transition hover:-translate-y-0.5 hover:border-primary-400 hover:shadow-md focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-500"
                >
                  <span
                    className="relative block h-56 overflow-hidden bg-secondary-100 dark:bg-secondary-800"
                    aria-hidden="true"
                  >
                    {isEmail && d.body_html ? (
                      <iframe
                        title={d.name}
                        sandbox=""
                        tabIndex={-1}
                        srcDoc={`<!doctype html><html><body style="margin:16px;background:#f4f5f7">${sample(d.body_html)}</body></html>`}
                        style={{
                          position: 'absolute',
                          left: '50%',
                          top: 0,
                          width: 640,
                          height: 1000,
                          border: 0,
                          transform: 'translateX(-50%) scale(0.42)',
                          transformOrigin: 'top center',
                          pointerEvents: 'none',
                        }}
                      />
                    ) : (
                      <span className="m-4 block max-w-[85%] rounded-2xl rounded-bl-sm bg-white p-3 text-sm text-secondary-800 shadow-sm dark:bg-secondary-700 dark:text-secondary-100">
                        {sample(d.body_text || '')}
                      </span>
                    )}
                  </span>
                  <span className="block border-t border-secondary-200 p-3">
                    <span className="block text-sm font-semibold text-secondary-900">{d.name}</span>
                    {d.subject && (
                      <span className="block truncate text-xs text-secondary-500">{sample(d.subject)}</span>
                    )}
                    <span className="mt-2 inline-block text-xs font-semibold text-primary-700 group-hover:underline dark:text-primary-300">
                      Use this design →
                    </span>
                  </span>
                </button>
              </li>
            ))}
          </ul>
          {designs && designs.length === 0 && (
            <div className="mt-4 flex flex-col items-center gap-3 rounded-xl border-2 border-dashed border-secondary-200 p-8 text-center">
              <p className="text-base font-semibold text-secondary-900">No ready-made designs yet</p>
              <p className="max-w-sm text-sm text-secondary-600">
                Add them — welcome, newsletter, special offer, event invitation and more.
              </p>
              <Button
                leftIcon={<Sparkles className="h-4 w-4" />}
                isLoading={adding}
                onClick={() => void addReadyMade()}
              >
                Add ready-made designs
              </Button>
            </div>
          )}
        </>
      )}
    </Modal>
  );
}

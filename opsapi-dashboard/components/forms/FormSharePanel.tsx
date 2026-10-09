'use client';

/** The Share tab: the public link and its state. */

import React, { useMemo, useState } from 'react';
import qrcode from 'qrcode-generator';
import { Check, Code2, Copy, Download, ExternalLink, Globe, Link2, Lock, QrCode } from 'lucide-react';
import { Card, Input, Select } from '@/components/ui';
import { shareUrl, type Form } from '@/services/forms.service';

const PREFILLABLE = ['short_text', 'long_text', 'email', 'phone', 'url', 'number', 'date', 'time', 'single_select', 'radio'];

function CopyButton({ text, label = 'Copy' }: { text: string; label?: string }) {
  const [done, setDone] = useState(false);
  return (
    <button type="button" onClick={async () => { await navigator.clipboard.writeText(text); setDone(true); setTimeout(() => setDone(false), 1500); }}
      className="inline-flex h-10 shrink-0 items-center justify-center gap-1.5 rounded-lg border border-secondary-300 px-3 text-sm font-medium text-secondary-700 hover:bg-secondary-50">
      {done ? <Check className="h-4 w-4" /> : <Copy className="h-4 w-4" />}{done ? 'Copied' : label}
    </button>
  );
}

function download(name: string, href: string) {
  const a = document.createElement('a');
  a.href = href;
  a.download = name;
  a.click();
}

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
      <EmbedCard url={url} />
      <QrCard url={url} title={form.title} />
      <PrefillCard url={url} form={form} />
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

function EmbedCard({ url }: { url: string }) {
  const origin = useMemo(() => { try { return new URL(url).origin; } catch { return ''; } }, [url]);
  const snippet = `<div data-opsapi-form="${url}"></div>\n<script src="${origin}/forms-embed.js" async></script>`;
  return (
    <Card padding="md">
      <div className="flex items-start gap-3">
        <Code2 className="mt-0.5 h-5 w-5 text-secondary-500" aria-hidden="true" />
        <div className="min-w-0 flex-1">
          <h2 className="text-base font-semibold text-secondary-900">Put it on your website</h2>
          <p className="mt-0.5 text-sm text-secondary-600">Paste this where the form should appear. It fits its height to the form, and campaign tags on your page are recorded with each response.</p>
          <pre className="mt-3 overflow-x-auto rounded-lg bg-secondary-900 p-3 text-xs leading-relaxed text-secondary-50"><code>{snippet}</code></pre>
          <div className="mt-2"><CopyButton text={snippet} label="Copy code" /></div>
        </div>
      </div>
    </Card>
  );
}

function QrCard({ url, title }: { url: string; title: string }) {
  const svg = useMemo(() => {
    const qr = qrcode(0, 'M');
    qr.addData(url);
    qr.make();
    return qr.createSvgTag({ cellSize: 6, margin: 2, scalable: true });
  }, [url]);
  const file = title.replace(/[^\w-]+/g, '-').slice(0, 40) || 'form';
  const svgHref = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
  const png = () => {
    const img = new Image();
    img.onload = () => {
      const c = document.createElement('canvas');
      c.width = c.height = 1024;
      const ctx = c.getContext('2d');
      if (!ctx) return;
      ctx.fillStyle = '#fff';
      ctx.fillRect(0, 0, 1024, 1024);
      ctx.drawImage(img, 0, 0, 1024, 1024);
      download(`${file}-qr.png`, c.toDataURL('image/png'));
    };
    img.src = svgHref;
  };
  return (
    <Card padding="md">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center">
        <div className="h-36 w-36 shrink-0 rounded-lg border border-secondary-200 bg-white p-2 [&>svg]:h-full [&>svg]:w-full"
          role="img" aria-label="QR code of the form's link" dangerouslySetInnerHTML={{ __html: svg }} />
        <div>
          <h2 className="flex items-center gap-2 text-base font-semibold text-secondary-900"><QrCode className="h-5 w-5 text-secondary-500" />QR code</h2>
          <p className="mt-0.5 text-sm text-secondary-600">For posters, flyers, packaging and events: a phone camera opens the form.</p>
          <div className="mt-3 flex flex-wrap gap-2">
            <button type="button" onClick={png} className="inline-flex h-10 items-center gap-1.5 rounded-lg border border-secondary-300 px-3 text-sm font-medium text-secondary-700 hover:bg-secondary-50">
              <Download className="h-4 w-4" /> PNG
            </button>
            <button type="button" onClick={() => download(`${file}-qr.svg`, svgHref)} className="inline-flex h-10 items-center gap-1.5 rounded-lg border border-secondary-300 px-3 text-sm font-medium text-secondary-700 hover:bg-secondary-50">
              <Download className="h-4 w-4" /> SVG
            </button>
          </div>
        </div>
      </div>
    </Card>
  );
}

function PrefillCard({ url, form }: { url: string; form: Form }) {
  const fields = form.schema.fields.filter((f) => f.key && PREFILLABLE.includes(f.type));
  const [key, setKey] = useState(fields[0]?.key || '');
  const [value, setValue] = useState('');
  if (fields.length === 0) return null;
  const field = fields.find((f) => f.key === key) || fields[0];
  const link = value ? `${url}?${encodeURIComponent(field.key || '')}=${encodeURIComponent(value)}` : url;
  return (
    <Card padding="md">
      <h2 className="flex items-center gap-2 text-base font-semibold text-secondary-900"><Link2 className="h-5 w-5 text-secondary-500" />Prefilled link</h2>
      <p className="mt-0.5 text-sm text-secondary-600">Fill in an answer for people in advance, e.g. their email in a newsletter, or the event they&apos;re booking.</p>
      <div className="mt-3 grid gap-3 sm:grid-cols-2">
        <Select label="Question" value={field.key} onChange={(e) => { setKey(e.target.value); setValue(''); }}>
          {fields.map((f) => <option key={f.key} value={f.key}>{f.label}</option>)}
        </Select>
        {field.options?.length ? (
          <Select label="Answer" value={value} onChange={(e) => setValue(e.target.value)}>
            <option value="">Choose…</option>
            {field.options.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
          </Select>
        ) : (
          <Input label="Answer" value={value} onChange={(e) => setValue(e.target.value)} />
        )}
      </div>
      <div className="mt-3 flex gap-2">
        <input readOnly value={link} aria-label="Prefilled link" onFocus={(e) => e.target.select()}
          className="h-10 min-w-0 flex-1 rounded-lg border border-secondary-300 bg-secondary-50 px-3 font-mono text-xs text-secondary-800" />
        <CopyButton text={link} />
      </div>
    </Card>
  );
}

'use client';

import React, { useState } from 'react';
import { AlertTriangle, CheckCircle2, Plus, Trash2 } from 'lucide-react';
import { Button, Input, Textarea } from '@/components/ui';
import {
  SEO_DESC_MAX,
  SEO_DESC_MIN,
  SEO_TITLE_MAX,
  defaultSeoDescription,
  defaultSeoTitle,
  fillPrice,
  seoWarnings,
} from '@/lib/shop-seo';
import { SHOP_SEO_LOCALES, type ShopSeo, type ShopSeoBlock, type ShopSeoLocale } from '@/types/shop';

const LANG: Record<ShopSeoLocale, string> = { en: 'English (UK)', fr: 'Français (BE)', nl: 'Nederlands (BE)' };

function Count({ n, min, max }: { n: number; min: number; max: number }) {
  const ok = n >= min && n <= max;
  return (
    <span className={`text-xs tabular-nums ${ok ? 'text-success-600' : 'text-warning-700'}`} aria-live="polite">
      {n} / {min}–{max} characters
    </span>
  );
}

/**
 * Per-language search and page content: target keyword (staff only), title, description, intro and — for
 * products — "Who it's for" and questions. Live character counts and keyword checks.
 */
export function SeoContentEditor({
  value,
  onChange,
  kind,
  h1,
  lead,
  price,
}: {
  value: ShopSeo;
  onChange: (v: ShopSeo) => void;
  kind: 'product' | 'category';
  /** The page heading: the product or category name. */
  h1: string;
  /** What the default description starts with when there is no intro (short description). */
  lead?: string;
  /** The live "from" price as the shop shows it ("£17,805"), or null (quote only / categories). */
  price: string | null;
}) {
  const [loc, setLoc] = useState<ShopSeoLocale>('en');
  const block: ShopSeoBlock = value[loc] ?? {};
  const set = (patch: Partial<ShopSeoBlock>) => onChange({ ...value, [loc]: { ...block, ...patch } });

  const defTitle = defaultSeoTitle(block.target_keyword) || `${h1} | Workstation`;
  // Categories: the shop uses the intro (or description) as it is, trimmed to 160 characters.
  const catDesc = (block.intro || lead || h1).replace(/\s+/g, ' ').trim();
  const defDesc =
    kind === 'product'
      ? defaultSeoDescription(block.intro || lead || h1, price, loc)
      : catDesc.length > SEO_DESC_MAX
        ? `${catDesc.slice(0, SEO_DESC_MAX - 1).replace(/\s+\S*$/, '')}…`
        : catDesc;
  const title = block.title?.trim() || defTitle;
  const description = block.description?.trim() ? fillPrice(block.description.trim(), price) : defDesc;
  const warnings = seoWarnings({ block, h1, title, description });
  const faqs = block.faqs ?? [];

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap gap-1" role="tablist" aria-label="Language">
        {SHOP_SEO_LOCALES.map((l) => (
          <button
            key={l}
            type="button"
            role="tab"
            aria-selected={l === loc}
            onClick={() => setLoc(l)}
            className={`rounded-lg px-3 py-1.5 text-sm ${l === loc ? 'bg-primary-600 text-white' : 'bg-secondary-100 text-secondary-700 hover:bg-secondary-200'}`}
          >
            {LANG[l]}
          </button>
        ))}
      </div>

      <Input
        label="Target keyword (staff only)"
        id={`seo-${kind}-${loc}-kw`}
        value={block.target_keyword ?? ''}
        onChange={(e) => set({ target_keyword: e.target.value })}
        placeholder={loc === 'en' ? 'e.g. Threadripper PRO AI workstation UK' : ''}
        helperText="The phrase you want this page to rank for. Never shown on the shop or sent to it."
      />

      <div>
        <Input
          label="Page title"
          id={`seo-${kind}-${loc}-title`}
          value={block.title ?? ''}
          onChange={(e) => set({ title: e.target.value })}
          placeholder={defTitle}
          helperText="Empty = the default shown here. Main words first."
        />
        <div className="mt-1 flex flex-wrap items-center justify-between gap-2">
          <Count n={title.length} min={30} max={SEO_TITLE_MAX} />
          {!block.title?.trim() && block.target_keyword?.trim() && (
            <button type="button" className="text-xs text-primary-600 hover:underline" onClick={() => set({ title: defTitle })}>
              Use the default and edit it
            </button>
          )}
        </div>
      </div>

      <div>
        <Textarea
          label="Meta description"
          id={`seo-${kind}-${loc}-desc`}
          rows={3}
          value={block.description ?? ''}
          onChange={(e) => set({ description: e.target.value })}
          placeholder={defDesc}
          helperText={
            kind === 'product'
              ? 'Results first, then "From {price} ex VAT" and "UK". {price} becomes the live from-price. Empty = the default shown here.'
              : 'Results first, plain words. Empty = the default shown here.'
          }
        />
        <div className="mt-1 flex flex-wrap items-center justify-between gap-2">
          <Count n={description.length} min={SEO_DESC_MIN} max={SEO_DESC_MAX} />
          {!block.description?.trim() && (
            <button
              type="button"
              className="text-xs text-primary-600 hover:underline"
              onClick={() => set({ description: price ? defDesc.split(price).join('{price}') : defDesc })}
            >
              Use the default and edit it
            </button>
          )}
        </div>
      </div>

      <Textarea
        label={kind === 'product' ? 'Intro (shown above the configurator)' : 'Intro (shown above the products)'}
        id={`seo-${kind}-${loc}-intro`}
        rows={3}
        value={block.intro ?? ''}
        onChange={(e) => set({ intro: e.target.value })}
        helperText="2–4 short sentences on what this lets people do (e.g. “Fine-tune 70B models on one desk-side machine.”), not just the parts."
      />

      {kind === 'product' && (
        <>
          <Textarea
            label="Who it's for (one per line)"
            id={`seo-${kind}-${loc}-aud`}
            rows={3}
            value={(block.audience ?? []).join('\n')}
            onChange={(e) => set({ audience: e.target.value.split('\n').map((s) => s.trimStart()).slice(0, 8) })}
            helperText="e.g. University labs, AI start-ups, Render studios"
          />
          <div className="space-y-2">
            <p className="text-sm font-medium text-secondary-800">Product questions</p>
            <p className="text-xs text-secondary-500">
              The shop already answers lead time, warranty, VAT, delivery and returns from your settings and Terms of Sale. Add questions only this product needs.
            </p>
            {faqs.map((f, i) => (
              <div key={i} className="space-y-2 rounded-lg border border-secondary-200 p-3">
                <div className="flex items-start gap-2">
                  <div className="flex-1">
                    <Input
                      aria-label={`Question ${i + 1}`}
                      value={f.q}
                      placeholder="Question"
                      onChange={(e) => set({ faqs: faqs.map((x, j) => (j === i ? { ...x, q: e.target.value } : x)) })}
                    />
                  </div>
                  <Button type="button" size="sm" variant="ghost" aria-label="Remove question" onClick={() => set({ faqs: faqs.filter((_, j) => j !== i) })}>
                    <Trash2 className="h-4 w-4" />
                  </Button>
                </div>
                <Textarea
                  aria-label={`Answer ${i + 1}`}
                  rows={2}
                  value={f.a}
                  placeholder="Answer (plain words, real facts only)"
                  onChange={(e) => set({ faqs: faqs.map((x, j) => (j === i ? { ...x, a: e.target.value } : x)) })}
                />
              </div>
            ))}
            {faqs.length < 6 && (
              <Button type="button" size="sm" variant="ghost" leftIcon={<Plus className="h-4 w-4" />} onClick={() => set({ faqs: [...faqs, { q: '', a: '' }] })}>
                Add a question
              </Button>
            )}
          </div>
        </>
      )}

      <div className={`rounded-lg p-3 text-sm ${warnings.length ? 'bg-warning-50 text-warning-800' : 'bg-success-50 text-success-800'}`}>
        {warnings.length ? (
          <ul className="space-y-1">
            {warnings.map((w) => (
              <li key={w} className="flex gap-2">
                <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden /> {w}
              </li>
            ))}
          </ul>
        ) : (
          <p className="flex items-center gap-2">
            <CheckCircle2 className="h-4 w-4" aria-hidden /> Title, description and keyword look good for {LANG[loc]}.
          </p>
        )}
        <p className="mt-2 text-xs opacity-80">
          Search preview: <strong>{title}</strong> — {description}
        </p>
      </div>
    </div>
  );
}

/** Trim a seo document before saving (blank lines and empty questions dropped). */
export function cleanSeo(seo: ShopSeo): ShopSeo {
  const out: ShopSeo = {};
  for (const l of SHOP_SEO_LOCALES) {
    const b = seo[l];
    if (!b) continue;
    const c: ShopSeoBlock = {};
    for (const k of ['target_keyword', 'title', 'description', 'intro'] as const) {
      const v = b[k]?.trim();
      if (v) c[k] = v;
    }
    const aud = (b.audience ?? []).map((s) => s.trim()).filter(Boolean);
    if (aud.length) c.audience = aud;
    const faqs = (b.faqs ?? []).map((f) => ({ q: f.q.trim(), a: f.a.trim() })).filter((f) => f.q && f.a);
    if (faqs.length) c.faqs = faqs;
    if (Object.keys(c).length) out[l] = c;
  }
  return out;
}

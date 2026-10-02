'use client';

import React from 'react';
import { ArrowDown, ArrowUp, ImageOff, Plus, Trash2 } from 'lucide-react';
import { Button, Input, Textarea } from '@/components/ui';
import { cn } from '@/lib/utils';
import { shopAssetUrl } from '@/lib/shop';

let keySeq = 0;
/** Stable client-side React key for editor rows. */
export const newKey = (): string => `k${Date.now().toString(36)}${(keySeq++).toString(36)}`;

export function moveItem<T>(arr: T[], index: number, dir: -1 | 1): T[] {
  const j = index + dir;
  if (j < 0 || j >= arr.length) return arr;
  const out = arr.slice();
  [out[index], out[j]] = [out[j], out[index]];
  return out;
}

export function IconButton({
  label,
  onClick,
  disabled,
  danger,
  children,
}: {
  label: string;
  onClick: () => void;
  disabled?: boolean;
  danger?: boolean;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      aria-label={label}
      title={label}
      className={cn(
        'rounded-lg p-1.5 text-secondary-500 transition-colors disabled:cursor-not-allowed disabled:opacity-30',
        danger ? 'hover:bg-error-50 hover:text-error-500' : 'hover:bg-secondary-100 hover:text-secondary-800'
      )}
    >
      {children}
    </button>
  );
}

export function ReorderButtons({
  index,
  count,
  onMove,
}: {
  index: number;
  count: number;
  onMove: (dir: -1 | 1) => void;
}) {
  return (
    <>
      <IconButton label="Move up" onClick={() => onMove(-1)} disabled={index === 0}>
        <ArrowUp className="h-4 w-4" />
      </IconButton>
      <IconButton label="Move down" onClick={() => onMove(1)} disabled={index === count - 1}>
        <ArrowDown className="h-4 w-4" />
      </IconButton>
    </>
  );
}

// ============================================================
// Specs: ordered key/value editor
// ============================================================

export interface KvRow {
  key: string;
  k: string;
  v: string;
}

export function kvFromObject(obj: Record<string, unknown> | null | undefined): KvRow[] {
  return Object.entries(obj ?? {}).map(([k, v]) => ({ key: newKey(), k, v: v === null || v === undefined ? '' : String(v) }));
}

export function kvToObject(rows: KvRow[]): Record<string, string> {
  const out: Record<string, string> = {};
  for (const r of rows) {
    const k = r.k.trim();
    if (k) out[k] = r.v.trim();
  }
  return out;
}

export function KeyValueEditor({
  rows,
  onChange,
  keyPlaceholder = 'Label',
  valuePlaceholder = 'Value',
}: {
  rows: KvRow[];
  onChange: (rows: KvRow[]) => void;
  keyPlaceholder?: string;
  valuePlaceholder?: string;
}) {
  const dupes = new Set<string>();
  const seen = new Set<string>();
  rows.forEach((r) => {
    const k = r.k.trim();
    if (k && seen.has(k)) dupes.add(k);
    seen.add(k);
  });
  const update = (i: number, patch: Partial<KvRow>) => onChange(rows.map((r, j) => (j === i ? { ...r, ...patch } : r)));
  return (
    <div className="space-y-2">
      {rows.length === 0 && <p className="text-sm text-secondary-500">No entries.</p>}
      {rows.map((r, i) => (
        <div key={r.key} className="flex items-start gap-2">
          <div className="w-2/5">
            <Input
              aria-label={`${keyPlaceholder} ${i + 1}`}
              placeholder={keyPlaceholder}
              value={r.k}
              onChange={(e) => update(i, { k: e.target.value })}
              error={dupes.has(r.k.trim()) ? 'Duplicate' : undefined}
            />
          </div>
          <div className="flex-1">
            <Input aria-label={`${valuePlaceholder} ${i + 1}`} placeholder={valuePlaceholder} value={r.v} onChange={(e) => update(i, { v: e.target.value })} />
          </div>
          <div className="flex shrink-0 items-center pt-1.5">
            <ReorderButtons index={i} count={rows.length} onMove={(d) => onChange(moveItem(rows, i, d))} />
            <IconButton label="Remove" danger onClick={() => onChange(rows.filter((_, j) => j !== i))}>
              <Trash2 className="h-4 w-4" />
            </IconButton>
          </div>
        </div>
      ))}
      <Button type="button" variant="ghost" size="sm" leftIcon={<Plus className="h-4 w-4" />} onClick={() => onChange([...rows, { key: newKey(), k: '', v: '' }])}>
        Add row
      </Button>
    </div>
  );
}

// ============================================================
// JSON object field with validation
// ============================================================

/** Parse a JSON object; returns [value, error]. Empty text → {}. */
export function parseJsonObject(text: string): [Record<string, unknown> | null, string | null] {
  const t = text.trim();
  if (!t) return [{}, null];
  try {
    const v = JSON.parse(t);
    if (v === null || typeof v !== 'object' || Array.isArray(v)) return [null, 'Must be a JSON object, e.g. {"gpu_slots": 4}'];
    return [v as Record<string, unknown>, null];
  } catch (e) {
    return [null, (e as Error).message || 'Invalid JSON'];
  }
}

export const prettyJson = (v: unknown): string =>
  v && typeof v === 'object' && Object.keys(v as object).length ? JSON.stringify(v, null, 2) : '';

export function JsonObjectField({
  label,
  value,
  onChange,
  rows = 6,
  helperText,
  placeholder = '{\n  "gpu_slots": 4,\n  "psu_watts": 2000\n}',
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  rows?: number;
  helperText?: string;
  placeholder?: string;
}) {
  const [, error] = parseJsonObject(value);
  const format = () => {
    const [obj] = parseJsonObject(value);
    if (obj) onChange(prettyJson(obj));
  };
  return (
    <div>
      <Textarea
        label={label}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        rows={rows}
        spellCheck={false}
        className="font-mono text-xs"
        placeholder={placeholder}
        error={error ?? undefined}
        helperText={helperText}
      />
      {!error && value.trim() && (
        <button type="button" onClick={format} className="mt-1 text-xs text-primary-600 hover:underline">
          Format JSON
        </button>
      )}
    </div>
  );
}

// ============================================================
// Image URL list
// ============================================================

export function ImageListEditor({ urls, onChange }: { urls: string[]; onChange: (urls: string[]) => void }) {
  const isUrl = (u: string) => !u.trim() || /^(https?:\/\/|\/)/i.test(u.trim());
  return (
    <div className="space-y-2">
      {urls.length === 0 && <p className="text-sm text-secondary-500">No images. The first image is the primary image.</p>}
      {urls.map((u, i) => (
        <div key={i} className="flex items-start gap-3">
          <div className="flex h-12 w-12 shrink-0 items-center justify-center overflow-hidden rounded-lg border border-secondary-200 bg-secondary-50">
            {u.trim() && isUrl(u) ? (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={shopAssetUrl(u)} alt="" className="h-full w-full object-cover" />
            ) : (
              <ImageOff className="h-5 w-5 text-secondary-300" aria-hidden="true" />
            )}
          </div>
          <div className="flex-1">
            <Input
              aria-label={`Image URL ${i + 1}`}
              placeholder="https://…/image.webp"
              value={u}
              onChange={(e) => onChange(urls.map((x, j) => (j === i ? e.target.value : x)))}
              error={isUrl(u) ? undefined : 'Must be an http(s) URL or a /path'}
            />
          </div>
          <div className="flex shrink-0 items-center pt-1.5">
            <ReorderButtons index={i} count={urls.length} onMove={(d) => onChange(moveItem(urls, i, d))} />
            <IconButton label="Remove image" danger onClick={() => onChange(urls.filter((_, j) => j !== i))}>
              <Trash2 className="h-4 w-4" />
            </IconButton>
          </div>
        </div>
      ))}
      <Button type="button" variant="ghost" size="sm" leftIcon={<Plus className="h-4 w-4" />} onClick={() => onChange([...urls, ''])}>
        Add image URL
      </Button>
    </div>
  );
}

/** Checkbox with a label, matching dashboard form styling. */
export function CheckboxField({
  label,
  checked,
  onChange,
  description,
}: {
  label: string;
  checked: boolean;
  onChange: (v: boolean) => void;
  description?: string;
}) {
  return (
    <label className="flex cursor-pointer items-start gap-2.5 text-sm">
      <input
        type="checkbox"
        checked={checked}
        onChange={(e) => onChange(e.target.checked)}
        className="mt-0.5 h-4 w-4 rounded border-secondary-300 text-primary-600 focus:ring-primary-500"
      />
      <span>
        <span className="font-medium text-secondary-800">{label}</span>
        {description && <span className="block text-xs text-secondary-500">{description}</span>}
      </span>
    </label>
  );
}

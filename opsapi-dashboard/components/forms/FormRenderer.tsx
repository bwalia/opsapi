'use client';

/**
 * Renders a form's fields: the builder's preview and the public page use this
 * same component, so what the admin sees is what visitors get. Controlled:
 * the parent owns `values` and `errors` (the server validates every answer;
 * the checks here are only for convenience).
 */

import React, { useRef, useState } from 'react';
import { FileUp, Loader2, Paperclip, Star, X } from 'lucide-react';
import { cn } from '@/lib/utils';
import type { FormField } from '@/services/forms.service';
import type { UploadedFile } from '@/services/forms-public.service';

/** Stores one file for a file question (the public page passes it; the preview doesn't). */
export type UploadFn = (fieldKey: string, file: File) => Promise<UploadedFile>;

// The form's brand colour (FormRunner sets --form-accent), else the app's.
const ACCENT = 'var(--form-accent,var(--color-primary-500))';
const SELECTED = 'border-[var(--form-accent,var(--color-primary-500))] bg-[color-mix(in_srgb,var(--form-accent,var(--color-primary-500))_6%,transparent)]';

export type Answers = Record<string, unknown>;

const control =
  'w-full rounded-lg border bg-surface px-3.5 py-2.5 text-[15px] text-secondary-900 placeholder:text-secondary-400 ' +
  'transition-colors focus:outline-none focus:ring-2 focus:ring-[color-mix(in_srgb,var(--form-accent,var(--color-primary-500))_25%,transparent)] focus:border-[var(--form-accent,var(--color-primary-500))] ' +
  'disabled:cursor-not-allowed disabled:bg-secondary-50';

function border(error?: string) {
  return error ? 'border-error-500' : 'border-secondary-300 hover:border-secondary-400';
}

function str(v: unknown): string {
  return typeof v === 'string' || typeof v === 'number' ? String(v) : '';
}

/** Client-side required check (the server re-checks everything). */
export function missingRequired(fields: FormField[], values: Answers, shown?: Set<string>): Record<string, string> {
  const errors: Record<string, string> = {};
  for (const f of fields) {
    if (!f.required || !f.key || ['heading', 'paragraph', 'hidden', 'page_break'].includes(f.type)) continue;
    if (shown && !shown.has(f.key)) continue;
    const v = values[f.key];
    let empty = v === undefined || v === null || v === '' || (Array.isArray(v) && v.length === 0);
    if (f.type === 'name') empty = !str((v as { first?: string })?.first).trim();
    if (f.type === 'address') empty = !str((v as { line1?: string })?.line1).trim();
    if (f.type === 'consent') empty = v !== true;
    if (empty) errors[f.key] = f.type === 'consent' ? 'Please tick this box.' : 'This field is required.';
  }
  return errors;
}

interface Props {
  fields: FormField[];
  values: Answers;
  errors?: Record<string, string>;
  onChange: (key: string, value: unknown) => void;
  disabled?: boolean;
  /** Prefix for element ids (two renderers on one page must not clash). */
  idPrefix?: string;
  /** Keys shown by conditional logic (components/forms/logic.ts); all when absent. */
  shown?: Set<string>;
  upload?: UploadFn;
}

export default function FormRenderer({ fields, values, errors = {}, onChange, disabled, idPrefix = 'f', shown, upload }: Props) {
  return (
    <div className="grid grid-cols-1 gap-x-4 gap-y-6 sm:grid-cols-2">
      {fields.map((f, i) => {
        if (f.type === 'hidden' || f.type === 'page_break') return null;
        if (shown && !shown.has(f.key || `idx-${i}`)) return null;
        const full = f.width !== 'half' || f.type === 'heading' || f.type === 'paragraph';
        return (
          <div key={f.key || i} className={cn(full && 'sm:col-span-2')}>
            <Field field={f} value={f.key ? values[f.key] : undefined} error={f.key ? errors[f.key] : undefined}
              onChange={(v) => f.key && onChange(f.key, v)} disabled={disabled} id={`${idPrefix}-${f.key || i}`}
              upload={upload} />
          </div>
        );
      })}
    </div>
  );
}

function Label({ htmlFor, field, as = 'label' }: { htmlFor?: string; field: FormField; as?: 'label' | 'legend' }) {
  const Tag = as;
  return (
    <Tag htmlFor={as === 'label' ? htmlFor : undefined} className="mb-1.5 block text-sm font-medium text-secondary-800">
      {field.label}
      {field.required && <span className="ml-0.5 text-error-500" aria-hidden="true">*</span>}
      {field.required && <span className="sr-only"> (required)</span>}
    </Tag>
  );
}

function Help({ id, field, error }: { id: string; field: FormField; error?: string }) {
  return (
    <>
      {field.help && !error && <p id={`${id}-help`} className="mt-1.5 text-xs text-secondary-500">{field.help}</p>}
      {error && <p id={`${id}-error`} role="alert" className="mt-1.5 text-xs font-medium text-error-600">{error}</p>}
    </>
  );
}

function describedBy(id: string, field: FormField, error?: string) {
  return error ? `${id}-error` : field.help ? `${id}-help` : undefined;
}

function Field({ field: f, value, error, onChange, disabled, id, upload }: {
  field: FormField; value: unknown; error?: string; onChange: (v: unknown) => void; disabled?: boolean; id: string;
  upload?: UploadFn;
}) {
  const aria = { 'aria-invalid': error ? true : undefined, 'aria-describedby': describedBy(id, f, error) };
  const max = f.validation?.max_length;

  switch (f.type) {
    case 'heading':
      return <h2 className="border-b border-secondary-200 pb-2 pt-2 text-lg font-semibold text-secondary-900">{f.label}</h2>;
    case 'paragraph':
      return <p className="whitespace-pre-line text-sm leading-relaxed text-secondary-600">{f.text}</p>;

    case 'long_text':
      return (
        <div>
          <Label htmlFor={id} field={f} />
          <textarea id={id} rows={4} value={str(value)} maxLength={max} placeholder={f.placeholder} disabled={disabled}
            onChange={(e) => onChange(e.target.value)} className={cn(control, border(error), 'resize-y')} {...aria} />
          <Help id={id} field={f} error={error} />
        </div>
      );

    case 'single_select':
      return (
        <div>
          <Label htmlFor={id} field={f} />
          <select id={id} value={str(value)} disabled={disabled} onChange={(e) => onChange(e.target.value)}
            className={cn(control, border(error))} {...aria}>
            <option value="">Choose…</option>
            {(f.options || []).map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
          </select>
          <Help id={id} field={f} error={error} />
        </div>
      );

    case 'radio':
    case 'boolean': {
      const options = f.type === 'boolean'
        ? [{ value: 'true', label: 'Yes' }, { value: 'false', label: 'No' }]
        : f.options || [];
      const current = f.type === 'boolean' ? (value === true ? 'true' : value === false ? 'false' : '') : str(value);
      return (
        <fieldset aria-describedby={describedBy(id, f, error)}>
          <Label field={f} as="legend" />
          <div className={cn('flex gap-2', f.type === 'boolean' ? 'flex-row' : 'flex-col')}>
            {options.map((o) => (
              <label key={o.value} className={cn(
                'flex min-h-11 cursor-pointer items-center gap-3 rounded-lg border px-3.5 py-2.5 text-[15px] transition-colors',
                current === o.value ? SELECTED : 'border-secondary-300 hover:border-secondary-400',
                f.type === 'boolean' && 'flex-1 justify-center')}>
                <input type="radio" name={id} value={o.value} checked={current === o.value} disabled={disabled}
                  onChange={() => onChange(f.type === 'boolean' ? o.value === 'true' : o.value)}
                  className="h-4 w-4" style={{ accentColor: ACCENT }} />
                <span className="text-secondary-800">{o.label}</span>
              </label>
            ))}
          </div>
          <Help id={id} field={f} error={error} />
        </fieldset>
      );
    }

    case 'multi_select': {
      const selected = Array.isArray(value) ? (value as string[]) : [];
      return (
        <fieldset aria-describedby={describedBy(id, f, error)}>
          <Label field={f} as="legend" />
          <div className="flex flex-col gap-2">
            {(f.options || []).map((o) => {
              const on = selected.includes(o.value);
              return (
                <label key={o.value} className={cn(
                  'flex min-h-11 cursor-pointer items-center gap-3 rounded-lg border px-3.5 py-2.5 text-[15px] transition-colors',
                  on ? SELECTED : 'border-secondary-300 hover:border-secondary-400')}>
                  <input type="checkbox" checked={on} disabled={disabled} className="h-4 w-4" style={{ accentColor: ACCENT }}
                    onChange={() => onChange(on ? selected.filter((v) => v !== o.value) : [...selected, o.value])} />
                  <span className="text-secondary-800">{o.label}</span>
                </label>
              );
            })}
          </div>
          <Help id={id} field={f} error={error} />
        </fieldset>
      );
    }

    case 'rating': {
      const scale = f.scale === 10 ? 10 : 5;
      const n = Number(value) || 0;
      return (
        <fieldset aria-describedby={describedBy(id, f, error)}>
          <Label field={f} as="legend" />
          <div role="radiogroup" aria-label={f.label} className="flex flex-wrap gap-1">
            {Array.from({ length: scale }, (_, i) => i + 1).map((k) => (
              <button key={k} type="button" role="radio" aria-checked={n === k} aria-label={`${k} of ${scale}`}
                disabled={disabled} onClick={() => onChange(k)}
                className={cn('flex h-11 w-11 items-center justify-center rounded-lg transition-colors',
                  'focus:outline-none focus:ring-2 focus:ring-primary-500/30',
                  k <= n ? 'text-warning-500' : 'text-secondary-300 hover:text-secondary-400')}>
                {scale === 10
                  ? <span className={cn('text-sm font-semibold', k <= n ? 'text-[var(--form-accent,var(--color-primary-600))]' : 'text-secondary-500')}>{k}</span>
                  : <Star className="h-7 w-7" fill={k <= n ? 'currentColor' : 'none'} />}
              </button>
            ))}
          </div>
          <Help id={id} field={f} error={error} />
        </fieldset>
      );
    }

    case 'file_upload':
      return <FileField field={f} value={value} error={error} onChange={onChange} disabled={disabled} id={id} upload={upload} />;

    case 'consent':
      return (
        <div>
          <label className={cn('flex cursor-pointer items-start gap-3 rounded-lg border px-3.5 py-3',
            error ? 'border-error-500' : 'border-secondary-200')}>
            <input id={id} type="checkbox" checked={value === true} disabled={disabled}
              onChange={(e) => onChange(e.target.checked)} className="mt-0.5 h-4 w-4 shrink-0" style={{ accentColor: ACCENT }} {...aria} />
            <span className="text-sm text-secondary-700">
              <span className="font-medium text-secondary-900">{f.label}</span>
              {f.required && <span className="ml-0.5 text-error-500" aria-hidden="true">*</span>}
              <span className="mt-0.5 block whitespace-pre-line">{f.text}</span>
            </span>
          </label>
          <Help id={id} field={f} error={error} />
        </div>
      );

    case 'name': {
      const v = (value as { first?: string; last?: string }) || {};
      return (
        <fieldset aria-describedby={describedBy(id, f, error)}>
          <Label field={f} as="legend" />
          <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
            <input aria-label="First name" autoComplete="given-name" placeholder="First name" value={v.first || ''}
              disabled={disabled} onChange={(e) => onChange({ ...v, first: e.target.value })}
              className={cn(control, border(error))} aria-invalid={error ? true : undefined} />
            <input aria-label="Last name" autoComplete="family-name" placeholder="Last name" value={v.last || ''}
              disabled={disabled} onChange={(e) => onChange({ ...v, last: e.target.value })}
              className={cn(control, border(error))} />
          </div>
          <Help id={id} field={f} error={error} />
        </fieldset>
      );
    }

    case 'address': {
      const v = (value as Record<string, string>) || {};
      const part = (k: string, label: string, auto: string, cls = '') => (
        <input aria-label={label} placeholder={label} autoComplete={auto} value={v[k] || ''} disabled={disabled}
          onChange={(e) => onChange({ ...v, [k]: e.target.value })} className={cn(control, border(error), cls)} />
      );
      return (
        <fieldset aria-describedby={describedBy(id, f, error)}>
          <Label field={f} as="legend" />
          <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
            {part('line1', 'Address line 1', 'address-line1', 'sm:col-span-2')}
            {part('line2', 'Address line 2', 'address-line2', 'sm:col-span-2')}
            {part('city', 'Town or city', 'address-level2')}
            {part('postcode', 'Postcode', 'postal-code')}
            {part('country', 'Country', 'country-name', 'sm:col-span-2')}
          </div>
          <Help id={id} field={f} error={error} />
        </fieldset>
      );
    }

    default: {
      const input: Record<string, { type: string; autoComplete?: string; inputMode?: 'decimal' | 'tel' | 'email' | 'url' }> = {
        short_text: { type: 'text' },
        email: { type: 'email', autoComplete: 'email', inputMode: 'email' },
        phone: { type: 'tel', autoComplete: 'tel', inputMode: 'tel' },
        url: { type: 'url', autoComplete: 'url', inputMode: 'url' },
        // No native min/max: the browser would block submit before the server can explain.
        number: { type: 'text', inputMode: 'decimal' },
        date: { type: 'date' },
        time: { type: 'time' },
      };
      const cfg = input[f.type] || { type: 'text' };
      return (
        <div>
          <Label htmlFor={id} field={f} />
          <input id={id} type={cfg.type} autoComplete={cfg.autoComplete} inputMode={cfg.inputMode}
            value={str(value)} maxLength={max} placeholder={f.placeholder} disabled={disabled}
            onChange={(e) => onChange(e.target.value)} className={cn(control, border(error))} {...aria} />
          <Help id={id} field={f} error={error} />
        </div>
      );
    }
  }
}

const ACCEPT: Record<string, string> = {
  images: 'image/jpeg,image/png,image/gif,image/webp,.heic,.heif',
  documents: '.pdf,.doc,.docx,.xls,.xlsx,.ppt,.pptx,.txt,.csv',
};

function size(bytes: number) {
  return bytes >= 1024 * 1024 ? `${(bytes / 1024 / 1024).toFixed(1)} MB` : `${Math.max(1, Math.round(bytes / 1024))} KB`;
}

/** A file question: each file uploads when picked; the answer is the stored files. */
function FileField({ field: f, value, error, onChange, disabled, id, upload }: {
  field: FormField; value: unknown; error?: string; onChange: (v: unknown) => void; disabled?: boolean; id: string;
  upload?: UploadFn;
}) {
  const files = Array.isArray(value) ? (value as UploadedFile[]) : [];
  const [busy, setBusy] = useState(0);
  const [problem, setProblem] = useState('');
  const input = useRef<HTMLInputElement>(null);
  const max = f.max_files || 1;
  const limit = (f.max_size_mb || 10) * 1024 * 1024;
  const accept = f.accept === 'images' ? ACCEPT.images : f.accept === 'documents' ? ACCEPT.documents
    : `${ACCEPT.images},${ACCEPT.documents}`;

  const pick = async (list: FileList | null) => {
    if (!list || !upload || !f.key) return;
    setProblem('');
    const chosen = Array.from(list).slice(0, Math.max(0, max - files.length));
    let next = files;
    for (const file of chosen) {
      if (file.size > limit) {
        setProblem(`${file.name} is larger than ${f.max_size_mb || 10} MB.`);
        continue;
      }
      setBusy((b) => b + 1);
      try {
        const stored = await upload(f.key, file);
        next = [...next, stored];
        onChange(next);
      } catch (e) {
        setProblem((e as Error).message || `${file.name} couldn't be uploaded.`);
      } finally {
        setBusy((b) => b - 1);
      }
    }
    if (input.current) input.current.value = '';
  };

  const shownError = error || problem;
  return (
    <div>
      <Label htmlFor={id} field={f} />
      {files.length > 0 && (
        <ul className="mb-2 space-y-1.5">
          {files.map((file) => (
            <li key={file.id} className="flex items-center gap-2 rounded-lg border border-secondary-200 px-3 py-2 text-sm">
              <Paperclip className="h-4 w-4 shrink-0 text-secondary-400" aria-hidden="true" />
              <span className="min-w-0 flex-1 truncate text-secondary-800">{file.name}</span>
              <span className="shrink-0 text-xs text-secondary-500">{size(file.size)}</span>
              <button type="button" disabled={disabled} aria-label={`Remove ${file.name}`}
                onClick={() => onChange(files.filter((x) => x.id !== file.id))}
                className="inline-flex h-8 w-8 items-center justify-center rounded-md text-secondary-500 hover:bg-secondary-100">
                <X className="h-4 w-4" />
              </button>
            </li>
          ))}
        </ul>
      )}
      {files.length < max && (
        <label htmlFor={id} className={cn('flex min-h-[88px] cursor-pointer flex-col items-center justify-center gap-1.5 rounded-lg border-2 border-dashed px-4 py-4 text-center text-sm transition-colors',
          shownError ? 'border-error-500' : 'border-secondary-300 hover:border-secondary-400',
          (!upload || disabled) && 'cursor-not-allowed opacity-60')}>
          {busy > 0 ? <Loader2 className="h-5 w-5 animate-spin text-secondary-400" /> : <FileUp className="h-5 w-5 text-secondary-400" aria-hidden="true" />}
          <span className="font-medium text-secondary-700">{busy > 0 ? 'Uploading…' : max > 1 ? 'Choose files' : 'Choose a file'}</span>
          <span className="text-xs text-secondary-500">
            {f.accept === 'images' ? 'Images' : f.accept === 'documents' ? 'Documents' : 'Images or documents'}
            {` up to ${f.max_size_mb || 10} MB`}{max > 1 ? ` · up to ${max} files` : ''}
            {!upload && ' · uploads work on the live form'}
          </span>
          <input ref={input} id={id} type="file" className="sr-only" accept={accept} multiple={max - files.length > 1}
            disabled={!upload || disabled || busy > 0} onChange={(e) => pick(e.target.files)}
            aria-invalid={shownError ? true : undefined} aria-describedby={describedBy(id, f, shownError)} />
        </label>
      )}
      <Help id={id} field={f} error={shownError} />
    </div>
  );
}

'use client';

/**
 * Renders a form's fields: the builder's preview and the public page use this
 * same component, so what the admin sees is what visitors get. Controlled:
 * the parent owns `values` and `errors` (the server validates every answer;
 * the checks here are only for convenience).
 */

import React from 'react';
import { Star } from 'lucide-react';
import { cn } from '@/lib/utils';
import type { FormField } from '@/services/forms.service';

export type Answers = Record<string, unknown>;

const control =
  'w-full rounded-lg border bg-surface px-3.5 py-2.5 text-[15px] text-secondary-900 placeholder:text-secondary-400 ' +
  'transition-colors focus:outline-none focus:ring-2 focus:ring-primary-500/25 focus:border-primary-500 ' +
  'disabled:cursor-not-allowed disabled:bg-secondary-50';

function border(error?: string) {
  return error ? 'border-error-500' : 'border-secondary-300 hover:border-secondary-400';
}

function str(v: unknown): string {
  return typeof v === 'string' || typeof v === 'number' ? String(v) : '';
}

/** Client-side required check (the server re-checks everything). */
export function missingRequired(fields: FormField[], values: Answers): Record<string, string> {
  const errors: Record<string, string> = {};
  for (const f of fields) {
    if (!f.required || !f.key || f.type === 'heading' || f.type === 'paragraph' || f.type === 'hidden') continue;
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
}

export default function FormRenderer({ fields, values, errors = {}, onChange, disabled, idPrefix = 'f' }: Props) {
  return (
    <div className="grid grid-cols-1 gap-x-4 gap-y-6 sm:grid-cols-2">
      {fields.map((f, i) => {
        if (f.type === 'hidden') return null;
        const full = f.width !== 'half' || f.type === 'heading' || f.type === 'paragraph';
        return (
          <div key={f.key || i} className={cn(full && 'sm:col-span-2')}>
            <Field field={f} value={f.key ? values[f.key] : undefined} error={f.key ? errors[f.key] : undefined}
              onChange={(v) => f.key && onChange(f.key, v)} disabled={disabled} id={`${idPrefix}-${f.key || i}`} />
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

function Field({ field: f, value, error, onChange, disabled, id }: {
  field: FormField; value: unknown; error?: string; onChange: (v: unknown) => void; disabled?: boolean; id: string;
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
                current === o.value ? 'border-primary-500 bg-primary-500/5' : 'border-secondary-300 hover:border-secondary-400',
                f.type === 'boolean' && 'flex-1 justify-center')}>
                <input type="radio" name={id} value={o.value} checked={current === o.value} disabled={disabled}
                  onChange={() => onChange(f.type === 'boolean' ? o.value === 'true' : o.value)}
                  className="h-4 w-4 accent-primary-500" />
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
                  on ? 'border-primary-500 bg-primary-500/5' : 'border-secondary-300 hover:border-secondary-400')}>
                  <input type="checkbox" checked={on} disabled={disabled} className="h-4 w-4 accent-primary-500"
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
                  ? <span className={cn('text-sm font-semibold', k <= n ? 'text-primary-600' : 'text-secondary-500')}>{k}</span>
                  : <Star className="h-7 w-7" fill={k <= n ? 'currentColor' : 'none'} />}
              </button>
            ))}
          </div>
          <Help id={id} field={f} error={error} />
        </fieldset>
      );
    }

    case 'consent':
      return (
        <div>
          <label className={cn('flex cursor-pointer items-start gap-3 rounded-lg border px-3.5 py-3',
            error ? 'border-error-500' : 'border-secondary-200')}>
            <input id={id} type="checkbox" checked={value === true} disabled={disabled}
              onChange={(e) => onChange(e.target.checked)} className="mt-0.5 h-4 w-4 shrink-0 accent-primary-500" {...aria} />
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

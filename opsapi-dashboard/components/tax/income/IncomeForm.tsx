'use client';

/**
 * Renders an income type's field schema as an accessible form. The schema is data
 * (Tax → Income types), so this one component draws every income type — and the
 * administrator's live preview. Server-side validation is the source of truth
 * (lib/income-types validate_values); errors come back keyed by field and are
 * shown next to the field they belong to.
 */

import React from 'react';
import { FileUp, Info } from 'lucide-react';
import { formatCurrency } from '@/lib/utils';
import type { FieldSchema, IncomeField, Suggestion, ValueSource, Values } from '@/services/my-income.service';

const gbp = (n: number) => formatCurrency(n, 'GBP', 'en-GB');

export function isVisible(field: IncomeField, values: Values): boolean {
  const s = field.show_if;
  if (!s) return true;
  const v = values[s.field];
  if (s.equals === undefined || s.equals === null) return v === true || v === 'true';
  return v === s.equals || String(v) === String(s.equals);
}

const inputCls =
  'block w-full rounded-lg border bg-surface px-3 py-2 text-secondary-900 placeholder:text-secondary-400 ' +
  'focus:outline-none focus:ring-2 focus:ring-primary-500/30 disabled:cursor-not-allowed disabled:opacity-60';

interface FieldProps {
  field: IncomeField;
  id: string;
  value: Values[string] | undefined;
  error?: string;
  source?: ValueSource;
  suggestion?: Suggestion;
  disabled?: boolean;
  onChange: (value: Values[string], source: ValueSource) => void;
}

function FieldControl({ field, id, value, error, source, suggestion, disabled, onChange }: FieldProps) {
  const describedBy = [error ? `${id}-error` : '', field.help ? `${id}-help` : ''].filter(Boolean).join(' ') || undefined;
  const border = error ? 'border-red-400' : 'border-secondary-300';
  const str = value === null || value === undefined ? '' : String(value);
  const numeric = field.type === 'currency' || field.type === 'number' || field.type === 'percentage';
  const showSuggestion =
    !!suggestion && !disabled && (str === '' || Number(str.replace(/[£,\s]/g, '')) !== suggestion.amount);

  let control: React.ReactNode;
  if (field.type === 'boolean') {
    const current = value === true || value === 'true' ? 'yes' : value === false || value === 'false' ? 'no' : '';
    control = (
      <div role="radiogroup" aria-labelledby={`${id}-label`} aria-describedby={describedBy} className="flex gap-2">
        {(['yes', 'no'] as const).map((opt) => (
          <button
            key={opt}
            type="button"
            role="radio"
            aria-checked={current === opt}
            disabled={disabled}
            onClick={() => onChange(opt === 'yes', 'manual')}
            className={`min-w-[4.5rem] rounded-lg border px-4 py-2 text-sm font-medium transition-colors ${
              current === opt
                ? 'border-primary-500 bg-primary-50 text-primary-700'
                : 'border-secondary-300 bg-surface text-secondary-700 hover:border-primary-300'
            }`}
          >
            {opt === 'yes' ? 'Yes' : 'No'}
          </button>
        ))}
      </div>
    );
  } else if (field.type === 'select') {
    control = (
      <select
        id={id}
        value={str}
        disabled={disabled}
        aria-invalid={error ? 'true' : undefined}
        aria-describedby={describedBy}
        onChange={(e) => onChange(e.target.value === '' ? null : e.target.value, 'manual')}
        className={`${inputCls} ${border}`}
      >
        <option value="">Choose…</option>
        {(field.options || []).map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
    );
  } else {
    const prefix = field.type === 'currency' ? '£' : null;
    const suffix = field.type === 'percentage' ? '%' : null;
    control = (
      <div className="relative">
        {prefix && (
          <span className="pointer-events-none absolute inset-y-0 left-3 flex items-center text-secondary-500" aria-hidden="true">
            {prefix}
          </span>
        )}
        <input
          id={id}
          type={field.type === 'date' ? 'date' : 'text'}
          inputMode={numeric ? 'decimal' : undefined}
          autoComplete="off"
          value={str}
          placeholder={field.placeholder || (field.type === 'currency' ? '0.00' : undefined)}
          disabled={disabled}
          aria-invalid={error ? 'true' : undefined}
          aria-describedby={describedBy}
          aria-required={field.required ? 'true' : undefined}
          onChange={(e) => onChange(e.target.value, 'manual')}
          className={`${inputCls} ${border} ${prefix ? 'pl-7' : ''} ${suffix ? 'pr-8' : ''} ${numeric ? 'tabular-nums' : ''}`}
        />
        {suffix && (
          <span className="pointer-events-none absolute inset-y-0 right-3 flex items-center text-secondary-500" aria-hidden="true">
            {suffix}
          </span>
        )}
      </div>
    );
  }

  return (
    <div className="space-y-1.5">
      <div className="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
        <label id={`${id}-label`} htmlFor={field.type === 'boolean' ? undefined : id} className="text-sm font-medium text-secondary-800">
          {field.label}
          {field.required && <span className="ml-1 text-secondary-400">(needed)</span>}
        </label>
        <span className="flex items-center gap-2">
          {source === 'statements' && (
            <span className="inline-flex items-center gap-1 rounded-full bg-blue-50 px-2 py-0.5 text-xs font-medium text-blue-700">
              <FileUp className="h-3 w-3" aria-hidden="true" /> From your statements
            </span>
          )}
          {field.hmrc_box && <span className="text-xs text-secondary-400">{field.hmrc_box}</span>}
        </span>
      </div>
      {control}
      {field.help && (
        <p id={`${id}-help`} className="text-xs leading-relaxed text-secondary-500">
          {field.help}
        </p>
      )}
      {showSuggestion && suggestion && (
        <div className="flex flex-wrap items-center gap-2 rounded-lg bg-blue-50 px-3 py-2 text-xs text-blue-800">
          <span>
            Your bank statements show <strong>{gbp(suggestion.amount)}</strong> ({suggestion.count} transaction
            {suggestion.count === 1 ? '' : 's'}) for this.
          </span>
          <button
            type="button"
            onClick={() => onChange(suggestion.amount, 'statements')}
            className="rounded-md bg-white px-2 py-1 font-medium text-blue-700 ring-1 ring-blue-200 hover:bg-blue-100"
          >
            Use this figure
          </button>
        </div>
      )}
      {error && (
        <p id={`${id}-error`} role="alert" className="text-sm text-red-600">
          {error}
        </p>
      )}
    </div>
  );
}

export interface IncomeFormProps {
  schema: FieldSchema;
  values: Values;
  onChange: (key: string, value: Values[string], source: ValueSource) => void;
  errors?: Record<string, string>;
  sources?: Record<string, ValueSource>;
  suggestions?: Record<string, Suggestion>;
  disabled?: boolean;
  idPrefix?: string;
}

export default function IncomeForm({
  schema,
  values,
  onChange,
  errors = {},
  sources = {},
  suggestions = {},
  disabled,
  idPrefix = 'inc',
}: IncomeFormProps) {
  if (!schema.sections?.length) {
    return (
      <p className="flex items-center gap-2 rounded-lg bg-secondary-50 p-4 text-sm text-secondary-600">
        <Info className="h-4 w-4" aria-hidden="true" /> This income type has no form yet. An administrator can add one
        under Tax → Income types.
      </p>
    );
  }
  return (
    <div className="space-y-6">
      {schema.sections.map((section) => {
        const fields = section.fields.filter((f) => isVisible(f, values));
        if (fields.length === 0) return null;
        return (
          <fieldset key={section.key} className="space-y-4">
            <div>
              <legend className="text-base font-semibold text-secondary-900">{section.title}</legend>
              {section.help && <p className="mt-0.5 text-sm text-secondary-500">{section.help}</p>}
            </div>
            <div className="grid grid-cols-1 gap-x-6 gap-y-5 md:grid-cols-2">
              {fields.map((f) => (
                <div key={f.key} className={f.type === 'text' && !f.placeholder ? 'md:col-span-2' : undefined}>
                  <FieldControl
                    field={f}
                    id={`${idPrefix}-${f.key}`}
                    value={values[f.key]}
                    error={errors[f.key]}
                    source={sources[f.key]}
                    suggestion={f.prefill ? suggestions[f.key] : undefined}
                    disabled={disabled}
                    onChange={(v, src) => onChange(f.key, v, src)}
                  />
                </div>
              ))}
            </div>
          </fieldset>
        );
      })}
    </div>
  );
}

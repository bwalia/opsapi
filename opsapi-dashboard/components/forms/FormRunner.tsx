'use client';

/**
 * Runs a form: conditional logic, steps (split at "page break" fields) with a
 * progress bar, the required check of each step, and Submit on the last one.
 * The public page and the builder's preview both use it, so they behave the
 * same. When the server rejects answers, it jumps to the step of the first one.
 */

import React, { useEffect, useMemo, useRef, useState } from 'react';
import { ArrowLeft, ArrowRight, Loader2 } from 'lucide-react';
import { cn } from '@/lib/utils';
import type { FormField } from '@/services/forms.service';
import FormRenderer, { missingRequired, type Answers, type UploadFn } from './FormRenderer';
import { visibleAnswers, visibleKeys } from './logic';

interface Step {
  title?: string;
  fields: FormField[];
}

/** Split at page breaks; a break's label titles the step after it. */
export function stepsOf(fields: FormField[]): Step[] {
  const steps: Step[] = [{ fields: [] }];
  for (const f of fields) {
    if (f.type === 'page_break') steps.push({ title: f.label || undefined, fields: [] });
    else steps[steps.length - 1].fields.push(f);
  }
  return steps.filter((s, i) => s.fields.length > 0 || i === 0);
}

interface Props {
  fields: FormField[];
  values: Answers;
  onChange: (key: string, value: unknown) => void;
  errors: Record<string, string>;
  setErrors: (e: Record<string, string>) => void;
  /** Gets the answers of the shown questions only. */
  onSubmit: (answers: Answers) => void;
  submitting?: boolean;
  submitLabel?: string;
  formError?: string;
  idPrefix?: string;
  /** A step was reached (1-based), for analytics. */
  onStep?: (step: number, total: number) => void;
  /** Rendered inside the form, before the buttons (e.g. the honeypot). */
  children?: React.ReactNode;
  accent?: string;
  upload?: UploadFn;
}

export default function FormRunner(props: Props) {
  const { fields, values, onChange, errors, setErrors, onSubmit, submitting, submitLabel = 'Submit', formError,
    idPrefix = 'f', onStep, children, accent, upload } = props;
  const [step, setStep] = useState(0);
  const ref = useRef<HTMLFormElement>(null);

  const shown = useMemo(() => visibleKeys(fields, values), [fields, values]);
  // Steps whose questions are all hidden by logic are skipped.
  const steps = useMemo(() => {
    const all = stepsOf(fields);
    const live = all.filter((s) => s.fields.some((f, i) => f.type !== 'hidden' && shown.has(f.key || `idx-${i}`)));
    return live.length ? live : all.slice(0, 1);
  }, [fields, shown]);
  const at = Math.min(step, steps.length - 1);
  const current = steps[at];
  const last = at === steps.length - 1;

  useEffect(() => { onStep?.(at + 1, steps.length); }, [at, steps.length, onStep]);

  // A server error on another step: go to the first one that has an error.
  useEffect(() => {
    const keys = Object.keys(errors);
    if (!keys.length) return;
    const idx = steps.findIndex((s) => s.fields.some((f) => f.key && keys.includes(f.key)));
    if (idx >= 0 && idx !== at) setStep(idx);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [errors]);

  const focusFirstError = () => {
    requestAnimationFrame(() => {
      const first = ref.current?.querySelector<HTMLElement>('[aria-invalid="true"], fieldset [role="alert"]');
      const target = first?.closest('fieldset')?.querySelector<HTMLElement>('input, select, textarea, button') || first;
      target?.focus();
    });
  };

  const next = (e: React.FormEvent) => {
    e.preventDefault();
    if (submitting) return;
    const missing = missingRequired(current.fields, values, shown);
    setErrors(missing);
    if (Object.keys(missing).length) return focusFirstError();
    if (!last) {
      setStep(at + 1);
      requestAnimationFrame(() => ref.current?.scrollIntoView({ behavior: 'smooth', block: 'start' }));
      return;
    }
    onSubmit(visibleAnswers(fields, values));
  };

  const style = accent ? ({ '--form-accent': accent } as React.CSSProperties) : undefined;
  return (
    <form ref={ref} onSubmit={next} noValidate style={style} aria-describedby={formError ? `${idPrefix}-form-error` : undefined}>
      {steps.length > 1 && (
        <div className="mb-6">
          <div className="mb-1.5 flex items-center justify-between text-xs font-medium text-secondary-500">
            <span>{current.title || `Step ${at + 1}`}</span>
            <span>{at + 1} of {steps.length}</span>
          </div>
          <div className="h-1.5 overflow-hidden rounded-full bg-secondary-100" role="progressbar"
            aria-valuemin={1} aria-valuemax={steps.length} aria-valuenow={at + 1} aria-label="Progress">
            <div className="h-full rounded-full bg-[var(--form-accent,var(--color-primary-500))] transition-all"
              style={{ width: `${((at + 1) / steps.length) * 100}%` }} />
          </div>
        </div>
      )}
      <FormRenderer fields={current.fields} values={values} errors={errors} disabled={submitting} idPrefix={idPrefix}
        shown={shown} onChange={onChange} upload={upload} />
      {children}
      {formError && <p id={`${idPrefix}-form-error`} role="alert" className="mt-6 text-sm font-medium text-error-600">{formError}</p>}
      <div className="mt-8 flex flex-wrap items-center gap-3">
        {at > 0 && (
          <button type="button" onClick={() => setStep(at - 1)} disabled={submitting}
            className="inline-flex h-12 items-center gap-2 rounded-lg border border-secondary-300 px-5 text-base font-medium text-secondary-700 hover:bg-secondary-50">
            <ArrowLeft className="h-4 w-4" /> Back
          </button>
        )}
        <button type="submit" disabled={submitting}
          className={cn('inline-flex h-12 items-center justify-center gap-2 rounded-lg px-6 text-base font-semibold text-white shadow-sm',
            'bg-[var(--form-accent,var(--color-primary-500))] transition-opacity hover:opacity-90 focus:outline-none focus:ring-2 focus:ring-offset-2 disabled:opacity-60',
            at === 0 && 'w-full sm:w-auto')}>
          {submitting && <Loader2 className="h-4 w-4 animate-spin" />}
          {last ? (submitting ? 'Sending…' : submitLabel) : 'Next'}
          {!last && <ArrowRight className="h-4 w-4" />}
        </button>
      </div>
    </form>
  );
}

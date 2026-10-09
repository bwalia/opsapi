'use client';

/**
 * Public form — /f/[publicId] (no login). Anyone with the link fills it in.
 *
 * Hidden fields are filled from the link's query string (?utm_campaign=…),
 * UTM tags and the page/referrer are sent as context, and a honeypot plus the
 * render token from the GET let the server drop bots. The Idempotency-Key is
 * made once per page view, so a double-click or a retried request is stored once.
 */

import React, { useEffect, useMemo, useRef, useState } from 'react';
import { useParams } from 'next/navigation';
import { CheckCircle2, Loader2, Lock } from 'lucide-react';
import FormRenderer, { missingRequired, type Answers } from '@/components/forms/FormRenderer';
import { formsPublic, PublicFormError, type PublicForm } from '@/services/forms-public.service';

type State =
  | { kind: 'loading' }
  | { kind: 'unavailable'; title?: string; message: string }
  | { kind: 'ready'; form: PublicForm }
  | { kind: 'done'; message: string };

export default function PublicFormPage() {
  const params = useParams();
  const publicId = params?.publicId as string;
  const [state, setState] = useState<State>({ kind: 'loading' });
  const [values, setValues] = useState<Answers>({});
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [formError, setFormError] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [honeypot, setHoneypot] = useState('');
  const loadedAt = useRef(Date.now());
  const idempotencyKey = useMemo(
    () => (typeof crypto !== 'undefined' && crypto.randomUUID ? crypto.randomUUID() : String(Math.random()).slice(2)),
    []
  );
  const formRef = useRef<HTMLFormElement>(null);

  useEffect(() => {
    if (!publicId) return;
    formsPublic
      .form(publicId)
      .then((form) => {
        // Hidden fields read their value from the link (?param=value).
        const query = new URLSearchParams(window.location.search);
        const prefill: Answers = {};
        for (const f of form.fields) {
          if (f.type === 'hidden' && f.key && query.get(f.param || f.key)) prefill[f.key] = query.get(f.param || f.key);
        }
        setValues(prefill);
        loadedAt.current = Date.now();
        setState({ kind: 'ready', form });
        document.title = form.title;
      })
      .catch((e: unknown) => {
        const err = e as PublicFormError;
        setState({
          kind: 'unavailable',
          title: err.title,
          message: err.status === 404 || !err.status ? "This form isn't available." : err.message,
        });
      });
  }, [publicId]);

  const focusFirstError = (errs: Record<string, string>) => {
    requestAnimationFrame(() => {
      const first = formRef.current?.querySelector<HTMLElement>('[aria-invalid="true"], fieldset [role="alert"]');
      const target = first?.closest('fieldset')?.querySelector<HTMLElement>('input, select, textarea, button') || first;
      target?.focus();
    });
    setFormError(Object.keys(errs).length > 1 ? `Please check the ${Object.keys(errs).length} highlighted answers.` : '');
  };

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (state.kind !== 'ready' || submitting) return;
    const local = missingRequired(state.form.fields, values);
    setErrors(local);
    if (Object.keys(local).length) return focusFirstError(local);
    setSubmitting(true);
    setFormError('');
    try {
      const query = new URLSearchParams(window.location.search);
      const utm: Record<string, string> = {};
      for (const k of ['source', 'medium', 'campaign', 'term', 'content']) {
        const v = query.get(`utm_${k}`);
        if (v) utm[k] = v;
      }
      const res = await formsPublic.submit(publicId, {
        answers: values,
        render_token: state.form.render_token,
        _hp: honeypot,
        context: {
          page_url: window.location.href.slice(0, 1000),
          referrer: document.referrer.slice(0, 1000) || undefined,
          utm,
          duration_ms: Date.now() - loadedAt.current,
        },
      }, idempotencyKey);
      if (res.redirect_url && /^https:\/\//.test(res.redirect_url)) {
        window.location.assign(res.redirect_url);
        return;
      }
      setState({ kind: 'done', message: res.message });
    } catch (err) {
      const e2 = err as PublicFormError;
      if (e2.errors) {
        setErrors(e2.errors);
        focusFirstError(e2.errors);
        setFormError(e2.message);
      } else if (e2.status === 409 || e2.status === 410) {
        setState({ kind: 'unavailable', title: state.form.title, message: e2.message });
      } else {
        setFormError(e2.status === 429 ? e2.message : 'Something went wrong. Please try again.');
      }
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <main id="main-content" className="min-h-dvh bg-secondary-50 px-4 py-8 sm:py-14">
      <div className="mx-auto w-full max-w-2xl">
        {state.kind === 'loading' && (
          <div className="grid min-h-[40vh] place-items-center" aria-busy="true">
            <Loader2 className="h-6 w-6 animate-spin text-secondary-400" />
          </div>
        )}

        {state.kind === 'unavailable' && (
          <section className="rounded-2xl border border-secondary-200 bg-surface p-8 text-center shadow-sm">
            <Lock className="mx-auto h-8 w-8 text-secondary-400" aria-hidden="true" />
            {state.title && <h1 className="mt-4 text-xl font-semibold text-secondary-900">{state.title}</h1>}
            <p className="mt-2 text-secondary-600">{state.message}</p>
          </section>
        )}

        {state.kind === 'done' && (
          <section className="rounded-2xl border border-secondary-200 bg-surface p-8 text-center shadow-sm" aria-live="polite">
            <CheckCircle2 className="mx-auto h-10 w-10 text-success-500" aria-hidden="true" />
            <p className="mt-4 whitespace-pre-line text-lg text-secondary-800">{state.message}</p>
          </section>
        )}

        {state.kind === 'ready' && (
          <form ref={formRef} onSubmit={submit} noValidate
            className="rounded-2xl border border-secondary-200 bg-surface shadow-sm">
            <header className="border-b border-secondary-100 px-6 py-6 sm:px-8">
              {(state.form.workspace.logo_url || state.form.workspace.name) && (
                <div className="mb-4 flex items-center gap-2.5 text-sm text-secondary-500">
                  {state.form.workspace.logo_url && (
                    // eslint-disable-next-line @next/next/no-img-element
                    <img src={state.form.workspace.logo_url} alt="" className="h-7 w-7 rounded object-contain"
                      referrerPolicy="no-referrer" />
                  )}
                  <span>{state.form.workspace.name}</span>
                </div>
              )}
              <h1 className="text-2xl font-bold tracking-tight text-secondary-900">{state.form.title}</h1>
              {state.form.description && (
                <p className="mt-2 whitespace-pre-line text-secondary-600">{state.form.description}</p>
              )}
            </header>
            <div className="px-6 py-6 sm:px-8">
              {/* Honeypot: people never see or fill it; many bots do. */}
              <div aria-hidden="true" className="absolute -left-[9999px] h-px w-px overflow-hidden">
                <label>
                  Website
                  <input type="text" name="website" tabIndex={-1} autoComplete="off" value={honeypot}
                    onChange={(e) => setHoneypot(e.target.value)} />
                </label>
              </div>
              <FormRenderer fields={state.form.fields} values={values} errors={errors} disabled={submitting}
                onChange={(k, v) => {
                  setValues((prev) => ({ ...prev, [k]: v }));
                  if (errors[k]) {
                    setErrors((prev) => {
                      const next = { ...prev };
                      delete next[k];
                      return next;
                    });
                  }
                }} />
              {formError && <p role="alert" className="mt-6 text-sm font-medium text-error-600">{formError}</p>}
              <button type="submit" disabled={submitting}
                className="mt-8 inline-flex h-12 w-full items-center justify-center gap-2 rounded-lg bg-primary-500 px-6 text-base font-semibold text-white shadow-sm transition-colors hover:bg-primary-600 focus:outline-none focus:ring-2 focus:ring-primary-500 focus:ring-offset-2 disabled:opacity-60 sm:w-auto">
                {submitting && <Loader2 className="h-4 w-4 animate-spin" />}
                {submitting ? 'Sending…' : 'Submit'}
              </button>
            </div>
          </form>
        )}

        <p className="mt-6 text-center text-xs text-secondary-400">Powered by OpsAPI</p>
      </div>
    </main>
  );
}

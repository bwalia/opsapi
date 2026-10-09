'use client';

/**
 * Public form — /f/[publicId] (no login). Anyone with the link fills it in.
 *
 * The link can prefill answers (?<answer_key>=value) and hidden fields
 * (?<param>=value). UTM tags and the page/referrer are sent as context. A
 * honeypot plus the render token from the GET let the server drop bots, and
 * the Idempotency-Key, made once per page view, stores a double-click once.
 * ?embed=1 drops the page chrome and reports the form's height to the parent
 * window (public/forms-embed.js sizes the iframe from it).
 */

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useParams } from 'next/navigation';
import { CheckCircle2, Loader2, Lock } from 'lucide-react';
import FormRunner from '@/components/forms/FormRunner';
import Turnstile from '@/components/forms/Turnstile';
import type { Answers } from '@/components/forms/FormRenderer';
import { formsPublic, PublicFormError, type PublicForm } from '@/services/forms-public.service';
import type { FormField } from '@/services/forms.service';

type State =
  | { kind: 'loading' }
  | { kind: 'unavailable'; title?: string; message: string }
  | { kind: 'ready'; form: PublicForm }
  | { kind: 'done'; message: string };

// Types a link may prefill (?key=value).
const PREFILLABLE = ['short_text', 'long_text', 'email', 'phone', 'url', 'number', 'date', 'time', 'single_select', 'radio'];

function prefill(fields: FormField[], query: URLSearchParams): Answers {
  const out: Answers = {};
  for (const f of fields) {
    if (!f.key) continue;
    if (f.type === 'hidden') {
      const v = query.get(f.param || f.key);
      if (v) out[f.key] = v.slice(0, 500);
    } else if (PREFILLABLE.includes(f.type)) {
      const v = query.get(f.key);
      if (v && (!f.options || f.options.some((o) => o.value === v))) out[f.key] = v.slice(0, 1000);
    }
  }
  return out;
}

export default function PublicFormPage() {
  const params = useParams();
  const publicId = params?.publicId as string;
  const [state, setState] = useState<State>({ kind: 'loading' });
  const [values, setValues] = useState<Answers>({});
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [formError, setFormError] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [honeypot, setHoneypot] = useState('');
  const [embed, setEmbed] = useState(false);
  const [captcha, setCaptcha] = useState('');
  const loadedAt = useRef(Date.now());
  const started = useRef(false);
  const lastStep = useRef(0);
  const shell = useRef<HTMLDivElement>(null);
  const idempotencyKey = useMemo(
    () => (typeof crypto !== 'undefined' && crypto.randomUUID ? crypto.randomUUID() : String(Math.random()).slice(2)),
    []
  );

  useEffect(() => {
    if (!publicId) return;
    const query = new URLSearchParams(window.location.search);
    setEmbed(query.get('embed') === '1');
    formsPublic
      .form(publicId)
      .then((form) => {
        setValues(prefill(form.fields, query));
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

  // Embedded: tell the parent page how tall the form is.
  useEffect(() => {
    if (!embed || !shell.current || typeof ResizeObserver === 'undefined') return;
    const post = () => window.parent?.postMessage({ type: 'opsapi-form:height', id: publicId,
      height: Math.ceil(shell.current?.getBoundingClientRect().height || 0) }, '*');
    const ro = new ResizeObserver(post);
    ro.observe(shell.current);
    post();
    return () => ro.disconnect();
  }, [embed, publicId, state.kind]);

  // Analytics: the first answer, and each step reached (best effort).
  const onStep = useCallback((step: number) => {
    if (step > lastStep.current && step > 1) {
      lastStep.current = step;
      formsPublic.event(publicId, 'step', step);
    }
  }, [publicId]);

  const change = (k: string, v: unknown) => {
    if (!started.current) {
      started.current = true;
      formsPublic.event(publicId, 'start');
    }
    setValues((prev) => ({ ...prev, [k]: v }));
    if (errors[k]) {
      setErrors((prev) => {
        const next = { ...prev };
        delete next[k];
        return next;
      });
    }
  };

  const submit = async (answers: Answers) => {
    if (state.kind !== 'ready' || submitting) return;
    if (state.form.captcha && !captcha) {
      setFormError('Please complete the security check.');
      return;
    }
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
        answers,
        render_token: state.form.render_token,
        _hp: honeypot,
        captcha_token: captcha || undefined,
        context: {
          page_url: (embed && document.referrer ? document.referrer : window.location.href).slice(0, 1000),
          referrer: (embed ? '' : document.referrer).slice(0, 1000) || undefined,
          utm,
          duration_ms: Date.now() - loadedAt.current,
        },
      }, idempotencyKey);
      if (res.redirect_url && /^https:\/\//.test(res.redirect_url)) {
        (embed ? window.top || window : window).location.assign(res.redirect_url);
        return;
      }
      setState({ kind: 'done', message: res.message });
    } catch (err) {
      const e2 = err as PublicFormError;
      if (e2.errors) {
        setErrors(e2.errors);
        setFormError(e2.message);
      } else if (e2.code === 'captcha') {
        setCaptcha('');
        setFormError(e2.message);
      } else if (e2.status === 409 || e2.status === 410) {
        setState({ kind: 'unavailable', title: state.form.title, message: e2.message });
      } else {
        setFormError(e2.status === 429 || e2.status === 413 ? e2.message : 'Something went wrong. Please try again.');
      }
    } finally {
      setSubmitting(false);
    }
  };

  const theme = state.kind === 'ready' ? state.form.theme : undefined;
  return (
    <main id="main-content" className={embed ? 'bg-transparent' : 'min-h-dvh px-4 py-8 sm:py-14'}
      style={!embed ? { background: theme?.background || 'var(--color-secondary-50)' } : undefined}>
      <div ref={shell} className={embed ? 'w-full' : 'mx-auto w-full max-w-2xl'}>
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
          <div className={embed ? '' : 'rounded-2xl border border-secondary-200 bg-surface shadow-sm'}>
            <header className={embed ? 'pb-5' : 'border-b border-secondary-100 px-6 py-6 sm:px-8'}>
              {!embed && (theme?.logo_url || state.form.workspace.logo_url || state.form.workspace.name) && (
                <div className="mb-4 flex items-center gap-2.5 text-sm text-secondary-500">
                  {(theme?.logo_url || state.form.workspace.logo_url) && (
                    // eslint-disable-next-line @next/next/no-img-element
                    <img src={theme?.logo_url || state.form.workspace.logo_url} alt=""
                      className="h-8 max-w-[160px] rounded object-contain" referrerPolicy="no-referrer" />
                  )}
                  {!theme?.logo_url && <span>{state.form.workspace.name}</span>}
                </div>
              )}
              <h1 className="text-2xl font-bold tracking-tight text-secondary-900">{state.form.title}</h1>
              {state.form.description && (
                <p className="mt-2 whitespace-pre-line text-secondary-600">{state.form.description}</p>
              )}
            </header>
            <div className={embed ? '' : 'px-6 py-6 sm:px-8'}>
              <FormRunner fields={state.form.fields}
                upload={(key, file) => formsPublic.upload(publicId, key, file, state.form.render_token)} values={values} errors={errors} setErrors={setErrors}
                onChange={change} onSubmit={submit} submitting={submitting} formError={formError} onStep={onStep}
                accent={theme?.primary_color} submitLabel={theme?.submit_label || 'Submit'}>
                {/* Honeypot: people never see or fill it; many bots do. */}
                <div aria-hidden="true" className="absolute -left-[9999px] h-px w-px overflow-hidden">
                  <label>
                    Website
                    <input type="text" name="website" tabIndex={-1} autoComplete="off" value={honeypot}
                      onChange={(e) => setHoneypot(e.target.value)} />
                  </label>
                </div>
                {state.form.captcha?.site_key && <Turnstile siteKey={state.form.captcha.site_key} onToken={setCaptcha} />}
              </FormRunner>
            </div>
          </div>
        )}

        {!embed && !theme?.hide_branding && (
          <p className="mt-6 text-center text-xs text-secondary-400">Powered by OpsAPI</p>
        )}
      </div>
    </main>
  );
}

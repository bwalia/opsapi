'use client';

/**
 * Form editor — /dashboard/forms/[uuid]: Build · Settings · Share · Responses.
 *
 * The draft autosaves (title, questions, "create records") with the form's
 * updated_at, so a change made elsewhere meanwhile is refused rather than
 * overwritten. Publishing turns the draft into a new live version; until then
 * visitors keep seeing the last published one.
 */

import React, { Suspense, useCallback, useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import { useParams, useSearchParams } from 'next/navigation';
import toast from 'react-hot-toast';
import { ArrowLeft, Check, CloudOff, ExternalLink, Loader2, Lock, Rocket, Unlock } from 'lucide-react';
import { Badge, Button } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import { apiError } from '@/components/field-service/shared';
import FormBuilder from '@/components/forms/FormBuilder';
import FormSettingsPanel from '@/components/forms/FormSettingsPanel';
import FormSharePanel from '@/components/forms/FormSharePanel';
import FormResponses from '@/components/forms/FormResponses';
import FormInsights from '@/components/forms/FormInsights';
import {
  formsService, shareUrl, type Form, type FormField, type FormSettings, type FormTarget, type TargetOption,
} from '@/services/forms.service';

type Tab = 'build' | 'settings' | 'share' | 'responses' | 'insights';
type SaveState = 'saved' | 'dirty' | 'saving' | 'error' | 'conflict';

const TABS: { key: Tab; label: string }[] = [
  { key: 'build', label: 'Build' },
  { key: 'settings', label: 'Settings' },
  { key: 'share', label: 'Share' },
  { key: 'responses', label: 'Responses' },
  { key: 'insights', label: 'Insights' },
];

function FormEditor() {
  const params = useParams();
  const search = useSearchParams();
  const uuid = params?.uuid as string;
  const { canUpdate } = usePermissions();
  const readOnly = !canUpdate('forms');

  const [form, setForm] = useState<Form | null>(null);
  const [failed, setFailed] = useState(false);
  const [title, setTitle] = useState('');
  const [fields, setFields] = useState<FormField[]>([]);
  const [targets, setTargets] = useState<FormTarget[]>([]);
  const [targetOptions, setTargetOptions] = useState<TargetOption[]>([]);
  const [tab, setTab] = useState<Tab>(search?.get('response') ? 'responses' : ((search?.get('tab') as Tab) || 'build'));
  const [save, setSave] = useState<SaveState>('saved');
  const [publishing, setPublishing] = useState(false);

  // Edits made while a save is in flight are saved next; `edits` counts them.
  const edits = useRef(0);
  const updatedAt = useRef<string | undefined>(undefined);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const inFlight = useRef<Promise<void> | null>(null);
  const draft = useRef({ title, fields, targets });
  draft.current = { title, fields, targets };

  const adopt = useCallback((f: Form) => {
    setForm(f);
    updatedAt.current = f.updated_at;
    setTitle(f.title);
    setFields(f.schema.fields);
    setTargets(f.targets);
  }, []);

  useEffect(() => {
    if (!uuid) return;
    Promise.all([formsService.get(uuid), formsService.targets().catch(() => [])])
      .then(([f, opts]) => {
        adopt(f);
        setTargetOptions(opts);
      })
      .catch(() => setFailed(true));
  }, [uuid, adopt]);

  const flush = useCallback(async () => {
    if (timer.current) {
      clearTimeout(timer.current);
      timer.current = null;
    }
    if (inFlight.current) await inFlight.current;
    if (edits.current === 0 || !form) return;
    const seen = edits.current;
    const { title: t, fields: fs, targets: ts } = draft.current;
    setSave('saving');
    const run = (async () => {
      try {
        const next = await formsService.update(form.uuid, {
          title: t.trim() || 'Untitled form', fields: fs, targets: ts, expected_updated_at: updatedAt.current,
        });
        updatedAt.current = next.updated_at;
        setForm(next);
        if (edits.current === seen) {
          // Nothing changed meanwhile: take the server's version (it may have
          // added or locked the contact fields the targets need).
          edits.current = 0;
          setFields(next.schema.fields);
          setTargets(next.targets);
          setSave('saved');
        } else {
          edits.current -= seen;
          setSave('dirty');
        }
      } catch (e) {
        const status = (e as { response?: { status?: number } })?.response?.status;
        setSave(status === 409 ? 'conflict' : 'error');
        if (status !== 409) toast.error(apiError(e, 'Could not save'));
      }
    })();
    inFlight.current = run;
    await run;
    inFlight.current = null;
    if (edits.current > 0 && !timer.current) timer.current = setTimeout(() => flush(), 800);
  }, [form]);

  const touch = () => {
    edits.current += 1;
    setSave('dirty');
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(() => flush(), 800);
  };

  // Don't lose an edit when leaving the page.
  useEffect(() => {
    const warn = (e: BeforeUnloadEvent) => {
      if (edits.current > 0) {
        e.preventDefault();
        e.returnValue = '';
      }
    };
    window.addEventListener('beforeunload', warn);
    return () => window.removeEventListener('beforeunload', warn);
  }, []);

  const publish = async () => {
    if (!form) return;
    setPublishing(true);
    try {
      await flush();
      const next = await formsService.publish(form.uuid);
      adopt(next);
      toast.success(next.published_version === 1 ? 'Published — your form is live' : 'Changes published');
      if (next.published_version === 1) setTab('share');
    } catch (e) {
      toast.error(apiError(e, 'Could not publish'));
    } finally {
      setPublishing(false);
    }
  };

  const setOpen = async (open: boolean) => {
    if (!form) return;
    try {
      const next = await formsService.setOpen(form.uuid, open);
      setForm(next);
      updatedAt.current = next.updated_at;
      toast.success(open ? 'Reopened' : 'Closed — it no longer takes responses');
    } catch (e) {
      toast.error(apiError(e, 'That did not work'));
    }
  };

  const saveSettings = async (settings: FormSettings) => {
    if (!form) return;
    await flush();
    const next = await formsService.update(form.uuid, { settings, expected_updated_at: updatedAt.current });
    setForm(next);
    updatedAt.current = next.updated_at;
  };

  if (failed) {
    return (
      <div className="rounded-xl border border-secondary-200 bg-surface p-10 text-center">
        <p className="text-secondary-700">This form doesn&apos;t exist or you can&apos;t open it.</p>
        <Link href="/dashboard/forms" className="mt-4 inline-block text-primary-600 hover:underline">Back to forms</Link>
      </div>
    );
  }
  if (!form) {
    return <div className="grid h-64 place-items-center" aria-busy="true"><Loader2 className="h-6 w-6 animate-spin text-secondary-400" /></div>;
  }

  const live = form.status === 'published';
  const unpublished = !form.published_version || form.has_unpublished_changes || save !== 'saved';

  return (
    <div className="space-y-5">
      <div className="flex flex-col gap-3 lg:flex-row lg:items-center">
        <div className="flex min-w-0 flex-1 items-center gap-2">
          <Link href="/dashboard/forms" aria-label="Back to forms"
            className="inline-flex h-9 w-9 shrink-0 items-center justify-center rounded-lg text-secondary-500 hover:bg-secondary-100">
            <ArrowLeft className="h-5 w-5" />
          </Link>
          <input aria-label="Form title" value={title} readOnly={readOnly} maxLength={200}
            onChange={(e) => { setTitle(e.target.value); touch(); }}
            className="min-w-0 flex-1 rounded-lg border border-transparent bg-transparent px-2 py-1 text-xl font-bold text-secondary-900 hover:border-secondary-200 focus:border-primary-500 focus:outline-none focus:ring-2 focus:ring-primary-500/20" />
          <Badge size="sm" variant={live ? 'success' : form.status === 'closed' ? 'warning' : 'secondary'}>
            {live ? 'Live' : form.status === 'closed' ? 'Closed' : 'Draft'}
          </Badge>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <SaveIndicator state={save} onReload={() => formsService.get(form.uuid).then((f) => { edits.current = 0; adopt(f); setSave('saved'); })} />
          {form.published_version && (
            <a href={shareUrl(form)} target="_blank" rel="noopener noreferrer"
              className="inline-flex h-10 items-center gap-1.5 rounded-lg px-3 text-sm font-medium text-secondary-600 hover:bg-secondary-100">
              <ExternalLink className="h-4 w-4" /> View live
            </a>
          )}
          {!readOnly && live && (
            <Button variant="ghost" leftIcon={<Lock className="h-4 w-4" />} onClick={() => setOpen(false)}>Close</Button>
          )}
          {!readOnly && form.status === 'closed' && (
            <Button variant="ghost" leftIcon={<Unlock className="h-4 w-4" />} onClick={() => setOpen(true)}>Reopen</Button>
          )}
          {!readOnly && (
            <Button leftIcon={<Rocket className="h-4 w-4" />} onClick={publish} isLoading={publishing}
              disabled={!unpublished || save === 'conflict'}>
              {!form.published_version ? 'Publish' : unpublished ? 'Publish changes' : 'Published'}
            </Button>
          )}
        </div>
      </div>

      <div role="tablist" aria-label="Form sections" className="flex gap-1 overflow-x-auto border-b border-secondary-200">
        {TABS.map((t) => (
          <button key={t.key} role="tab" type="button" aria-selected={tab === t.key} onClick={() => setTab(t.key)}
            className={`-mb-px whitespace-nowrap border-b-2 px-4 py-2.5 text-sm font-medium transition-colors ${tab === t.key
              ? 'border-primary-500 text-primary-600' : 'border-transparent text-secondary-500 hover:text-secondary-800'}`}>
            {t.label}
            {t.key === 'responses' && form.submission_count > 0 && (
              <span className="ml-1.5 rounded-full bg-secondary-100 px-1.5 py-0.5 text-xs text-secondary-600">{form.submission_count}</span>
            )}
          </button>
        ))}
      </div>

      <div role="tabpanel">
        {tab === 'build' && (
          <FormBuilder fields={fields} targets={targets} targetOptions={targetOptions} readOnly={readOnly}
            publishedKeys={form.published_keys || []}
            onFieldsChange={(f) => { setFields(f); touch(); }}
            onTargetsChange={(t) => { setTargets(t); touch(); }} />
        )}
        {tab === 'settings' && <FormSettingsPanel form={form} onSave={saveSettings} readOnly={readOnly} />}
        {tab === 'share' && <FormSharePanel form={form} />}
        {tab === 'responses' && <FormResponses formUuid={form.uuid} initialResponse={search?.get('response') || undefined} />}
        {tab === 'insights' && <FormInsights formUuid={form.uuid} />}
      </div>
    </div>
  );
}

function SaveIndicator({ state, onReload }: { state: SaveState; onReload: () => void }) {
  if (state === 'conflict') {
    return (
      <span className="inline-flex items-center gap-2 text-sm text-warning-600" role="status">
        Changed elsewhere.
        <button type="button" onClick={onReload} className="font-medium underline">Reload</button>
      </span>
    );
  }
  const map: Record<string, { icon: React.ReactNode; text: string }> = {
    saved: { icon: <Check className="h-4 w-4 text-success-500" />, text: 'Saved' },
    dirty: { icon: <Loader2 className="h-4 w-4 text-secondary-400" />, text: 'Unsaved' },
    saving: { icon: <Loader2 className="h-4 w-4 animate-spin text-secondary-400" />, text: 'Saving…' },
    error: { icon: <CloudOff className="h-4 w-4 text-error-500" />, text: 'Not saved' },
  };
  const m = map[state];
  return <span className="inline-flex items-center gap-1.5 text-sm text-secondary-500" role="status" aria-live="polite">{m.icon}{m.text}</span>;
}

export default function FormEditorPage() {
  return (
    <ProtectedPage module="forms" title="Forms">
      <Suspense fallback={null}>
        <FormEditor />
      </Suspense>
    </ProtectedPage>
  );
}

'use client';

/**
 * One income type, drawn entirely from its definition (field schema) — so an income
 * type an administrator adds under Tax → Income types works here with no code change.
 *
 * Types tracked per item (properties, jobs, businesses…) list the items first; pick
 * one to fill in its figures. Other types show one form for the year.
 * One primary action: "Save and mark as done". "Save for later" keeps a draft.
 * Backend: lapis/routes/tax-my-income.lua.
 */

import React, { Suspense, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import Link from 'next/link';
import { useParams, useSearchParams } from 'next/navigation';
import { AlertTriangle, ArrowLeft, CheckCircle2, ExternalLink, Info, Loader2, Pencil, Plus, Trash2 } from 'lucide-react';
import toast from 'react-hot-toast';
import { ProtectedPage } from '@/components/permissions';
import { confirmDialog, promptDialog } from '@/components/ui';
import IncomeForm from '@/components/tax/income/IncomeForm';
import { IncomeIcon } from '@/components/tax/income/IncomeIcon';
import StatusBadge from '@/components/tax/income/StatusBadge';
import { extractApiError, formatCurrency } from '@/lib/utils';
import {
  currentFilingYear,
  myIncomeService,
  pluralNoun,
  type FieldSchema,
  type IncomeRecord,
  type IncomeTypePage,
  type ValueSource,
  type Values,
} from '@/services/my-income.service';

const gbp = (n: number) => formatCurrency(n, 'GBP', 'en-GB');

function defaultsFor(schema: FieldSchema): Values {
  const v: Values = {};
  for (const s of schema.sections) for (const f of s.fields) if (f.default !== undefined) v[f.key] = f.default as Values[string];
  return v;
}

function fieldErrorsOf(e: unknown): Record<string, string> | null {
  const data = (e as { response?: { status?: number; data?: { field_errors?: Record<string, string> } } })?.response;
  return data?.status === 422 && data.data?.field_errors ? data.data.field_errors : null;
}

function TypeContent() {
  const { key } = useParams<{ key: string }>();
  const search = useSearchParams();
  const taxYear = useMemo(() => {
    const y = search.get('tax_year');
    return y && /^\d{4}-\d{2}$/.test(y) ? y : currentFilingYear();
  }, [search]);

  const [page, setPage] = useState<IncomeTypePage | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const [values, setValues] = useState<Values>({});
  const [sources, setSources] = useState<Record<string, ValueSource>>({});
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [dirty, setDirty] = useState(false);
  const [saving, setSaving] = useState<null | 'draft' | 'done'>(null);
  const [newLabel, setNewLabel] = useState('');
  const [adding, setAdding] = useState(false);
  const errorSummary = useRef<HTMLDivElement>(null);

  const type = page?.type;
  const perItem = !!type?.entity_type;
  const itemWord = type?.entity_label || 'item';

  const fillForm = useCallback((record: IncomeRecord | null, schema: FieldSchema) => {
    setValues(record ? { ...defaultsFor(schema), ...record.values } : defaultsFor(schema));
    setSources(record?.sources ?? {});
    setErrors({});
    setDirty(false);
  }, []);

  const load = useCallback(
    async (keepSelection?: string | null) => {
      setLoading(true);
      setLoadError(null);
      try {
        const p = await myIncomeService.typePage(key, taxYear);
        setPage(p);
        if (p.type.entity_type) {
          const pick =
            p.entities.find((e) => e.uuid === keepSelection) ??
            p.entities.find((e) => e.record?.status !== 'done') ??
            p.entities[0] ??
            null;
          setSelected(pick?.uuid ?? null);
          fillForm(pick?.record ?? null, p.type.field_schema);
        } else {
          fillForm(p.record, p.type.field_schema);
        }
      } catch (e) {
        setLoadError(extractApiError(e, 'Could not load this income type.'));
      } finally {
        setLoading(false);
      }
    },
    [key, taxYear, fillForm],
  );

  useEffect(() => {
    load();
  }, [load]);

  const confirmDiscard = async () =>
    !dirty ||
    (await confirmDialog({
      title: 'Discard your changes?',
      message: 'You have figures that aren’t saved yet.',
      confirmText: 'Discard',
      danger: true,
    }));

  const selectEntity = async (uuid: string) => {
    if (uuid === selected || !page) return;
    if (!(await confirmDiscard())) return;
    setSelected(uuid);
    fillForm(page.entities.find((e) => e.uuid === uuid)?.record ?? null, page.type.field_schema);
  };

  const onChange = (k: string, v: Values[string], src: ValueSource) => {
    setValues((prev) => ({ ...prev, [k]: v }));
    setSources((prev) => ({ ...prev, [k]: src }));
    setErrors((prev) => {
      if (!prev[k]) return prev;
      const next = { ...prev };
      delete next[k];
      return next;
    });
    setDirty(true);
  };

  const save = async (status: 'in_progress' | 'done') => {
    if (!page) return;
    setSaving(status === 'done' ? 'done' : 'draft');
    try {
      await myIncomeService.saveRecord(page.type.key, {
        tax_year: taxYear,
        entity_uuid: perItem ? selected : null,
        values,
        sources,
        status,
      });
      toast.success(status === 'done' ? 'Saved and marked as done' : 'Saved — you can finish later');
      setDirty(false);
      await load(selected);
    } catch (e) {
      const fe = fieldErrorsOf(e);
      if (fe) {
        setErrors(fe);
        requestAnimationFrame(() => errorSummary.current?.focus());
      } else {
        toast.error(extractApiError(e, 'Could not save. Please try again.'));
      }
    } finally {
      setSaving(null);
    }
  };

  const addEntity = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!page || !newLabel.trim()) return;
    if (!(await confirmDiscard())) return;
    setAdding(true);
    try {
      const ent = await myIncomeService.addEntity(page.type.key, newLabel.trim());
      setNewLabel('');
      toast.success(`Added “${ent.label}”`);
      await load(ent.uuid);
    } catch (err) {
      toast.error(extractApiError(err, 'Could not add it. Please try again.'));
    } finally {
      setAdding(false);
    }
  };

  const renameEntity = async (uuid: string, current: string) => {
    const label = await promptDialog({
      title: `Rename this ${itemWord}`,
      label: 'Name',
      defaultValue: current,
      validate: (v) => (v.trim() ? null : 'Give it a name you’ll recognise.'),
    });
    if (!label || label.trim() === current) return;
    try {
      await myIncomeService.renameEntity(uuid, label.trim());
      await load(selected);
    } catch (err) {
      toast.error(extractApiError(err, 'Could not rename it.'));
    }
  };

  const removeEntity = async (uuid: string, label: string) => {
    const ok = await confirmDialog({
      title: `Remove “${label}”?`,
      message: `Its figures will no longer count towards your tax for any year. You can’t undo this here.`,
      confirmText: 'Remove',
      danger: true,
    });
    if (!ok) return;
    try {
      await myIncomeService.removeEntity(uuid);
      toast.success('Removed');
      await load(selected === uuid ? null : selected);
    } catch (err) {
      toast.error(extractApiError(err, 'Could not remove it.'));
    }
  };

  const setNotApplicable = async (on: boolean) => {
    if (!page) return;
    try {
      await myIncomeService.setNotApplicable(page.type.key, taxYear, on);
      toast.success(on ? 'Noted — you didn’t have this income' : 'Back on your list');
      await load(selected);
    } catch (err) {
      toast.error(extractApiError(err, 'Could not update that.'));
    }
  };

  if (loading && !page) {
    return (
      <div className="flex items-center justify-center gap-2 py-20 text-secondary-500">
        <Loader2 className="h-5 w-5 animate-spin" aria-hidden="true" /> Loading…
      </div>
    );
  }
  if (loadError || !page || !type) {
    return (
      <div className="space-y-4">
        <BackLink taxYear={taxYear} />
        <div role="alert" className="rounded-xl border border-red-200 bg-red-50 p-5 text-sm text-red-800">
          {loadError || 'This income type isn’t available.'}
        </div>
      </div>
    );
  }

  const current = perItem ? page.entities.find((e) => e.uuid === selected) ?? null : null;
  const record = perItem ? current?.record ?? null : page.record;
  const errorCount = Object.keys(errors).length;
  const showForm = !page.not_applicable && (!perItem || !!current);
  const nothingYet = page.status === 'not_started';

  return (
    <div className="space-y-6">
      <BackLink taxYear={taxYear} />

      {/* Header */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div className="flex items-start gap-3.5">
          <span className="mt-0.5 flex h-11 w-11 shrink-0 items-center justify-center rounded-xl bg-primary-500/10 text-primary-600">
            <IncomeIcon name={type.icon} className="h-5 w-5" />
          </span>
          <div>
            <div className="flex flex-wrap items-center gap-2">
              <h1 className="text-2xl font-bold tracking-tight text-secondary-900 sm:text-3xl">{type.name}</h1>
              <StatusBadge status={page.status} />
            </div>
            <p className="mt-1 text-secondary-500">Tax year {taxYear}</p>
          </div>
        </div>
      </div>

      {/* What HMRC wants */}
      {(type.help_text || type.description || type.schedule) && (
        <div className="rounded-xl border border-blue-200 bg-blue-50 p-4 text-sm text-blue-900">
          <div className="flex gap-3">
            <Info className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
            <div className="space-y-2">
              <p>{type.help_text || type.description}</p>
              {type.schedule && (
                <p className="text-blue-800">
                  On your return this goes on <strong>{type.schedule}</strong>
                  {type.schedule_description ? ` — ${type.schedule_description}` : '.'}{' '}
                  {type.schedule_link && (
                    <a
                      href={type.schedule_link}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="inline-flex items-center gap-1 font-medium underline"
                    >
                      See the HMRC form <ExternalLink className="h-3.5 w-3.5" aria-hidden="true" />
                      <span className="sr-only">(opens in a new tab)</span>
                    </a>
                  )}
                </p>
              )}
            </div>
          </div>
        </div>
      )}
      {type.estimate_note && (
        <p className="flex gap-2 rounded-lg bg-amber-50 p-3 text-sm text-amber-900">
          <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" /> {type.estimate_note}
        </p>
      )}

      {/* Not for me */}
      {page.not_applicable ? (
        <div className="flex flex-col gap-3 rounded-xl border border-secondary-200 bg-surface p-5 sm:flex-row sm:items-center sm:justify-between">
          <p className="text-secondary-700">You told us you didn’t have this income in {taxYear}.</p>
          <button
            type="button"
            onClick={() => setNotApplicable(false)}
            className="rounded-lg border border-secondary-300 px-4 py-2 text-sm font-medium text-secondary-700 hover:bg-secondary-50"
          >
            Actually, I did
          </button>
        </div>
      ) : (
        <>
          {/* Items (properties, jobs, businesses…) */}
          {perItem && (
            <section aria-labelledby="items-h" className="space-y-3">
              <h2 id="items-h" className="text-lg font-semibold text-secondary-900">
                Your {pluralNoun(itemWord)}
              </h2>
              {page.entities.length > 0 && (
                <ul className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
                  {page.entities.map((e) => {
                    const active = e.uuid === selected;
                    const st = e.record ? (e.record.status === 'done' ? 'done' : 'in_progress') : 'not_started';
                    return (
                      <li key={e.uuid}>
                        <div
                          className={`flex h-full flex-col rounded-xl border p-4 transition-colors ${
                            active ? 'border-primary-500 bg-primary-50/50 ring-1 ring-primary-500' : 'border-secondary-200 bg-surface hover:border-primary-300'
                          }`}
                        >
                          <button
                            type="button"
                            onClick={() => selectEntity(e.uuid)}
                            aria-pressed={active}
                            className="flex-1 text-left"
                          >
                            <span className="flex flex-wrap items-center gap-2">
                              <span className="font-medium text-secondary-900">{e.label}</span>
                              <StatusBadge status={st} />
                            </span>
                            {e.record && (e.record.totals.income > 0 || e.record.totals.expense > 0) && (
                              <span className="mt-1 block text-sm tabular-nums text-secondary-600">
                                Income {gbp(e.record.totals.income)}
                                {e.record.totals.expense > 0 && ` · Costs ${gbp(e.record.totals.expense)}`}
                              </span>
                            )}
                          </button>
                          <span className="mt-2 flex gap-1">
                            <button
                              type="button"
                              onClick={() => renameEntity(e.uuid, e.label)}
                              className="rounded p-1.5 text-secondary-500 hover:bg-secondary-100 hover:text-secondary-800"
                              aria-label={`Rename ${e.label}`}
                            >
                              <Pencil className="h-4 w-4" aria-hidden="true" />
                            </button>
                            <button
                              type="button"
                              onClick={() => removeEntity(e.uuid, e.label)}
                              className="rounded p-1.5 text-secondary-500 hover:bg-red-50 hover:text-red-600"
                              aria-label={`Remove ${e.label}`}
                            >
                              <Trash2 className="h-4 w-4" aria-hidden="true" />
                            </button>
                          </span>
                        </div>
                      </li>
                    );
                  })}
                </ul>
              )}

              <form
                onSubmit={addEntity}
                className={`flex flex-col gap-2 sm:flex-row sm:items-end ${
                  page.entities.length === 0 ? 'rounded-xl border border-dashed border-secondary-300 p-5' : ''
                }`}
              >
                <div className="flex-1 space-y-1">
                  <label htmlFor="new-entity" className="text-sm font-medium text-secondary-800">
                    {page.entities.length === 0 ? `Add your first ${itemWord}` : `Add another ${itemWord}`}
                  </label>
                  <input
                    id="new-entity"
                    value={newLabel}
                    onChange={(e) => setNewLabel(e.target.value)}
                    maxLength={120}
                    placeholder={
                      type.entity_type === 'employment'
                        ? 'Employer name, e.g. Acme Ltd'
                        : type.entity_type === 'business'
                          ? 'Business name, e.g. Jo’s Plumbing'
                          : 'A name you’ll recognise, e.g. 12 High Street'
                    }
                    className="block w-full rounded-lg border border-secondary-300 bg-surface px-3 py-2 text-secondary-900 placeholder:text-secondary-400 focus:outline-none focus:ring-2 focus:ring-primary-500/30"
                  />
                </div>
                <button
                  type="submit"
                  disabled={adding || !newLabel.trim()}
                  className="inline-flex items-center justify-center gap-1.5 rounded-lg bg-primary-600 px-4 py-2 text-sm font-medium text-white hover:bg-primary-700 disabled:opacity-50"
                >
                  {adding ? <Loader2 className="h-4 w-4 animate-spin" aria-hidden="true" /> : <Plus className="h-4 w-4" aria-hidden="true" />}
                  Add {itemWord}
                </button>
              </form>
            </section>
          )}

          {/* The form */}
          {showForm && (
            <section
              aria-labelledby="form-h"
              className="rounded-xl border border-secondary-200 bg-surface p-5 shadow-sm sm:p-6"
            >
              <div className="mb-5 flex flex-wrap items-center justify-between gap-2">
                <h2 id="form-h" className="text-lg font-semibold text-secondary-900">
                  {perItem && current ? `Figures for ${current.label}` : `Your figures for ${taxYear}`}
                </h2>
                {record?.updated_at && !dirty && (
                  <span className="text-xs text-secondary-400">Last saved {String(record.updated_at).slice(0, 10)}</span>
                )}
              </div>

              {errorCount > 0 && (
                <div
                  ref={errorSummary}
                  tabIndex={-1}
                  role="alert"
                  className="mb-5 rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-800 focus:outline-none focus:ring-2 focus:ring-red-300"
                >
                  <p className="font-medium">Please check {errorCount === 1 ? 'one figure' : `${errorCount} figures`}:</p>
                  <ul className="mt-1 list-disc pl-5">
                    {Object.entries(errors).map(([k, msg]) => (
                      <li key={k}>
                        <a href={`#inc-${k}`} className="underline">
                          {msg}
                        </a>
                      </li>
                    ))}
                  </ul>
                </div>
              )}

              <IncomeForm
                schema={type.field_schema}
                values={values}
                onChange={onChange}
                errors={errors}
                sources={sources}
                suggestions={perItem && page.entities.length > 1 ? {} : page.suggestions}
              />
              {perItem && page.entities.length > 1 && Object.keys(page.suggestions).length > 0 && (
                <p className="mt-4 text-xs text-secondary-500">
                  Your bank statements have figures for this income type, but we can’t tell which {itemWord} they belong
                  to — enter each one’s figures yourself.
                </p>
              )}

              <div className="mt-6 flex flex-col-reverse gap-2 border-t border-secondary-100 pt-5 sm:flex-row sm:items-center sm:justify-end">
                <button
                  type="button"
                  disabled={!!saving}
                  onClick={() => save('in_progress')}
                  className="rounded-lg border border-secondary-300 px-4 py-2 text-sm font-medium text-secondary-700 hover:bg-secondary-50 disabled:opacity-50"
                >
                  {saving === 'draft' ? 'Saving…' : 'Save for later'}
                </button>
                <button
                  type="button"
                  disabled={!!saving}
                  onClick={() => save('done')}
                  className="inline-flex items-center justify-center gap-1.5 rounded-lg bg-primary-600 px-5 py-2 text-sm font-semibold text-white hover:bg-primary-700 disabled:opacity-50"
                >
                  {saving === 'done' ? (
                    <Loader2 className="h-4 w-4 animate-spin" aria-hidden="true" />
                  ) : (
                    <CheckCircle2 className="h-4 w-4" aria-hidden="true" />
                  )}
                  Save and mark as done
                </button>
              </div>
            </section>
          )}

          {nothingYet && (
            <p className="text-sm text-secondary-500">
              Didn’t have this income in {taxYear}?{' '}
              <button type="button" onClick={() => setNotApplicable(true)} className="font-medium text-primary-700 underline">
                Tell us it’s not for you
              </button>
            </p>
          )}

          {page.status === 'done' && (
            <div className="flex flex-col gap-3 rounded-xl border border-green-200 bg-green-50 p-4 sm:flex-row sm:items-center sm:justify-between">
              <p className="flex items-center gap-2 text-sm text-green-800">
                <CheckCircle2 className="h-4 w-4" aria-hidden="true" /> {type.name} is done for {taxYear}.
              </p>
              <Link
                href={`/dashboard/tax/income?tax_year=${taxYear}`}
                className="inline-flex items-center justify-center rounded-lg bg-green-700 px-4 py-2 text-sm font-medium text-white hover:bg-green-800"
              >
                Back to My Income
              </Link>
            </div>
          )}
        </>
      )}
    </div>
  );
}

function BackLink({ taxYear }: { taxYear: string }) {
  return (
    <Link
      href={`/dashboard/tax/income?tax_year=${taxYear}`}
      className="inline-flex items-center gap-1.5 text-sm font-medium text-secondary-600 hover:text-secondary-900"
    >
      <ArrowLeft className="h-4 w-4" aria-hidden="true" /> My Income
    </Link>
  );
}

export default function IncomeTypePageRoute() {
  return (
    <ProtectedPage module="tax_statements" title="My Income">
      <Suspense fallback={null}>
        <TypeContent />
      </Suspense>
    </ProtectedPage>
  );
}

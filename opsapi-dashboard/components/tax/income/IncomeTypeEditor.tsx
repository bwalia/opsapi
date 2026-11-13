'use client';

/**
 * Edit (or create) an income type: details, the form customers fill in (a form
 * builder — no JSON needed), how its figures feed the estimate, a live preview, and
 * the raw JSON for power users. The server validates everything again on save
 * (lib/income-types validate_definition) and its messages are listed here.
 *
 * Built-in types: edits apply to THIS workspace only (an override) unless a platform
 * administrator ticks "every workspace". What an item IS (property, job…) can't be
 * changed per workspace for a built-in type.
 */

import React, { useMemo, useState } from 'react';
import { ArrowDown, ArrowUp, ChevronDown, ChevronRight, Plus, RotateCcw, Trash2 } from 'lucide-react';
import toast from 'react-hot-toast';
import { confirmDialog } from '@/components/ui';
import IncomeForm from '@/components/tax/income/IncomeForm';
import { INCOME_ICONS, IncomeIcon } from '@/components/tax/income/IncomeIcon';
import { extractApiError } from '@/lib/utils';
import {
  myIncomeService,
  type BuilderMeta,
  type EstimatorMapping,
  type FieldRole,
  type FieldSchema,
  type FieldType,
  type IncomeField,
  type IncomeSection,
  type IncomeType,
  type TypeDraft,
  type ValueSource,
  type Values,
} from '@/services/my-income.service';

const TYPE_LABEL: Record<FieldType, string> = {
  currency: 'Money (£)',
  number: 'Number',
  percentage: 'Percentage',
  boolean: 'Yes / No',
  text: 'Text',
  date: 'Date',
  select: 'Choice from a list',
};
const ROLE_LABEL: Record<FieldRole, string> = {
  income: 'Income',
  expense: 'Cost / expense',
  tax_paid: 'Tax already paid',
  relief: 'Relief (e.g. mortgage interest, pension paid in)',
  info: 'Information only',
};

export function slugify(s: string): string {
  let k = s
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .slice(0, 40);
  if (!k) k = 'field';
  if (/^[0-9]/.test(k)) k = `f_${k}`;
  return k;
}

const uniqueKey = (base: string, taken: Set<string>) => {
  let k = base;
  let i = 2;
  while (taken.has(k)) k = `${base}_${i++}`;
  return k;
};

const inputCls =
  'block w-full rounded-lg border border-secondary-300 bg-surface px-3 py-2 text-sm text-secondary-900 ' +
  'placeholder:text-secondary-400 focus:outline-none focus:ring-2 focus:ring-primary-500/30 disabled:opacity-60';
const labelCls = 'mb-1 block text-xs font-medium text-secondary-700';

function TextField(props: {
  id: string;
  label: string;
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
  hint?: string;
  disabled?: boolean;
  multiline?: boolean;
}) {
  return (
    <div>
      <label htmlFor={props.id} className={labelCls}>
        {props.label}
      </label>
      {props.multiline ? (
        <textarea
          id={props.id}
          rows={3}
          value={props.value}
          placeholder={props.placeholder}
          disabled={props.disabled}
          onChange={(e) => props.onChange(e.target.value)}
          className={inputCls}
        />
      ) : (
        <input
          id={props.id}
          value={props.value}
          placeholder={props.placeholder}
          disabled={props.disabled}
          onChange={(e) => props.onChange(e.target.value)}
          className={inputCls}
        />
      )}
      {props.hint && <p className="mt-1 text-xs text-secondary-500">{props.hint}</p>}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Field editor
// ─────────────────────────────────────────────────────────────────────────────

function FieldEditor({
  field,
  idp,
  allFields,
  meta,
  onChange,
  onMove,
  onRemove,
  first,
  last,
}: {
  field: IncomeField;
  idp: string;
  allFields: IncomeField[];
  meta: BuilderMeta | null;
  onChange: (f: IncomeField) => void;
  onMove: (dir: -1 | 1) => void;
  onRemove: () => void;
  first: boolean;
  last: boolean;
}) {
  const [open, setOpen] = useState(!field.label);
  const [catFilter, setCatFilter] = useState('');
  const numeric = field.type === 'currency' || field.type === 'number' || field.type === 'percentage';
  const set = (patch: Partial<IncomeField>) => onChange({ ...field, ...patch });
  const triggerFields = allFields.filter((f) => f.key !== field.key && (f.type === 'boolean' || f.type === 'select'));
  const cats = (meta?.categories ?? []).filter(
    (c) => !catFilter || c.key.includes(catFilter.toLowerCase()) || c.label.toLowerCase().includes(catFilter.toLowerCase()),
  );
  const picked = new Set(field.prefill?.categories ?? []);

  return (
    <li className="rounded-lg border border-secondary-200 bg-surface">
      <div className="flex items-center gap-2 px-3 py-2">
        <button
          type="button"
          onClick={() => setOpen((o) => !o)}
          aria-expanded={open}
          className="flex min-w-0 flex-1 items-center gap-2 text-left"
        >
          {open ? <ChevronDown className="h-4 w-4 shrink-0" aria-hidden="true" /> : <ChevronRight className="h-4 w-4 shrink-0" aria-hidden="true" />}
          <span className="truncate text-sm font-medium text-secondary-900">{field.label || 'New field'}</span>
          <span className="shrink-0 text-xs text-secondary-400">
            {TYPE_LABEL[field.type]}
            {field.required ? ' · needed' : ''}
          </span>
        </button>
        <button type="button" disabled={first} onClick={() => onMove(-1)} className="rounded p-1 text-secondary-500 hover:bg-secondary-100 disabled:opacity-30" aria-label={`Move ${field.label || 'field'} up`}>
          <ArrowUp className="h-4 w-4" aria-hidden="true" />
        </button>
        <button type="button" disabled={last} onClick={() => onMove(1)} className="rounded p-1 text-secondary-500 hover:bg-secondary-100 disabled:opacity-30" aria-label={`Move ${field.label || 'field'} down`}>
          <ArrowDown className="h-4 w-4" aria-hidden="true" />
        </button>
        <button type="button" onClick={onRemove} className="rounded p-1 text-secondary-500 hover:bg-red-50 hover:text-red-600" aria-label={`Delete ${field.label || 'field'}`}>
          <Trash2 className="h-4 w-4" aria-hidden="true" />
        </button>
      </div>
      {open && (
        <div className="grid grid-cols-1 gap-3 border-t border-secondary-100 p-3 sm:grid-cols-2">
          <TextField id={`${idp}-label`} label="Question the customer sees" value={field.label} onChange={(v) => set({ label: v })} placeholder="e.g. Rent received" />
          <TextField id={`${idp}-key`} label="Key (used in the estimate mapping)" value={field.key} onChange={(v) => set({ key: slugify(v) })} hint="lower_snake_case; changing it breaks figures already saved under the old key." />
          <div>
            <label htmlFor={`${idp}-type`} className={labelCls}>
              Answer type
            </label>
            <select id={`${idp}-type`} value={field.type} onChange={(e) => set({ type: e.target.value as FieldType })} className={inputCls}>
              {(Object.keys(TYPE_LABEL) as FieldType[]).map((t) => (
                <option key={t} value={t}>
                  {TYPE_LABEL[t]}
                </option>
              ))}
            </select>
          </div>
          <div>
            <label htmlFor={`${idp}-role`} className={labelCls}>
              What is this figure?
            </label>
            <select id={`${idp}-role`} value={field.role ?? ''} onChange={(e) => set({ role: (e.target.value || undefined) as FieldRole | undefined })} className={inputCls}>
              <option value="">Not counted in totals</option>
              {(Object.keys(ROLE_LABEL) as FieldRole[]).map((r) => (
                <option key={r} value={r}>
                  {ROLE_LABEL[r]}
                </option>
              ))}
            </select>
          </div>
          <div className="sm:col-span-2">
            <TextField id={`${idp}-help`} label="Help text (plain English: where to find it, what to leave out)" value={field.help ?? ''} onChange={(v) => set({ help: v || undefined })} multiline />
          </div>
          <TextField id={`${idp}-box`} label="HMRC form box (shown as a hint)" value={field.hmrc_box ?? ''} onChange={(v) => set({ hmrc_box: v || undefined })} placeholder="e.g. SA105 box 20" />
          <TextField id={`${idp}-ph`} label="Placeholder" value={field.placeholder ?? ''} onChange={(v) => set({ placeholder: v || undefined })} />
          <label className="flex items-center gap-2 text-sm text-secondary-800">
            <input type="checkbox" checked={!!field.required} onChange={(e) => set({ required: e.target.checked || undefined })} className="h-4 w-4 rounded border-secondary-300" />
            Needed before the customer can mark it done
          </label>
          {numeric && (
            <div className="grid grid-cols-2 gap-2">
              <TextField id={`${idp}-min`} label="Minimum" value={field.min?.toString() ?? ''} onChange={(v) => set({ min: v === '' ? undefined : Number(v) })} />
              <TextField id={`${idp}-max`} label="Maximum" value={field.max?.toString() ?? ''} onChange={(v) => set({ max: v === '' ? undefined : Number(v) })} />
            </div>
          )}
          {field.type === 'percentage' && (
            <TextField id={`${idp}-def`} label="Default" value={field.default?.toString() ?? ''} onChange={(v) => set({ default: v === '' ? undefined : Number(v) })} placeholder="100" />
          )}
          {field.type === 'select' && (
            <div className="sm:col-span-2">
              <label htmlFor={`${idp}-opts`} className={labelCls}>
                Choices — one per line, as <code>value|Label</code>
              </label>
              <textarea
                id={`${idp}-opts`}
                rows={3}
                className={inputCls}
                defaultValue={(field.options ?? []).map((o) => `${o.value}|${o.label}`).join('\n')}
                onBlur={(e) =>
                  set({
                    options: e.target.value
                      .split('\n')
                      .map((l) => l.trim())
                      .filter(Boolean)
                      .map((l) => {
                        const [v, ...rest] = l.split('|');
                        return { value: slugify(v), label: (rest.join('|') || v).trim() };
                      }),
                  })
                }
              />
            </div>
          )}
          <div className="sm:col-span-2 grid grid-cols-1 gap-2 sm:grid-cols-2">
            <div>
              <label htmlFor={`${idp}-showif`} className={labelCls}>
                Only show when…
              </label>
              <select
                id={`${idp}-showif`}
                value={field.show_if?.field ?? ''}
                onChange={(e) => set({ show_if: e.target.value ? { field: e.target.value, equals: true } : undefined })}
                className={inputCls}
              >
                <option value="">Always show</option>
                {triggerFields.map((f) => (
                  <option key={f.key} value={f.key}>
                    {f.label || f.key}
                  </option>
                ))}
              </select>
            </div>
            {field.show_if && (
              <TextField
                id={`${idp}-equals`}
                label="…has the answer"
                value={field.show_if.equals === true ? 'yes' : field.show_if.equals === false ? 'no' : String(field.show_if.equals ?? '')}
                onChange={(v) =>
                  set({ show_if: { field: field.show_if!.field, equals: v === 'yes' ? true : v === 'no' ? false : v } })
                }
                hint="yes / no, or a choice value"
              />
            )}
          </div>
          {(field.type === 'currency' || field.type === 'number') && (
            <div className="sm:col-span-2 rounded-lg bg-secondary-50 p-3">
              <label className="flex items-center gap-2 text-sm font-medium text-secondary-800">
                <input
                  type="checkbox"
                  checked={!!field.prefill}
                  onChange={(e) => set({ prefill: e.target.checked ? { categories: [], direction: 'credit' } : undefined })}
                  className="h-4 w-4 rounded border-secondary-300"
                />
                Suggest this figure from the customer’s classified bank transactions
              </label>
              {field.prefill && (
                <div className="mt-2 space-y-2">
                  <select
                    aria-label="Money in or out"
                    value={field.prefill.direction}
                    onChange={(e) => set({ prefill: { ...field.prefill!, direction: e.target.value as 'credit' | 'debit' } })}
                    className={inputCls}
                  >
                    <option value="credit">Money in (credits)</option>
                    <option value="debit">Money out (debits)</option>
                  </select>
                  <input aria-label="Filter categories" placeholder="Filter categories…" value={catFilter} onChange={(e) => setCatFilter(e.target.value)} className={inputCls} />
                  <div className="max-h-40 overflow-y-auto rounded border border-secondary-200 bg-surface p-2">
                    {cats.map((c) => (
                      <label key={c.key} className="flex items-center gap-2 py-0.5 text-sm">
                        <input
                          type="checkbox"
                          checked={picked.has(c.key)}
                          onChange={(e) => {
                            const next = new Set(picked);
                            if (e.target.checked) next.add(c.key);
                            else next.delete(c.key);
                            set({ prefill: { ...field.prefill!, categories: Array.from(next) } });
                          }}
                        />
                        {c.label} <span className="text-xs text-secondary-400">({c.key}, {c.type})</span>
                      </label>
                    ))}
                  </div>
                </div>
              )}
            </div>
          )}
        </div>
      )}
    </li>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Editor
// ─────────────────────────────────────────────────────────────────────────────

type Tab = 'details' | 'form' | 'estimate' | 'preview' | 'json';

export interface IncomeTypeEditorProps {
  initial?: IncomeType;
  meta: BuilderMeta | null;
  canEditGlobal: boolean;
  onSaved: (t: IncomeType) => void;
  onCancel: () => void;
}

export default function IncomeTypeEditor({ initial, meta, canEditGlobal, onSaved, onCancel }: IncomeTypeEditorProps) {
  const creating = !initial;
  const isSystem = initial?.origin === 'system';
  const [tab, setTab] = useState<Tab>('details');
  const [name, setName] = useState(initial?.name ?? '');
  const [key, setKey] = useState('');
  const [keyEdited, setKeyEdited] = useState(false);
  const [description, setDescription] = useState(initial?.description ?? '');
  const [help, setHelp] = useState(initial?.help_text ?? '');
  const [icon, setIcon] = useState(initial?.icon ?? 'Wallet');
  const [perItem, setPerItem] = useState(!!initial?.entity_type);
  const [entityType, setEntityType] = useState(initial?.entity_type ?? '');
  const [entityLabel, setEntityLabel] = useState(initial?.entity_label ?? '');
  const [schedule, setSchedule] = useState(initial?.schedule ?? '');
  const [scheduleDesc, setScheduleDesc] = useState(initial?.schedule_description ?? '');
  const [scheduleLink, setScheduleLink] = useState(initial?.schedule_link ?? '');
  const [estimateNote, setEstimateNote] = useState(initial?.estimate_note ?? '');
  const [schema, setSchema] = useState<FieldSchema>(
    initial?.field_schema?.sections?.length ? initial.field_schema : { sections: [{ key: 'main', title: 'Your figures', fields: [] }] },
  );
  const [mapping, setMapping] = useState<EstimatorMapping[]>(initial?.estimator_mapping ?? []);
  const [scope, setScope] = useState<'namespace' | 'global'>('namespace');
  const [serverErrors, setServerErrors] = useState<string[]>([]);
  const [saving, setSaving] = useState(false);
  const [jsonText, setJsonText] = useState('');
  const [jsonError, setJsonError] = useState<string | null>(null);
  const [previewValues, setPreviewValues] = useState<Values>({});
  const [previewSources, setPreviewSources] = useState<Record<string, ValueSource>>({});

  const entityLocked = isSystem && scope === 'namespace';
  const allFields = useMemo(() => schema.sections.flatMap((s) => s.fields), [schema]);
  const moneyFields = allFields.filter((f) => f.type === 'currency' || f.type === 'number');
  const shareFields = allFields.filter((f) => f.type === 'percentage');
  const effectiveKey = keyEdited ? key : slugify(name);

  // ── schema mutations ──
  const updateSection = (si: number, patch: Partial<IncomeSection>) =>
    setSchema((s) => ({ sections: s.sections.map((sec, i) => (i === si ? { ...sec, ...patch } : sec)) }));
  const updateField = (si: number, fi: number, f: IncomeField) =>
    updateSection(si, { fields: schema.sections[si].fields.map((x, i) => (i === fi ? f : x)) });
  const moveField = (si: number, fi: number, dir: -1 | 1) => {
    const fields = [...schema.sections[si].fields];
    const j = fi + dir;
    if (j < 0 || j >= fields.length) return;
    [fields[fi], fields[j]] = [fields[j], fields[fi]];
    updateSection(si, { fields });
  };
  const addField = (si: number) => {
    const taken = new Set(allFields.map((f) => f.key));
    const f: IncomeField = { key: uniqueKey('new_field', taken), label: '', type: 'currency', role: 'income' };
    updateSection(si, { fields: [...schema.sections[si].fields, f] });
  };
  const removeField = async (si: number, fi: number) => {
    const f = schema.sections[si].fields[fi];
    if (f.label && !(await confirmDialog({ title: `Delete “${f.label}”?`, message: 'Figures customers already saved for it will no longer show.', danger: true, confirmText: 'Delete' }))) return;
    updateSection(si, { fields: schema.sections[si].fields.filter((_, i) => i !== fi) });
    setMapping((m) => m.filter((x) => x.field !== f.key && x.scale_by !== f.key));
  };
  const addSection = () => {
    const taken = new Set(schema.sections.map((s) => s.key));
    setSchema((s) => ({ sections: [...s.sections, { key: uniqueKey('section', taken), title: 'New section', fields: [] }] }));
  };
  const moveSection = (si: number, dir: -1 | 1) => {
    const secs = [...schema.sections];
    const j = si + dir;
    if (j < 0 || j >= secs.length) return;
    [secs[si], secs[j]] = [secs[j], secs[si]];
    setSchema({ sections: secs });
  };
  const removeSection = async (si: number) => {
    const sec = schema.sections[si];
    if (sec.fields.length && !(await confirmDialog({ title: `Delete the “${sec.title}” section and its ${sec.fields.length} field(s)?`, danger: true, confirmText: 'Delete' }))) return;
    const gone = new Set(sec.fields.map((f) => f.key));
    setSchema((s) => ({ sections: s.sections.filter((_, i) => i !== si) }));
    setMapping((m) => m.filter((x) => !gone.has(x.field)));
  };

  const draft = (): TypeDraft => {
    const d: TypeDraft = {
      display_name: name.trim(),
      description: description.trim() || null,
      help_text: help.trim() || null,
      icon,
      estimate_note: estimateNote.trim() || null,
      field_schema: schema,
      estimator_mapping: mapping,
    };
    if (!entityLocked) {
      d.entity_type = perItem ? entityType.trim() || null : null;
      d.entity_label = perItem ? entityLabel.trim() || null : null;
    }
    if (!isSystem || scope === 'global') {
      d.linked_form_title = schedule.trim() || null;
      d.linked_form_description = scheduleDesc.trim() || null;
      d.linked_form_weblink = scheduleLink.trim() || null;
    }
    if (creating) d.key = effectiveKey;
    if (isSystem && scope === 'global') d.scope = 'global';
    return d;
  };

  const save = async () => {
    setSaving(true);
    setServerErrors([]);
    try {
      const t = creating ? await myIncomeService.create(draft()) : await myIncomeService.update(initial!.key, draft());
      toast.success(creating ? 'Income type added' : 'Saved');
      onSaved(t);
    } catch (e) {
      const data = (e as { response?: { data?: { errors?: string[] } } })?.response?.data;
      if (data?.errors?.length) setServerErrors(data.errors);
      else setServerErrors([extractApiError(e, 'Could not save.')]);
    } finally {
      setSaving(false);
    }
  };

  const checkOnly = async () => {
    try {
      const r = await myIncomeService.validate({ ...draft(), key: creating ? effectiveKey : initial!.key, creating });
      setServerErrors(r.errors);
      if (r.valid) toast.success('Looks good — nothing to fix');
    } catch (e) {
      setServerErrors([extractApiError(e, 'Could not check.')]);
    }
  };

  const reset = async () => {
    if (!initial) return;
    if (!(await confirmDialog({ title: `Reset “${initial.name}” to the default?`, message: 'This workspace’s changes to this income type are removed.', confirmText: 'Reset' }))) return;
    try {
      const t = await myIncomeService.reset(initial.key);
      toast.success('Back to the default');
      onSaved(t);
    } catch (e) {
      toast.error(extractApiError(e, 'Could not reset.'));
    }
  };

  const openJson = () => {
    setJsonText(JSON.stringify({ field_schema: schema, estimator_mapping: mapping }, null, 2));
    setJsonError(null);
    setTab('json');
  };
  const applyJson = () => {
    try {
      const parsed = JSON.parse(jsonText) as { field_schema?: FieldSchema; estimator_mapping?: EstimatorMapping[] };
      if (!parsed.field_schema || !Array.isArray(parsed.field_schema.sections)) throw new Error('field_schema.sections must be a list');
      setSchema(parsed.field_schema);
      setMapping(Array.isArray(parsed.estimator_mapping) ? parsed.estimator_mapping : []);
      setJsonError(null);
      toast.success('Applied — check the Form and Preview tabs');
    } catch (e) {
      setJsonError(e instanceof Error ? e.message : 'Invalid JSON');
    }
  };

  const TABS: Array<{ id: Tab; label: string }> = [
    { id: 'details', label: 'Details' },
    { id: 'form', label: `Form (${allFields.length})` },
    { id: 'estimate', label: 'Estimate' },
    { id: 'preview', label: 'Preview' },
    { id: 'json', label: 'JSON' },
  ];

  return (
    <div className="space-y-4">
      {isSystem && (
        <div className="rounded-lg bg-secondary-50 p-3 text-sm text-secondary-700">
          {scope === 'global'
            ? 'You’re changing the platform default — every workspace without its own changes will see this.'
            : 'This is a built-in income type. Your changes apply to this workspace only; you can reset them any time.'}
          {canEditGlobal && (
            <label className="mt-2 flex items-center gap-2 font-medium">
              <input type="checkbox" checked={scope === 'global'} onChange={(e) => setScope(e.target.checked ? 'global' : 'namespace')} className="h-4 w-4 rounded border-secondary-300" />
              Change the default for every workspace (platform administrators)
            </label>
          )}
        </div>
      )}

      <div role="tablist" aria-label="Income type editor" className="flex gap-1 overflow-x-auto border-b border-secondary-200">
        {TABS.map((t) => (
          <button
            key={t.id}
            type="button"
            role="tab"
            aria-selected={tab === t.id}
            onClick={() => (t.id === 'json' ? openJson() : setTab(t.id))}
            className={`whitespace-nowrap border-b-2 px-3 py-2 text-sm font-medium ${
              tab === t.id ? 'border-primary-600 text-primary-700' : 'border-transparent text-secondary-500 hover:text-secondary-800'
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>

      {tab === 'details' && (
        <div role="tabpanel" className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <TextField id="it-name" label="Name customers see" value={name} onChange={setName} placeholder="e.g. Crypto staking rewards" />
          {creating ? (
            <TextField id="it-key" label="Key" value={effectiveKey} onChange={(v) => { setKey(slugify(v)); setKeyEdited(true); }} hint="Set once; it can’t be changed later." />
          ) : (
            <div>
              <span className={labelCls}>Key</span>
              <p className="rounded-lg bg-secondary-50 px-3 py-2 font-mono text-sm text-secondary-700">{initial?.key}</p>
            </div>
          )}
          <div className="sm:col-span-2">
            <TextField id="it-desc" label="One-line description (on the My Income card)" value={description} onChange={setDescription} />
          </div>
          <div className="sm:col-span-2">
            <TextField id="it-help" label="Guidance at the top of the page — what HMRC wants and why" value={help} onChange={setHelp} multiline />
          </div>
          <div className="sm:col-span-2">
            <span className={labelCls}>Icon</span>
            <div className="flex flex-wrap gap-1.5" role="radiogroup" aria-label="Icon">
              {Object.keys(INCOME_ICONS).map((n) => (
                <button
                  key={n}
                  type="button"
                  role="radio"
                  aria-checked={icon === n}
                  aria-label={n}
                  title={n}
                  onClick={() => setIcon(n)}
                  className={`flex h-9 w-9 items-center justify-center rounded-lg border ${icon === n ? 'border-primary-500 bg-primary-50 text-primary-700' : 'border-secondary-200 text-secondary-600 hover:border-primary-300'}`}
                >
                  <IncomeIcon name={n} className="h-4 w-4" />
                </button>
              ))}
            </div>
          </div>
          <div className="sm:col-span-2 rounded-lg border border-secondary-200 p-3">
            <label className="flex items-center gap-2 text-sm font-medium text-secondary-800">
              <input type="checkbox" checked={perItem} disabled={entityLocked} onChange={(e) => setPerItem(e.target.checked)} className="h-4 w-4 rounded border-secondary-300" />
              Customers add several of these (e.g. each property, job or business), each with its own figures
            </label>
            {perItem && (
              <div className="mt-3 grid grid-cols-1 gap-3 sm:grid-cols-2">
                <div>
                  <label htmlFor="it-etype" className={labelCls}>
                    Kind of item
                  </label>
                  <input id="it-etype" list="it-etypes" value={entityType} disabled={entityLocked} onChange={(e) => setEntityType(slugify(e.target.value))} className={inputCls} placeholder="property" />
                  <datalist id="it-etypes">
                    {(meta?.entity_types ?? []).map((t) => (
                      <option key={t} value={t} />
                    ))}
                  </datalist>
                  <p className="mt-1 text-xs text-secondary-500">Same kind as another type = the same list of items (shared with the DIY app).</p>
                </div>
                <TextField id="it-elabel" label="What to call one (singular)" value={entityLabel} disabled={entityLocked} onChange={setEntityLabel} placeholder="property" />
              </div>
            )}
          </div>
          {(!isSystem || scope === 'global') && (
            <>
              <TextField id="it-sched" label="HMRC form / schedule" value={schedule} onChange={setSchedule} placeholder="e.g. SA105" />
              <TextField id="it-link" label="Link to the HMRC form (https://…)" value={scheduleLink} onChange={setScheduleLink} />
              <div className="sm:col-span-2">
                <TextField id="it-sdesc" label="About the form" value={scheduleDesc} onChange={setScheduleDesc} placeholder="These figures go on the UK property pages." />
              </div>
            </>
          )}
          <div className="sm:col-span-2">
            <TextField id="it-note" label="Note shown when it isn’t (fully) in the estimate" value={estimateNote} onChange={setEstimateNote} placeholder="e.g. Capital Gains Tax is worked out separately and isn’t in this estimate yet." />
          </div>
        </div>
      )}

      {tab === 'form' && (
        <div role="tabpanel" className="space-y-4">
          <p className="text-sm text-secondary-600">
            Group questions into sections. Keep labels in plain English and say where to find each figure (P60, lender’s
            statement…). Customers see this exactly — check the Preview tab.
          </p>
          {schema.sections.map((sec, si) => (
            <div key={`${sec.key}-${si}`} className="space-y-3 rounded-xl border border-secondary-200 bg-secondary-50/50 p-3">
              <div className="flex flex-wrap items-end gap-2">
                <div className="min-w-[12rem] flex-1">
                  <TextField id={`sec-${si}-title`} label={`Section ${si + 1} title`} value={sec.title} onChange={(v) => updateSection(si, { title: v })} />
                </div>
                <button type="button" disabled={si === 0} onClick={() => moveSection(si, -1)} className="rounded p-2 text-secondary-500 hover:bg-secondary-100 disabled:opacity-30" aria-label={`Move section ${sec.title} up`}>
                  <ArrowUp className="h-4 w-4" aria-hidden="true" />
                </button>
                <button type="button" disabled={si === schema.sections.length - 1} onClick={() => moveSection(si, 1)} className="rounded p-2 text-secondary-500 hover:bg-secondary-100 disabled:opacity-30" aria-label={`Move section ${sec.title} down`}>
                  <ArrowDown className="h-4 w-4" aria-hidden="true" />
                </button>
                <button type="button" onClick={() => removeSection(si)} className="rounded p-2 text-secondary-500 hover:bg-red-50 hover:text-red-600" aria-label={`Delete section ${sec.title}`}>
                  <Trash2 className="h-4 w-4" aria-hidden="true" />
                </button>
              </div>
              <TextField id={`sec-${si}-help`} label="Section help (optional)" value={sec.help ?? ''} onChange={(v) => updateSection(si, { help: v || undefined })} />
              <ul className="space-y-2">
                {sec.fields.map((f, fi) => (
                  <FieldEditor
                    key={`${si}-${fi}`}
                    idp={`f-${si}-${fi}`}
                    field={f}
                    allFields={allFields}
                    meta={meta}
                    first={fi === 0}
                    last={fi === sec.fields.length - 1}
                    onChange={(nf) => {
                      // keep the estimate mapping pointing at a renamed key
                      if (nf.key !== f.key) {
                        setMapping((m) => m.map((x) => ({ ...x, field: x.field === f.key ? nf.key : x.field, scale_by: x.scale_by === f.key ? nf.key : x.scale_by })));
                      }
                      updateField(si, fi, nf);
                    }}
                    onMove={(d) => moveField(si, fi, d)}
                    onRemove={() => removeField(si, fi)}
                  />
                ))}
              </ul>
              <button type="button" onClick={() => addField(si)} className="inline-flex items-center gap-1.5 rounded-lg border border-dashed border-secondary-300 px-3 py-1.5 text-sm font-medium text-secondary-700 hover:border-primary-400 hover:text-primary-700">
                <Plus className="h-4 w-4" aria-hidden="true" /> Add a question
              </button>
            </div>
          ))}
          <button type="button" onClick={addSection} className="inline-flex items-center gap-1.5 text-sm font-medium text-primary-700 hover:underline">
            <Plus className="h-4 w-4" aria-hidden="true" /> Add a section
          </button>
        </div>
      )}

      {tab === 'estimate' && (
        <div role="tabpanel" className="space-y-3">
          <p className="text-sm text-secondary-600">
            Say which figures feed the tax estimate and as what. The tax rules (allowances, bands, Section 24) are applied
            by the estimator — you only label the figures. Questions not listed here are kept for the return but don’t
            change the estimate.
          </p>
          {mapping.length === 0 && <p className="rounded-lg bg-amber-50 p-3 text-sm text-amber-900">Nothing from this income type is in the estimate yet.</p>}
          <ul className="space-y-2">
            {mapping.map((m, i) => {
              const desc = meta?.estimator_inputs.find((x) => x.key === m.input)?.description;
              const setM = (patch: Partial<EstimatorMapping>) => setMapping((all) => all.map((x, j) => (j === i ? { ...x, ...patch } : x)));
              return (
                <li key={i} className="grid grid-cols-1 gap-2 rounded-lg border border-secondary-200 p-3 sm:grid-cols-[1fr_1fr_auto]">
                  <div>
                    <label htmlFor={`m-${i}-field`} className={labelCls}>
                      Figure
                    </label>
                    <select id={`m-${i}-field`} value={m.field} onChange={(e) => setM({ field: e.target.value })} className={inputCls}>
                      <option value="">Choose…</option>
                      {moneyFields.map((f) => (
                        <option key={f.key} value={f.key}>
                          {f.label || f.key}
                        </option>
                      ))}
                    </select>
                  </div>
                  <div>
                    <label htmlFor={`m-${i}-input`} className={labelCls}>
                      Counts in the estimate as
                    </label>
                    <select id={`m-${i}-input`} value={m.input} onChange={(e) => setM({ input: e.target.value })} className={inputCls}>
                      <option value="">Choose…</option>
                      {(meta?.estimator_inputs ?? []).map((x) => (
                        <option key={x.key} value={x.key}>
                          {x.description}
                        </option>
                      ))}
                    </select>
                    {desc && <p className="mt-1 font-mono text-[11px] text-secondary-400">{m.input}</p>}
                  </div>
                  <div className="flex items-end gap-2">
                    <button type="button" onClick={() => setMapping((all) => all.filter((_, j) => j !== i))} className="rounded p-2 text-secondary-500 hover:bg-red-50 hover:text-red-600" aria-label="Remove this line">
                      <Trash2 className="h-4 w-4" aria-hidden="true" />
                    </button>
                  </div>
                  <div className="flex flex-wrap items-center gap-4 sm:col-span-3">
                    {shareFields.length > 0 && (
                      <label className="flex items-center gap-2 text-sm text-secondary-700">
                        Scale by
                        <select aria-label="Scale by a share" value={m.scale_by ?? ''} onChange={(e) => setM({ scale_by: e.target.value || undefined })} className="rounded border border-secondary-300 bg-surface px-2 py-1 text-sm">
                          <option value="">— (whole figure)</option>
                          {shareFields.map((f) => (
                            <option key={f.key} value={f.key}>
                              {f.label || f.key}
                            </option>
                          ))}
                        </select>
                      </label>
                    )}
                    <label className="flex items-center gap-2 text-sm text-secondary-700">
                      <input type="checkbox" checked={m.sign === -1} onChange={(e) => setM({ sign: e.target.checked ? -1 : undefined })} className="h-4 w-4 rounded border-secondary-300" />
                      Subtract it (a cost against that input)
                    </label>
                  </div>
                </li>
              );
            })}
          </ul>
          <button type="button" onClick={() => setMapping((m) => [...m, { field: moneyFields[0]?.key ?? '', input: '' }])} disabled={moneyFields.length === 0} className="inline-flex items-center gap-1.5 rounded-lg border border-dashed border-secondary-300 px-3 py-1.5 text-sm font-medium text-secondary-700 hover:border-primary-400 disabled:opacity-50">
            <Plus className="h-4 w-4" aria-hidden="true" /> Add a line
          </button>
        </div>
      )}

      {tab === 'preview' && (
        <div role="tabpanel" className="space-y-3 rounded-xl border border-secondary-200 bg-surface p-4">
          <p className="text-xs uppercase tracking-wide text-secondary-400">What customers see</p>
          <h3 className="flex items-center gap-2 text-lg font-semibold text-secondary-900">
            <IncomeIcon name={icon} /> {name || 'Untitled income type'}
          </h3>
          {help && <p className="rounded-lg bg-blue-50 p-3 text-sm text-blue-900">{help}</p>}
          <IncomeForm
            schema={schema}
            values={previewValues}
            sources={previewSources}
            idPrefix="pv"
            onChange={(k, v, src) => {
              setPreviewValues((p) => ({ ...p, [k]: v }));
              setPreviewSources((p) => ({ ...p, [k]: src }));
            }}
          />
        </div>
      )}

      {tab === 'json' && (
        <div role="tabpanel" className="space-y-2">
          <label htmlFor="it-json" className={labelCls}>
            Field schema and estimate mapping (advanced)
          </label>
          <textarea id="it-json" rows={18} spellCheck={false} value={jsonText} onChange={(e) => setJsonText(e.target.value)} className={`${inputCls} font-mono text-xs`} />
          {jsonError && <p role="alert" className="text-sm text-red-600">{jsonError}</p>}
          <button type="button" onClick={applyJson} className="rounded-lg border border-secondary-300 px-3 py-1.5 text-sm font-medium text-secondary-700 hover:bg-secondary-50">
            Apply JSON
          </button>
        </div>
      )}

      {serverErrors.length > 0 && (
        <div role="alert" className="rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-800">
          <p className="font-medium">Please fix:</p>
          <ul className="mt-1 list-disc pl-5">
            {serverErrors.map((e, i) => (
              <li key={i}>{e}</li>
            ))}
          </ul>
        </div>
      )}

      <div className="flex flex-col-reverse gap-2 border-t border-secondary-100 pt-4 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex gap-2">
          {isSystem && initial && Object.keys(initial.overridden ?? {}).length > 0 && scope === 'namespace' && (
            <button type="button" onClick={reset} className="inline-flex items-center gap-1.5 rounded-lg px-3 py-2 text-sm font-medium text-secondary-600 hover:bg-secondary-100">
              <RotateCcw className="h-4 w-4" aria-hidden="true" /> Reset to default
            </button>
          )}
          <button type="button" onClick={checkOnly} className="rounded-lg px-3 py-2 text-sm font-medium text-secondary-600 hover:bg-secondary-100">
            Check for problems
          </button>
        </div>
        <div className="flex flex-col-reverse gap-2 sm:flex-row">
          <button type="button" onClick={onCancel} className="rounded-lg border border-secondary-300 px-4 py-2 text-sm font-medium text-secondary-700 hover:bg-secondary-50">
            Cancel
          </button>
          <button type="button" onClick={save} disabled={saving || !name.trim()} className="rounded-lg bg-primary-600 px-5 py-2 text-sm font-semibold text-white hover:bg-primary-700 disabled:opacity-50">
            {saving ? 'Saving…' : creating ? 'Add income type' : 'Save changes'}
          </button>
        </div>
      </div>
    </div>
  );
}

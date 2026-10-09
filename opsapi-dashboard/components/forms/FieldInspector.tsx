'use client';

/**
 * Settings of the selected field. A locked field (one the form's targets need)
 * keeps its type and stays required; its label, help and position can change.
 */

import React, { useEffect, useState } from 'react';
import { GitBranch, Lock, Plus, Trash2 } from 'lucide-react';
import { Input, Select, Switch, Textarea } from '@/components/ui';
import type { FieldLogic, FieldOption, FormField, LogicOp, LogicRule, MapsTo } from '@/services/forms.service';
import { FIELD_TYPE_BY_NAME, MAPS_TO_LABEL } from './field-types';
import { opsFor } from './logic';

function optionValue(label: string, taken: Set<string>, i: number) {
  let base = label.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 100) || `option_${i + 1}`;
  const root = base;
  for (let n = 2; taken.has(base); n++) base = `${root}_${n}`;
  taken.add(base);
  return base;
}

/** Options from "one per line" text, keeping the value of every label that stays. */
function parseOptions(text: string, previous: FieldOption[]): FieldOption[] {
  const byLabel = new Map(previous.map((o) => [o.label, o.value]));
  const taken = new Set<string>();
  return text
    .split('\n')
    .map((l) => l.trim())
    .filter(Boolean)
    .slice(0, 500)
    .map((label, i) => {
      const kept = byLabel.get(label);
      if (kept && !taken.has(kept)) {
        taken.add(kept);
        return { value: kept, label };
      }
      return { value: optionValue(label, taken, i), label };
    });
}

function num(v: string): number | undefined {
  if (v.trim() === '') return undefined;
  const n = Number(v);
  return Number.isFinite(n) ? n : undefined;
}

interface Props {
  field: FormField;
  lockedBecause?: string;
  onChange: (patch: Partial<FormField>) => void;
  /** Questions above this one (what its logic may refer to). */
  earlier: FormField[];
}

export default function FieldInspector({ field, lockedBecause, onChange, earlier }: Props) {
  const def = FIELD_TYPE_BY_NAME[field.type];
  const locked = !!field.system;
  const v = field.validation || {};
  const [optionsText, setOptionsText] = useState((field.options || []).map((o) => o.label).join('\n'));

  // Re-seed the options box when another field is selected.
  useEffect(() => {
    setOptionsText((field.options || []).map((o) => o.label).join('\n'));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [field.key]);

  const setValidation = (patch: Record<string, unknown>) => onChange({ validation: { ...v, ...patch } });

  return (
    <div className="space-y-4">
      <div className="flex items-center gap-2 text-sm font-semibold text-secondary-900">
        {def && <def.icon className="h-4 w-4 text-secondary-500" aria-hidden="true" />}
        {def?.label || field.type}
        {locked && (
          <span className="ml-auto inline-flex items-center gap-1 rounded-full bg-secondary-100 px-2 py-0.5 text-xs font-medium text-secondary-600">
            <Lock className="h-3 w-3" aria-hidden="true" /> Locked
          </span>
        )}
      </div>
      {locked && lockedBecause && (
        <p className="rounded-lg bg-info-500/10 px-3 py-2 text-xs text-info-600">{lockedBecause}</p>
      )}

      {field.type !== 'paragraph' && (
        <Input label={field.type === 'heading' ? 'Heading' : 'Question'} value={field.label} maxLength={300}
          onChange={(e) => onChange({ label: e.target.value })} />
      )}
      {(field.type === 'paragraph' || field.type === 'consent') && (
        <Textarea label={field.type === 'consent' ? 'Statement they agree to' : 'Text'} rows={4}
          value={field.text || ''} maxLength={field.type === 'consent' ? 2000 : 5000}
          onChange={(e) => onChange({ text: e.target.value })} />
      )}
      {def?.input && field.type !== 'hidden' && (
        <Input label="Help text" value={field.help || ''} maxLength={500} placeholder="Shown under the question"
          onChange={(e) => onChange({ help: e.target.value })} />
      )}
      {def?.hasPlaceholder && (
        <Input label="Placeholder" value={field.placeholder || ''} maxLength={200}
          onChange={(e) => onChange({ placeholder: e.target.value })} />
      )}

      {def?.hasOptions && (
        <Textarea label="Options (one per line)" rows={5} value={optionsText}
          onChange={(e) => {
            setOptionsText(e.target.value);
            onChange({ options: parseOptions(e.target.value, field.options || []) });
          }}
          helperText={`${(field.options || []).length} option(s). Paste a list to add many at once.`} />
      )}

      {(field.type === 'short_text' || field.type === 'long_text') && (
        <div className="grid grid-cols-2 gap-3">
          <Input label="Min length" inputMode="numeric" value={v.min_length ?? ''}
            onChange={(e) => setValidation({ min_length: num(e.target.value) })} />
          <Input label="Max length" inputMode="numeric" value={v.max_length ?? ''}
            onChange={(e) => setValidation({ max_length: num(e.target.value) })} />
        </div>
      )}
      {field.type === 'number' && (
        <>
          <div className="grid grid-cols-2 gap-3">
            <Input label="Minimum" inputMode="decimal" value={String(v.min ?? '')}
              onChange={(e) => setValidation({ min: num(e.target.value) })} />
            <Input label="Maximum" inputMode="decimal" value={String(v.max ?? '')}
              onChange={(e) => setValidation({ max: num(e.target.value) })} />
          </div>
          <ToggleRow label="Whole numbers only" checked={!!v.integer} onChange={(b) => setValidation({ integer: b || undefined })} />
        </>
      )}
      {field.type === 'multi_select' && (
        <div className="grid grid-cols-2 gap-3">
          <Input label="Choose at least" inputMode="numeric" value={v.min_selected ?? ''}
            onChange={(e) => setValidation({ min_selected: num(e.target.value) })} />
          <Input label="Choose at most" inputMode="numeric" value={v.max_selected ?? ''}
            onChange={(e) => setValidation({ max_selected: num(e.target.value) })} />
        </div>
      )}
      {field.type === 'date' && (
        <div className="grid grid-cols-2 gap-3">
          <Input label="Earliest" type="date" value={String(v.min ?? '')}
            onChange={(e) => setValidation({ min: e.target.value || undefined })} />
          <Input label="Latest" type="date" value={String(v.max ?? '')}
            onChange={(e) => setValidation({ max: e.target.value || undefined })} />
        </div>
      )}
      {field.type === 'rating' && (
        <Select label="Scale" value={String(field.scale || 5)} onChange={(e) => onChange({ scale: Number(e.target.value) as 5 | 10 })}>
          <option value="5">1 to 5 stars</option>
          <option value="10">1 to 10</option>
        </Select>
      )}
      {field.type === 'file_upload' && (
        <>
          <Select label="Kind of files" value={field.accept || 'any'}
            onChange={(e) => onChange({ accept: e.target.value as FormField['accept'] })}>
            <option value="any">Images or documents</option>
            <option value="images">Images only (JPG, PNG, GIF, WebP, HEIC)</option>
            <option value="documents">Documents only (PDF, Word, Excel, PowerPoint, text, CSV)</option>
          </Select>
          <div className="grid grid-cols-2 gap-3">
            <Select label="Files" value={String(field.max_files || 1)} onChange={(e) => onChange({ max_files: Number(e.target.value) })}>
              {[1, 2, 3, 5, 10].map((n) => <option key={n} value={n}>Up to {n}</option>)}
            </Select>
            <Select label="Size each" value={String(field.max_size_mb || 10)} onChange={(e) => onChange({ max_size_mb: Number(e.target.value) })}>
              {[1, 2, 5, 10].map((n) => <option key={n} value={n}>{n} MB</option>)}
            </Select>
          </div>
        </>
      )}
      {field.type === 'hidden' && (
        <Input label="Read from the link parameter" value={field.param || ''} maxLength={64}
          helperText={`e.g. ?${field.param || 'utm_campaign'}=autumn — the value is saved with the response.`}
          onChange={(e) => onChange({ param: e.target.value.replace(/[^A-Za-z0-9_-]/g, '') })} />
      )}

      {def?.input && field.type !== 'hidden' && (
        <ToggleRow label="Required" checked={!!field.required || locked} disabled={locked}
          onChange={(b) => onChange({ required: b })} />
      )}
      {def?.input && field.type !== 'hidden' && (
        <Select label="Width" value={field.width || 'full'} onChange={(e) => onChange({ width: e.target.value === 'half' ? 'half' : undefined })}>
          <option value="full">Full width</option>
          <option value="half">Half width (side by side on wide screens)</option>
        </Select>
      )}
      {def?.maps && def.maps.length > 0 && !locked && (
        <Select label="Copy the answer to the record's…" value={field.maps_to || ''}
          onChange={(e) => onChange({ maps_to: (e.target.value || undefined) as MapsTo | undefined })}
          helperText="When this form creates a customer or lead, this answer fills that field.">
          <option value="">Don&apos;t copy</option>
          {def.maps.map((m) => <option key={m} value={m}>{MAPS_TO_LABEL[m]}</option>)}
        </Select>
      )}
      {!locked && field.type !== 'hidden' && (
        <LogicEditor logic={field.logic} earlier={earlier} onChange={(logic) => onChange({ logic })} />
      )}
      {field.key && def?.input && (
        <p className="text-xs text-secondary-500">
          Answer key <code className="rounded bg-secondary-100 px-1 py-0.5">{field.key}</code> — use{' '}
          <code className="rounded bg-secondary-100 px-1 py-0.5">{`{{${field.key}}}`}</code> in the auto-reply; webhooks send it too.
        </p>
      )}
    </div>
  );
}

function ToggleRow({ label, checked, onChange, disabled }: {
  label: string; checked: boolean; onChange: (b: boolean) => void; disabled?: boolean;
}) {
  return (
    <div className="flex items-center justify-between gap-3">
      <span className="text-sm font-medium text-secondary-700">{label}</span>
      <Switch checked={checked} onChange={onChange} disabled={disabled} aria-label={label} />
    </div>
  );
}

/** "Show this question only if …" over the questions above it. */
function LogicEditor({ logic, earlier, onChange }: {
  logic?: FieldLogic; earlier: FormField[]; onChange: (l: FieldLogic | undefined) => void;
}) {
  const sources = earlier.filter((f) => f.key && FIELD_TYPE_BY_NAME[f.type]?.input && f.type !== 'file_upload');
  const rules = logic?.rules || [];
  const on = rules.length > 0;
  const set = (next: LogicRule[]) => onChange(next.length ? { match: logic?.match || 'all', rules: next } : undefined);
  const firstRule = (): LogicRule | null => {
    const src = sources[sources.length - 1];
    if (!src?.key) return null;
    const op = opsFor(src.type)[0].op;
    return { field: src.key, op, value: defaultValue(src, op) };
  };

  return (
    <div className="space-y-3 border-t border-secondary-100 pt-4">
      <div className="flex items-center justify-between gap-3">
        <span className="inline-flex items-center gap-1.5 text-sm font-medium text-secondary-700">
          <GitBranch className="h-4 w-4 text-secondary-500" aria-hidden="true" /> Show only if…
        </span>
        <Switch checked={on} aria-label="Show this question only if" disabled={!on && sources.length === 0}
          onChange={(b) => { const r = firstRule(); set(b && r ? [r] : []); }} />
      </div>
      {!on && sources.length === 0 && <p className="text-xs text-secondary-500">Add a question above this one first.</p>}
      {on && (
        <>
          {rules.length > 1 && (
            <Select aria-label="Match" value={logic?.match || 'all'}
              onChange={(e) => onChange({ match: e.target.value === 'any' ? 'any' : 'all', rules })}>
              <option value="all">All of these are true</option>
              <option value="any">Any of these is true</option>
            </Select>
          )}
          {rules.map((r, i) => {
            const src = sources.find((f) => f.key === r.field);
            const update = (patch: Partial<LogicRule>) => set(rules.map((x, j) => (j === i ? { ...x, ...patch } : x)));
            return (
              <div key={i} className="space-y-2 rounded-lg bg-secondary-50 p-2.5">
                <div className="flex gap-2">
                  <Select aria-label="Question" value={r.field} className="min-w-0"
                    onChange={(e) => {
                      const next = sources.find((f) => f.key === e.target.value);
                      if (!next) return;
                      const op = opsFor(next.type)[0].op;
                      update({ field: e.target.value, op, value: defaultValue(next, op) });
                    }}>
                    {!src && <option value={r.field}>(question removed or moved below)</option>}
                    {sources.map((f) => <option key={f.key} value={f.key}>{f.label}</option>)}
                  </Select>
                  <button type="button" aria-label="Remove condition" onClick={() => set(rules.filter((_, j) => j !== i))}
                    className="inline-flex h-10 w-10 shrink-0 items-center justify-center rounded-lg text-secondary-500 hover:bg-secondary-100">
                    <Trash2 className="h-4 w-4" />
                  </button>
                </div>
                {src && (
                  <div className="flex gap-2">
                    <Select aria-label="Condition" value={r.op} className="min-w-0"
                      onChange={(e) => { const op = e.target.value as LogicOp; update({ op, value: defaultValue(src, op) }); }}>
                      {opsFor(src.type).map((o) => <option key={o.op} value={o.op}>{o.label}</option>)}
                    </Select>
                    <RuleValue source={src} rule={r} onChange={(value) => update({ value })} />
                  </div>
                )}
              </div>
            );
          })}
          {rules.length < 10 && (
            <button type="button" onClick={() => { const r = firstRule(); if (r) set([...rules, r]); }}
              className="inline-flex items-center gap-1 text-sm font-medium text-primary-600 hover:underline">
              <Plus className="h-4 w-4" /> Add condition
            </button>
          )}
        </>
      )}
    </div>
  );
}

function defaultValue(src: FormField, op: LogicOp): LogicRule['value'] {
  if (op === 'filled' || op === 'empty') return undefined;
  if (op === 'in' || op === 'not_in') return src.options?.[0] ? [src.options[0].value] : [];
  if (src.options?.length) return src.options[0].value;
  if (src.type === 'boolean' || src.type === 'consent') return true;
  if (src.type === 'number' || src.type === 'rating') return 1;
  return '';
}

function RuleValue({ source: src, rule, onChange }: {
  source: FormField; rule: LogicRule; onChange: (v: LogicRule['value']) => void;
}) {
  if (rule.op === 'filled' || rule.op === 'empty') return null;
  if (rule.op === 'in' || rule.op === 'not_in') {
    const chosen = Array.isArray(rule.value) ? rule.value : [];
    return (
      <div className="flex min-w-0 flex-1 flex-wrap gap-1.5">
        {(src.options || []).map((o) => {
          const on = chosen.includes(o.value);
          return (
            <button key={o.value} type="button" aria-pressed={on}
              onClick={() => onChange(on ? chosen.filter((v) => v !== o.value) : [...chosen, o.value])}
              className={`rounded-full border px-2.5 py-1 text-xs ${on ? 'border-primary-500 bg-primary-500/10 text-primary-700' : 'border-secondary-300 text-secondary-600'}`}>
              {o.label}
            </button>
          );
        })}
      </div>
    );
  }
  if (src.options?.length) {
    return (
      <Select aria-label="Value" value={String(rule.value ?? '')} className="min-w-0" onChange={(e) => onChange(e.target.value)}>
        {src.options.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
      </Select>
    );
  }
  if (src.type === 'boolean' || src.type === 'consent') {
    return (
      <Select aria-label="Value" value={rule.value === false ? 'false' : 'true'} className="min-w-0"
        onChange={(e) => onChange(e.target.value === 'true')}>
        <option value="true">{src.type === 'consent' ? 'ticked' : 'Yes'}</option>
        <option value="false">{src.type === 'consent' ? 'not ticked' : 'No'}</option>
      </Select>
    );
  }
  if (src.type === 'number' || src.type === 'rating') {
    return <Input aria-label="Value" inputMode="decimal" value={String(rule.value ?? '')}
      onChange={(e) => onChange(e.target.value === '' ? '' : Number(e.target.value))} />;
  }
  if (src.type === 'date') {
    return <Input aria-label="Value" type="date" value={String(rule.value ?? '')} onChange={(e) => onChange(e.target.value)} />;
  }
  return <Input aria-label="Value" value={String(rule.value ?? '')} maxLength={200} onChange={(e) => onChange(e.target.value)} />;
}

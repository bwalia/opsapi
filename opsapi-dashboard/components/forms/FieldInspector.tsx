'use client';

/**
 * Settings of the selected field. A locked field (one the form's targets need)
 * keeps its type and stays required; its label, help and position can change.
 */

import React, { useEffect, useState } from 'react';
import { Lock } from 'lucide-react';
import { Input, Select, Switch, Textarea } from '@/components/ui';
import type { FieldOption, FormField, MapsTo } from '@/services/forms.service';
import { FIELD_TYPE_BY_NAME, MAPS_TO_LABEL } from './field-types';

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
}

export default function FieldInspector({ field, lockedBecause, onChange }: Props) {
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

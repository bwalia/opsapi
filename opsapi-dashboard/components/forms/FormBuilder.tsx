'use client';

/**
 * The Build tab: field palette, the canvas (drag to reorder, or the move
 * buttons from the keyboard), the selected field's settings, and the
 * "Create records" card. Controlled: the page owns the draft and saves it.
 */

import React, { useMemo, useState } from 'react';
import {
  DndContext, KeyboardSensor, PointerSensor, TouchSensor, closestCenter, useSensor, useSensors,
  type DragEndEvent,
} from '@dnd-kit/core';
import {
  SortableContext, arrayMove, sortableKeyboardCoordinates, useSortable, verticalListSortingStrategy,
} from '@dnd-kit/sortable';
import { CSS } from '@dnd-kit/utilities';
import {
  ArrowDown, ArrowUp, Copy, Eye, GripVertical, Lock, Monitor, PencilRuler, Plus, Smartphone, Trash2, UserPlus,
} from 'lucide-react';
import { cn } from '@/lib/utils';
import { Card, Select, Switch } from '@/components/ui';
import type { FormField, FormTarget, TargetOption, TargetType } from '@/services/forms.service';
import { FIELD_TYPES, FIELD_TYPE_BY_NAME, MAPS_TO_LABEL, keyFromLabel, newField } from './field-types';
import FieldInspector from './FieldInspector';
import FormRenderer, { type Answers } from './FormRenderer';

interface Props {
  fields: FormField[];
  onFieldsChange: (fields: FormField[]) => void;
  targets: FormTarget[];
  onTargetsChange: (targets: FormTarget[]) => void;
  targetOptions: TargetOption[];
  /** Answer keys of the published version: their keys never change. */
  publishedKeys: string[];
  readOnly?: boolean;
}

const GROUPS = ['Text', 'Choice', 'Contact', 'Other', 'Layout'] as const;

export default function FormBuilder(props: Props) {
  const { fields, onFieldsChange, targets, onTargetsChange, targetOptions, publishedKeys, readOnly } = props;
  const [selected, setSelected] = useState<string | null>(fields[0]?.key ?? null);
  const [preview, setPreview] = useState<null | 'desktop' | 'mobile'>(null);
  const [previewValues, setPreviewValues] = useState<Answers>({});

  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 6 } }),
    useSensor(TouchSensor, { activationConstraint: { delay: 200, tolerance: 8 } }),
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates })
  );

  const keys = useMemo(() => fields.map((f, i) => f.key || `idx-${i}`), [fields]);
  const current = fields.find((f) => f.key === selected) || null;
  const published = useMemo(() => new Set(publishedKeys), [publishedKeys]);

  // Which targets lock a contact field (for the explanation in the inspector).
  const lockReason = useMemo(() => {
    const names = targets.map((t) => targetOptions.find((o) => o.key === t.type)?.label.toLowerCase()).filter(Boolean);
    return names.length
      ? `This form needs it to ${names.join(' and ')}. Turn that off under "Create records" to unlock it.`
      : undefined;
  }, [targets, targetOptions]);

  const update = (key: string, patch: Partial<FormField>) => {
    onFieldsChange(fields.map((f) => {
      if (f.key !== key) return f;
      const next = { ...f, ...patch };
      // A key follows its label until the field is published (then answers depend on it).
      if (patch.label !== undefined && !f.system && !published.has(f.key || '') && next.label.trim()) {
        const taken = new Set(fields.filter((o) => o.key !== key).map((o) => o.key || ''));
        next.key = keyFromLabel(next.label, taken);
        if (selected === key) setSelected(next.key);
      }
      return next;
    }));
  };

  const add = (type: FormField['type']) => {
    const taken = new Set(fields.map((f) => f.key || ''));
    const field = newField(type, taken);
    const at = selected ? fields.findIndex((f) => f.key === selected) + 1 : fields.length;
    const next = [...fields];
    next.splice(at > 0 ? at : fields.length, 0, field);
    onFieldsChange(next);
    setSelected(field.key || null);
  };

  const move = (key: string, by: number) => {
    const i = fields.findIndex((f) => f.key === key);
    const j = i + by;
    if (i < 0 || j < 0 || j >= fields.length) return;
    onFieldsChange(arrayMove(fields, i, j));
  };

  const duplicate = (f: FormField) => {
    const taken = new Set(fields.map((x) => x.key || ''));
    const copy: FormField = { ...f, system: undefined, label: `${f.label} (copy)` };
    copy.key = keyFromLabel(copy.label, taken);
    const i = fields.findIndex((x) => x.key === f.key);
    const next = [...fields];
    next.splice(i + 1, 0, copy);
    onFieldsChange(next);
    setSelected(copy.key || null);
  };

  const remove = (f: FormField) => {
    if (f.system) return;
    const i = fields.findIndex((x) => x.key === f.key);
    onFieldsChange(fields.filter((x) => x.key !== f.key));
    setSelected(fields[i + 1]?.key || fields[i - 1]?.key || null);
  };

  const onDragEnd = (e: DragEndEvent) => {
    if (!e.over || e.active.id === e.over.id) return;
    const from = keys.indexOf(String(e.active.id));
    const to = keys.indexOf(String(e.over.id));
    if (from >= 0 && to >= 0) onFieldsChange(arrayMove(fields, from, to));
  };

  const toggleTarget = (type: TargetType, on: boolean) => {
    if (on) {
      const role = type === 'user' ? targetOptions.find((o) => o.key === 'user')?.roles?.find((r) => r.name === 'member')?.name
        || targetOptions.find((o) => o.key === 'user')?.roles?.[0]?.name : undefined;
      onTargetsChange([...targets, type === 'user' ? { type, role } : { type }]);
    } else {
      onTargetsChange(targets.filter((t) => t.type !== type));
    }
  };

  if (preview) {
    return (
      <div className="space-y-4">
        <div className="flex flex-wrap items-center gap-2">
          <button type="button" onClick={() => setPreview(null)}
            className="inline-flex h-10 items-center gap-2 rounded-lg border border-secondary-300 px-3 text-sm font-medium text-secondary-700 hover:bg-secondary-50">
            <PencilRuler className="h-4 w-4" /> Back to editing
          </button>
          <div className="ml-auto inline-flex rounded-lg border border-secondary-300 p-0.5" role="group" aria-label="Preview size">
            {(['desktop', 'mobile'] as const).map((m) => (
              <button key={m} type="button" onClick={() => setPreview(m)} aria-pressed={preview === m}
                className={cn('inline-flex h-9 items-center gap-1.5 rounded-md px-3 text-sm',
                  preview === m ? 'bg-secondary-900 text-white' : 'text-secondary-600 hover:bg-secondary-100')}>
                {m === 'desktop' ? <Monitor className="h-4 w-4" /> : <Smartphone className="h-4 w-4" />}
                {m === 'desktop' ? 'Desktop' : 'Mobile'}
              </button>
            ))}
          </div>
        </div>
        <div className={cn('mx-auto rounded-2xl border border-secondary-200 bg-surface p-6 shadow-sm',
          preview === 'mobile' ? 'max-w-[390px]' : 'max-w-2xl')}>
          <FormRenderer fields={fields} values={previewValues} idPrefix="preview"
            onChange={(k, v) => setPreviewValues((p) => ({ ...p, [k]: v }))} />
          <button type="button" disabled className="mt-8 h-11 rounded-lg bg-primary-500 px-6 font-semibold text-white opacity-80">
            Submit
          </button>
          <p className="mt-2 text-xs text-secondary-500">Preview only: nothing is sent.</p>
        </div>
      </div>
    );
  }

  return (
    <div className="grid grid-cols-1 gap-5 lg:grid-cols-[220px_minmax(0,1fr)_320px]">
      {/* Palette */}
      <Card padding="sm" className="h-fit lg:sticky lg:top-4">
        <h2 className="mb-3 text-sm font-semibold text-secondary-900">Add a field</h2>
        <div className="space-y-4">
          {GROUPS.map((g) => (
            <div key={g}>
              <p className="mb-1.5 text-xs font-medium uppercase tracking-wide text-secondary-400">{g}</p>
              <div className="grid grid-cols-2 gap-1.5 lg:grid-cols-1">
                {FIELD_TYPES.filter((t) => t.group === g).map((t) => (
                  <button key={t.type} type="button" disabled={readOnly} onClick={() => add(t.type)}
                    className="flex h-10 items-center gap-2 rounded-lg px-2.5 text-left text-sm text-secondary-700 transition-colors hover:bg-secondary-100 disabled:opacity-50">
                    <t.icon className="h-4 w-4 shrink-0 text-secondary-500" aria-hidden="true" />
                    <span className="truncate">{t.label}</span>
                    <Plus className="ml-auto h-3.5 w-3.5 text-secondary-400" aria-hidden="true" />
                  </button>
                ))}
              </div>
            </div>
          ))}
        </div>
      </Card>

      {/* Canvas */}
      <div className="min-w-0 space-y-4">
        <TargetsCard targets={targets} options={targetOptions} onToggle={toggleTarget} readOnly={readOnly}
          onRole={(role) => onTargetsChange(targets.map((t) => (t.type === 'user' ? { ...t, role } : t)))} />

        <div className="flex items-center justify-between">
          <h2 className="text-sm font-semibold text-secondary-900">Questions ({fields.length})</h2>
          <button type="button" onClick={() => setPreview('desktop')}
            className="inline-flex h-9 items-center gap-1.5 rounded-lg px-3 text-sm font-medium text-secondary-600 hover:bg-secondary-100">
            <Eye className="h-4 w-4" /> Preview
          </button>
        </div>

        {fields.length === 0 ? (
          <div className="rounded-xl border-2 border-dashed border-secondary-200 p-10 text-center text-sm text-secondary-500">
            Add your first question from the list on the left.
          </div>
        ) : (
          <DndContext sensors={sensors} collisionDetection={closestCenter} onDragEnd={onDragEnd}>
            <SortableContext items={keys} strategy={verticalListSortingStrategy}>
              <ul className="space-y-2" aria-label="Questions">
                {fields.map((f, i) => (
                  <SortableField key={keys[i]} id={keys[i]} field={f} index={i} total={fields.length}
                    selected={f.key === selected} readOnly={readOnly}
                    onSelect={() => setSelected(f.key || null)} onMove={(by) => f.key && move(f.key, by)}
                    onDuplicate={() => duplicate(f)} onRemove={() => remove(f)} />
                ))}
              </ul>
            </SortableContext>
          </DndContext>
        )}
      </div>

      {/* Inspector */}
      <Card padding="sm" className="h-fit lg:sticky lg:top-4">
        {current ? (
          <fieldset disabled={readOnly}>
            <FieldInspector field={current} lockedBecause={lockReason}
              onChange={(patch) => current.key && update(current.key, patch)} />
          </fieldset>
        ) : (
          <p className="text-sm text-secondary-500">Select a question to edit it.</p>
        )}
      </Card>
    </div>
  );
}

function SortableField({ id, field, index, total, selected, readOnly, onSelect, onMove, onDuplicate, onRemove }: {
  id: string; field: FormField; index: number; total: number; selected: boolean; readOnly?: boolean;
  onSelect: () => void; onMove: (by: number) => void; onDuplicate: () => void; onRemove: () => void;
}) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({ id, disabled: readOnly });
  const def = FIELD_TYPE_BY_NAME[field.type];
  const Icon = def?.icon;
  const iconBtn = 'inline-flex h-8 w-8 items-center justify-center rounded-md text-secondary-500 hover:bg-secondary-100 hover:text-secondary-800 disabled:opacity-30';
  return (
    <li ref={setNodeRef} style={{ transform: CSS.Transform.toString(transform), transition }}
      className={cn('group flex items-center gap-2 rounded-xl border bg-surface px-2 py-2.5 shadow-sm transition-colors',
        selected ? 'border-primary-500 ring-2 ring-primary-500/15' : 'border-secondary-200 hover:border-secondary-300',
        isDragging && 'z-10 opacity-80 shadow-lg')}>
      <button type="button" {...attributes} {...listeners} aria-label={`Drag to reorder: ${field.label || def?.label}`}
        className="cursor-grab touch-none rounded p-1 text-secondary-400 hover:text-secondary-600 active:cursor-grabbing">
        <GripVertical className="h-4 w-4" />
      </button>
      <button type="button" onClick={onSelect} className="flex min-w-0 flex-1 items-center gap-2.5 text-left"
        aria-current={selected ? 'true' : undefined}>
        {Icon && <Icon className="h-4 w-4 shrink-0 text-secondary-500" aria-hidden="true" />}
        <span className="min-w-0">
          <span className="block truncate text-sm font-medium text-secondary-900">
            {field.type === 'paragraph' ? (field.text || 'Text block') : (field.label || def?.label)}
            {field.required && <span className="ml-0.5 text-error-500" aria-label="required">*</span>}
          </span>
          <span className="flex flex-wrap items-center gap-1.5 text-xs text-secondary-500">
            {def?.label}
            {field.system && <span className="inline-flex items-center gap-0.5"><Lock className="h-3 w-3" /> locked</span>}
            {field.maps_to && <span>→ {MAPS_TO_LABEL[field.maps_to]}</span>}
            {field.width === 'half' && <span>· half width</span>}
          </span>
        </span>
      </button>
      {!readOnly && (
        <div className="flex shrink-0 items-center opacity-100 sm:opacity-0 sm:group-focus-within:opacity-100 sm:group-hover:opacity-100">
          <button type="button" className={iconBtn} onClick={() => onMove(-1)} disabled={index === 0} aria-label="Move up">
            <ArrowUp className="h-4 w-4" />
          </button>
          <button type="button" className={iconBtn} onClick={() => onMove(1)} disabled={index === total - 1} aria-label="Move down">
            <ArrowDown className="h-4 w-4" />
          </button>
          <button type="button" className={iconBtn} onClick={onDuplicate} aria-label="Duplicate">
            <Copy className="h-4 w-4" />
          </button>
          <button type="button" className={cn(iconBtn, 'hover:text-error-600')} onClick={onRemove} disabled={!!field.system}
            aria-label={field.system ? 'Locked: needed by "Create records"' : 'Delete'}
            title={field.system ? 'Needed by "Create records"' : undefined}>
            <Trash2 className="h-4 w-4" />
          </button>
        </div>
      )}
    </li>
  );
}

function TargetsCard({ targets, options, onToggle, onRole, readOnly }: {
  targets: FormTarget[]; options: TargetOption[]; readOnly?: boolean;
  onToggle: (type: TargetType, on: boolean) => void; onRole: (role: string) => void;
}) {
  if (options.length === 0) return null;
  const user = targets.find((t) => t.type === 'user');
  const userOption = options.find((o) => o.key === 'user');
  return (
    <Card padding="sm">
      <div className="flex items-start gap-3">
        <span className="mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-primary-500/10 text-primary-500">
          <UserPlus className="h-4 w-4" aria-hidden="true" />
        </span>
        <div className="min-w-0 flex-1">
          <h2 className="text-sm font-semibold text-secondary-900">Create records from each response</h2>
          <p className="text-xs text-secondary-500">
            Ticking one adds the name and email questions it needs and locks them. An email that already exists is linked, never changed.
          </p>
          <div className="mt-3 space-y-2.5">
            {options.map((o) => {
              const on = targets.some((t) => t.type === o.key);
              return (
                <div key={o.key} className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <p className="text-sm font-medium text-secondary-800">{o.label}</p>
                    <p className="text-xs text-secondary-500">
                      {o.allowed ? o.description : `Needs the ${o.permission} permission.`}
                    </p>
                  </div>
                  <Switch checked={on} disabled={readOnly || (!o.allowed && !on)} aria-label={o.label}
                    onChange={(b) => onToggle(o.key, b)} />
                </div>
              );
            })}
          </div>
          {user && userOption && (
            <div className="mt-3 rounded-lg bg-warning-500/10 p-3">
              <p className="text-xs text-warning-600">
                Anyone with the link can ask to join this workspace. They get the role below only after accepting
                the invitation from their email.
              </p>
              <Select className="mt-2" aria-label="Role for invited people" value={user.role || ''} disabled={readOnly}
                onChange={(e) => onRole(e.target.value)}>
                {(userOption.roles || []).map((r) => <option key={r.name} value={r.name}>{r.label}</option>)}
              </Select>
            </div>
          )}
        </div>
      </div>
    </Card>
  );
}

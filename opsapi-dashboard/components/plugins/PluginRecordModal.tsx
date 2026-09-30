'use client';

/**
 * Create / edit / view form for one record of a plugin resource. The inputs
 * come from the resource schema (see services/plugins.service.ts), so any
 * plugin's sdk.crud fields render here without plugin-specific code.
 */

import React, { useState } from 'react';
import toast from 'react-hot-toast';
import { format } from 'date-fns';
import { Modal, Button, Input, Textarea, Select, DateTimeField } from '@/components/ui';
import { CheckboxField, Pill, apiError } from '@/components/field-service/shared';
import { formatDate } from '@/lib/utils';
import {
  pluginService,
  type PluginField,
  type PluginRecord,
  type PluginResourceSchema,
} from '@/services/plugins.service';

type FormValue = string | boolean;
type FormState = Record<string, FormValue>;

/** "Tickets" → "Ticket", "Categories" → "Category" (UI copy only). */
export function singular(label: string): string {
  if (/ies$/i.test(label)) return label.slice(0, -3) + 'y';
  if (/s$/i.test(label) && !/ss$/i.test(label)) return label.slice(0, -1);
  return label;
}

// Postgres returns "2026-09-30 06:00:00+00"; Safari needs "T" and "+00:00".
function parseTimestamp(value: unknown): Date | null {
  if (typeof value !== 'string' || !value) return null;
  const d = new Date(value.replace(' ', 'T').replace(/([+-]\d\d)$/, '$1:00'));
  return Number.isNaN(d.getTime()) ? null : d;
}

function truncate(text: string, max: number): string {
  return text.length > max ? `${text.slice(0, max - 1)}…` : text;
}

/** Read-only rendering of a value, for table cells and the view mode. */
export function renderValue(field: PluginField, value: unknown): React.ReactNode {
  if (value === null || value === undefined || value === '') {
    return <span className="text-secondary-400">—</span>;
  }
  switch (field.type) {
    case 'boolean':
      return value ? (
        <Pill className="bg-green-50 text-green-700">Yes</Pill>
      ) : (
        <Pill className="bg-secondary-100 text-secondary-500">No</Pill>
      );
    case 'date':
      try {
        return formatDate(String(value).slice(0, 10));
      } catch {
        return String(value);
      }
    case 'datetime': {
      const d = parseTimestamp(value);
      return d ? format(d, 'MMM d, yyyy h:mm a') : String(value);
    }
    case 'json':
      return (
        <code className="text-xs text-secondary-600">
          {truncate(typeof value === 'string' ? value : JSON.stringify(value), 60)}
        </code>
      );
    case 'text':
      return truncate(String(value), 80);
    default:
      if (field.enum) return <Pill className="bg-primary-50 text-primary-700">{String(value)}</Pill>;
      return String(value);
  }
}

function toFormValue(field: PluginField, value: unknown): FormValue {
  if (field.type === 'boolean') return value === true;
  if (value === null || value === undefined) return '';
  switch (field.type) {
    case 'date':
      return String(value).slice(0, 10);
    case 'datetime': {
      const d = parseTimestamp(value);
      return d ? format(d, "yyyy-MM-dd'T'HH:mm") : '';
    }
    case 'json':
      return typeof value === 'string' ? value : JSON.stringify(value, null, 2);
    default:
      return String(value);
  }
}

// Form value → API value. Returns an error message for bad input.
function toPayloadValue(field: PluginField, value: FormValue): { value?: unknown; error?: string } {
  if (field.type === 'boolean') return { value };
  const text = String(value).trim();
  if (text === '') return { value: null };
  switch (field.type) {
    case 'integer':
    case 'number':
      return { value: Number(text) };
    case 'datetime': {
      const d = new Date(text);
      return Number.isNaN(d.getTime()) ? { error: 'must be a valid date and time' } : { value: d.toISOString() };
    }
    case 'json':
      try {
        return { value: JSON.parse(text) };
      } catch {
        return { error: 'must be valid JSON' };
      }
    default:
      return { value: text };
  }
}

function capitalize(message: string): string {
  return message.charAt(0).toUpperCase() + message.slice(1);
}

function FieldInput({
  field,
  value,
  error,
  onChange,
}: {
  field: PluginField;
  value: FormValue;
  error?: string;
  onChange: (value: FormValue) => void;
}) {
  const label = field.required ? `${field.label} *` : field.label;
  const text = typeof value === 'string' ? value : '';
  const id = `plugin-field-${field.name}`;

  if (field.type === 'boolean') {
    return <CheckboxField label={field.label} checked={value === true} onChange={onChange} />;
  }
  if (field.enum) {
    return (
      <Select
        id={id}
        label={label}
        value={text}
        onChange={(e) => onChange(e.target.value)}
        error={!!error}
        helperText={error}
      >
        <option value="">{field.required ? 'Select…' : '—'}</option>
        {field.enum.map((option) => (
          <option key={option} value={option}>
            {option}
          </option>
        ))}
      </Select>
    );
  }
  if (field.type === 'text' || field.type === 'json') {
    return (
      <Textarea
        id={id}
        label={label}
        value={text}
        rows={field.type === 'json' ? 6 : 4}
        className={field.type === 'json' ? 'font-mono text-xs' : undefined}
        onChange={(e) => onChange(e.target.value)}
        error={error}
      />
    );
  }
  if (field.type === 'date' || field.type === 'datetime') {
    return (
      <DateTimeField
        id={id}
        mode={field.type}
        label={label}
        value={text}
        onChange={(e) => onChange(e.target.value)}
        error={error}
      />
    );
  }
  const numeric = field.type === 'integer' || field.type === 'number';
  return (
    <Input
      id={id}
      label={label}
      type={numeric ? 'number' : field.type === 'email' ? 'email' : 'text'}
      step={field.type === 'integer' ? 1 : numeric ? 'any' : undefined}
      min={numeric ? field.min : undefined}
      max={numeric ? field.max : undefined}
      maxLength={numeric ? undefined : (field.max ?? 255)}
      value={text}
      onChange={(e) => onChange(e.target.value)}
      error={error}
    />
  );
}

interface PluginRecordModalProps {
  isOpen: boolean;
  schema: PluginResourceSchema;
  /** null = create a new record. */
  record: PluginRecord | null;
  onClose: () => void;
  onSaved: () => void;
}

export function PluginRecordModal(props: PluginRecordModalProps) {
  const { isOpen, schema, record, onClose } = props;
  const readOnly = !!record && !schema.can.update;
  const name = singular(schema.label).toLowerCase();
  const title = readOnly ? singular(schema.label) : record ? `Edit ${name}` : `New ${name}`;
  return (
    <Modal isOpen={isOpen} onClose={onClose} title={title} description={schema.plugin.name} size="lg">
      {isOpen &&
        (readOnly && record ? (
          <RecordView schema={schema} record={record} />
        ) : (
          // Keyed so switching records resets the form state.
          <RecordForm key={record?.uuid ?? 'new'} {...props} />
        ))}
    </Modal>
  );
}

function RecordView({ schema, record }: { schema: PluginResourceSchema; record: PluginRecord }) {
  return (
    <dl className="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-4">
      {schema.fields.map((field) => (
        <div key={field.name} className={field.type === 'text' || field.type === 'json' ? 'sm:col-span-2' : ''}>
          <dt className="text-xs font-medium uppercase tracking-wide text-secondary-500">{field.label}</dt>
          <dd className="mt-1 text-sm text-secondary-900 whitespace-pre-wrap break-words">
            {field.type === 'text' ? String(record[field.name] ?? '—') : renderValue(field, record[field.name])}
          </dd>
        </div>
      ))}
    </dl>
  );
}

function RecordForm({ schema, record, onClose, onSaved }: PluginRecordModalProps) {
  const [form, setForm] = useState<FormState>(() =>
    Object.fromEntries(schema.fields.map((f) => [f.name, toFormValue(f, record?.[f.name])]))
  );
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [saving, setSaving] = useState(false);
  const name = singular(schema.label).toLowerCase();

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    const payload: Record<string, unknown> = {};
    const problems: Record<string, string> = {};
    for (const field of schema.fields) {
      const { value, error } = toPayloadValue(field, form[field.name]);
      if (error) problems[field.name] = capitalize(error);
      else if (value === null && field.required) problems[field.name] = `${field.label} is required`;
      // On create leave empty optional fields out; on edit send null to clear them.
      else if (value !== null || record) payload[field.name] = value;
    }
    setErrors(problems);
    if (Object.keys(problems).length > 0) return;

    setSaving(true);
    try {
      if (record) await pluginService.update(schema, record.uuid, payload);
      else await pluginService.create(schema, payload);
      toast.success(record ? `${singular(schema.label)} updated` : `${singular(schema.label)} created`);
      onSaved();
      onClose();
    } catch (err) {
      const details = (err as { response?: { data?: { details?: Record<string, string> } } })?.response?.data?.details;
      if (details && typeof details === 'object') {
        setErrors(Object.fromEntries(Object.entries(details).map(([k, v]) => [k, capitalize(String(v))])));
        toast.error('Please fix the highlighted fields');
      } else {
        toast.error(apiError(err, `Could not save ${name}`));
      }
    } finally {
      setSaving(false);
    }
  };

  return (
    <form onSubmit={submit} noValidate className="space-y-4">
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        {schema.fields.map((field) => (
          <div
            key={field.name}
            className={
              field.type === 'text' || field.type === 'json' || field.type === 'boolean' ? 'sm:col-span-2' : ''
            }
          >
            <FieldInput
              field={field}
              value={form[field.name]}
              error={errors[field.name]}
              onChange={(value) => setForm((f) => ({ ...f, [field.name]: value }))}
            />
          </div>
        ))}
      </div>
      <div className="flex justify-end gap-3 pt-2">
        <Button type="button" variant="outline" onClick={onClose} disabled={saving}>
          Cancel
        </Button>
        <Button type="submit" isLoading={saving}>
          {record ? 'Save changes' : `Create ${name}`}
        </Button>
      </div>
    </form>
  );
}

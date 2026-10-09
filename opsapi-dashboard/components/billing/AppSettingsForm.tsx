'use client';

/**
 * An app's settings, rendered from the server's settings schema
 * (GET /api/v2/billing/settings-schema): a new setting appears here without
 * a dashboard change. Only changed values are sent.
 */

import React, { useEffect, useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { Button, Card, Input, Select, Switch, Textarea } from '@/components/ui';
import { apiError } from '@/components/field-service/shared';
import { CopyButton } from '@/components/billing/shared';
import { billingService, type BillingApp, type SettingSpec } from '@/services/billing.service';

const GROUPS: { id: string; title: string; hint?: string }[] = [
  { id: 'offline', title: 'Offline behaviour', hint: 'How long apps keep working without reaching OpsAPI.' },
  { id: 'licences', title: 'Licences and devices' },
  { id: 'public', title: 'Public endpoints', hint: 'Where browsers may call from, redirects, and abuse limits.' },
  { id: 'customers', title: 'Customers and privacy' },
  { id: 'branding', title: 'Branding', hint: 'Used on hosted pages and in emails.' },
  { id: 'delivery', title: 'Key delivery' },
  { id: 'payments', title: 'Payments' },
];

type Values = Record<string, unknown>;

function Field({
  spec,
  value,
  onChange,
  disabled,
}: {
  spec: SettingSpec;
  value: unknown;
  onChange: (v: unknown) => void;
  disabled: boolean;
}) {
  const id = `setting-${spec.key}`;
  const help = spec.help;
  switch (spec.type) {
    case 'boolean':
      return (
        <div className="flex items-center justify-between gap-3 rounded-lg border border-secondary-200 px-3 py-2">
          <div>
            <p className="text-sm font-medium text-secondary-800">{spec.label}</p>
            {help && <p className="text-xs text-secondary-500">{help}</p>}
          </div>
          <Switch checked={value === true} onChange={onChange} disabled={disabled} aria-label={spec.label} />
        </div>
      );
    case 'enum':
      return (
        <Select id={id} label={spec.label} value={String(value ?? '')} onChange={(e) => onChange(e.target.value)} helperText={help} disabled={disabled}>
          {(spec.values || []).map((v) => (
            <option key={v} value={v}>
              {v.replace(/_/g, ' ')}
            </option>
          ))}
        </Select>
      );
    case 'integer':
      return (
        <Input
          id={id}
          label={spec.label}
          type="number"
          min={spec.min}
          max={spec.max}
          value={value === null || value === undefined ? '' : String(value)}
          placeholder={spec.nullable ? 'Unlimited' : undefined}
          onChange={(e) => onChange(e.target.value === '' ? (spec.nullable ? null : spec.min) : Math.floor(Number(e.target.value)))}
          helperText={help}
          disabled={disabled}
        />
      );
    case 'origins':
    case 'urls':
      return (
        <Textarea
          id={id}
          label={`${spec.label} (one per line)`}
          rows={3}
          value={Array.isArray(value) ? (value as string[]).join('\n') : ''}
          onChange={(e) => onChange(e.target.value.split('\n').map((s) => s.trim()).filter(Boolean))}
          placeholder={spec.type === 'origins' ? 'https://app.example.com' : 'https://app.example.com/account'}
          helperText={help}
          disabled={disabled}
        />
      );
    case 'object':
      return (
        <fieldset className="rounded-lg border border-secondary-200 p-3" disabled={disabled}>
          <legend className="px-1 text-sm font-medium text-secondary-800">{spec.label}</legend>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            {(spec.fields || []).map((f) => {
              const obj = (value as Record<string, number>) || {};
              return (
                <Input
                  key={f.key}
                  label={f.key.replace(/_/g, ' ')}
                  type="number"
                  min={f.min}
                  max={f.max}
                  value={String(obj[f.key] ?? f.default)}
                  onChange={(e) => onChange({ ...obj, [f.key]: Math.floor(Number(e.target.value)) })}
                />
              );
            })}
          </div>
        </fieldset>
      );
    case 'color':
      return (
        <div>
          <label htmlFor={id} className="block text-sm font-medium text-secondary-700 mb-1">
            {spec.label}
          </label>
          <div className="flex items-center gap-2">
            <input
              id={id}
              type="color"
              value={typeof value === 'string' && value ? value : '#2563eb'}
              onChange={(e) => onChange(e.target.value)}
              disabled={disabled}
              className="h-10 w-14 rounded border border-secondary-300"
            />
            <code className="text-xs text-secondary-500">{String(value || '—')}</code>
          </div>
        </div>
      );
    default:
      if (spec.readonly) {
        return (
          <div>
            <p className="text-sm font-medium text-secondary-700 mb-1">{spec.label}</p>
            <div className="flex items-center gap-1">
              <code className="truncate rounded bg-secondary-100 px-2 py-1 text-xs">{String(value ?? '')}</code>
              {value ? <CopyButton value={String(value)} label={`Copy ${spec.label}`} /> : null}
            </div>
            {help && <p className="mt-1 text-xs text-secondary-500">{help}</p>}
          </div>
        );
      }
      return (
        <Input
          id={id}
          label={spec.label}
          type={spec.type === 'email' ? 'email' : spec.type === 'url' ? 'url' : 'text'}
          value={String(value ?? '')}
          onChange={(e) => onChange(e.target.value)}
          helperText={help}
          disabled={disabled}
        />
      );
  }
}

export default function AppSettingsForm({
  app,
  editable,
  onSaved,
}: {
  app: BillingApp;
  editable: boolean;
  onSaved: (a: BillingApp) => void;
}) {
  const [schema, setSchema] = useState<SettingSpec[]>([]);
  const [values, setValues] = useState<Values>(app.settings);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    billingService.settingsSchema(app.kind).then(setSchema).catch(() => setSchema([]));
  }, [app.kind]);

  const changed = useMemo(() => {
    const out: Values = {};
    for (const s of schema) {
      if (s.readonly) continue;
      if (JSON.stringify(values[s.key] ?? null) !== JSON.stringify(app.settings[s.key] ?? null)) out[s.key] = values[s.key];
    }
    return out;
  }, [schema, values, app.settings]);

  const save = async (e: React.FormEvent) => {
    e.preventDefault();
    setSaving(true);
    try {
      const updated = await billingService.updateApp(app.uuid, { settings: changed });
      setValues(updated.settings);
      onSaved(updated);
      toast.success('Settings saved');
    } catch (err) {
      toast.error(apiError(err, 'Could not save the settings'));
    } finally {
      setSaving(false);
    }
  };

  if (schema.length === 0) return null;
  return (
    <form onSubmit={save} className="space-y-4">
      {GROUPS.map((g) => {
        const fields = schema.filter((s) => s.group === g.id);
        if (fields.length === 0) return null;
        return (
          <Card key={g.id} className="shadow-sm">
            <h2 className="text-base font-semibold text-secondary-900">{g.title}</h2>
            {g.hint && <p className="text-sm text-secondary-500">{g.hint}</p>}
            <div className="mt-4 grid grid-cols-1 sm:grid-cols-2 gap-4">
              {fields.map((s) => (
                <div key={s.key} className={s.type === 'object' || s.type === 'origins' || s.type === 'urls' ? 'sm:col-span-2' : ''}>
                  <Field
                    spec={s}
                    value={values[s.key]}
                    onChange={(v) => setValues((cur) => ({ ...cur, [s.key]: v }))}
                    disabled={!editable || !!s.readonly}
                  />
                </div>
              ))}
            </div>
          </Card>
        );
      })}
      {editable && (
        <div className="sticky bottom-4 flex justify-end">
          <Button type="submit" isLoading={saving} disabled={Object.keys(changed).length === 0}>
            Save settings{Object.keys(changed).length > 0 ? ` (${Object.keys(changed).length})` : ''}
          </Button>
        </div>
      )}
    </form>
  );
}

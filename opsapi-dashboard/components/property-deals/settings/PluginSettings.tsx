'use client';

/**
 * The plugin's scalar settings (manifest `settings`), grouped: SLA & escalation, urgency
 * weights, digest & notifications, AI caps, matching weights, retention, general.
 * Saved through core PUT /api/v2/namespace/plugins/property_deals (needs namespace.update).
 */
import React, { useEffect, useState } from 'react';
import toast from 'react-hot-toast';
import { Button, Card, Input, Select, Switch } from '@/components/ui';
import { pdService, pdErrorText, type PluginSettingDef } from '@/services/property-deals.service';
import { ErrorNote, Spinner } from '../ui';
import { usePdData } from '../usePd';

const GROUPS: { title: string; hint: string; match: (n: string) => boolean }[] = [
  { title: 'SLA and escalation', hint: 'When the owner is warned, the task goes overdue (manager told) and is reassigned.', match: (n) => /^sla_|^escalation|^red_min|^due_time/.test(n) },
  { title: 'Urgency weights', hint: 'How the urgency score is made (docs: urgency.md). They need not add up to 100.', match: (n) => n.startsWith('urgency_') },
  { title: 'Daily digest and notifications', hint: 'When each person gets their day, and whether escalations can be muted.', match: (n) => /^digest|escalations_always|expiring_within/.test(n) },
  { title: 'AI budget', hint: 'Caps for every agent run and per day (USD).', match: (n) => n.startsWith('ai_') },
  { title: 'Buyer matching weights', hint: 'Budget, area, strategy, yield/discount and condition fit.', match: (n) => n.startsWith('match_w_') },
  { title: 'Data retention', hint: 'Applied nightly. Facts (who, when, outcome, cost) are kept.', match: (n) => n.startsWith('retention_') },
  { title: 'General', hint: 'Time zone, holiday calendar, currency and the board’s default template.', match: () => true },
];

export default function PluginSettings({ canEdit }: { canEdit: boolean }) {
  const info = usePdData(async () => pdService.pluginInfo(), []);
  const [values, setValues] = useState<Record<string, unknown>>({});
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    const v: Record<string, unknown> = {};
    for (const s of info.data?.settings || []) v[s.name] = s.value ?? s.default;
    setValues(v);
  }, [info.data]);

  if (info.loading && !info.data) return <Spinner />;
  if (info.error) return <ErrorNote error={info.error} />;
  const defs = info.data?.settings || [];
  const used = new Set<string>();

  function field(s: PluginSettingDef) {
    const v = values[s.name];
    const set = (nv: unknown) => setValues({ ...values, [s.name]: nv });
    if (s.type === 'boolean') {
      return (
        <label key={s.name} className="flex items-center justify-between gap-3 rounded-lg border border-secondary-200 p-3 text-sm">
          <span>
            <span className="font-medium text-secondary-900">{s.label}</span>
            {s.description && <span className="block text-xs text-secondary-500">{s.description}</span>}
          </span>
          <Switch checked={Boolean(v)} onChange={(c: boolean) => set(c)} disabled={!canEdit} />
        </label>
      );
    }
    if (s.enum) {
      return (
        <Select key={s.name} label={s.label} helperText={s.description} value={String(v ?? '')} disabled={!canEdit} onChange={(e) => set(e.target.value)}>
          {s.enum.map((o) => <option key={o} value={o}>{o.replace(/_/g, ' ')}</option>)}
        </Select>
      );
    }
    const numeric = s.type === 'integer' || s.type === 'number';
    return (
      <Input
        key={s.name}
        label={s.label}
        helperText={s.description}
        type={numeric ? 'number' : 'text'}
        step={s.type === 'number' ? 'any' : undefined}
        min={s.min}
        max={s.max}
        value={v === undefined || v === null ? '' : String(v)}
        disabled={!canEdit}
        onChange={(e) => set(numeric ? (e.target.value === '' ? undefined : Number(e.target.value)) : e.target.value)}
      />
    );
  }

  return (
    <div className="space-y-5">
      {GROUPS.map((g) => {
        const items = defs.filter((d) => !used.has(d.name) && g.match(d.name));
        items.forEach((d) => used.add(d.name));
        if (!items.length) return null;
        return (
          <Card key={g.title}>
            <h3 className="font-semibold text-secondary-900">{g.title}</h3>
            <p className="mb-4 text-sm text-secondary-500">{g.hint}</p>
            <div className="grid gap-3 sm:grid-cols-2">{items.map(field)}</div>
          </Card>
        );
      })}
      {canEdit ? (
        <div className="flex justify-end">
          <Button isLoading={busy} onClick={async () => {
            setBusy(true);
            try {
              const changed: Record<string, unknown> = {};
              for (const s of defs) if (values[s.name] !== (s.value ?? s.default)) changed[s.name] = values[s.name];
              if (!Object.keys(changed).length) { toast('Nothing changed'); return; }
              await pdService.savePluginSettings(changed);
              toast.success('Settings saved');
              info.refresh();
            } catch (e) {
              toast.error(pdErrorText(e));
            } finally {
              setBusy(false);
            }
          }}>Save settings</Button>
        </div>
      ) : (
        <p className="text-sm text-secondary-500">Only workspace admins can change these.</p>
      )}
    </div>
  );
}

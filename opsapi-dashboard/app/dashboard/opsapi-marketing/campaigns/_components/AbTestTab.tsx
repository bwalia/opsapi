'use client';

import React, { useState } from 'react';
import { Plus, Save, Trash2, FlaskConical } from 'lucide-react';
import { Button } from '@/components/ui';
import { marketingService } from '@/services/opsapi-marketing.service';
import {
  type AbVariant,
  type Campaign,
  INPUT_CLASS,
  Notice,
  Toggle,
  apiErrorMessage,
  unwrap,
  normaliseCampaign,
} from './shared';

type Row = { key: string; subject: string; body_html: string; body_text: string; weight: string; override: boolean };

const MAX_VARIANTS = 5;

function toRows(c: Campaign): Row[] {
  const vs = c.ab_config?.variants ?? [];
  if (vs.length >= 2) {
    return vs.map((v) => ({
      key: v.key,
      subject: v.subject ?? '',
      body_html: v.body_html ?? '',
      body_text: v.body_text ?? '',
      weight: v.weight != null ? String(v.weight) : '',
      override: !!(v.body_html || v.body_text),
    }));
  }
  return [
    { key: 'A', subject: c.subject ?? '', body_html: '', body_text: '', weight: '50', override: false },
    { key: 'B', subject: '', body_html: '', body_text: '', weight: '50', override: false },
  ];
}

function nextKey(rows: Row[]): string {
  for (const k of 'ABCDEFGHIJ') if (!rows.some((r) => r.key === k)) return k;
  return `V${rows.length + 1}`;
}

export default function AbTestTab({
  campaign,
  editable,
  onSaved,
}: {
  campaign: Campaign;
  /** A/B config is only editable in draft/validated. */
  editable: boolean;
  onSaved: (c: Campaign, message: string) => void;
}) {
  const [enabled, setEnabled] = useState(campaign.ab_config?.enabled === true);
  const [rows, setRows] = useState<Row[]>(() => toRows(campaign));
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const update = (i: number, patch: Partial<Row>) =>
    setRows((rs) => rs.map((r, idx) => (idx === i ? { ...r, ...patch } : r)));

  const totalWeight = rows.reduce((sum, r) => sum + (Number(r.weight) || 0), 0);

  const validate = (): string | null => {
    if (rows.length < 2) return 'An A/B test needs at least two variants.';
    const keys = rows.map((r) => r.key.trim());
    if (keys.some((k) => !k)) return 'Every variant needs a key.';
    if (new Set(keys).size !== keys.length) return 'Variant keys must be unique.';
    if (rows.some((r) => r.weight.trim() !== '' && !(Number(r.weight) > 0))) return 'Weights must be positive numbers.';
    if (enabled && rows.some((r) => !r.subject.trim() && !(campaign.subject ?? '').trim()))
      return 'Give each variant a subject (or set a campaign subject to fall back to).';
    return null;
  };

  const save = async () => {
    const problem = validate();
    if (problem) {
      setError(problem);
      return;
    }
    setSaving(true);
    setError(null);
    const variants: AbVariant[] = rows.map((r) => {
      const v: AbVariant = { key: r.key.trim() };
      if (r.subject.trim()) v.subject = r.subject;
      if (r.override && r.body_html.trim()) v.body_html = r.body_html;
      if (r.override && r.body_text.trim()) v.body_text = r.body_text;
      if (r.weight.trim()) v.weight = Number(r.weight);
      return v;
    });
    try {
      const res = await marketingService.setAbConfig(campaign.uuid, { enabled, variants });
      const row = normaliseCampaign(unwrap<Campaign>(res));
      const saved = enabled ? 'A/B test saved and enabled.' : 'A/B variants saved (test disabled).';
      onSaved(
        row,
        campaign.status !== 'draft' && row.status === 'draft'
          ? `${saved} The campaign went back to draft — validate it again before sending.`
          : saved,
      );
    } catch (e: unknown) {
      setError(apiErrorMessage(e, 'Could not save A/B test'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="space-y-4">
      {!editable && (
        <Notice tone="warn">
          A/B settings can only be changed while the campaign is a draft or validated. Duplicate the campaign to test a
          new idea.
        </Notice>
      )}
      {error && <Notice tone="error">{error}</Notice>}

      <fieldset disabled={!editable} className="space-y-4">
        <legend className="sr-only">A/B test</legend>
        <section className="space-y-3 rounded-lg border border-secondary-200 p-4">
          <div className="flex items-center gap-2">
            <FlaskConical className="h-4 w-4 text-secondary-500" aria-hidden="true" />
            <h2 className="text-sm font-medium">Split test</h2>
          </div>
          <Toggle
            id="ab-enabled"
            label="Enable A/B test"
            description="Each contact is assigned a variant by a stable hash of their ID, so re-sends and resumes always give a contact the same variant. Weights set the split."
            checked={enabled}
            onChange={setEnabled}
          />
        </section>

        <div className={enabled ? 'space-y-3' : 'space-y-3 opacity-60'}>
          {rows.map((r, i) => {
            const share = totalWeight > 0 ? ((Number(r.weight) || 0) / totalWeight) * 100 : 100 / rows.length;
            return (
              <section
                key={i}
                aria-label={`Variant ${r.key || i + 1}`}
                className="space-y-3 rounded-lg border border-secondary-200 p-4"
              >
                <div className="flex flex-wrap items-end gap-3">
                  <label className="block text-sm">
                    <span className="font-medium">Key</span>
                    <input
                      className={`${INPUT_CLASS} mt-1 block w-20`}
                      value={r.key}
                      onChange={(e) => update(i, { key: e.target.value.slice(0, 16) })}
                    />
                  </label>
                  <label className="block min-w-64 flex-1 text-sm">
                    <span className="font-medium">Subject</span>
                    <input
                      className={`${INPUT_CLASS} mt-1 block w-full`}
                      value={r.subject}
                      onChange={(e) => update(i, { subject: e.target.value })}
                      placeholder={campaign.subject ?? 'Subject line'}
                    />
                  </label>
                  <label className="block text-sm">
                    <span className="font-medium">Weight</span>
                    <input
                      type="number"
                      min={1}
                      className={`${INPUT_CLASS} mt-1 block w-24`}
                      value={r.weight}
                      onChange={(e) => update(i, { weight: e.target.value })}
                      placeholder="1"
                    />
                  </label>
                  <span className="pb-2 text-xs tabular-nums text-secondary-500">≈ {share.toFixed(0)}% of sends</span>
                  <Button
                    size="sm"
                    variant="ghost"
                    leftIcon={<Trash2 className="h-4 w-4" />}
                    onClick={() => setRows((rs) => rs.filter((_, idx) => idx !== i))}
                    disabled={rows.length <= 2}
                    aria-label={`Remove variant ${r.key}`}
                  >
                    Remove
                  </Button>
                </div>
                <Toggle
                  id={`ab-override-${i}`}
                  label="Override body for this variant"
                  description="Otherwise the campaign's main content is used."
                  checked={r.override}
                  onChange={(v) => update(i, { override: v })}
                />
                {r.override && (
                  <div className="grid gap-3 lg:grid-cols-2">
                    <label className="block text-sm">
                      <span className="font-medium">HTML body</span>
                      <textarea
                        className={`${INPUT_CLASS} mt-1 h-40 w-full font-mono text-xs`}
                        value={r.body_html}
                        onChange={(e) => update(i, { body_html: e.target.value })}
                        spellCheck={false}
                      />
                    </label>
                    <label className="block text-sm">
                      <span className="font-medium">Plain-text body</span>
                      <textarea
                        className={`${INPUT_CLASS} mt-1 h-40 w-full font-mono text-xs`}
                        value={r.body_text}
                        onChange={(e) => update(i, { body_text: e.target.value })}
                      />
                    </label>
                  </div>
                )}
              </section>
            );
          })}
        </div>

        <div className="flex flex-wrap items-center gap-2">
          <Button
            variant="outline"
            leftIcon={<Plus className="h-4 w-4" />}
            onClick={() =>
              setRows((rs) => [
                ...rs,
                { key: nextKey(rs), subject: '', body_html: '', body_text: '', weight: '50', override: false },
              ])
            }
            disabled={rows.length >= MAX_VARIANTS}
          >
            Add variant
          </Button>
          <Button leftIcon={<Save className="h-4 w-4" />} onClick={() => void save()} isLoading={saving}>
            Save A/B test
          </Button>
        </div>
        <p className="text-xs text-secondary-500">
          Results and the statistical winner appear on the Performance tab once the campaign is sending.
        </p>
      </fieldset>
    </div>
  );
}

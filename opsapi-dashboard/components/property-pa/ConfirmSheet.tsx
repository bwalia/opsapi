'use client';

/**
 * The capture confirm sheet (HOW-IT-WORKS scene 3): every change the PA proposed from a note, typed
 * stated / inferred / proposed, with the words it came from. [Change something] lets the person correct or
 * reject single rows; [Confirm] applies the rest. Material rows (price, offer, decision makers, next action)
 * are marked: nothing is applied without this confirmation.
 */
import React, { useMemo, useState } from 'react';
import { Check, Pencil, Undo2, X, Quote } from 'lucide-react';
import toast from 'react-hot-toast';
import { Badge, Button, Card, Input } from '@/components/ui';
import { cn } from '@/lib/utils';
import { paService, type CaptureSheet, type Decision, type SheetRow } from '@/services/property-pa.service';
import { pdErrorText } from '@/services/property-deals.service';

const MONEY_FIELDS = new Set(['expectation_price', 'est_market_value']);

const gbp = (v: unknown) => {
  const n = Number(v);
  return Number.isFinite(n) ? n.toLocaleString('en-GB', { style: 'currency', currency: 'GBP', maximumFractionDigits: 0 }) : String(v ?? '—');
};

const when = (v: unknown) => {
  const d = new Date(String(v));
  return Number.isNaN(d.getTime()) ? String(v ?? '') : d.toLocaleString('en-GB', { weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
};

type Obj = Record<string, unknown>;

/** A proposed value as one readable line. */
export function valueText(row: Pick<SheetRow, 'field' | 'target_table' | 'owner'>, v: unknown): string {
  if (v === null || v === undefined || v === '') return '—';
  if (MONEY_FIELDS.has(row.field)) return gbp(v);
  if (row.field === 'decision_makers' && Array.isArray(v)) {
    return v.map((d) => (typeof d === 'object' && d ? `${(d as Obj).name ?? '?'}${(d as Obj).role ? ` (${(d as Obj).role})` : ''}` : String(d))).join(', ');
  }
  if (row.target_table === 'next_action' && typeof v === 'object') {
    const a = v as Obj;
    return `${a.title ?? 'Next action'} — ${when(a.due_at)}${row.owner?.name ? ` · owner ${row.owner.name}` : ''}${a.reason ? ` · why: ${a.reason}` : ''}`;
  }
  if (row.target_table === 'pa_events' && typeof v === 'object') {
    const e = v as Obj;
    const amount = (e.details as Obj | undefined)?.amount;
    return `${e.title ?? e.kind}${amount ? ` (${gbp(amount)})` : ''} — ${when(e.at)}`;
  }
  if (row.target_table === 'pa_offers' && typeof v === 'object') {
    const o = v as Obj;
    return `Offer ${gbp(o.amount)}${o.conditions ? ` — ${o.conditions}` : ''}`;
  }
  if (typeof v === 'object') return JSON.stringify(v);
  return String(v);
}

const KIND_STYLE: Record<SheetRow['kind'], 'info' | 'warning' | 'secondary'> = {
  stated: 'info',
  inferred: 'warning',
  proposed: 'secondary',
};

/** The value being edited, as text fields. */
type Draft = { text: string; title?: string; due?: string; reason?: string };

function toDraft(row: SheetRow): Draft {
  const v = row.new_value;
  if (row.target_table === 'next_action' && v && typeof v === 'object') {
    const a = v as Obj;
    const d = new Date(String(a.due_at));
    const local = Number.isNaN(d.getTime()) ? '' : new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
    return { text: '', title: String(a.title ?? ''), due: local, reason: String(a.reason ?? '') };
  }
  if (row.field === 'decision_makers') return { text: valueText(row, v) };
  return { text: v === null || v === undefined ? '' : String(v) };
}

function fromDraft(row: SheetRow, d: Draft): unknown {
  if (row.target_table === 'next_action') {
    return { ...(row.new_value as Obj), title: d.title, reason: d.reason, due_at: d.due ? new Date(d.due).toISOString() : undefined };
  }
  if (row.field === 'decision_makers') {
    return d.text.split(',').map((s) => s.trim()).filter(Boolean).map((s) => {
      const m = s.match(/^(.*?)\s*\((.*)\)$/);
      return m ? { name: m[1], role: m[2] } : { name: s };
    });
  }
  if (MONEY_FIELDS.has(row.field) || row.field === 'bedrooms') {
    const n = Number(d.text.replace(/[£,\s]/g, '').replace(/k$/i, '000'));
    return Number.isFinite(n) ? n : d.text;
  }
  return d.text;
}

/** Rows a person can edit here (events and offers: keep or reject). */
const editable = (r: SheetRow) => r.target_table !== 'pa_events' && r.target_table !== 'pa_offers';

export default function ConfirmSheet({ sheet, onDecided }: { sheet: CaptureSheet; onDecided: (s: CaptureSheet) => void }) {
  const [edits, setEdits] = useState<Record<string, Draft>>({});
  const [rejects, setRejects] = useState<Record<string, boolean>>({});
  const [changing, setChanging] = useState(false);
  const [saving, setSaving] = useState(false);
  const open = useMemo(() => sheet.proposals.filter((r) => r.status === 'proposed'), [sheet.proposals]);

  const submit = async () => {
    const decisions: Decision[] = [];
    for (const r of open) {
      if (rejects[r.uuid]) decisions.push({ uuid: r.uuid, action: 'reject' });
      else if (edits[r.uuid]) decisions.push({ uuid: r.uuid, action: 'correct', value: fromDraft(r, edits[r.uuid]) });
    }
    setSaving(true);
    try {
      const out = await paService.decide(sheet.interaction.uuid, decisions, true);
      const failed = out.results.filter((x) => !x.ok);
      if (failed.length) toast.error(`${failed.length} change(s) not applied: ${failed.map((f) => f.error).join('; ')}`);
      else toast.success('Saved. The record is up to date.');
      setEdits({});
      setRejects({});
      setChanging(false);
      onDecided(out.sheet);
    } catch (e) {
      toast.error(pdErrorText(e));
    } finally {
      setSaving(false);
    }
  };

  if (!sheet.proposals.length) return null;
  const toApply = open.filter((r) => !rejects[r.uuid]).length;

  return (
    <Card className="space-y-4" data-testid="confirm-sheet">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h3 className="text-base font-semibold text-secondary-900">Check what I picked up</h3>
          <p className="text-sm text-secondary-500">
            {open.length ? `${open.length} change${open.length === 1 ? '' : 's'} to confirm` : 'All decided'}
            {sheet.counts.material ? ` · ${sheet.counts.material} need your confirmation (price, offer, decision makers, next action)` : ''}
          </p>
        </div>
        {sheet.run?.model && <span className="text-xs text-secondary-400">{sheet.run.model} · {sheet.run.prompt_version}</span>}
      </div>

      <ul className="divide-y divide-secondary-200 rounded-lg border border-secondary-200">
        {sheet.proposals.map((r) => {
          const editing = changing && r.status === 'proposed' && edits[r.uuid];
          const rejected = rejects[r.uuid] || r.status === 'rejected';
          return (
            <li key={r.uuid} className={cn('p-3', rejected && 'opacity-50')} data-testid="sheet-row">
              <div className="flex flex-wrap items-start justify-between gap-2">
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="text-sm font-medium text-secondary-900">{r.label}</span>
                    <Badge size="sm" variant={KIND_STYLE[r.kind]}>{r.kind_label}</Badge>
                    {r.material && <Badge size="sm" variant="error">Material</Badge>}
                    {r.status !== 'proposed' && <Badge size="sm" variant={r.status === 'rejected' ? 'secondary' : 'success'}>{r.status}</Badge>}
                  </div>
                  {!editing && (
                    <p className={cn('mt-1 text-sm text-secondary-800', rejected && 'line-through')}>
                      {r.old_value !== undefined && r.old_value !== null && r.target_table !== 'next_action' && (
                        <span className="text-secondary-400">{valueText(r, r.old_value)} → </span>
                      )}
                      {valueText(r, r.new_value)}
                    </p>
                  )}
                  {editing && (
                    <div className="mt-2 grid gap-2 sm:grid-cols-3">
                      {r.target_table === 'next_action' ? (
                        <>
                          <Input aria-label="Title" value={edits[r.uuid].title} onChange={(e) => setEdits({ ...edits, [r.uuid]: { ...edits[r.uuid], title: e.target.value } })} />
                          <Input aria-label="Due" type="datetime-local" value={edits[r.uuid].due} onChange={(e) => setEdits({ ...edits, [r.uuid]: { ...edits[r.uuid], due: e.target.value } })} />
                          <Input aria-label="Reason" value={edits[r.uuid].reason} onChange={(e) => setEdits({ ...edits, [r.uuid]: { ...edits[r.uuid], reason: e.target.value } })} />
                        </>
                      ) : (
                        <Input className="sm:col-span-3" aria-label={r.label} value={edits[r.uuid].text} onChange={(e) => setEdits({ ...edits, [r.uuid]: { ...edits[r.uuid], text: e.target.value } })} />
                      )}
                    </div>
                  )}
                  {r.source_quote && (
                    <p className="mt-1 flex items-start gap-1 text-xs italic text-secondary-500">
                      <Quote className="mt-0.5 h-3 w-3 shrink-0" aria-hidden />“{r.source_quote}”
                    </p>
                  )}
                </div>
                {changing && r.status === 'proposed' && (
                  <div className="flex gap-1">
                    {editable(r) && !rejects[r.uuid] && (
                      <Button size="sm" variant="ghost" leftIcon={edits[r.uuid] ? <Undo2 className="h-4 w-4" /> : <Pencil className="h-4 w-4" />}
                        onClick={() => {
                          const next = { ...edits };
                          if (next[r.uuid]) delete next[r.uuid];
                          else next[r.uuid] = toDraft(r);
                          setEdits(next);
                        }}>
                        {edits[r.uuid] ? 'Undo' : 'Change'}
                      </Button>
                    )}
                    <Button size="sm" variant="ghost" leftIcon={rejects[r.uuid] ? <Undo2 className="h-4 w-4" /> : <X className="h-4 w-4" />}
                      onClick={() => setRejects({ ...rejects, [r.uuid]: !rejects[r.uuid] })}>
                      {rejects[r.uuid] ? 'Keep' : 'Reject'}
                    </Button>
                  </div>
                )}
              </div>
            </li>
          );
        })}
      </ul>

      {open.length > 0 && (
        <div className="flex flex-wrap justify-end gap-2">
          <Button variant="outline" leftIcon={<Pencil className="h-4 w-4" />} onClick={() => setChanging(!changing)}>
            {changing ? 'Done changing' : 'Change something'}
          </Button>
          <Button leftIcon={<Check className="h-4 w-4" />} isLoading={saving} onClick={submit} data-testid="confirm-all">
            {toApply ? `Confirm ${toApply}` : 'Save'}
          </Button>
        </div>
      )}
    </Card>
  );
}

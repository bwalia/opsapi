'use client';

/**
 * Income types — what customers fill in under My Income, maintained without code.
 *
 * Accountants / workspace administrators (RBAC module `tax_income_types`) can:
 * reorder, hide/show, customise a built-in type for this workspace (and reset it),
 * or add the workspace's own type with its own form and estimate mapping.
 * Platform administrators can also change the default for every workspace.
 * Backend: lapis/routes/tax-my-income.lua (/api/v2/tax/income-types).
 */

import React, { useCallback, useEffect, useState } from 'react';
import { ArrowDown, ArrowUp, Layers, Loader2, Pencil, Plus } from 'lucide-react';
import toast from 'react-hot-toast';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { Modal, Switch } from '@/components/ui';
import IncomeTypeEditor from '@/components/tax/income/IncomeTypeEditor';
import { IncomeIcon } from '@/components/tax/income/IncomeIcon';
import { extractApiError } from '@/lib/utils';
import { myIncomeService, type AdminList, type BuilderMeta, type IncomeType } from '@/services/my-income.service';

function OriginBadge({ t }: { t: IncomeType }) {
  if (t.origin === 'custom')
    return <span className="rounded-full bg-violet-50 px-2 py-0.5 text-xs font-medium text-violet-700">Your own</span>;
  const customised = Object.keys(t.overridden ?? {}).filter((k) => k !== 'display_order').length > 0;
  return customised ? (
    <span className="rounded-full bg-amber-50 px-2 py-0.5 text-xs font-medium text-amber-800">Built-in · customised</span>
  ) : (
    <span className="rounded-full bg-secondary-100 px-2 py-0.5 text-xs font-medium text-secondary-600">Built-in</span>
  );
}

function IncomeTypesContent() {
  const [list, setList] = useState<AdminList | null>(null);
  const [order, setOrder] = useState<IncomeType[]>([]);
  const [orderDirty, setOrderDirty] = useState(false);
  const [meta, setMeta] = useState<BuilderMeta | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState<IncomeType | 'new' | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const l = await myIncomeService.adminList(true);
      setList(l);
      setOrder(l.types);
      setOrderDirty(false);
    } catch (e) {
      setError(extractApiError(e, 'Could not load income types.'));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
    myIncomeService.meta().then(setMeta).catch(() => setMeta(null));
  }, [load]);

  const move = (i: number, dir: -1 | 1) => {
    const j = i + dir;
    if (j < 0 || j >= order.length) return;
    const next = [...order];
    [next[i], next[j]] = [next[j], next[i]];
    setOrder(next);
    setOrderDirty(true);
  };

  const saveOrder = async () => {
    setBusy('order');
    try {
      await myIncomeService.reorder(order.map((t) => t.key));
      toast.success('Order saved');
      await load();
    } catch (e) {
      toast.error(extractApiError(e, 'Could not save the order.'));
    } finally {
      setBusy(null);
    }
  };

  const toggle = async (t: IncomeType, on: boolean) => {
    setBusy(t.key);
    try {
      await myIncomeService.update(t.key, { is_active: on });
      toast.success(on ? `${t.name} is shown to customers` : `${t.name} is hidden from customers`);
      await load();
    } catch (e) {
      toast.error(extractApiError(e, 'Could not change that.'));
    } finally {
      setBusy(null);
    }
  };

  const canEdit = !!list?.can_edit;

  return (
    <div className="space-y-6">
      <PageHeader
        title="Income types"
        description="The income types customers fill in under My Income. Changes apply to this workspace straight away."
        icon={<Layers className="h-5 w-5" />}
        actions={
          list?.can_create ? (
            <button
              type="button"
              onClick={() => setEditing('new')}
              className="inline-flex items-center gap-1.5 rounded-lg bg-primary-600 px-4 py-2 text-sm font-medium text-white hover:bg-primary-700"
            >
              <Plus className="h-4 w-4" aria-hidden="true" /> Add income type
            </button>
          ) : null
        }
      />

      <div className="rounded-xl border border-blue-200 bg-blue-50 p-4 text-sm text-blue-900">
        <strong>How this works.</strong> Each income type has a form (the questions customers answer) and an estimate
        mapping (which answers count as rent, pay, dividends…). Built-in types come with sensible defaults — customise them
        for your clients or reset them. Hiding a type stops new entries; figures already entered stay safe and still count.
      </div>

      {orderDirty && (
        <div className="sticky top-2 z-10 flex flex-col gap-2 rounded-xl border border-primary-200 bg-primary-50 p-3 shadow-sm sm:flex-row sm:items-center sm:justify-between">
          <p className="text-sm text-primary-900">You’ve changed the order customers see.</p>
          <div className="flex gap-2">
            <button type="button" onClick={() => { setOrder(list?.types ?? []); setOrderDirty(false); }} className="rounded-lg px-3 py-1.5 text-sm font-medium text-secondary-700 hover:bg-white">
              Undo
            </button>
            <button type="button" onClick={saveOrder} disabled={busy === 'order'} className="rounded-lg bg-primary-600 px-4 py-1.5 text-sm font-medium text-white hover:bg-primary-700 disabled:opacity-50">
              {busy === 'order' ? 'Saving…' : 'Save order'}
            </button>
          </div>
        </div>
      )}

      {loading && !list ? (
        <div className="flex items-center justify-center gap-2 py-16 text-secondary-500">
          <Loader2 className="h-5 w-5 animate-spin" aria-hidden="true" /> Loading…
        </div>
      ) : error ? (
        <div role="alert" className="rounded-xl border border-red-200 bg-red-50 p-5 text-sm text-red-800">
          {error}
        </div>
      ) : (
        <ol className="divide-y divide-secondary-100 overflow-hidden rounded-xl border border-secondary-200 bg-surface shadow-sm">
          {order.map((t, i) => (
            <li key={t.key} className={`flex flex-col gap-3 p-4 sm:flex-row sm:items-center ${t.is_active ? '' : 'bg-secondary-50/60'}`}>
              <div className="flex items-center gap-1">
                <button type="button" disabled={!canEdit || i === 0} onClick={() => move(i, -1)} className="rounded p-1.5 text-secondary-500 hover:bg-secondary-100 disabled:opacity-30" aria-label={`Move ${t.name} up`}>
                  <ArrowUp className="h-4 w-4" aria-hidden="true" />
                </button>
                <button type="button" disabled={!canEdit || i === order.length - 1} onClick={() => move(i, 1)} className="rounded p-1.5 text-secondary-500 hover:bg-secondary-100 disabled:opacity-30" aria-label={`Move ${t.name} down`}>
                  <ArrowDown className="h-4 w-4" aria-hidden="true" />
                </button>
              </div>
              <div className="flex min-w-0 flex-1 items-start gap-3">
                <span className={`flex h-9 w-9 shrink-0 items-center justify-center rounded-lg ${t.is_active ? 'bg-primary-500/10 text-primary-600' : 'bg-secondary-100 text-secondary-400'}`}>
                  <IncomeIcon name={t.icon} />
                </span>
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className={`font-medium ${t.is_active ? 'text-secondary-900' : 'text-secondary-500'}`}>{t.name}</span>
                    <OriginBadge t={t} />
                    {!t.is_active && <span className="rounded-full bg-secondary-200 px-2 py-0.5 text-xs text-secondary-600">Hidden</span>}
                  </div>
                  <p className="mt-0.5 text-xs text-secondary-500">
                    <span className="font-mono">{t.key}</span>
                    {t.schedule ? ` · ${t.schedule}` : ''}
                    {t.entity_type ? ` · per ${t.entity_label || t.entity_type}` : ''}
                    {` · ${t.field_schema.sections.reduce((n, s) => n + s.fields.length, 0)} questions`}
                    {t.in_estimate ? ' · in the estimate' : ' · not in the estimate'}
                    {t.usage_count ? ` · ${t.usage_count} saved` : ''}
                  </p>
                </div>
              </div>
              <div className="flex items-center gap-3 sm:justify-end">
                <span className="flex items-center gap-2 text-sm text-secondary-600">
                  <Switch checked={t.is_active} disabled={!canEdit || busy === t.key} onChange={(v) => toggle(t, v)} aria-label={`Show ${t.name} to customers`} />
                  <span className="hidden sm:inline">{t.is_active ? 'Shown' : 'Hidden'}</span>
                </span>
                {canEdit && (
                  <button type="button" onClick={() => setEditing(t)} className="inline-flex items-center gap-1.5 rounded-lg border border-secondary-300 px-3 py-1.5 text-sm font-medium text-secondary-700 hover:bg-secondary-50" aria-label={`Edit ${t.name}`}>
                    <Pencil className="h-4 w-4" aria-hidden="true" /> Edit
                  </button>
                )}
              </div>
            </li>
          ))}
        </ol>
      )}

      <Modal
        isOpen={editing !== null}
        onClose={() => setEditing(null)}
        title={editing === 'new' ? 'Add an income type' : editing ? `Edit ${editing.name}` : ''}
        size="3xl"
      >
        {editing !== null && (
          <IncomeTypeEditor
            initial={editing === 'new' ? undefined : editing}
            meta={meta}
            canEditGlobal={!!list?.can_edit_global}
            onCancel={() => setEditing(null)}
            onSaved={() => {
              setEditing(null);
              load();
            }}
          />
        )}
      </Modal>
    </div>
  );
}

export default function IncomeTypesPage() {
  return (
    <ProtectedPage module="tax_income_types" title="Income types">
      <IncomeTypesContent />
    </ProtectedPage>
  );
}

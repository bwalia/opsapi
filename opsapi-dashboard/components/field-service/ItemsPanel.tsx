'use client';

/**
 * Parts, materials and expenses charged to a job. Invoiced items are locked.
 * ItemFormModal is reused on the visit page to log parts used on site.
 */

import React, { useState } from 'react';
import toast from 'react-hot-toast';
import { Lock, Package, Pencil, Plus, Trash2 } from 'lucide-react';
import { Modal, Button, Input, Select, ConfirmDialog } from '@/components/ui';
import { fieldService, type FsJobItem, type FsPhase, type JobItemType } from '@/services/field-service.service';
import { CheckboxField, SectionCard, apiError, money } from './shared';

const ITEM_TYPE_LABELS: Record<JobItemType, string> = {
  part: 'Part',
  material: 'Material',
  labour: 'Labour',
  expense: 'Expense',
  other: 'Other',
};

interface ItemFormModalProps {
  isOpen: boolean;
  jobUuid: string;
  item?: FsJobItem | null;
  phases?: FsPhase[];
  /** Log the item against this visit (visit page). */
  visitUuid?: string;
  onClose: () => void;
  onSaved: () => void;
}

export function ItemFormModal(props: ItemFormModalProps) {
  return (
    <Modal isOpen={props.isOpen} onClose={props.onClose} title={props.item ? 'Edit item' : 'Add part / material'} size="md">
      {props.isOpen && <ItemForm {...props} />}
    </Modal>
  );
}

function ItemForm({ jobUuid, item, phases = [], visitUuid, onClose, onSaved }: ItemFormModalProps) {
  const [itemType, setItemType] = useState<JobItemType>(item?.item_type || 'part');
  const [description, setDescription] = useState(item?.description || '');
  const [quantity, setQuantity] = useState(item ? String(item.quantity) : '1');
  const [unitPrice, setUnitPrice] = useState(item ? String(item.unit_price) : '');
  const [taxRate, setTaxRate] = useState(item ? String(item.tax_rate) : '20');
  const [billable, setBillable] = useState(item?.is_billable ?? true);
  const [phaseUuid, setPhaseUuid] = useState(item?.phase_uuid || '');
  const [saving, setSaving] = useState(false);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!description.trim()) {
      toast.error('Description is required');
      return;
    }
    const payload: Record<string, unknown> = {
      item_type: itemType,
      description: description.trim(),
      quantity: Number(quantity) || 1,
      unit_price: Number(unitPrice) || 0,
      tax_rate: Number(taxRate) || 0,
      is_billable: billable,
    };
    if (phases.length) payload.phase_uuid = item ? phaseUuid : phaseUuid || undefined;
    if (visitUuid && !item) payload.visit_uuid = visitUuid;
    setSaving(true);
    try {
      if (item) await fieldService.updateItem(item.uuid, payload);
      else await fieldService.addItem(jobUuid, payload);
      toast.success(item ? 'Item updated' : 'Item added');
      onSaved();
      onClose();
    } catch (err) {
      toast.error(apiError(err, 'Failed to save item'));
    } finally {
      setSaving(false);
    }
  };

  const lineTotal = (Number(quantity) || 0) * (Number(unitPrice) || 0);

  return (
    <form onSubmit={submit} className="space-y-4">
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
        <Select label="Type" value={itemType} onChange={(e) => setItemType(e.target.value as JobItemType)}>
          {(Object.keys(ITEM_TYPE_LABELS) as JobItemType[]).map((t) => (
            <option key={t} value={t}>
              {ITEM_TYPE_LABELS[t]}
            </option>
          ))}
        </Select>
        <div className="sm:col-span-2">
          <Input label="Description *" value={description} onChange={(e) => setDescription(e.target.value)} autoFocus />
        </div>
        <Input label="Quantity" value={quantity} onChange={(e) => setQuantity(e.target.value)} inputMode="decimal" />
        <Input label="Unit price (net)" value={unitPrice} onChange={(e) => setUnitPrice(e.target.value)} inputMode="decimal" />
        <Input label="VAT %" value={taxRate} onChange={(e) => setTaxRate(e.target.value)} inputMode="decimal" />
      </div>
      {phases.length > 0 && (
        <Select label="Phase" value={phaseUuid} onChange={(e) => setPhaseUuid(e.target.value)}>
          <option value="">No specific phase</option>
          {phases.map((p) => (
            <option key={p.uuid} value={p.uuid}>
              {p.sort_order}. {p.name}
            </option>
          ))}
        </Select>
      )}
      <div className="flex items-center justify-between">
        <CheckboxField label="Billable to customer" checked={billable} onChange={setBillable} />
        <span className="text-sm text-secondary-600">Line total: {money(lineTotal)}</span>
      </div>
      <div className="flex justify-end gap-2">
        <Button type="button" variant="ghost" onClick={onClose}>
          Cancel
        </Button>
        <Button type="submit" isLoading={saving}>
          {item ? 'Save item' : 'Add item'}
        </Button>
      </div>
    </form>
  );
}

// ============================================================
// Items table (shared by the job and visit pages)
// ============================================================

export function ItemsTable({
  items,
  currency,
  canEdit,
  onEdit,
  onDelete,
}: {
  items: FsJobItem[];
  currency: string;
  /** true/false for every row, or a per-row check (engineers may only edit parts they logged). */
  canEdit: boolean | ((item: FsJobItem) => boolean);
  onEdit: (item: FsJobItem) => void;
  onDelete: (item: FsJobItem) => void;
}) {
  const editable = (item: FsJobItem) => (typeof canEdit === 'function' ? canEdit(item) : canEdit);
  if (items.length === 0) return <p className="text-sm text-secondary-500">No parts or materials logged.</p>;
  return (
    <div className="overflow-x-auto">
      <table className="w-full text-sm">
        <thead>
          <tr className="text-left text-xs uppercase tracking-wide text-secondary-500 border-b border-secondary-200">
            <th className="py-2 pr-3 font-medium">Item</th>
            <th className="py-2 pr-3 font-medium text-right">Qty</th>
            <th className="py-2 pr-3 font-medium text-right">Unit</th>
            <th className="py-2 pr-3 font-medium text-right">Total</th>
            <th className="py-2 w-20" />
          </tr>
        </thead>
        <tbody className="divide-y divide-secondary-100">
          {items.map((it) => (
            <tr key={it.uuid}>
              <td className="py-2 pr-3">
                <p className="text-secondary-900">{it.description}</p>
                <p className="text-xs text-secondary-500">
                  {ITEM_TYPE_LABELS[it.item_type] ?? it.item_type}
                  {it.phase_name ? ` · ${it.phase_name}` : ''}
                  {it.created_by_name ? ` · ${it.created_by_name}` : ''}
                  {!it.is_billable && ' · non-billable'}
                  {it.tax_rate ? ` · VAT ${it.tax_rate}%` : ''}
                </p>
              </td>
              <td className="py-2 pr-3 text-right">{it.quantity}</td>
              <td className="py-2 pr-3 text-right">{money(it.unit_price, currency)}</td>
              <td className="py-2 pr-3 text-right font-medium">{money(it.line_total, currency)}</td>
              <td className="py-2 text-right whitespace-nowrap">
                {it.invoiced ? (
                  <span className="inline-flex items-center gap-1 text-xs text-secondary-500" title="Invoiced — locked">
                    <Lock className="w-3 h-3" /> invoiced
                  </span>
                ) : (
                  editable(it) && (
                    <>
                      <button type="button" className="p-1.5 text-secondary-500 hover:text-primary-600" title="Edit" onClick={() => onEdit(it)}>
                        <Pencil className="w-4 h-4" />
                      </button>
                      <button type="button" className="p-1.5 text-secondary-500 hover:text-error-500" title="Remove" onClick={() => onDelete(it)}>
                        <Trash2 className="w-4 h-4" />
                      </button>
                    </>
                  )
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/** Edit/delete state + dialogs for an items list. */
export function useItemActions(onChanged: () => void) {
  const [deleteTarget, setDeleteTarget] = useState<FsJobItem | null>(null);
  const [busy, setBusy] = useState(false);

  const remove = async () => {
    if (!deleteTarget) return;
    setBusy(true);
    try {
      await fieldService.deleteItem(deleteTarget.uuid);
      toast.success('Item removed');
      setDeleteTarget(null);
      onChanged();
    } catch (err) {
      toast.error(apiError(err, 'Could not remove item'));
    } finally {
      setBusy(false);
    }
  };

  const confirm = (
    <ConfirmDialog
      isOpen={!!deleteTarget}
      onClose={() => setDeleteTarget(null)}
      onConfirm={remove}
      title="Remove item"
      message={`Remove "${deleteTarget?.description || ''}" from the job?`}
      confirmText="Remove"
      variant="danger"
      isLoading={busy}
    />
  );
  return { requestDelete: setDeleteTarget, confirm };
}

// ============================================================
// Panel (job page)
// ============================================================

export function ItemsPanel({
  jobUuid,
  items,
  phases,
  currency,
  canEdit,
  onChanged,
}: {
  jobUuid: string;
  items: FsJobItem[];
  phases: FsPhase[];
  currency: string;
  canEdit: boolean;
  onChanged: () => void;
}) {
  const [formOpen, setFormOpen] = useState(false);
  const [editing, setEditing] = useState<FsJobItem | null>(null);
  const { requestDelete, confirm } = useItemActions(onChanged);
  const total = items.filter((i) => i.is_billable).reduce((sum, i) => sum + i.line_total, 0);

  return (
    <SectionCard
      title="Parts & materials"
      actions={
        <>
          {items.length > 0 && <span className="text-sm text-secondary-500">Billable: {money(total, currency)}</span>}
          {canEdit && (
            <Button
              size="sm"
              variant="ghost"
              onClick={() => {
                setEditing(null);
                setFormOpen(true);
              }}
            >
              <Plus className="w-4 h-4 mr-1" /> Add item
            </Button>
          )}
        </>
      }
    >
      {items.length === 0 && (
        <div className="flex items-center gap-2 text-sm text-secondary-500">
          <Package className="w-4 h-4" /> No parts or materials logged.
        </div>
      )}
      {items.length > 0 && (
        <ItemsTable
          items={items}
          currency={currency}
          canEdit={canEdit}
          onEdit={(it) => {
            setEditing(it);
            setFormOpen(true);
          }}
          onDelete={requestDelete}
        />
      )}
      <ItemFormModal isOpen={formOpen} jobUuid={jobUuid} item={editing} phases={phases} onClose={() => setFormOpen(false)} onSaved={onChanged} />
      {confirm}
    </SectionCard>
  );
}

export default ItemsPanel;

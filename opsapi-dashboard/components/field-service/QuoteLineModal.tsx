'use client';

/**
 * QuoteLineModal — add a labour / material / hire line to a job, matching the
 * engineer's paper quote sheet. One modal, three shapes; the engineer never
 * sees pricing they don't need (labour rate is a manager concern).
 */

import React, { useState } from 'react';
import toast from 'react-hot-toast';
import { Modal, Button, Input, Select } from '@/components/ui';
import { fieldService } from '@/services/field-service.service';
import { apiError } from './shared';

export type LineKind = 'labour' | 'material' | 'hire';

export const LABOUR_OPTIONS: { value: string; label: string }[] = [
  { value: 'engineer_nt', label: 'Engineer — normal time' },
  { value: 'engineer_ot', label: 'Engineer — overtime' },
  { value: 'mate_nt', label: 'Mate — normal time' },
  { value: 'mate_ot', label: 'Mate — overtime' },
];
export const LABOUR_LABEL: Record<string, string> = Object.fromEntries(LABOUR_OPTIONS.map((o) => [o.value, o.label]));

const TITLES: Record<LineKind, string> = { labour: 'Add labour', material: 'Add material', hire: 'Add tool / access hire' };

interface Props {
  isOpen: boolean;
  kind: LineKind;
  jobUuid: string;
  visitUuid?: string;
  onClose: () => void;
  onSaved: () => void;
}

export function QuoteLineModal(props: Props) {
  return (
    <Modal isOpen={props.isOpen} onClose={props.onClose} title={TITLES[props.kind]} size="md">
      {props.isOpen && <LineForm {...props} />}
    </Modal>
  );
}

function LineForm({ kind, jobUuid, visitUuid, onClose, onSaved }: Props) {
  const [f, setF] = useState({
    labour_category: 'engineer_nt',
    description: '',
    part_number: '',
    supplier: '',
    quantity: '',
    days: '',
    unit_price: '',
  });
  const [saving, setSaving] = useState(false);
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) =>
    setF((prev) => ({ ...prev, [k]: e.target.value }));

  const save = async () => {
    const payload: Record<string, unknown> = { visit_uuid: visitUuid };
    if (kind === 'labour') {
      payload.item_type = 'labour';
      payload.labour_category = f.labour_category;
      payload.description = LABOUR_LABEL[f.labour_category];
      if (!f.quantity.trim() && !f.days.trim()) {
        toast.error('Enter hours or days');
        return;
      }
      payload.quantity = f.quantity.trim() || '1';
      payload.days = f.days.trim() || '0';
      payload.unit_price = f.unit_price.trim() || '0';
    } else if (kind === 'material') {
      if (!f.description.trim()) {
        toast.error('What material is it?');
        return;
      }
      payload.item_type = 'part';
      payload.description = f.description.trim();
      payload.part_number = f.part_number.trim();
      payload.supplier = f.supplier.trim();
      payload.quantity = f.quantity.trim() || '1';
      payload.unit_price = f.unit_price.trim() || '0';
    } else {
      if (!f.description.trim()) {
        toast.error('What was hired?');
        return;
      }
      payload.item_type = 'hire';
      payload.description = f.description.trim();
      payload.part_number = f.part_number.trim();
      payload.supplier = f.supplier.trim();
      payload.days = f.days.trim() || '1';
      payload.quantity = '1';
      payload.unit_price = f.unit_price.trim() || '0';
    }
    setSaving(true);
    try {
      await fieldService.addItem(jobUuid, payload);
      toast.success('Added');
      onSaved();
    } catch (err) {
      toast.error(apiError(err, 'Failed to add'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="space-y-3">
      {kind === 'labour' && (
        <>
          <Select label="Who / rate" value={f.labour_category} onChange={set('labour_category')}>
            {LABOUR_OPTIONS.map((o) => (
              <option key={o.value} value={o.value}>{o.label}</option>
            ))}
          </Select>
          <div className="grid grid-cols-2 gap-3">
            <Input label="Hours" inputMode="decimal" value={f.quantity} onChange={set('quantity')} placeholder="e.g. 9" />
            <Input label="Days" inputMode="decimal" value={f.days} onChange={set('days')} placeholder="e.g. 2" />
          </div>
        </>
      )}

      {kind === 'material' && (
        <>
          <Input label="Material *" value={f.description} onChange={set('description')} placeholder="e.g. Compressor" autoFocus />
          <div className="grid grid-cols-2 gap-3">
            <Input label="Part number" value={f.part_number} onChange={set('part_number')} placeholder="e.g. A471y18" />
            <Input label="Supplier" value={f.supplier} onChange={set('supplier')} placeholder="e.g. Daikin / Stock" />
          </div>
          <div className="grid grid-cols-2 gap-3">
            <Input label="Quantity" inputMode="decimal" value={f.quantity} onChange={set('quantity')} placeholder="1" />
            <Input label="Price each" inputMode="decimal" value={f.unit_price} onChange={set('unit_price')} placeholder="0.00" />
          </div>
        </>
      )}

      {kind === 'hire' && (
        <>
          <Input label="Equipment *" value={f.description} onChange={set('description')} placeholder="e.g. Genie lift" autoFocus />
          <div className="grid grid-cols-2 gap-3">
            <Input label="Supplier" value={f.supplier} onChange={set('supplier')} placeholder="e.g. HSS" />
            <Input label="Ref / part no." value={f.part_number} onChange={set('part_number')} placeholder="e.g. D152728" />
          </div>
          <div className="grid grid-cols-2 gap-3">
            <Input label="Days" inputMode="decimal" value={f.days} onChange={set('days')} placeholder="1" />
            <Input label="Price / day" inputMode="decimal" value={f.unit_price} onChange={set('unit_price')} placeholder="0.00" />
          </div>
        </>
      )}

      <div className="flex justify-end gap-2 -mx-5 sm:-mx-6 px-5 sm:px-6 pt-4 mt-4 border-t border-secondary-200">
        <Button variant="ghost" onClick={onClose} disabled={saving}>Cancel</Button>
        <Button onClick={save} isLoading={saving}>Add</Button>
      </div>
    </div>
  );
}

export default QuoteLineModal;

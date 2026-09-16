'use client';

import React, { useState } from 'react';
import toast from 'react-hot-toast';
import { Modal, Button, Input, Textarea } from '@/components/ui';
import { fieldService, type FsPart } from '@/services/field-service.service';
import { apiError, optional, CheckboxField } from './shared';

interface PartFormModalProps {
  isOpen: boolean;
  part?: FsPart | null;
  onClose: () => void;
  onSaved: (part: FsPart) => void;
}

const EMPTY = {
  sku: '',
  name: '',
  description: '',
  category: '',
  unit_cost: '',
  unit_price: '',
  tax_rate: '20',
  stock_quantity: '',
  reorder_level: '',
  is_active: true,
};

type PartForm = typeof EMPTY;

function formFromPart(p?: FsPart | null): PartForm {
  if (!p) return { ...EMPTY };
  const s = (n?: number | null) => (n != null ? String(n) : '');
  return {
    sku: p.sku || '',
    name: p.name || '',
    description: p.description || '',
    category: p.category || '',
    unit_cost: s(p.unit_cost),
    unit_price: s(p.unit_price),
    tax_rate: p.tax_rate != null ? String(p.tax_rate) : '20',
    stock_quantity: s(p.stock_quantity),
    reorder_level: s(p.reorder_level),
    is_active: !!p.is_active,
  };
}

export function PartFormModal(props: PartFormModalProps) {
  const title = props.part ? 'Edit part' : 'New part';
  return (
    <Modal isOpen={props.isOpen} onClose={props.onClose} title={title} size="md">
      {props.isOpen && <PartForm {...props} />}
    </Modal>
  );
}

function PartForm({ part, onClose, onSaved }: PartFormModalProps) {
  const [form, setForm] = useState<PartForm>(() => formFromPart(part));
  const [saving, setSaving] = useState(false);
  const isEdit = !!part;

  const set = (key: keyof PartForm) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) =>
    setForm((f) => ({ ...f, [key]: e.target.value }));

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!form.name.trim()) {
      toast.error('Part name is required');
      return;
    }
    setSaving(true);
    // Numbers go as trimmed strings; the backend coerces and treats '' as clear.
    const payload: Record<string, unknown> = {
      name: form.name.trim(),
      tax_rate: form.tax_rate.trim(),
      is_active: form.is_active,
      sku: isEdit ? form.sku.trim() : optional(form.sku),
      description: isEdit ? form.description.trim() : optional(form.description),
      category: isEdit ? form.category.trim() : optional(form.category),
      unit_cost: form.unit_cost.trim(),
      unit_price: form.unit_price.trim(),
      stock_quantity: form.stock_quantity.trim(),
      reorder_level: form.reorder_level.trim(),
    };
    try {
      const saved = part ? await fieldService.updatePart(part.uuid, payload) : await fieldService.createPart(payload);
      toast.success(part ? 'Part updated' : 'Part created');
      onSaved(saved);
      onClose();
    } catch (err) {
      toast.error(apiError(err, 'Failed to save part'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <form onSubmit={submit} className="space-y-4">
      <Input label="Part name *" value={form.name} onChange={set('name')} placeholder="e.g. Compressor 1HP" />
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <Input label="Part code (SKU)" value={form.sku} onChange={set('sku')} placeholder="e.g. CMP-100" helperText="Your own reference code (optional)" />
        <Input label="Category" value={form.category} onChange={set('category')} placeholder="e.g. spares" />
        <Input label="Unit cost (buy)" value={form.unit_cost} onChange={set('unit_cost')} inputMode="decimal" helperText="What you pay" />
        <Input label="Unit price (sell)" value={form.unit_price} onChange={set('unit_price')} inputMode="decimal" helperText="What the customer pays" />
        <Input label="VAT %" value={form.tax_rate} onChange={set('tax_rate')} inputMode="decimal" />
        <Input label="Stock qty" value={form.stock_quantity} onChange={set('stock_quantity')} inputMode="decimal" helperText="How many you hold now" />
        <Input label="Reorder level" value={form.reorder_level} onChange={set('reorder_level')} inputMode="decimal" helperText="Warn when stock drops to this" />
      </div>
      <Textarea label="Description" value={form.description} onChange={set('description')} rows={2} />
      <CheckboxField
        label="Active"
        hint="Available to add to jobs"
        checked={form.is_active}
        onChange={(v) => setForm((f) => ({ ...f, is_active: v }))}
      />
      <div className="flex justify-end gap-2">
        <Button type="button" variant="ghost" onClick={onClose}>
          Cancel
        </Button>
        <Button type="submit" isLoading={saving}>
          {part ? 'Save changes' : 'Create part'}
        </Button>
      </div>
    </form>
  );
}

export default PartFormModal;

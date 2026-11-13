'use client';

/**
 * Workspace → Getting paid — /dashboard/namespace/payment-methods
 *
 * The workspace's bank accounts and other ways of getting paid. Methods with "Show on documents" on are
 * printed as a "How to pay" block on Order Authorisations, bank-transfer shop orders and invoices; the
 * default one comes first and is the bank account an invoice uses unless it picks another.
 */

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import toast from 'react-hot-toast';
import { ArrowLeft, Landmark, Plus, Star, Trash2, Pencil } from 'lucide-react';
import { Button, Card, ConfirmDialog, Input, Modal, Select, Switch, Textarea } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { usePermissions } from '@/contexts/PermissionsContext';
import { apiError, Pill } from '@/components/field-service/shared';
import HowToPay from '@/components/payments/HowToPay';
import {
  PAYMENT_METHOD_KINDS,
  formatSortCode,
  kindLabel,
  paymentMethodRows,
  typeIban,
  typeSortCode,
  validAccountNumber,
  validBic,
  validIban,
  type PaymentMethodKind,
} from '@/lib/payment-methods';
import { paymentMethodsService, type PaymentMethod, type PaymentMethodInput } from '@/services/payment-methods.service';

interface Draft {
  kind: PaymentMethodKind;
  label: string;
  account_name: string;
  bank_name: string;
  sort_code: string;
  account_number: string;
  iban: string;
  swift_bic: string;
  currency: string;
  instructions: string;
  is_default: boolean;
  show_on_documents: boolean;
}

const EMPTY: Draft = {
  kind: 'bank_transfer',
  label: '',
  account_name: '',
  bank_name: '',
  sort_code: '',
  account_number: '',
  iban: '',
  swift_bic: '',
  currency: 'GBP',
  instructions: 'Please use the reference below so we can match your payment.',
  is_default: false,
  show_on_documents: true,
};

const toDraft = (m: PaymentMethod): Draft => ({
  kind: m.kind,
  label: m.label || '',
  account_name: m.account_name || '',
  bank_name: m.bank_name || '',
  sort_code: m.sort_code || '',
  account_number: m.account_number || '',
  iban: m.iban ? typeIban(m.iban) : '',
  swift_bic: m.swift_bic || '',
  currency: m.currency || 'GBP',
  instructions: m.instructions || '',
  is_default: m.is_default,
  show_on_documents: m.show_on_documents,
});

/** Field errors as you type (the API checks again). Empty fields only fail the "needs" rules on save. */
function draftErrors(d: Draft, submitting: boolean): Partial<Record<keyof Draft | 'bank', string>> {
  const e: Partial<Record<keyof Draft | 'bank', string>> = {};
  if (d.kind !== 'bank_transfer') return e;
  if (d.sort_code && !formatSortCode(d.sort_code)) e.sort_code = 'Six digits, e.g. 12-34-56';
  if (d.account_number && !validAccountNumber(d.account_number)) e.account_number = '6 to 10 digits';
  if (d.iban && !validIban(d.iban)) e.iban = 'Not a valid IBAN — check the characters';
  if (d.swift_bic && !validBic(d.swift_bic)) e.swift_bic = '8 or 11 characters';
  if (d.currency && !/^[A-Za-z]{3}$/.test(d.currency)) e.currency = 'Three letters, e.g. GBP';
  if (submitting) {
    if (!d.account_name.trim()) e.account_name = 'Required';
    const uk = d.sort_code || d.account_number;
    if (uk && (!d.sort_code || !d.account_number)) e.bank = 'A UK account needs both a sort code and an account number';
    if (!uk && !d.iban) e.bank = 'Add a sort code and account number, or an IBAN';
  }
  return e;
}

function toInput(d: Draft): PaymentMethodInput {
  const bank = d.kind === 'bank_transfer';
  return {
    kind: d.kind,
    label: d.label.trim() || undefined,
    account_name: bank ? d.account_name.trim() : undefined,
    bank_name: bank ? d.bank_name.trim() : undefined,
    sort_code: bank ? d.sort_code.trim() : '',
    account_number: bank ? d.account_number.replace(/\s/g, '') : '',
    iban: bank ? d.iban.replace(/\s/g, '') : '',
    swift_bic: bank ? d.swift_bic.trim().toUpperCase() : '',
    currency: (d.currency || 'GBP').toUpperCase(),
    instructions: d.instructions.trim(),
    is_default: d.is_default,
    show_on_documents: d.show_on_documents,
  };
}

/** What the draft will look like on documents (label defaults the way the API does). */
function previewOf(d: Draft) {
  const label =
    d.label.trim() ||
    (d.kind === 'bank_transfer' ? `${d.bank_name.trim() ? `${d.bank_name.trim()} ` : ''}${(d.currency || 'GBP').toUpperCase()} account` : kindLabel(d.kind));
  return {
    kind: d.kind,
    label,
    account_name: d.account_name.trim() || null,
    bank_name: d.bank_name.trim() || null,
    sort_code: formatSortCode(d.sort_code) || (d.sort_code || null),
    account_number: d.account_number.replace(/\s/g, '') || null,
    iban: d.iban.replace(/\s/g, '') || null,
    swift_bic: d.swift_bic.toUpperCase() || null,
    currency: (d.currency || 'GBP').toUpperCase(),
    instructions: d.instructions.trim() || null,
  };
}

function MethodDialog({
  open,
  editing,
  others,
  onClose,
  onSaved,
}: {
  open: boolean;
  editing: PaymentMethod | null;
  others: PaymentMethod[];
  onClose: () => void;
  onSaved: () => void;
}) {
  const [d, setD] = useState<Draft>(EMPTY);
  const [submitted, setSubmitted] = useState(false);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!open) return;
    setSubmitted(false);
    setD(editing ? toDraft(editing) : { ...EMPTY, is_default: others.every((m) => !m.is_active) });
  }, [open, editing, others]);

  const set = <K extends keyof Draft>(k: K, v: Draft[K]) => setD((p) => ({ ...p, [k]: v }));
  const errors = draftErrors(d, submitted);
  const bank = d.kind === 'bank_transfer';

  // The block customers will see: this method in place (or added), in document order.
  const preview = useMemo(() => {
    const mine = { ...previewOf(d), is_default: d.is_default, show_on_documents: d.show_on_documents };
    const list = others
      .filter((m) => m.is_active && m.show_on_documents && m.uuid !== editing?.uuid)
      .map((m) => ({ ...m, is_default: d.is_default ? false : m.is_default }));
    const all = d.show_on_documents ? [...list, mine] : list;
    return all.sort((a, b) => Number(b.is_default) - Number(a.is_default));
  }, [d, others, editing]);

  const save = async (e: React.FormEvent) => {
    e.preventDefault();
    setSubmitted(true);
    if (Object.keys(draftErrors(d, true)).length > 0) return;
    setSaving(true);
    try {
      if (editing) await paymentMethodsService.update(editing.uuid, toInput(d));
      else await paymentMethodsService.create(toInput(d));
      toast.success(editing ? 'Payment method saved' : 'Payment method added');
      onSaved();
    } catch (err) {
      toast.error(apiError(err, 'Could not save'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal isOpen={open} onClose={onClose} title={editing ? 'Edit payment method' : 'Add payment method'} size="3xl">
      <form onSubmit={save} className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <div className="space-y-3">
          <Select label="Kind" value={d.kind} onChange={(e) => set('kind', e.target.value as PaymentMethodKind)}>
            {PAYMENT_METHOD_KINDS.map((k) => (
              <option key={k.value} value={k.value}>
                {k.label}
              </option>
            ))}
          </Select>
          {bank && (
            <>
              <Input
                label="Account name *"
                value={d.account_name}
                onChange={(e) => set('account_name', e.target.value)}
                placeholder="Workstation Ltd"
                error={errors.account_name}
                autoFocus
              />
              <Input label="Bank name" value={d.bank_name} onChange={(e) => set('bank_name', e.target.value)} placeholder="Barclays" />
              <div className="grid grid-cols-2 gap-3">
                <Input
                  label="Sort code"
                  value={d.sort_code}
                  onChange={(e) => set('sort_code', typeSortCode(e.target.value))}
                  placeholder="12-34-56"
                  inputMode="numeric"
                  error={errors.sort_code}
                />
                <Input
                  label="Account number"
                  value={d.account_number}
                  onChange={(e) => set('account_number', e.target.value.replace(/\D/g, '').slice(0, 10))}
                  placeholder="12345678"
                  inputMode="numeric"
                  error={errors.account_number}
                />
              </div>
              <Input
                label="IBAN (international payments)"
                value={d.iban}
                onChange={(e) => set('iban', typeIban(e.target.value))}
                placeholder="GB29 NWBK 6016 1331 9268 19"
                error={errors.iban}
                helperText={d.iban && !errors.iban && validIban(d.iban) ? 'Valid IBAN' : undefined}
              />
              <div className="grid grid-cols-2 gap-3">
                <Input
                  label="SWIFT/BIC"
                  value={d.swift_bic}
                  onChange={(e) => set('swift_bic', e.target.value.replace(/\s/g, '').toUpperCase().slice(0, 11))}
                  placeholder="NWBKGB2L"
                  error={errors.swift_bic}
                />
                <Input
                  label="Currency"
                  value={d.currency}
                  onChange={(e) => set('currency', e.target.value.toUpperCase().slice(0, 3))}
                  error={errors.currency}
                />
              </div>
              {errors.bank && <p className="text-sm text-error-600">{errors.bank}</p>}
            </>
          )}
          <Input
            label="Label"
            value={d.label}
            onChange={(e) => set('label', e.target.value)}
            placeholder={bank ? 'Barclays GBP business account' : kindLabel(d.kind)}
            helperText="Optional — shown as the method's name."
          />
          <Textarea
            label="Instructions for the customer"
            value={d.instructions}
            onChange={(e) => set('instructions', e.target.value)}
            rows={2}
          />
          <div className="flex items-center justify-between rounded-lg border border-secondary-200 px-3 py-2">
            <span className="text-sm text-secondary-700">Default (first on documents and invoices)</span>
            <Switch checked={d.is_default} onChange={(v) => set('is_default', v)} aria-label="Default" />
          </div>
          <div className="flex items-center justify-between rounded-lg border border-secondary-200 px-3 py-2">
            <span className="text-sm text-secondary-700">Show on documents (Order Authorisations, invoices)</span>
            <Switch checked={d.show_on_documents} onChange={(v) => set('show_on_documents', v)} aria-label="Show on documents" />
          </div>
        </div>
        <div className="space-y-2">
          <p className="text-sm font-medium text-secondary-700">Preview — as customers see it</p>
          <HowToPay methods={preview} reference="WSQ-2026-00042" />
          <p className="text-xs text-secondary-500">
            On an Order Authorisation the reference is its number; on an invoice, the invoice number.
          </p>
          <div className="flex justify-end gap-2 pt-4">
            <Button type="button" variant="ghost" onClick={onClose}>
              Cancel
            </Button>
            <Button type="submit" isLoading={saving}>
              {editing ? 'Save' : 'Add'}
            </Button>
          </div>
        </div>
      </form>
    </Modal>
  );
}

function GettingPaidContent() {
  const { hasPermission } = usePermissions();
  const editable = hasPermission('namespace', 'update');
  const [methods, setMethods] = useState<PaymentMethod[]>([]);
  const [loading, setLoading] = useState(true);
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editing, setEditing] = useState<PaymentMethod | null>(null);
  const [removeTarget, setRemoveTarget] = useState<PaymentMethod | null>(null);

  const load = useCallback(() => {
    paymentMethodsService
      .list(true)
      .then(setMethods)
      .catch((err) => toast.error(apiError(err, 'Failed to load payment methods')))
      .finally(() => setLoading(false));
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const patch = async (m: PaymentMethod, input: PaymentMethodInput, done: string) => {
    try {
      await paymentMethodsService.update(m.uuid, input);
      toast.success(done);
      load();
    } catch (err) {
      toast.error(apiError(err, 'Could not save'));
    }
  };

  const remove = async () => {
    if (!removeTarget) return;
    try {
      const res = await paymentMethodsService.remove(removeTarget.uuid);
      toast.success(res.deactivated ? 'Deactivated — an invoice still uses it' : 'Payment method deleted');
      setRemoveTarget(null);
      load();
    } catch (err) {
      toast.error(apiError(err, 'Could not delete'));
    }
  };

  const onDocuments = methods
    .filter((m) => m.is_active && m.show_on_documents)
    .sort((a, b) => Number(b.is_default) - Number(a.is_default) || a.sort_order - b.sort_order);

  return (
    <div className="space-y-6">
      <Link href="/dashboard/namespace" className="inline-flex items-center text-sm text-secondary-500 hover:text-secondary-800">
        <ArrowLeft className="w-4 h-4 mr-1" /> My workspace
      </Link>
      <PageHeader
        title="Getting paid"
        description="Your bank accounts and other ways customers pay you. Shown as “How to pay” on Order Authorisations and invoices."
        icon={<Landmark className="w-5 h-5" />}
        actions={
          editable ? (
            <Button
              onClick={() => {
                setEditing(null);
                setDialogOpen(true);
              }}
            >
              <Plus className="w-4 h-4 mr-1" /> Add bank account
            </Button>
          ) : undefined
        }
      />

      <div className="grid grid-cols-1 gap-6 xl:grid-cols-12">
        <Card className="shadow-sm xl:col-span-7">
          {loading ? (
            <p className="text-sm text-secondary-500">Loading…</p>
          ) : methods.length === 0 ? (
            <div className="py-8 text-center">
              <Landmark className="mx-auto h-8 w-8 text-secondary-300" />
              <p className="mt-2 text-sm text-secondary-600">No payment methods yet.</p>
              <p className="text-sm text-secondary-500">Add your business bank account so trade customers can pay by bank transfer.</p>
            </div>
          ) : (
            <ul className="divide-y divide-secondary-100">
              {methods.map((m) => {
                const rows = paymentMethodRows(m);
                return (
                  <li key={m.uuid} className={`flex flex-wrap items-start justify-between gap-3 py-3 ${m.is_active ? '' : 'opacity-60'}`}>
                    <div className="min-w-0">
                      <p className="flex flex-wrap items-center gap-2 font-medium text-secondary-900">
                        {m.label}
                        {m.is_default && (
                          <Pill className="bg-primary-600 text-white">
                            <Star className="mr-1 h-3 w-3" /> Default
                          </Pill>
                        )}
                        <Pill className="bg-secondary-100 text-secondary-600">{kindLabel(m.kind)}</Pill>
                        {!m.is_active && <Pill className="bg-secondary-200 text-secondary-700">Inactive</Pill>}
                        {m.is_active && !m.show_on_documents && (
                          <Pill className="bg-warning-50 text-warning-700">Not on documents</Pill>
                        )}
                      </p>
                      {rows.length > 0 && (
                        <p className="mt-0.5 text-sm text-secondary-500">
                          {rows
                            .filter(([k]) => k !== 'Bank')
                            .map(([k, v]) => `${k} ${v}`)
                            .join(' · ')}
                        </p>
                      )}
                    </div>
                    {editable && (
                      <div className="flex flex-wrap items-center gap-2">
                        {m.is_active && !m.is_default && (
                          <Button size="sm" variant="ghost" onClick={() => patch(m, { is_default: true }, 'Default changed')}>
                            Set as default
                          </Button>
                        )}
                        <label className="flex items-center gap-1.5 text-xs text-secondary-600">
                          <Switch
                            checked={m.show_on_documents}
                            onChange={(v) => patch(m, { show_on_documents: v }, v ? 'Shown on documents' : 'Hidden from documents')}
                            aria-label="Show on documents"
                            disabled={!m.is_active}
                          />
                          On documents
                        </label>
                        <Button
                          size="sm"
                          variant="ghost"
                          onClick={() => patch(m, { is_active: !m.is_active }, m.is_active ? 'Deactivated' : 'Activated')}
                        >
                          {m.is_active ? 'Deactivate' : 'Activate'}
                        </Button>
                        <Button
                          size="sm"
                          variant="outline"
                          onClick={() => {
                            setEditing(m);
                            setDialogOpen(true);
                          }}
                          aria-label="Edit"
                        >
                          <Pencil className="h-4 w-4" />
                        </Button>
                        <Button size="sm" variant="ghost" onClick={() => setRemoveTarget(m)} aria-label="Delete">
                          <Trash2 className="h-4 w-4" />
                        </Button>
                      </div>
                    )}
                  </li>
                );
              })}
            </ul>
          )}
        </Card>
        <div className="space-y-2 xl:col-span-5">
          <p className="text-sm font-medium text-secondary-700">What customers see</p>
          <HowToPay methods={onDocuments} reference="WSQ-2026-00042" />
          <p className="text-xs text-secondary-500">
            On Order Authorisations, bank-transfer orders and invoices. The reference is the document&apos;s own number.
          </p>
        </div>
      </div>

      <MethodDialog
        open={dialogOpen}
        editing={editing}
        others={methods}
        onClose={() => setDialogOpen(false)}
        onSaved={() => {
          setDialogOpen(false);
          load();
        }}
      />
      <ConfirmDialog
        isOpen={!!removeTarget}
        onClose={() => setRemoveTarget(null)}
        onConfirm={remove}
        title="Delete this payment method?"
        message="It disappears from new documents. If an invoice already uses it, it is deactivated instead so that invoice keeps its bank details."
        confirmText="Delete"
        variant="danger"
      />
    </div>
  );
}

export default function GettingPaidPage() {
  return (
    <ProtectedPage module="namespace" title="Getting paid">
      <GettingPaidContent />
    </ProtectedPage>
  );
}

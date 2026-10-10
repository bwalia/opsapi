'use client';

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { Modal, SearchableSelect } from '@/components/ui';
import {
  purchaseOrdersService,
  purchaseOrderError,
  type PurchaseOrder,
  type PurchaseOrderPayload,
} from '@/services/purchase-orders.service';
import { kanbanService } from '@/services/kanban.service';
import { crmService, type CrmAccount } from '@/services/crm.service';

const inputClass =
  'w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 bg-surface';
const labelClass = 'block text-sm font-medium text-secondary-700 mb-1';

const CURRENCIES = ['GBP', 'EUR', 'USD', 'CAD', 'AUD', 'INR'];

const todayISO = () => new Date().toISOString().slice(0, 10);

function emptyForm(): PurchaseOrderPayload {
  return {
    supplier_name: '',
    supplier_email: '',
    supplier_phone: '',
    supplier_address: '',
    supplier_company_uuid: '',
    reference: '',
    issue_date: todayISO(),
    expected_date: '',
    delivery_address: '',
    currency: 'GBP',
    notes: '',
    terms: '',
    project_uuid: '',
  };
}

function fromPurchaseOrder(po: PurchaseOrder): PurchaseOrderPayload {
  return {
    supplier_name: po.supplier_name || '',
    supplier_email: po.supplier_email || '',
    supplier_phone: po.supplier_phone || '',
    supplier_address: po.supplier_address || '',
    supplier_company_uuid: po.supplier_company_uuid || '',
    reference: po.reference || '',
    issue_date: po.issue_date?.slice(0, 10) || todayISO(),
    expected_date: po.expected_date?.slice(0, 10) || '',
    delivery_address: po.delivery_address || '',
    currency: po.currency || 'GBP',
    notes: po.notes || '',
    terms: po.terms || '',
    project_uuid: po.project_uuid || '',
  };
}

interface Props {
  isOpen: boolean;
  onClose: () => void;
  onSaved: (po: PurchaseOrder) => void;
  /** Edit this PO; omit to create a new draft. */
  purchaseOrder?: PurchaseOrder | null;
}

/**
 * Create / edit a purchase order header. The project and CRM supplier pickers
 * appear only when those modules answer (Kanban / CRM may not be deployed).
 */
export const PurchaseOrderFormModal: React.FC<Props> = ({ isOpen, onClose, onSaved, purchaseOrder }) => {
  const isEdit = !!purchaseOrder;
  const [form, setForm] = useState<PurchaseOrderPayload>(emptyForm);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [projects, setProjects] = useState<{ value: string; label: string }[] | null>(null);
  const [companies, setCompanies] = useState<CrmAccount[] | null>(null);

  useEffect(() => {
    if (!isOpen) return;
    setForm(purchaseOrder ? fromPurchaseOrder(purchaseOrder) : emptyForm());
  }, [isOpen, purchaseOrder]);

  // Optional lookups: hide the picker when the module isn't available.
  useEffect(() => {
    if (!isOpen) return;
    let cancelled = false;
    kanbanService
      .getProjects({ perPage: 100 })
      .then((r) => {
        if (cancelled) return;
        setProjects((r?.data || []).map((p) => ({ value: p.uuid, label: p.name })));
      })
      .catch(() => !cancelled && setProjects(null));
    crmService
      .getAccounts({ perPage: 50 })
      .then((r) => !cancelled && setCompanies(r.data || []))
      .catch(() => !cancelled && setCompanies(null));
    return () => {
      cancelled = true;
    };
  }, [isOpen]);

  const handleCompanySearch = useCallback((q: string) => {
    crmService
      .getAccounts({ search: q, perPage: 50 })
      .then((r) => setCompanies(r.data || []))
      .catch(() => {});
  }, []);

  const companyOptions = useMemo(
    () => (companies || []).map((c) => ({ value: c.uuid, label: c.name, hint: c.email })),
    [companies]
  );

  // Keep the current project selectable even if it isn't in the first page.
  const projectOptions = useMemo(() => {
    const opts = projects || [];
    const current = purchaseOrder?.project;
    if (current && !opts.some((o) => o.value === current.uuid)) {
      return [{ value: current.uuid, label: current.name }, ...opts];
    }
    return opts;
  }, [projects, purchaseOrder]);

  const set = <K extends keyof PurchaseOrderPayload>(key: K, value: PurchaseOrderPayload[K]) =>
    setForm((prev) => ({ ...prev, [key]: value }));

  const pickCompany = (uuid: string) => {
    const c = (companies || []).find((x) => x.uuid === uuid);
    setForm((prev) => ({
      ...prev,
      supplier_company_uuid: uuid,
      supplier_name: c && !prev.supplier_name ? c.name : prev.supplier_name,
      supplier_email: c && !prev.supplier_email ? c.email || '' : prev.supplier_email,
      supplier_phone: c && !prev.supplier_phone ? c.phone || '' : prev.supplier_phone,
    }));
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!form.supplier_name.trim() && !form.supplier_company_uuid) {
      toast.error('Supplier name is required');
      return;
    }
    setIsSubmitting(true);
    try {
      // Send blanks as "" on edit (clears the field); drop them on create.
      const payload: PurchaseOrderPayload = { ...form };
      if (!isEdit) {
        (Object.keys(payload) as (keyof PurchaseOrderPayload)[]).forEach((k) => {
          if (payload[k] === '') delete payload[k];
        });
      }
      const saved = isEdit
        ? await purchaseOrdersService.updatePurchaseOrder(purchaseOrder!.uuid, payload)
        : await purchaseOrdersService.createPurchaseOrder(payload);
      toast.success(isEdit ? 'Purchase order updated' : `Purchase order ${saved.po_number} created`);
      onSaved(saved);
      onClose();
    } catch (error) {
      toast.error(purchaseOrderError(error, isEdit ? 'Failed to update purchase order' : 'Failed to create purchase order'));
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title={isEdit ? 'Edit Purchase Order' : 'New Purchase Order'} size="lg">
      <form onSubmit={handleSubmit} className="space-y-4">
        {companies !== null && (
          <SearchableSelect
            label="CRM company (optional)"
            options={companyOptions}
            value={form.supplier_company_uuid || ''}
            onChange={pickCompany}
            onSearch={handleCompanySearch}
            placeholder="Link a CRM company"
            clearable
          />
        )}

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div>
            <label className={labelClass}>Supplier Name *</label>
            <input
              type="text"
              value={form.supplier_name}
              onChange={(e) => set('supplier_name', e.target.value)}
              className={inputClass}
              placeholder="e.g. Bob Builders Ltd"
            />
          </div>
          <div>
            <label className={labelClass}>Supplier Email</label>
            <input
              type="email"
              value={form.supplier_email}
              onChange={(e) => set('supplier_email', e.target.value)}
              className={inputClass}
              placeholder="orders@supplier.co.uk"
            />
          </div>
          <div>
            <label className={labelClass}>Supplier Phone</label>
            <input
              type="tel"
              value={form.supplier_phone}
              onChange={(e) => set('supplier_phone', e.target.value)}
              className={inputClass}
            />
          </div>
          <div>
            <label className={labelClass}>Reference</label>
            <input
              type="text"
              value={form.reference}
              onChange={(e) => set('reference', e.target.value)}
              className={inputClass}
              placeholder="Quote / job reference"
            />
          </div>
        </div>

        <div>
          <label className={labelClass}>Supplier Address</label>
          <textarea
            value={form.supplier_address}
            onChange={(e) => set('supplier_address', e.target.value)}
            className={inputClass}
            rows={2}
          />
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
          <div>
            <label className={labelClass}>Issue Date</label>
            <input
              type="date"
              value={form.issue_date}
              onChange={(e) => set('issue_date', e.target.value)}
              className={inputClass}
            />
          </div>
          <div>
            <label className={labelClass}>Expected Date</label>
            <input
              type="date"
              value={form.expected_date}
              onChange={(e) => set('expected_date', e.target.value)}
              className={inputClass}
            />
          </div>
          <div>
            <label className={labelClass}>Currency</label>
            <select value={form.currency} onChange={(e) => set('currency', e.target.value)} className={inputClass}>
              {CURRENCIES.map((c) => (
                <option key={c} value={c}>
                  {c}
                </option>
              ))}
            </select>
          </div>
        </div>

        <div>
          <label className={labelClass}>Delivery Address</label>
          <textarea
            value={form.delivery_address}
            onChange={(e) => set('delivery_address', e.target.value)}
            className={inputClass}
            rows={2}
            placeholder="Site address for delivery"
          />
        </div>

        {projects !== null && (
          <SearchableSelect
            label="Project (optional)"
            options={projectOptions}
            value={form.project_uuid || ''}
            onChange={(v) => set('project_uuid', v)}
            placeholder="Link a renovation project"
            clearable
          />
        )}

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div>
            <label className={labelClass}>Notes</label>
            <textarea
              value={form.notes}
              onChange={(e) => set('notes', e.target.value)}
              className={inputClass}
              rows={3}
            />
          </div>
          <div>
            <label className={labelClass}>Terms</label>
            <textarea
              value={form.terms}
              onChange={(e) => set('terms', e.target.value)}
              className={inputClass}
              rows={3}
              placeholder="e.g. 30 days from delivery"
            />
          </div>
        </div>

        <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
          <button
            type="button"
            onClick={onClose}
            className="px-4 py-2 text-sm font-medium text-secondary-700 bg-surface border border-secondary-300 rounded-lg hover:bg-secondary-50 transition-colors"
          >
            Cancel
          </button>
          <button
            type="submit"
            disabled={isSubmitting}
            className="px-4 py-2 text-sm font-medium text-white bg-primary-600 rounded-lg hover:bg-primary-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
          >
            {isSubmitting ? 'Saving...' : isEdit ? 'Save Changes' : 'Create Purchase Order'}
          </button>
        </div>
      </form>
    </Modal>
  );
};

export default PurchaseOrderFormModal;

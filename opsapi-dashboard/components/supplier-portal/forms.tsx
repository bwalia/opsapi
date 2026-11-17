'use client';

/** Dispatch and delivery forms, used by the supplier portal and the staff PO panel. */
import React, { useEffect, useState } from 'react';
import { PackageCheck, Truck } from 'lucide-react';
import toast from 'react-hot-toast';
import { Modal } from '@/components/ui';
import { FileField, btnPrimary, btnSecondary, inputClass, labelClass, todayIso } from '@/components/supplier-portal/shared';
import { checkUploadFile, type DeliveredInput, type DispatchInput } from '@/services/supplier-portal.service';

const blankDispatch = (): DispatchInput => ({
  carrier: '',
  tracking_number: '',
  tracking_url: '',
  dispatched_on: todayIso(),
  expected_on: '',
  note: '',
});

export function DispatchModal({
  isOpen,
  onClose,
  onSubmit,
  title = 'Enter dispatch',
}: {
  isOpen: boolean;
  onClose: () => void;
  /** Resolve true when saved (the modal closes); show any error yourself and resolve false. */
  onSubmit: (input: DispatchInput) => Promise<boolean>;
  title?: string;
}) {
  const [form, setForm] = useState<DispatchInput>(blankDispatch);
  const [saving, setSaving] = useState(false);
  useEffect(() => {
    if (isOpen) setForm(blankDispatch());
  }, [isOpen]);
  const set = (k: keyof DispatchInput) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) =>
    setForm((f) => ({ ...f, [k]: e.target.value }));

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!form.carrier.trim()) return void toast.error('Enter the carrier (for example DPD, DHL or your own van)');
    if (form.tracking_url?.trim() && !/^https:\/\//i.test(form.tracking_url.trim()))
      return void toast.error('The tracking link must start with https://');
    if (form.expected_on && form.dispatched_on && form.expected_on < form.dispatched_on)
      return void toast.error('The expected delivery can’t be before the dispatch date');
    setSaving(true);
    try {
      if (await onSubmit(form)) onClose();
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title={title}>
      <form onSubmit={submit} className="space-y-4">
        <div>
          <label className={labelClass}>Carrier *</label>
          <input className={inputClass} placeholder="e.g. DPD, DHL, our own van" value={form.carrier} onChange={set('carrier')} />
        </div>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <div>
            <label className={labelClass}>Tracking number</label>
            <input className={inputClass} value={form.tracking_number} onChange={set('tracking_number')} />
          </div>
          <div>
            <label className={labelClass}>Tracking link</label>
            <input className={inputClass} placeholder="https://" value={form.tracking_url} onChange={set('tracking_url')} />
          </div>
          <div>
            <label className={labelClass}>Dispatched on</label>
            <input type="date" className={inputClass} value={form.dispatched_on} onChange={set('dispatched_on')} />
          </div>
          <div>
            <label className={labelClass}>Expected delivery</label>
            <input type="date" className={inputClass} value={form.expected_on} onChange={set('expected_on')} />
          </div>
        </div>
        <div>
          <label className={labelClass}>Note (optional)</label>
          <textarea className={inputClass} value={form.note} maxLength={1000} onChange={set('note')} />
        </div>
        <div className="flex justify-end gap-2">
          <button type="button" className={btnSecondary} onClick={onClose}>
            Cancel
          </button>
          <button type="submit" className={btnPrimary} disabled={saving}>
            <Truck className="h-4 w-4" />
            {saving ? 'Saving…' : 'Save dispatch'}
          </button>
        </div>
      </form>
    </Modal>
  );
}

export function DeliveredModal({
  isOpen,
  onClose,
  hasPod,
  onSubmit,
}: {
  isOpen: boolean;
  onClose: () => void;
  /** A proof of delivery / delivery note is already uploaded, so the file is optional. */
  hasPod: boolean;
  /** Resolve true when saved (the modal closes). */
  onSubmit: (input: DeliveredInput, file: File | null) => Promise<boolean>;
}) {
  const [deliveredOn, setDeliveredOn] = useState(todayIso());
  const [receivedBy, setReceivedBy] = useState('');
  const [note, setNote] = useState('');
  const [file, setFile] = useState<File | null>(null);
  const [saving, setSaving] = useState(false);
  useEffect(() => {
    if (!isOpen) return;
    setDeliveredOn(todayIso());
    setReceivedBy('');
    setNote('');
    setFile(null);
  }, [isOpen]);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (file || !hasPod) {
      const p = checkUploadFile(file);
      if (p) return void toast.error(file ? p : 'Attach the proof of delivery (a signed delivery note or the courier’s proof)');
    }
    if (deliveredOn && deliveredOn > todayIso()) return void toast.error('The delivery date can’t be in the future');
    setSaving(true);
    try {
      if (await onSubmit({ delivered_on: deliveredOn, received_by: receivedBy, note }, file)) onClose();
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Mark delivered">
      <form onSubmit={submit} className="space-y-4">
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <div>
            <label className={labelClass}>Delivered on *</label>
            <input
              type="date"
              className={inputClass}
              max={todayIso()}
              value={deliveredOn}
              onChange={(e) => setDeliveredOn(e.target.value)}
            />
          </div>
          <div>
            <label className={labelClass}>Received by</label>
            <input
              className={inputClass}
              placeholder="Name of the person who signed"
              value={receivedBy}
              onChange={(e) => setReceivedBy(e.target.value)}
            />
          </div>
        </div>
        <FileField
          label="Proof of delivery"
          file={file}
          onChange={setFile}
          required={!hasPod}
          hint={
            hasPod
              ? 'Optional: a delivery note or proof of delivery is already uploaded'
              : 'A signed delivery note or the courier’s proof (PDF, PNG or JPG)'
          }
        />
        <div>
          <label className={labelClass}>Note (optional)</label>
          <textarea className={inputClass} value={note} maxLength={1000} onChange={(e) => setNote(e.target.value)} />
        </div>
        <div className="flex justify-end gap-2">
          <button type="button" className={btnSecondary} onClick={onClose}>
            Cancel
          </button>
          <button type="submit" className={btnPrimary} disabled={saving}>
            <PackageCheck className="h-4 w-4" />
            {saving ? 'Saving…' : 'Mark delivered'}
          </button>
        </div>
      </form>
    </Modal>
  );
}

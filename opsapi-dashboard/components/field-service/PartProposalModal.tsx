'use client';

/**
 * PartProposalModal — the engineer's "propose a part replacement" flow.
 *
 * The engineer picks a part that ALREADY EXISTS in the namespace catalogue
 * (they can't invent parts), says what they're fixing, and MUST attach at least
 * one photo of the fault. It's submitted for the service manager to approve —
 * only an approved part reaches the invoice. Price/VAT come from the catalogue
 * part, not the engineer, so there's nothing to fiddle.
 */

import React, { useEffect, useMemo, useRef, useState } from 'react';
import toast from 'react-hot-toast';
import { Camera, X } from 'lucide-react';
import { Modal, Button, Input, Textarea, SearchableSelect } from '@/components/ui';
import { fieldService, type FsPart } from '@/services/field-service.service';
import { apiError, money } from './shared';

interface Props {
  isOpen: boolean;
  jobUuid: string;
  visitUuid?: string;
  onClose: () => void;
  onSaved: () => void;
}

export function PartProposalModal(props: Props) {
  return (
    <Modal isOpen={props.isOpen} onClose={props.onClose} title="Propose a part replacement" size="md">
      {props.isOpen && <ProposalForm {...props} />}
    </Modal>
  );
}

function ProposalForm({ jobUuid, visitUuid, onClose, onSaved }: Props) {
  const [parts, setParts] = useState<FsPart[]>([]);
  const [partUuid, setPartUuid] = useState('');
  const [quantity, setQuantity] = useState('1');
  const [reason, setReason] = useState('');
  const [photos, setPhotos] = useState<File[]>([]);
  const [saving, setSaving] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    fieldService.getParts({ per_page: 200 }).then((r) => setParts(r.data)).catch(() => setParts([]));
  }, []);

  const partOptions = useMemo(
    () => parts.map((p) => ({ value: p.uuid, label: p.name, hint: p.sku || p.category || undefined })),
    [parts]
  );
  const picked = useMemo(() => parts.find((p) => p.uuid === partUuid) || null, [parts, partUuid]);

  // Object URLs for previews; revoke the previous set whenever it changes / unmounts.
  const previews = useMemo(() => photos.map((f) => URL.createObjectURL(f)), [photos]);
  useEffect(() => () => previews.forEach((u) => URL.revokeObjectURL(u)), [previews]);

  const addFiles = (files: FileList | null) => {
    if (files && files.length) setPhotos((prev) => [...prev, ...Array.from(files)]);
    if (inputRef.current) inputRef.current.value = '';
  };
  const removePhoto = (i: number) => setPhotos((prev) => prev.filter((_, idx) => idx !== i));

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!partUuid) return toast.error('Pick the part from the catalogue');
    if (!reason.trim()) return toast.error('Say what needs replacing and why');
    if (photos.length === 0) return toast.error('Add at least one photo of the fault');

    setSaving(true);
    try {
      const { item } = await fieldService.createPartProposal(
        jobUuid,
        {
          part_uuid: partUuid,
          quantity: Number(quantity) || 1,
          reason: reason.trim(),
          unit_price: picked?.unit_price ?? undefined,
          tax_rate: picked?.tax_rate ?? undefined,
          visit_uuid: visitUuid,
        },
        photos[0]
      );
      // Attach any extra photos to the same proposal.
      for (const f of photos.slice(1)) {
        await fieldService.uploadJobPhoto(jobUuid, f, { visit_uuid: visitUuid, item_uuid: item.uuid });
      }
      toast.success('Sent to your manager for approval');
      onSaved();
    } catch (err) {
      toast.error(apiError(err, 'Could not send the proposal'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <form onSubmit={submit} className="space-y-4">
      {partOptions.length > 0 ? (
        <SearchableSelect
          label="Part to replace *"
          options={partOptions}
          value={partUuid}
          onChange={setPartUuid}
          placeholder="Search the parts catalogue…"
          clearable
        />
      ) : (
        <p className="text-sm text-secondary-500">
          No parts in the catalogue yet. Ask your manager to add the part, then it&apos;ll show here to pick.
        </p>
      )}

      {picked && (
        <p className="text-xs text-secondary-500 -mt-2">
          {picked.sku ? `${picked.sku} · ` : ''}Price from catalogue: {money(picked.unit_price || 0)}
          {picked.tax_rate ? ` · VAT ${picked.tax_rate}%` : ''}
        </p>
      )}

      <Input label="How many" inputMode="decimal" value={quantity} onChange={(e) => setQuantity(e.target.value)} />

      <Textarea
        label="What's wrong / why replace it? *"
        rows={3}
        value={reason}
        onChange={(e) => setReason(e.target.value)}
        placeholder="e.g. Compressor seized — not cooling. Needs replacing to fix."
      />

      <div>
        <div className="flex items-center justify-between mb-1.5">
          <span className="block text-sm font-medium text-secondary-700">Fault photos *</span>
          <Button type="button" size="sm" variant="ghost" leftIcon={<Camera className="w-4 h-4" />} onClick={() => inputRef.current?.click()}>
            Add photo
          </Button>
        </div>
        <input ref={inputRef} type="file" accept="image/*" capture="environment" multiple hidden onChange={(e) => addFiles(e.target.files)} />
        {photos.length === 0 ? (
          <p className="text-xs text-secondary-500">At least one photo is required — it&apos;s the proof your manager checks.</p>
        ) : (
          <div className="grid grid-cols-3 sm:grid-cols-4 gap-2">
            {previews.map((src, i) => (
              <div key={i} className="relative aspect-square">
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img src={src} alt="Fault" className="w-full h-full object-cover rounded-lg border border-secondary-200" />
                <button
                  type="button"
                  onClick={() => removePhoto(i)}
                  aria-label="Remove photo"
                  className="absolute top-1 right-1 rounded-full bg-black/60 text-white p-1"
                >
                  <X className="w-3.5 h-3.5" />
                </button>
              </div>
            ))}
          </div>
        )}
      </div>

      <div className="flex justify-end gap-2 pt-2 border-t border-secondary-200">
        <Button type="button" variant="ghost" onClick={onClose} disabled={saving}>
          Cancel
        </Button>
        <Button type="submit" isLoading={saving} disabled={!partUuid || !reason.trim() || photos.length === 0}>
          Send for approval
        </Button>
      </div>
    </form>
  );
}

export default PartProposalModal;

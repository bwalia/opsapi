'use client';

import React, { useCallback, useEffect, useState } from 'react';
import { PenLine, ShieldCheck, Undo2 } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Card, Input, Modal, Switch, Textarea, promptDialog } from '@/components/ui';
import { SectionTitle } from '@/components/shop/shared';
import { SignaturePad } from '@/components/shop/SignaturePad';
import { shopService } from '@/services/shop.service';
import { extractApiError, formatDateTime } from '@/lib/utils';
import type { ShopOrder, ShopOrderSignatureState } from '@/types/shop';

/**
 * "Proof of delivery": when the goods are handed over, the customer signs on the screen (phone, tablet or
 * computer) and their name is typed in. The signature is kept privately with who took it and when, and the
 * order is marked delivered. A wrong signature is taken back with a reason (kept for the record).
 */
export function ProofOfDelivery({ order, editable, onChanged }: { order: ShopOrder; editable: boolean; onChanged: () => void }) {
  const [state, setState] = useState<ShopOrderSignatureState | null>(null);
  const [image, setImage] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [open, setOpen] = useState(false);
  const [name, setName] = useState('');
  const [note, setNote] = useState('');
  const [markDelivered, setMarkDelivered] = useState(true);
  const [png, setPng] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      const s = await shopService.getSignature(order.uuid);
      setState(s);
      setError(null);
      if (s.signature) {
        const blob = await shopService.getSignatureImage(order.uuid);
        setImage((old) => {
          if (old) URL.revokeObjectURL(old);
          return URL.createObjectURL(blob);
        });
      } else {
        setImage((old) => {
          if (old) URL.revokeObjectURL(old);
          return null;
        });
      }
    } catch (e) {
      setError(extractApiError(e, 'Could not load the proof of delivery'));
    }
  }, [order.uuid]);

  useEffect(() => {
    load();
  }, [load]);

  useEffect(() => () => {
    if (image) URL.revokeObjectURL(image);
  }, [image]);

  const start = () => {
    setName(order.customer?.name ?? '');
    setNote('');
    setPng(null);
    setMarkDelivered(order.status !== 'delivered');
    setOpen(true);
  };

  const save = async () => {
    if (!png) {
      toast.error('Ask the customer to sign in the box first');
      return;
    }
    if (name.trim().length < 2) {
      toast.error('Type the name of the person signing');
      return;
    }
    setSaving(true);
    try {
      await shopService.signForOrder(order.uuid, { signer_name: name.trim(), image: png, note: note.trim() || undefined, mark_delivered: markDelivered });
      toast.success(markDelivered && order.status !== 'delivered' ? 'Signed for. The order is now delivered.' : 'Signature saved');
      setOpen(false);
      await load();
      onChanged();
    } catch (e) {
      toast.error(extractApiError(e, 'The signature could not be saved'));
    } finally {
      setSaving(false);
    }
  };

  const takeBack = async () => {
    const reason = await promptDialog({
      title: 'Take this signature back?',
      message: 'Use this when the wrong person signed or it was the wrong order. The signature is kept for the record, and you can take a new one. The order status does not change.',
      label: 'Why?',
      placeholder: 'e.g. signed on the wrong order',
      confirmText: 'Take it back',
      danger: true,
      validate: (v) => (v.trim().length < 3 ? 'Say why in a few words' : null),
    });
    if (!reason) return;
    setBusy(true);
    try {
      await shopService.voidSignature(order.uuid, reason.trim());
      toast.success('Signature taken back');
      await load();
    } catch (e) {
      toast.error(extractApiError(e, 'Could not take the signature back'));
    } finally {
      setBusy(false);
    }
  };

  const sig = state?.signature ?? null;

  return (
    <Card className="print:break-inside-avoid">
      <SectionTitle
        actions={
          editable && sig ? (
            <Button size="sm" variant="ghost" className="print:hidden" onClick={takeBack} isLoading={busy} leftIcon={<Undo2 className="h-4 w-4" />}>
              Take back
            </Button>
          ) : undefined
        }
      >
        Proof of delivery
      </SectionTitle>

      {error && <p className="text-sm text-error-700" role="alert">{error}</p>}
      {!state && !error && <p className="text-sm text-secondary-500">Loading…</p>}

      {state && sig && (
        <div className="space-y-2">
          <p className="flex items-center gap-2 text-sm font-medium text-success-700">
            <ShieldCheck className="h-4 w-4" aria-hidden="true" /> Signed for by {sig.signer_name}
          </p>
          {image ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={image} alt={`Signature of ${sig.signer_name}`} className="max-h-40 w-full rounded-lg border border-secondary-200 bg-white object-contain" />
          ) : (
            <div className="h-24 animate-pulse rounded-lg bg-secondary-100" />
          )}
          <p className="text-xs text-secondary-500">
            {formatDateTime(sig.signed_at)}
            {sig.captured_by ? ` · taken by ${sig.captured_by}` : ''}
          </p>
          {sig.note && <p className="text-sm text-secondary-700">{sig.note}</p>}
        </div>
      )}

      {state && !sig && (
        <div className="space-y-3">
          <p className="text-sm text-secondary-600">
            {state.can_sign
              ? 'When you hand the order over, get the customer to sign here. It keeps a record that they received it.'
              : `This order is ${state.status.replace(/_/g, ' ')}, so it can’t be signed for.`}
          </p>
          {editable && state.can_sign && (
            <Button className="print:hidden" onClick={start} leftIcon={<PenLine className="h-4 w-4" />}>
              Get the customer’s signature
            </Button>
          )}
        </div>
      )}

      {open && (
        <Modal
          isOpen={open}
          onClose={() => !saving && setOpen(false)}
          title="Customer signs for the order"
          description={`Order ${order.order_number}. Hand the screen to the customer to sign.`}
          size="lg"
          footer={
            <>
              <Button variant="ghost" onClick={() => setOpen(false)} disabled={saving}>Cancel</Button>
              <Button onClick={save} isLoading={saving} disabled={!png || name.trim().length < 2}>Save signature</Button>
            </>
          }
        >
          <div className="space-y-4">
            <SignaturePad onChange={setPng} />
            <Input
              label="Name of the person signing"
              id="pod-name"
              value={name}
              onChange={(e) => setName(e.target.value)}
              maxLength={120}
              autoComplete="off"
            />
            <Textarea
              label="Note (optional)"
              id="pod-note"
              value={note}
              onChange={(e) => setNote(e.target.value)}
              rows={2}
              maxLength={1000}
              placeholder="e.g. left with reception, 2 boxes"
            />
            {order.status !== 'delivered' && (
              <label className="flex items-center justify-between gap-3 text-sm text-secondary-700">
                <span>Mark the order as delivered</span>
                <Switch checked={markDelivered} onChange={setMarkDelivered} aria-label="Mark the order as delivered" />
              </label>
            )}
          </div>
        </Modal>
      )}
    </Card>
  );
}

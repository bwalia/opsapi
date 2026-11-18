'use client';

/**
 * Stock enquiries from a product: "have you got this in stock?" to a supplier, before there is a customer.
 *
 *  - StockEnquiryModal: pick a supplier, a quantity and (optionally) the spec you need, and the message is ready
 *    ("Hello Sam", qty x product, their code and the part number when we know them, then: in stock or lead time?
 *    trade price ex VAT? delivery? how long is the price valid?). Edit it, then email it from here, or open
 *    WhatsApp or a text message with it ready on your own phone. Our prices are never in it.
 *  - StockEnquiriesCard: the enquiries sent for this product, newest first, where their answer is recorded.
 */
import React, { useCallback, useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import { Check, Mail, MessageCircle, MessageSquare, PackageSearch, Pencil, Trash2, X } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Card, Input, Modal, Select, Textarea } from '@/components/ui';
import { shopService } from '@/services/shop.service';
import { extractApiError } from '@/lib/utils';
import { formatMoney, minorToPounds, poundsToMinor } from '@/lib/shop';
import type { ShopAskChannel, ShopStockEnquiry, ShopStockEnquiryDraft, ShopSupplier } from '@/types/shop';

const LABEL: Record<ShopAskChannel, string> = { email: 'email', whatsapp: 'WhatsApp', sms: 'text message' };

export function StockEnquiryModal({ productUuid, productName, open, onClose, onSent }: {
  productUuid: string;
  productName: string;
  open: boolean;
  onClose: () => void;
  onSent?: () => void;
}) {
  const [suppliers, setSuppliers] = useState<ShopSupplier[] | null>(null);
  const [supplierUuid, setSupplierUuid] = useState('');
  const [qty, setQty] = useState('1');
  const [note, setNote] = useState('');
  const [draft, setDraft] = useState<ShopStockEnquiryDraft | null>(null);
  const [subject, setSubject] = useState('');
  const [message, setMessage] = useState('');
  const [edited, setEdited] = useState(false);
  const [loading, setLoading] = useState(false);
  const [sending, setSending] = useState<ShopAskChannel | null>(null);
  const seq = useRef(0);

  useEffect(() => {
    if (!open || suppliers) return;
    shopService.getSuppliers()
      .then((list) => setSuppliers([...list].filter((s) => s.is_active !== false).sort((a, b) => a.name.localeCompare(b.name))))
      .catch((e) => { setSuppliers([]); toast.error(extractApiError(e, 'Could not load your suppliers')); });
  }, [open, suppliers]);

  const qtyNum = Math.max(1, Math.floor(Number(qty) || 1));

  // The message follows the supplier, quantity and note until it is edited by hand.
  const redraft = useCallback(async (uuid: string, n: number, spec: string) => {
    if (!uuid) { setDraft(null); return; }
    const mine = ++seq.current;
    setLoading(true);
    try {
      const d = await shopService.stockEnquiryDraft(productUuid, uuid, n, spec);
      if (mine !== seq.current) return;
      setDraft(d);
      setSubject(d.subject);
      setMessage(d.body);
      setEdited(false);
    } catch (e) {
      if (mine === seq.current) toast.error(extractApiError(e, 'Could not get the message ready'));
    } finally {
      if (mine === seq.current) setLoading(false);
    }
  }, [productUuid]);

  useEffect(() => {
    if (!open || !supplierUuid || edited) return;
    const t = setTimeout(() => { void redraft(supplierUuid, qtyNum, note); }, 300);
    return () => clearTimeout(t);
  }, [open, supplierUuid, qtyNum, note, edited, redraft]);

  const reset = () => {
    setSupplierUuid(''); setQty('1'); setNote(''); setDraft(null); setSubject(''); setMessage(''); setEdited(false);
  };
  const close = () => { if (sending) return; reset(); onClose(); };

  const send = async (channel: ShopAskChannel) => {
    if (!draft || !message.trim()) return;
    // WhatsApp opens in a new tab: open it now, while the click still counts, and point it at the link after.
    const tab = channel === 'whatsapp' ? window.open('', '_blank') : null;
    setSending(channel);
    try {
      const res = await shopService.stockEnquirySend(productUuid, {
        supplier_uuid: draft.supplier.uuid, channel, qty: qtyNum, subject, message,
      });
      if (res.link) {
        if (tab) tab.location.href = res.link;
        else window.location.href = res.link;
      }
      const kept = res.enquiry ? ' Saved under Stock enquiries.' : '';
      toast.success(channel === 'email' ? `Emailed to ${res.sent_to}.${kept}` : `Opening ${LABEL[channel]}: press send there.${kept}`);
      onSent?.();
      reset();
      onClose();
    } catch (e) {
      tab?.close();
      toast.error(extractApiError(e, `Could not send the ${LABEL[channel]}`));
    } finally {
      setSending(null);
    }
  };

  const s = draft?.supplier;
  const busy = loading || !!sending;
  const noText = !message.trim();

  return (
    <Modal
      isOpen={open}
      onClose={close}
      size="2xl"
      title="Ask suppliers about stock"
      description={`Ask a supplier if they have ${productName} in stock, their price and when they could deliver. Our prices are never included.`}
      footer={
        <>
          <Button variant="ghost" onClick={close} disabled={!!sending}>Cancel</Button>
          <Button variant="outline" leftIcon={<MessageSquare className="h-4 w-4" />} onClick={() => send('sms')}
            isLoading={sending === 'sms'} disabled={!s?.phone_intl || busy || noText}
            title={s && !s.phone_intl ? 'Add a phone number to this supplier first' : 'Opens your messages app with the text ready'}>
            Text message
          </Button>
          <Button variant="outline" leftIcon={<MessageCircle className="h-4 w-4" />} onClick={() => send('whatsapp')}
            isLoading={sending === 'whatsapp'} disabled={!s?.phone_intl || busy || noText}
            title={s && !s.phone_intl ? 'Add a phone number to this supplier first' : 'Opens WhatsApp with the message ready'}>
            WhatsApp
          </Button>
          <Button leftIcon={<Mail className="h-4 w-4" />} onClick={() => send('email')}
            isLoading={sending === 'email'} disabled={!s?.email || busy || noText}
            title={s && !s.email ? 'Add an email address to this supplier first' : undefined}>
            Send email
          </Button>
        </>
      }
    >
      <div className="space-y-4">
        {suppliers === null && <p className="text-sm text-secondary-500">Loading your suppliers…</p>}
        {suppliers && suppliers.length === 0 && (
          <p className="text-sm text-secondary-600">
            You have no suppliers yet. <Link href="/dashboard/shop/suppliers" className="font-medium text-primary-600 hover:underline">Add one under Shop → Suppliers</Link>, then come back.
          </p>
        )}
        {suppliers && suppliers.length > 0 && (
          <div className="grid gap-3 sm:grid-cols-[1fr_8rem]">
            <Select label="Supplier" id="stock-supplier" value={supplierUuid}
              onChange={(e) => { setSupplierUuid(e.target.value); setEdited(false); if (!e.target.value) setDraft(null); }}
              disabled={!!sending}>
              <option value="">Choose a supplier…</option>
              {suppliers.map((x) => (
                <option key={x.uuid} value={x.uuid}>{x.contact_name ? `${x.name} (${x.contact_name})` : x.name}</option>
              ))}
            </Select>
            <Input label="Quantity" id="stock-qty" value={qty} onChange={(e) => setQty(e.target.value.replace(/[^\d]/g, ''))}
              inputMode="numeric" disabled={!!sending} />
          </div>
        )}
        {supplierUuid && (
          <Textarea label="Spec you need (optional)" id="stock-note" rows={2} value={note} maxLength={2000}
            placeholder={'e.g. RTX 5090, 64 GB RAM, 2 TB SSD (one item per line)'}
            onChange={(e) => setNote(e.target.value)} disabled={!!sending || edited}
            helperText={edited ? 'You have edited the message: change the spec there.' : undefined} />
        )}

        {loading && !draft && <p className="text-sm text-secondary-500">Getting the message ready…</p>}

        {draft && s && (
          <>
            <div className="rounded-lg border border-secondary-200 bg-secondary-50 p-3 text-sm">
              <p className="text-secondary-800">
                To <span className="font-medium">{s.contact_name ? `${s.contact_name} at ${s.name}` : s.name}</span>
              </p>
              <p className="mt-0.5 text-xs text-secondary-600">{[s.email ?? 'no email', s.phone ?? 'no phone'].join(' · ')}</p>
              {(!s.email || !s.phone_intl || !s.contact_name) && (
                <p className="mt-1 text-xs text-secondary-600">
                  {!s.contact_name && 'Add a contact name to greet them by name. '}
                  {!s.email && 'Add an email to send it by email. '}
                  {!s.phone_intl && 'Add a phone number to send it by WhatsApp or text. '}
                  <Link href="/dashboard/shop/suppliers" className="font-medium text-primary-600 hover:underline">Edit suppliers</Link>
                </p>
              )}
            </div>
            <Input label="Subject (email)" id="stock-subject" value={subject} maxLength={200}
              onChange={(e) => { setSubject(e.target.value); setEdited(true); }} />
            <Textarea label="Message" id="stock-message" rows={13} value={message} maxLength={8000}
              onChange={(e) => { setMessage(e.target.value); setEdited(true); }} />
            <div className="flex items-start justify-between gap-3">
              <p className="text-xs text-secondary-500">
                Email is sent from here and their reply comes to you. WhatsApp and text open on your device with the message ready: press send there.
                Each enquiry is saved on this product, where you record their answer.
              </p>
              {edited && (
                <Button size="sm" variant="ghost" onClick={() => setEdited(false)} disabled={busy}>Start again</Button>
              )}
            </div>
          </>
        )}
      </div>
    </Modal>
  );
}

interface AnswerForm { stock_qty: string; lead_time: string; price: string; valid_until: string; supplier_quote_ref: string; notes: string }

function toForm(e: ShopStockEnquiry): AnswerForm {
  return {
    stock_qty: e.stock_qty == null ? '' : String(e.stock_qty),
    lead_time: e.lead_time ?? '',
    price: e.unit_price_minor == null ? '' : String(minorToPounds(e.unit_price_minor)),
    valid_until: e.valid_until ?? '',
    supplier_quote_ref: e.supplier_quote_ref ?? '',
    notes: e.notes ?? '',
  };
}

function sentLabel(e: ShopStockEnquiry) {
  const when = e.sent_at ? new Date(e.sent_at).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }) : '';
  return [when && `sent ${when}`, e.channel && `by ${LABEL[e.channel]}`].filter(Boolean).join(' ');
}

export function StockEnquiriesCard({ productUuid, version, onAsk, canAsk, canEdit }: {
  productUuid: string;
  version: number;
  onAsk: () => void;
  canAsk: boolean;
  canEdit: boolean;
}) {
  const [rows, setRows] = useState<ShopStockEnquiry[] | null>(null);
  const [editing, setEditing] = useState<string | null>(null);
  const [form, setForm] = useState<AnswerForm | null>(null);
  const [saving, setSaving] = useState(false);

  const load = useCallback(() => {
    shopService.getStockEnquiries({ product: productUuid, limit: 20 })
      .then(setRows)
      .catch((e) => { setRows([]); toast.error(extractApiError(e, 'Could not load stock enquiries')); });
  }, [productUuid]);

  useEffect(() => { load(); }, [load, version]);

  const save = async (uuid: string) => {
    if (!form) return;
    const stock = form.stock_qty.trim() === '' ? null : Math.floor(Number(form.stock_qty));
    const price = form.price.trim() === '' ? null : poundsToMinor(form.price);
    if (stock !== null && (!Number.isFinite(stock) || stock < 0)) { toast.error('Stock must be a whole number'); return; }
    if (form.price.trim() !== '' && (price === null || price < 0)) { toast.error('Price must be an amount in pounds'); return; }
    setSaving(true);
    try {
      const updated = await shopService.updateStockEnquiry(uuid, {
        stock_qty: stock, unit_price_minor: price, lead_time: form.lead_time.trim() || null,
        valid_until: form.valid_until || null, supplier_quote_ref: form.supplier_quote_ref.trim() || null, notes: form.notes.trim() || null,
      });
      setRows((r) => (r ?? []).map((x) => (x.uuid === uuid ? updated : x)));
      setEditing(null);
      toast.success('Answer saved');
    } catch (e) {
      toast.error(extractApiError(e, 'Could not save the answer'));
    } finally {
      setSaving(false);
    }
  };

  const remove = async (uuid: string) => {
    if (!window.confirm('Delete this stock enquiry?')) return;
    try {
      await shopService.deleteStockEnquiry(uuid);
      setRows((r) => (r ?? []).filter((x) => x.uuid !== uuid));
    } catch (e) {
      toast.error(extractApiError(e, 'Could not delete it'));
    }
  };

  return (
    <Card>
      <div className="mb-3 flex items-center justify-between gap-2">
        <h2 className="text-base font-semibold text-secondary-900">Stock enquiries</h2>
        {canAsk && (
          <Button size="sm" variant="outline" leftIcon={<PackageSearch className="h-4 w-4" />} onClick={onAsk}>Ask suppliers</Button>
        )}
      </div>
      {rows === null && <p className="text-sm text-secondary-500">Loading…</p>}
      {rows && rows.length === 0 && (
        <p className="text-sm text-secondary-500">None yet. Ask suppliers if they have it in stock, by email, WhatsApp or text.</p>
      )}
      {rows && rows.length > 0 && (
        <ul className="divide-y divide-secondary-100">
          {rows.map((e) => (
            <li key={e.uuid} className="py-3 text-sm">
              <div className="flex items-start justify-between gap-2">
                <div>
                  <p className="font-medium text-secondary-900">{e.supplier_name} <span className="font-normal text-secondary-500">· {e.qty} wanted</span></p>
                  <p className="text-xs text-secondary-500">{sentLabel(e)}</p>
                </div>
                {canEdit && editing !== e.uuid && (
                  <div className="flex shrink-0 gap-1">
                    <Button size="sm" variant="ghost" aria-label="Record their answer" title="Record their answer"
                      onClick={() => { setEditing(e.uuid); setForm(toForm(e)); }}><Pencil className="h-4 w-4" /></Button>
                    <Button size="sm" variant="ghost" aria-label="Delete" title="Delete" onClick={() => remove(e.uuid)}><Trash2 className="h-4 w-4" /></Button>
                  </div>
                )}
              </div>
              {editing !== e.uuid && (
                e.answered ? (
                  <p className="mt-1 text-secondary-700">
                    {[e.stock_qty != null && `${e.stock_qty} in stock`, e.lead_time, e.unit_price_minor != null && `${formatMoney(e.unit_price_minor)} ex VAT each`,
                      e.valid_until && `valid until ${e.valid_until}`, e.supplier_quote_ref && `ref ${e.supplier_quote_ref}`].filter(Boolean).join(' · ')}
                  </p>
                ) : (
                  <p className="mt-1 text-xs text-warning-700">Waiting for their answer</p>
                )
              )}
              {editing !== e.uuid && e.notes && <p className="mt-0.5 text-xs text-secondary-600">{e.notes}</p>}
              {editing === e.uuid && form && (
                <div className="mt-2 space-y-2">
                  <div className="grid grid-cols-2 gap-2">
                    <Input label="In stock" id={`se-stock-${e.uuid}`} value={form.stock_qty} inputMode="numeric"
                      onChange={(ev) => setForm({ ...form, stock_qty: ev.target.value })} />
                    <Input label="Price each, £ ex VAT" id={`se-price-${e.uuid}`} value={form.price} inputMode="decimal"
                      onChange={(ev) => setForm({ ...form, price: ev.target.value })} />
                    <Input label="Lead time" id={`se-lead-${e.uuid}`} value={form.lead_time} placeholder="e.g. 3-5 working days"
                      onChange={(ev) => setForm({ ...form, lead_time: ev.target.value })} />
                    <Input label="Price valid until" id={`se-valid-${e.uuid}`} type="date" value={form.valid_until}
                      onChange={(ev) => setForm({ ...form, valid_until: ev.target.value })} />
                  </div>
                  <Input label="Their reference" id={`se-ref-${e.uuid}`} value={form.supplier_quote_ref}
                    onChange={(ev) => setForm({ ...form, supplier_quote_ref: ev.target.value })} />
                  <Textarea label="Notes" id={`se-notes-${e.uuid}`} rows={2} value={form.notes}
                    onChange={(ev) => setForm({ ...form, notes: ev.target.value })} />
                  <div className="flex justify-end gap-2">
                    <Button size="sm" variant="ghost" leftIcon={<X className="h-4 w-4" />} onClick={() => setEditing(null)} disabled={saving}>Cancel</Button>
                    <Button size="sm" leftIcon={<Check className="h-4 w-4" />} onClick={() => save(e.uuid)} isLoading={saving}>Save answer</Button>
                  </div>
                </div>
              )}
            </li>
          ))}
        </ul>
      )}
    </Card>
  );
}

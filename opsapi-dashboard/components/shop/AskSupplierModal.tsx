'use client';

/**
 * "Ask a supplier" on a quote: pick a supplier and the price request is ready ("Hello Sam", the quote's lines
 * and their parts, then: available? price? delivery? how long is the price valid?), subject
 * "Price request: <deal code>". Edit it, then email it from here, or open WhatsApp or a text message with it
 * ready on your own phone. Every request is recorded on the deal, where their prices go when they answer.
 * The customer is never named: the server refuses a message that shows their details or our quote number.
 */
import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import { AlertTriangle, Mail, MessageCircle, MessageSquare } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Input, Modal, Select, Textarea } from '@/components/ui';
import { TemplatePicker, templateValue } from './TemplatePicker';
import { shopService } from '@/services/shop.service';
import { extractApiError } from '@/lib/utils';
import type { ShopAskChannel, ShopSupplier, ShopSupplierAsk } from '@/types/shop';

const LABEL: Record<ShopAskChannel, string> = { email: 'email', whatsapp: 'WhatsApp', sms: 'text message' };

export function AskSupplierModal({ quoteUuid, open, onClose }: { quoteUuid: string; open: boolean; onClose: () => void }) {
  const [suppliers, setSuppliers] = useState<ShopSupplier[] | null>(null);
  const [supplierUuid, setSupplierUuid] = useState('');
  const [template, setTemplate] = useState('');
  const [draft, setDraft] = useState<ShopSupplierAsk | null>(null);
  const [subject, setSubject] = useState('');
  const [message, setMessage] = useState('');
  const [loading, setLoading] = useState(false);
  const [sending, setSending] = useState<ShopAskChannel | null>(null);

  useEffect(() => {
    if (!open || suppliers) return;
    shopService.getSuppliers()
      .then((list) => setSuppliers([...list].sort((a, b) => a.name.localeCompare(b.name))))
      .catch((e) => { setSuppliers([]); toast.error(extractApiError(e, 'Could not load your suppliers')); });
  }, [open, suppliers]);

  const choose = async (uuid: string, tpl?: string) => {
    setSupplierUuid(uuid);
    setDraft(null);
    if (!uuid) return;
    setLoading(true);
    try {
      const d = await shopService.askSupplierDraft(quoteUuid, uuid, tpl);
      setDraft(d);
      setTemplate(templateValue(d.template));
      setSubject(d.subject);
      setMessage(d.body);
    } catch (e) {
      toast.error(extractApiError(e, 'Could not get the message ready'));
    } finally {
      setLoading(false);
    }
  };

  const send = async (channel: ShopAskChannel) => {
    if (!draft || !message.trim()) return;
    // WhatsApp opens in a new tab: open it now, while the click still counts, and point it at the link after.
    const tab = channel === 'whatsapp' ? window.open('', '_blank') : null;
    setSending(channel);
    try {
      const res = await shopService.askSupplierSend(quoteUuid, { supplier_uuid: draft.supplier.uuid, channel, subject, message });
      if (res.link) {
        if (tab) tab.location.href = res.link;
        else window.location.href = res.link;
      }
      const where = res.request ? ` Recorded on deal ${draft.deal_code}.` : '';
      toast.success(channel === 'email' ? `Emailed to ${res.sent_to}.${where}` : `Opening ${LABEL[channel]}: press send there.${where}`);
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
      onClose={() => !sending && onClose()}
      size="2xl"
      title="Ask a supplier"
      description="Ask for availability, price and delivery. The customer is never named: the deal code is the only reference."
      footer={
        <>
          <Button variant="ghost" onClick={onClose} disabled={!!sending}>Cancel</Button>
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
          <div className="grid gap-3 sm:grid-cols-2">
            <Select label="Supplier" id="ask-supplier" value={supplierUuid} onChange={(e) => choose(e.target.value)} disabled={!!sending}>
              <option value="">Choose a supplier…</option>
              {suppliers.map((x) => (
                <option key={x.uuid} value={x.uuid}>{x.contact_name ? `${x.name} (${x.contact_name})` : x.name}</option>
              ))}
            </Select>
            {draft && (
              <TemplatePicker id="ask-template" templates={draft.templates} value={template} disabled={loading || !!sending}
                onChange={(v) => { setTemplate(v); void choose(supplierUuid, v); }} />
            )}
          </div>
        )}

        {loading && <p className="text-sm text-secondary-500">Getting the message ready…</p>}

        {draft && s && (
          <>
            <div className="rounded-lg border border-secondary-200 bg-secondary-50 p-3 text-sm">
              <p className="text-secondary-800">
                To <span className="font-medium">{s.contact_name ? `${s.contact_name} at ${s.name}` : s.name}</span>
              </p>
              <p className="mt-0.5 text-xs text-secondary-600">
                {[s.email ?? 'no email', s.phone ?? 'no phone'].join(' · ')} · Deal {draft.deal_code}
              </p>
              {(!s.email || !s.phone_intl || !s.contact_name) && (
                <p className="mt-1 text-xs text-secondary-600">
                  {!s.contact_name && 'Add a contact name to greet them by name. '}
                  {!s.email && 'Add an email to send it by email. '}
                  {!s.phone_intl && 'Add a phone number to send it by WhatsApp or text. '}
                  <Link href="/dashboard/shop/suppliers" className="font-medium text-primary-600 hover:underline">Edit suppliers</Link>
                </p>
              )}
            </div>
            {draft.customer_details.length > 0 && (
              <p className="flex items-start gap-2 rounded-lg border border-warning-200 bg-warning-50 p-3 text-sm text-warning-800" role="alert">
                <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
                The message shows the customer&apos;s {draft.customer_details.join(', ').replace(/_/g, ' ')}. Remove it before sending: suppliers must not see who the customer is.
              </p>
            )}
            <Input label="Subject (email)" id="ask-subject" value={subject} onChange={(e) => setSubject(e.target.value)} maxLength={200} />
            <Textarea label="Message" id="ask-message" rows={14} value={message} onChange={(e) => setMessage(e.target.value)} maxLength={8000} />
            <p className="text-xs text-secondary-500">
              Email is sent from here and their reply comes to you. WhatsApp and text open on your device with the message ready: press send there.
              Each request is saved on the deal, where you record their price when they answer.
            </p>
          </>
        )}
      </div>
    </Modal>
  );
}

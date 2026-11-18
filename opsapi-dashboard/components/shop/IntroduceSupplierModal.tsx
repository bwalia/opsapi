'use client';

/**
 * "Introduce to supplier" on a quote: when a supplier can serve the customer faster (stock, lead time, specialist
 * kit), introduce them directly. Pick a supplier and the message is ready from a template (this supplier's own,
 * e.g. "Introduction to Boston", else the default, else the built-in): "Hello Sam", who the customer is, what
 * they need, their contact details and our deal code.
 *
 * Unlike "Email supplier", this DOES share the customer's name, organisation, email and phone, so it can only be
 * sent once staff confirm the customer agreed. By email the customer is copied (untick to leave them off);
 * WhatsApp and text open on your own device. Every introduction is recorded on the deal.
 */
import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import { Mail, MessageCircle, MessageSquare, ShieldAlert } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Input, Modal, Select, Textarea } from '@/components/ui';
import { CheckboxField } from './editor-fields';
import { TemplatePicker, templateValue } from './TemplatePicker';
import { shopService } from '@/services/shop.service';
import { extractApiError } from '@/lib/utils';
import type { ShopAskChannel, ShopSupplier, ShopSupplierIntroDraft } from '@/types/shop';

const LABEL: Record<ShopAskChannel, string> = { email: 'email', whatsapp: 'WhatsApp', sms: 'text message' };

export function IntroduceSupplierModal({ quoteUuid, open, onClose }: { quoteUuid: string; open: boolean; onClose: () => void }) {
  const [suppliers, setSuppliers] = useState<ShopSupplier[] | null>(null);
  const [supplierUuid, setSupplierUuid] = useState('');
  const [template, setTemplate] = useState('');
  const [draft, setDraft] = useState<ShopSupplierIntroDraft | null>(null);
  const [subject, setSubject] = useState('');
  const [message, setMessage] = useState('');
  const [agreed, setAgreed] = useState(false);
  const [ccCustomer, setCcCustomer] = useState(true);
  const [loading, setLoading] = useState(false);
  const [sending, setSending] = useState<ShopAskChannel | null>(null);

  useEffect(() => {
    if (!open || suppliers) return;
    shopService.getSuppliers()
      .then((list) => setSuppliers([...list].sort((a, b) => a.name.localeCompare(b.name))))
      .catch((e) => { setSuppliers([]); toast.error(extractApiError(e, 'Could not load your suppliers')); });
  }, [open, suppliers]);

  const load = async (uuid: string, tpl?: string) => {
    setDraft(null);
    if (!uuid) return;
    setLoading(true);
    try {
      const d = await shopService.supplierIntroDraft(quoteUuid, uuid, tpl);
      setDraft(d);
      setTemplate(templateValue(d.template));
      setSubject(d.subject);
      setMessage(d.body);
    } catch (e) {
      toast.error(extractApiError(e, 'Could not get the introduction ready'));
    } finally {
      setLoading(false);
    }
  };

  const send = async (channel: ShopAskChannel) => {
    if (!draft || !message.trim() || !agreed) return;
    const tab = channel === 'whatsapp' ? window.open('', '_blank') : null;
    setSending(channel);
    try {
      const res = await shopService.supplierIntroSend(quoteUuid, {
        supplier_uuid: draft.supplier.uuid, channel, subject, message, customer_agreed: true, cc_customer: ccCustomer,
        template_uuid: draft.template?.uuid ?? null,
      });
      if (res.link) {
        if (tab) tab.location.href = res.link;
        else window.location.href = res.link;
      }
      toast.success(channel === 'email'
        ? `Introduction emailed to ${res.sent_to}${res.cc ? `, copying ${res.cc}` : ''}. Recorded on deal ${draft.deal_code}.`
        : `Opening ${LABEL[channel]}: press send there. Recorded on deal ${draft.deal_code}.`);
      onClose();
    } catch (e) {
      tab?.close();
      toast.error(extractApiError(e, `Could not send the ${LABEL[channel]}`));
    } finally {
      setSending(null);
    }
  };

  const s = draft?.supplier;
  const c = draft?.customer;
  const busy = loading || !!sending;
  const blocked = busy || !message.trim() || !agreed;

  return (
    <Modal
      isOpen={open}
      onClose={() => !sending && onClose()}
      size="2xl"
      title="Introduce to a supplier"
      description="Put the customer in touch with a supplier who can serve them faster. This shares the customer's details, so only send it with their agreement."
      footer={
        <>
          <Button variant="ghost" onClick={onClose} disabled={!!sending}>Cancel</Button>
          <Button variant="outline" leftIcon={<MessageSquare className="h-4 w-4" />} onClick={() => send('sms')}
            isLoading={sending === 'sms'} disabled={!s?.phone_intl || blocked}
            title={s && !s.phone_intl ? 'Add a phone number to this supplier first' : 'Opens your messages app with the text ready'}>
            Text message
          </Button>
          <Button variant="outline" leftIcon={<MessageCircle className="h-4 w-4" />} onClick={() => send('whatsapp')}
            isLoading={sending === 'whatsapp'} disabled={!s?.phone_intl || blocked}
            title={s && !s.phone_intl ? 'Add a phone number to this supplier first' : 'Opens WhatsApp with the message ready'}>
            WhatsApp
          </Button>
          <Button leftIcon={<Mail className="h-4 w-4" />} onClick={() => send('email')}
            isLoading={sending === 'email'} disabled={!s?.email || blocked}
            title={!agreed ? 'Confirm the customer agreed first' : s && !s.email ? 'Add an email address to this supplier first' : undefined}>
            Send introduction
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
            <Select label="Supplier" id="intro-supplier" value={supplierUuid}
              onChange={(e) => { setSupplierUuid(e.target.value); void load(e.target.value); }} disabled={!!sending}>
              <option value="">Choose a supplier…</option>
              {suppliers.map((x) => (
                <option key={x.uuid} value={x.uuid}>{x.contact_name ? `${x.name} (${x.contact_name})` : x.name}</option>
              ))}
            </Select>
            {draft && (
              <TemplatePicker id="intro-template" templates={draft.templates} value={template} disabled={busy}
                onChange={(v) => { setTemplate(v); void load(supplierUuid, v); }} />
            )}
          </div>
        )}

        {loading && <p className="text-sm text-secondary-500">Getting the introduction ready…</p>}

        {draft && s && c && (
          <>
            <div className="grid gap-3 sm:grid-cols-2">
              <div className="rounded-lg border border-secondary-200 bg-secondary-50 p-3 text-sm">
                <p className="text-xs font-semibold uppercase tracking-wide text-secondary-500">Supplier</p>
                <p className="text-secondary-800">{s.contact_name ? `${s.contact_name} at ${s.name}` : s.name}</p>
                <p className="text-xs text-secondary-600">{[s.email ?? 'no email', s.phone ?? 'no phone'].join(' · ')}</p>
              </div>
              <div className="rounded-lg border border-warning-200 bg-warning-50 p-3 text-sm">
                <p className="text-xs font-semibold uppercase tracking-wide text-warning-800">Customer (shared with the supplier)</p>
                <p className="text-secondary-800">{[c.name, c.company].filter(Boolean).join(', ') || 'No name on the quote'}</p>
                <p className="text-xs text-secondary-600">{[c.email ?? 'no email', c.phone ?? 'no phone'].join(' · ')} · Deal {draft.deal_code}</p>
              </div>
            </div>
            <Input label="Subject (email)" id="intro-subject" value={subject} onChange={(e) => setSubject(e.target.value)} maxLength={200} />
            <Textarea label="Message" id="intro-message" rows={14} value={message} onChange={(e) => setMessage(e.target.value)} maxLength={8000} />
            <div className="space-y-2 rounded-lg border border-warning-200 bg-warning-50 p-3">
              <p className="flex items-start gap-2 text-sm text-warning-800">
                <ShieldAlert className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
                This sends the customer&apos;s name, organisation, email and phone to {s.name}. Only do it if the customer agreed.
              </p>
              <CheckboxField label="The customer agreed to be introduced to this supplier" checked={agreed} onChange={setAgreed} />
              <CheckboxField label={c.email ? `Copy the customer on the email (${c.email})` : 'Copy the customer on the email (no email on the quote)'}
                description="Recommended: they see who now has their details and can reply directly."
                checked={ccCustomer && !!c.email} onChange={(v) => setCcCustomer(v)} />
            </div>
            <p className="text-xs text-secondary-500">
              Email is sent from here and replies come to you. WhatsApp and text open on your device with the message ready: press send there.
              The introduction is recorded on the deal.
            </p>
          </>
        )}
      </div>
    </Modal>
  );
}

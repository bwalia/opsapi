'use client';

import React, { useCallback, useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import { AlertTriangle, FlaskConical, Mail, Send } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Card, Input, Modal, Select, Textarea, confirmDialog } from '@/components/ui';
import { SectionTitle } from '@/components/shop/shared';
import { shopService } from '@/services/shop.service';
import { extractApiError, formatDateTime } from '@/lib/utils';
import type { ShopOrder, ShopOrderUpdateEmail, ShopOrderUpdateInfo, ShopOrderUpdatePreview } from '@/types/shop';

const KIND_LABEL: Record<string, string> = {
  received_reserved: 'Order received',
  in_stock_book_delivery: 'Ready to deliver',
  dispatched: 'Dispatched',
  delayed: 'Delayed',
  custom: 'Own message',
};

function HistoryItem({ e }: { e: ShopOrderUpdateEmail }) {
  return (
    <li className="py-2">
      <details className="group">
        <summary className="flex cursor-pointer list-none flex-wrap items-center justify-between gap-2 text-sm">
          <span className="flex min-w-0 items-center gap-2">
            {e.test ? (
              <span className="inline-flex shrink-0 items-center rounded-full bg-secondary-100 px-2 py-0.5 text-xs font-medium text-secondary-600">Test</span>
            ) : (
              <span className="inline-flex shrink-0 items-center rounded-full bg-success-50 px-2 py-0.5 text-xs font-medium text-success-700">Sent</span>
            )}
            <span className="truncate font-medium text-secondary-900">{e.headline}</span>
          </span>
          <span className="text-xs text-secondary-500">{formatDateTime(e.created_at)}</span>
        </summary>
        <div className="mt-2 rounded-lg bg-secondary-50 p-3 text-sm">
          <p className="text-xs text-secondary-500">
            To {e.to_email} · by {e.sent_by ?? 'staff'} · {KIND_LABEL[e.kind] ?? e.kind}
          </p>
          {e.subject && <p className="mt-1 text-xs text-secondary-600">Subject: {e.subject}</p>}
          <p className="mt-2 whitespace-pre-line text-secondary-700">{e.body}</p>
        </div>
      </details>
    </li>
  );
}

/**
 * "Email the customer" on the order page: pick a preset (order received, ready to deliver, dispatched,
 * delayed, or your own words), edit it, preview the real email and send a test to yourself or send it to
 * the customer. Sending to the customer needs Shop settings → "Customer emails from the shop" on.
 * The history lists every update sent, tests included.
 */
export function OrderUpdateEmail({ order, editable, onChanged }: { order: ShopOrder; editable: boolean; onChanged: (o: ShopOrder) => void }) {
  const [info, setInfo] = useState<ShopOrderUpdateInfo | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [open, setOpen] = useState(false);
  const [preset, setPreset] = useState('received_reserved');
  const [headline, setHeadline] = useState('');
  const [message, setMessage] = useState('');
  const [dirty, setDirty] = useState(false);
  const [preview, setPreview] = useState<ShopOrderUpdatePreview | null>(null);
  const [previewError, setPreviewError] = useState<string | null>(null);
  const [previewing, setPreviewing] = useState(false);
  const [busy, setBusy] = useState<'test' | 'send' | null>(null);
  const [showAll, setShowAll] = useState(false);
  const seq = useRef(0);

  const load = useCallback(() => {
    if (!editable) return;
    shopService
      .getOrderUpdateEmail(order.uuid)
      .then((i) => {
        setInfo(i);
        setLoadError(null);
      })
      .catch((err) => setLoadError(extractApiError(err, 'Could not load the order update emails')));
  }, [order.uuid, editable]);

  useEffect(() => {
    load();
  }, [load]);

  const applyPreset = (key: string, list = info?.presets) => {
    const p = list?.find((x) => x.key === key);
    setPreset(key);
    setHeadline(p?.headline ?? '');
    setMessage(p?.message ?? '');
    setDirty(false);
  };

  const openModal = () => {
    applyPreset(preset);
    setPreview(null);
    setPreviewError(null);
    setOpen(true);
  };

  const choosePreset = async (key: string) => {
    if (dirty && !(await confirmDialog({ title: 'Replace your text?', message: 'Your edits to the headline and message will be replaced by the preset.', confirmText: 'Replace' }))) return;
    applyPreset(key);
  };

  // Live preview, debounced; the latest request wins.
  useEffect(() => {
    if (!open) return;
    if (!headline.trim() || !message.trim()) {
      setPreview(null);
      setPreviewError(null);
      return;
    }
    const n = ++seq.current;
    const t = setTimeout(() => {
      setPreviewing(true);
      shopService
        .previewOrderUpdateEmail(order.uuid, { preset, headline, message })
        .then((p) => {
          if (n !== seq.current) return;
          setPreview(p);
          setPreviewError(null);
        })
        .catch((err) => {
          if (n !== seq.current) return;
          setPreviewError(extractApiError(err, 'Could not preview the email'));
        })
        .finally(() => n === seq.current && setPreviewing(false));
    }, 450);
    return () => clearTimeout(t);
  }, [open, order.uuid, preset, headline, message]);

  if (!editable) return null;

  const enabled = !!info?.customer_emails_enabled;
  const to = info?.to ?? null;
  const limits = info?.limits;
  const atLimit = !!limits && limits.sent_last_24h >= limits.per_day;
  const blank = !headline.trim() || !message.trim();
  const marker = /\[[A-Z][A-Z0-9 /-]*\]/.exec(`${headline}\n${message}`)?.[0] ?? null;
  const sendBlocked = !enabled
    ? 'Customer emails from the shop are off.'
    : !to
      ? 'This order has no customer email address.'
      : !info?.email_configured
        ? 'No email server is set up for this workspace.'
        : atLimit
          ? `This order has had ${limits?.per_day} update emails in the last 24 hours.`
          : marker
            ? `Replace ${marker} before sending.`
            : null;

  const send = async (test: boolean) => {
    if (blank) {
      toast.error('Write a headline and a message first');
      return;
    }
    if (!test) {
      const ok = await confirmDialog({
        title: 'Email the customer?',
        message: (
          <span>
            “{headline.trim()}” will be emailed to <strong>{to}</strong> now. A note is added to the order.
          </span>
        ),
        confirmText: 'Send to customer',
      });
      if (!ok) return;
    }
    setBusy(test ? 'test' : 'send');
    try {
      const res = await shopService.sendOrderUpdateEmail(order.uuid, { preset, headline, message, test });
      toast.success(test ? `Test sent to ${res.to}` : `Update emailed to ${res.to}`, { duration: 6000 });
      if (!res.logged) toast.error('The email was sent but could not be recorded on the order. Do not send it again.', { duration: 8000 });
      setInfo((i) => (i ? { ...i, history: res.history, limits: { ...i.limits, sent_last_24h: i.limits.sent_last_24h + (test ? 0 : 1) } } : i));
      if (!test) {
        setOpen(false);
        if (res.order?.uuid) onChanged(res.order);
      }
    } catch (err) {
      toast.error(extractApiError(err, 'The email could not be sent'), { duration: 8000 });
    } finally {
      setBusy(null);
    }
  };

  const history = info?.history ?? [];
  const visible = showAll ? history : history.slice(0, 5);

  return (
    <Card className="print:hidden">
      <SectionTitle
        actions={
          <Button size="sm" leftIcon={<Mail className="h-4 w-4" />} disabled={!info} onClick={openModal}>
            Email the customer
          </Button>
        }
      >
        Customer updates
      </SectionTitle>
      {loadError && <p className="text-sm text-error-600">{loadError}</p>}
      {info && (
        <div className="space-y-2 text-sm">
          <p className="text-secondary-600">
            {to ? (
              <>Send a short update about this order to <span className="font-medium text-secondary-900">{to}</span>: order received, ready to deliver, dispatched, delayed, or your own words.</>
            ) : (
              'This order has no customer email address, so it can’t be emailed.'
            )}
          </p>
          {!enabled && (
            <p className="flex items-start gap-1.5 rounded-lg bg-warning-50 px-3 py-2 text-xs text-warning-800">
              <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
              <span>
                Customer emails from the shop are off, so you can only send a test to yourself. Turn them on in{' '}
                <Link href="/dashboard/shop/settings" className="font-medium underline">Shop settings</Link> once the sending address is right.
              </span>
            </p>
          )}
        </div>
      )}
      {history.length > 0 && (
        <div className="mt-4 border-t border-secondary-100 pt-3">
          <p className="mb-1 text-xs font-semibold uppercase tracking-wider text-secondary-500">Sent</p>
          <ul className="divide-y divide-secondary-100">
            {visible.map((e) => (
              <HistoryItem key={e.uuid} e={e} />
            ))}
          </ul>
          {history.length > 5 && (
            <button type="button" className="mt-2 text-sm text-primary-600 hover:underline" onClick={() => setShowAll((v) => !v)}>
              {showAll ? 'Show fewer' : `Show all ${history.length}`}
            </button>
          )}
        </div>
      )}

      <Modal
        isOpen={open}
        onClose={() => !busy && setOpen(false)}
        title={`Email the customer: order ${order.order_number}`}
        description="A one-off update about this order. Not a marketing email: no unsubscribe link, no tracking."
        size="3xl"
        footer={
          <>
            <Button variant="ghost" onClick={() => setOpen(false)} disabled={!!busy}>
              Cancel
            </Button>
            <Button
              variant="outline"
              leftIcon={<FlaskConical className="h-4 w-4" />}
              isLoading={busy === 'test'}
              disabled={!!busy || blank || !info?.test_to}
              title={info?.test_to ? `Sends a [TEST] copy to ${info.test_to}` : 'Your account has no email address'}
              onClick={() => send(true)}
            >
              Send test to me
            </Button>
            <Button
              leftIcon={<Send className="h-4 w-4" />}
              isLoading={busy === 'send'}
              disabled={!!busy || blank || !!sendBlocked}
              title={sendBlocked ?? (to ? `Send to ${to}` : undefined)}
              onClick={() => send(false)}
            >
              Send to customer
            </Button>
          </>
        }
      >
        {info && (
          <div className="grid grid-cols-1 gap-5 lg:grid-cols-2">
            <div className="space-y-4">
              <Select label="Start from" id="order-update-preset" value={preset} onChange={(e) => choosePreset(e.target.value)}>
                {info.presets.map((p) => (
                  <option key={p.key} value={p.key}>
                    {p.label}
                  </option>
                ))}
              </Select>
              <Input
                label="Headline"
                id="order-update-headline"
                value={headline}
                maxLength={info.limits.headline_max}
                placeholder="e.g. Order received"
                onChange={(e) => {
                  setHeadline(e.target.value);
                  setDirty(true);
                }}
              />
              <Textarea
                label="Message"
                id="order-update-message"
                value={message}
                rows={11}
                maxLength={info.limits.message_max}
                placeholder="What you'd like to tell the customer. The greeting, order details, link and sign-off are added for you."
                helperText={`${message.length} / ${info.limits.message_max} characters. Signed “${info.signature}”.`}
                onChange={(e) => {
                  setMessage(e.target.value);
                  setDirty(true);
                }}
              />
              <div className="rounded-lg border border-secondary-200 p-3 text-xs text-secondary-600">
                <p>
                  <span className="font-medium text-secondary-800">To:</span> {to ?? 'no email on this order'}
                  {info.test_to && <span className="text-secondary-500"> · tests go to {info.test_to}</span>}
                </p>
                {sendBlocked && (
                  <p className="mt-1 text-warning-800">
                    {sendBlocked}{' '}
                    {!enabled && (
                      <>
                        Turn on “Customer emails from the shop” in{' '}
                        <Link href="/dashboard/shop/settings" className="font-medium underline">Shop settings</Link>. You can still send a test to yourself.
                      </>
                    )}
                  </p>
                )}
              </div>
            </div>
            <div className="flex min-h-[28rem] flex-col">
              <p className="mb-1 text-xs font-semibold uppercase tracking-wider text-secondary-500">
                Preview{previewing ? '…' : ''}
                {preview?.customised && <span className="ml-2 font-normal normal-case text-secondary-500">(your workspace’s version of the template)</span>}
              </p>
              {preview && (
                <p className="mb-2 truncate text-sm">
                  <span className="text-secondary-500">Subject:</span> {preview.subject}
                </p>
              )}
              {(preview?.warnings ?? []).map((w) => (
                <p key={w} className="mb-2 flex items-start gap-1.5 text-xs text-warning-800">
                  <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" /> {w}
                </p>
              ))}
              {previewError && <p className="mb-2 text-sm text-error-600">{previewError}</p>}
              {preview ? (
                <iframe title="Email preview" sandbox="" srcDoc={preview.html} className="w-full flex-1 rounded-lg border border-secondary-200 bg-white" />
              ) : (
                <div className="flex flex-1 items-center justify-center rounded-lg border border-dashed border-secondary-300 p-6 text-center text-sm text-secondary-500">
                  {blank ? 'Write a headline and a message to see the email.' : 'Loading the preview…'}
                </div>
              )}
            </div>
          </div>
        )}
      </Modal>
    </Card>
  );
}

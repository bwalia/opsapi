'use client';

import React, { useState } from 'react';
import Link from 'next/link';
import { Copy, ExternalLink, Link2, Lock } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Input, Modal } from '@/components/ui';
import { shopService } from '@/services/shop.service';
import { extractApiError } from '@/lib/utils';

export function dealHref(code: string) {
  return `/dashboard/shop/deals/${encodeURIComponent(code)}`;
}

export async function copyText(text: string, what = 'Copied') {
  try {
    await navigator.clipboard.writeText(text);
    toast.success(what);
  } catch {
    toast.error('Could not copy: select it and copy by hand');
  }
}

/**
 * The private deal code, with a copy button and a link to the deal page. Staff only: hidden when printing
 * (a printed order may go to the customer). With `kind` + `uuid` and `editable`, staff can move this quote
 * (and its revisions) or order (and its purchase orders) to another deal, or give it a new code.
 */
export function DealCodeBar({
  code,
  kind,
  uuid,
  editable = false,
  onChanged,
  className = '',
}: {
  code?: string | null;
  kind?: 'quote' | 'order';
  uuid?: string;
  editable?: boolean;
  onChanged?: (code: string) => void;
  className?: string;
}) {
  const [open, setOpen] = useState(false);
  const [value, setValue] = useState('');
  const [busy, setBusy] = useState<'link' | 'new' | null>(null);

  const link = async (body: { deal_code?: string; new?: boolean }) => {
    if (!kind || !uuid) return;
    setBusy(body.new ? 'new' : 'link');
    try {
      const res = await shopService.linkDealCode(kind, uuid, body);
      toast.success(res.moved ? `Now on deal ${res.deal_code}` : `Already on deal ${res.deal_code}`);
      setOpen(false);
      setValue('');
      onChanged?.(res.deal_code);
    } catch (err) {
      toast.error(extractApiError(err, 'Could not change the deal code'));
    } finally {
      setBusy(null);
    }
  };

  return (
    <div className={`print:hidden ${className}`}>
      <div className="flex flex-wrap items-center gap-2 rounded-lg border border-primary-100 bg-primary-50/60 px-3 py-2">
        <Lock className="h-3.5 w-3.5 shrink-0 text-primary-600" aria-hidden="true" />
        <span className="text-xs font-semibold uppercase tracking-wider text-secondary-500">Deal code</span>
        {code ? (
          <>
            <span className="font-mono text-sm font-semibold text-secondary-900" data-testid="deal-code">{code}</span>
            <button
              type="button"
              className="inline-flex items-center gap-1 rounded-md px-1.5 py-0.5 text-xs text-primary-700 hover:bg-primary-100"
              onClick={() => copyText(code, 'Deal code copied')}
              aria-label={`Copy deal code ${code}`}
            >
              <Copy className="h-3.5 w-3.5" aria-hidden="true" /> Copy
            </button>
            <Link href={dealHref(code)} className="inline-flex items-center gap-1 rounded-md px-1.5 py-0.5 text-xs text-primary-700 hover:bg-primary-100">
              <ExternalLink className="h-3.5 w-3.5" aria-hidden="true" /> Open deal
            </Link>
          </>
        ) : (
          <span className="text-sm text-secondary-500">Not set yet</span>
        )}
        {editable && kind && uuid && (
          <button
            type="button"
            className="ml-auto inline-flex items-center gap-1 rounded-md px-1.5 py-0.5 text-xs text-secondary-600 hover:bg-secondary-100"
            onClick={() => setOpen(true)}
          >
            <Link2 className="h-3.5 w-3.5" aria-hidden="true" /> Change
          </button>
        )}
      </div>
      <p className="mt-1 text-xs text-secondary-500">Private. Suppliers see this code; customers never do.</p>
      {open && (
        <Modal
          isOpen={open}
          onClose={() => setOpen(false)}
          title={kind === 'order' ? 'Move this order to another deal' : 'Move this quote to another deal'}
          description={
            kind === 'order'
              ? 'The order and its supplier purchase orders move to the deal you choose.'
              : 'The quote and all its revisions move to the deal you choose.'
          }
          footer={
            <>
              <Button variant="ghost" onClick={() => setOpen(false)}>Cancel</Button>
              <Button variant="outline" isLoading={busy === 'new'} disabled={!!busy} onClick={() => link({ new: true })}>New deal code</Button>
              <Button isLoading={busy === 'link'} disabled={!!busy || !value.trim()} onClick={() => link({ deal_code: value.trim() })}>Link</Button>
            </>
          }
        >
          <Input
            label="Deal code"
            id="deal-code-link"
            placeholder="The deal code, e.g. WS-…"
            value={value}
            autoFocus
            onChange={(e) => setValue(e.target.value)}
            helperText="The code of the deal this belongs to. Find it on the deal page or with search (Ctrl+K)."
          />
        </Modal>
      )}
    </div>
  );
}

export default DealCodeBar;

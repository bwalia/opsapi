'use client';

/**
 * The workspace's custom domain for form links (e.g. forms.acme.com/f/…).
 * The owner adds two DNS records: one pointing the domain at the platform's
 * edge, and a TXT record that proves they control it. The API checks DNS
 * (and keeps checking for a week), then form links switch to the domain.
 */

import React, { useEffect, useState } from 'react';
import toast from 'react-hot-toast';
import { Check, CheckCircle2, Clock, Copy, Globe } from 'lucide-react';
import { Badge, Button, Input, Modal } from '@/components/ui';
import { apiError } from '@/components/field-service/shared';
import { formsService, type FormDomain } from '@/services/forms.service';

function CopyValue({ value }: { value: string }) {
  const [done, setDone] = useState(false);
  return (
    <button type="button" aria-label={`Copy ${value}`}
      onClick={async () => { await navigator.clipboard.writeText(value); setDone(true); setTimeout(() => setDone(false), 1500); }}
      className="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-md text-secondary-500 hover:bg-secondary-100 hover:text-secondary-800">
      {done ? <Check className="h-4 w-4" /> : <Copy className="h-4 w-4" />}
    </button>
  );
}

export default function CustomDomainModal({ open, onClose, onChanged }: {
  open: boolean; onClose: () => void; onChanged?: (d: FormDomain) => void;
}) {
  const [d, setD] = useState<FormDomain | null>(null);
  const [input, setInput] = useState('');
  const [busy, setBusy] = useState<'' | 'save' | 'check' | 'remove'>('');
  const [confirmRemove, setConfirmRemove] = useState(false);

  useEffect(() => {
    if (!open) return;
    setConfirmRemove(false);
    setInput('');
    formsService.domain().then(setD).catch((e) => toast.error(apiError(e, 'Could not load the domain')));
  }, [open]);

  const run = async (kind: 'save' | 'check' | 'remove', fn: () => Promise<FormDomain>) => {
    setBusy(kind);
    try {
      const next = await fn();
      setD(next);
      setConfirmRemove(false);
      onChanged?.(next);
      if (kind === 'remove') toast.success('Domain removed');
      else if (next.status === 'active') toast.success(`${next.domain} is connected`);
    } catch (e) {
      toast.error(apiError(e, kind === 'save' ? 'Could not add the domain' : 'Something went wrong'));
    } finally {
      setBusy('');
    }
  };

  const active = d?.status === 'active';
  return (
    <Modal isOpen={open} onClose={onClose} title="Custom domain" size="lg"
      description="Share your forms on your own address, such as forms.yourcompany.com/f/…, instead of ours."
      footer={
        <div className="flex w-full flex-wrap items-center gap-2">
          {d?.domain && !confirmRemove && (
            <Button variant="ghost" className="text-error-600" onClick={() => setConfirmRemove(true)} disabled={!!busy}>
              Remove domain
            </Button>
          )}
          <div className="ml-auto flex gap-2">
            <Button variant="ghost" onClick={onClose}>Close</Button>
            {d?.available && !d.domain && (
              <Button onClick={() => run('save', () => formsService.saveDomain(input.trim()))} isLoading={busy === 'save'}
                disabled={!input.trim()}>Connect</Button>
            )}
            {d?.domain && (
              <Button variant={active ? 'outline' : 'primary'} onClick={() => run('check', formsService.checkDomain)}
                isLoading={busy === 'check'}>Check now</Button>
            )}
          </div>
        </div>
      }>
      {!d ? (
        <div className="h-32 animate-pulse rounded-lg bg-secondary-100" aria-busy="true" />
      ) : !d.available ? (
        <p className="rounded-lg bg-secondary-50 p-4 text-sm text-secondary-600">
          Custom domains aren&apos;t available on this platform yet. The platform administrator turns them on.
        </p>
      ) : !d.domain ? (
        <Input label="Domain" placeholder="forms.yourcompany.com" value={input} autoFocus
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter' && input.trim()) run('save', () => formsService.saveDomain(input.trim())); }}
          helperText="A subdomain you own works best, e.g. forms.yourcompany.com. Next you'll add two DNS records." />
      ) : (
        <div className="space-y-4">
          <div className="flex flex-wrap items-center gap-2">
            <Globe className="h-5 w-5 text-secondary-500" aria-hidden="true" />
            <span className="font-mono text-sm font-semibold text-secondary-900">{d.domain}</span>
            {active
              ? <Badge variant="success"><CheckCircle2 className="mr-1 h-3.5 w-3.5" aria-hidden="true" />Connected</Badge>
              : <Badge variant="warning"><Clock className="mr-1 h-3.5 w-3.5" aria-hidden="true" />Waiting for DNS</Badge>}
          </div>

          {active ? (
            <p className="rounded-lg bg-success-500/10 p-3 text-sm text-success-700">
              Form links now use <strong>https://{d.domain}/f/…</strong>. Links you shared before keep working.
            </p>
          ) : (
            <div className="space-y-1 text-sm text-secondary-600">
              <p>Add these records at your DNS provider. We check them for a week, so you can close this window.</p>
              {d.last_error && <p className="text-warning-700" role="status">{d.last_error}</p>}
            </div>
          )}

          <div className="divide-y divide-secondary-200 rounded-lg border border-secondary-200">
            {(d.records || []).map((r) => (
              <div key={r.type} className="grid gap-2 p-3 text-sm sm:grid-cols-[64px_1fr_1fr] sm:items-center">
                <span className="font-semibold text-secondary-700">{r.type}</span>
                <div className="flex min-w-0 items-center gap-1">
                  <span className="sm:hidden text-xs text-secondary-500">Name</span>
                  <code className="min-w-0 break-all font-mono text-xs text-secondary-800">{r.name}</code>
                  <CopyValue value={r.name} />
                </div>
                <div className="flex min-w-0 items-center gap-1">
                  <span className="sm:hidden text-xs text-secondary-500">Value</span>
                  <code className="min-w-0 break-all font-mono text-xs text-secondary-800">{r.value}</code>
                  <CopyValue value={r.value} />
                </div>
              </div>
            ))}
          </div>
          <ul className="list-disc space-y-1 pl-5 text-xs text-secondary-500">
            <li>The TXT record proves the domain is yours; keep it while the domain is connected.</li>
            <li>Using Cloudflare? Set the {d.records?.[0]?.type || 'CNAME'} record to <strong>DNS only</strong> (grey cloud).</li>
            <li>A root domain (yourcompany.com) can&apos;t have a CNAME: use your provider&apos;s ALIAS/ANAME record, or a subdomain.</li>
          </ul>

          {confirmRemove && (
            <div className="flex flex-wrap items-center gap-2 rounded-lg border border-error-200 bg-error-500/5 p-3 text-sm" role="alert">
              <span className="text-secondary-700">Links go back to this dashboard&apos;s address. Remove {d.domain}?</span>
              <div className="ml-auto flex gap-2">
                <Button size="sm" variant="ghost" onClick={() => setConfirmRemove(false)}>Keep it</Button>
                <Button size="sm" variant="danger" isLoading={busy === 'remove'}
                  onClick={() => run('remove', formsService.removeDomain)}>Remove</Button>
              </div>
            </div>
          )}
        </div>
      )}
    </Modal>
  );
}

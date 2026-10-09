'use client';

/**
 * Workspace-wide spam protection: the Cloudflare Turnstile keys every form of
 * the workspace can use (Forms → Settings → "I'm not a robot" check). The
 * secret is write-only: it's stored encrypted and never shown again.
 */

import React, { useEffect, useState } from 'react';
import toast from 'react-hot-toast';
import { ShieldCheck } from 'lucide-react';
import { Button, Input, Modal } from '@/components/ui';
import { apiError } from '@/components/field-service/shared';
import { formsService, type WorkspaceFormsSettings } from '@/services/forms.service';

export default function SpamProtectionModal({ open, onClose, onSaved }: {
  open: boolean; onClose: () => void; onSaved?: (s: WorkspaceFormsSettings) => void;
}) {
  const [current, setCurrent] = useState<WorkspaceFormsSettings | null>(null);
  const [siteKey, setSiteKey] = useState('');
  const [secret, setSecret] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!open) return;
    setSecret('');
    formsService.workspaceSettings().then((s) => { setCurrent(s); setSiteKey(s.turnstile.site_key || ''); })
      .catch((e) => toast.error(apiError(e, 'Could not load the settings')));
  }, [open]);

  const save = async (remove = false) => {
    setBusy(true);
    try {
      const s = await formsService.saveWorkspaceSettings({
        turnstile: remove ? { site_key: '', secret: '' } : { site_key: siteKey.trim(), ...(secret ? { secret: secret.trim() } : {}) },
      });
      setCurrent(s);
      setSecret('');
      onSaved?.(s);
      toast.success(remove ? 'Turnstile removed' : 'Saved');
      if (!remove) onClose();
    } catch (e) {
      toast.error(apiError(e, 'Could not save'));
    } finally {
      setBusy(false);
    }
  };

  const ready = !!current?.turnstile.site_key && current.turnstile.has_secret;
  return (
    <Modal isOpen={open} onClose={onClose} title="Spam protection" size="lg"
      description="Every form already blocks most bots (a hidden trap field, a minimum time and rate limits). Add Cloudflare Turnstile for an extra “I'm not a robot” check on the forms you choose."
      footer={
        <div className="flex w-full items-center gap-2">
          {ready && <Button variant="ghost" className="text-error-600" onClick={() => save(true)} disabled={busy}>Remove keys</Button>}
          <div className="ml-auto flex gap-2">
            <Button variant="ghost" onClick={onClose}>Cancel</Button>
            <Button onClick={() => save(false)} isLoading={busy} disabled={!siteKey.trim() || (!secret.trim() && !current?.turnstile.has_secret)}>
              Save
            </Button>
          </div>
        </div>
      }>
      <div className="space-y-4">
        <div className={`flex items-center gap-2 rounded-lg p-3 text-sm ${ready ? 'bg-success-500/10 text-success-600' : 'bg-secondary-50 text-secondary-600'}`}>
          <ShieldCheck className="h-4 w-4" aria-hidden="true" />
          {ready ? 'Turnstile is set up. Turn it on per form in its Settings tab.' : 'Not set up yet.'}
        </div>
        <ol className="list-decimal space-y-1 pl-5 text-sm text-secondary-600">
          <li>In the Cloudflare dashboard, open <strong>Turnstile → Add widget</strong> and add the domains your forms are on (this dashboard&apos;s, and your custom domain if you use one).</li>
          <li>Copy the <strong>site key</strong> and the <strong>secret key</strong> here.</li>
        </ol>
        <Input label="Site key" value={siteKey} onChange={(e) => setSiteKey(e.target.value)} placeholder="0x4AAAAAAA…" />
        <Input label="Secret key" type="password" autoComplete="off" value={secret} onChange={(e) => setSecret(e.target.value)}
          placeholder={current?.turnstile.has_secret ? 'Saved — leave empty to keep it' : '0x4AAAAAAA…'}
          helperText="Stored encrypted. It is never shown again." />
      </div>
    </Modal>
  );
}

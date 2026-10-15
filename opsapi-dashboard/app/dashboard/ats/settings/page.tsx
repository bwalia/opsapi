'use client';

/**
 * Hiring › Settings — /dashboard/ats/settings
 * Activation (payment), retention, ratings on/off (evidence only, e.g. for
 * NYC Local Law 144), decline reasons, extra notice text for candidates, and
 * integration tokens for the Snazzy Pro desktop app (shown once).
 */

import React, { Suspense, useCallback, useEffect, useState } from 'react';
import { useSearchParams } from 'next/navigation';
import toast from 'react-hot-toast';
import { Copy, KeyRound, Trash2 } from 'lucide-react';
import { Badge, Button, Card, ConfirmDialog, Input, Switch, Textarea } from '@/components/ui';
import { AtsShell } from '@/components/ats/AtsShell';
import { apiError } from '@/components/field-service/shared';
import { atsService, when, type AtsSettings, type IntegrationToken } from '@/services/ats.service';

function SettingsInner() {
  const params = useSearchParams();
  const [s, setS] = useState<AtsSettings | null>(null);
  const [reasons, setReasons] = useState('');
  const [tokens, setTokens] = useState<IntegrationToken[]>([]);
  const [tokenName, setTokenName] = useState('Snazzy Pro');
  const [newToken, setNewToken] = useState<string | null>(null);
  const [revoking, setRevoking] = useState<IntegrationToken | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => {
    atsService.settings().then((x) => { setS(x); setReasons(x.decline_reasons.join('\n')); })
      .catch((e) => toast.error(apiError(e, 'Could not load settings')));
    atsService.tokens().then(setTokens).catch(() => undefined);
  }, []);
  useEffect(load, [load]);
  useEffect(() => {
    if (params.get('activation') === 'success') toast.success('Thank you. Activation can take a minute to show.');
  }, [params]);

  const save = async () => {
    if (!s) return;
    setBusy(true);
    try {
      const x = await atsService.updateSettings({ retention_days: s.retention_days, ratings_enabled: s.ratings_enabled,
        legal_notice: s.legal_notice, decline_reasons: reasons.split('\n').map((r) => r.trim()).filter(Boolean) });
      setS({ ...x, activation: s.activation });
      toast.success('Saved');
    } catch (e) {
      toast.error(apiError(e, 'Could not save'));
    } finally {
      setBusy(false);
    }
  };

  const activate = async () => {
    try {
      const { checkout_url } = await atsService.checkout();
      window.location.href = checkout_url;
    } catch (e) {
      toast.error(apiError(e, 'Checkout is not available'));
    }
  };

  const createToken = async () => {
    try {
      const t = await atsService.createToken(tokenName);
      setNewToken(t.token ?? null);
      load();
    } catch (e) {
      toast.error(apiError(e, 'Could not create a token'));
    }
  };

  if (!s) return <AtsShell title="Hiring settings" module="ats_settings"><p className="text-secondary-500">Loading…</p></AtsShell>;
  const a = s.activation;

  return (
    <AtsShell title="Hiring settings" module="ats_settings" description="Activation, data, decisions and the Snazzy Pro app.">
      <Card>
        <h2 className="mb-2 flex items-center gap-2 font-semibold">
          Snazzy Interview {a?.active ? <Badge variant="success">Active</Badge> : <Badge variant="warning">Not active</Badge>}
        </h2>
        {a?.active ? (
          <p className="text-sm text-secondary-600">
            Active{a.source === 'manual' ? ' (set by an administrator)' : ''}{a.expires_at ? `, renews or ends ${when(a.expires_at)}` : ''}.
            {a.payment_failed_at && <span className="text-amber-800"> A payment failed on {when(a.payment_failed_at)}: please update your card in Stripe.</span>}
          </p>
        ) : (
          <div className="space-y-2 text-sm text-secondary-600">
            <p>Activate the module to invite candidates to AI interviews and receive interviews from Snazzy Pro. Without it you can still read, review and export everything here.</p>
            {a?.checkout_available ? <Button onClick={activate}>Activate</Button>
              : <p className="text-secondary-500">Online checkout isn&apos;t set up on this server. Ask your administrator to activate it.</p>}
          </div>
        )}
      </Card>

      <Card>
        <h2 className="mb-3 font-semibold">Data and decisions</h2>
        <div className="grid gap-4 sm:grid-cols-2">
          <Input label="Keep interviews for (days after a decision)" type="number" min={1} max={3650} value={String(s.retention_days)}
            onChange={(e) => setS({ ...s, retention_days: Number(e.target.value) || 1 })}
            helperText="Then they're deleted automatically, with the candidate if nothing else is left." />
          <label className="flex items-start gap-3 pt-6 text-sm">
            <Switch checked={s.ratings_enabled} onChange={(v) => setS({ ...s, ratings_enabled: v })} aria-label="AI suggested levels" />
            <span>AI suggests levels<br /><span className="text-secondary-500">Off: evidence only, no suggested levels (for example for jobs covered by NYC Local Law 144).</span></span>
          </label>
        </div>
        <Textarea className="mt-4" label="Decline reasons (one per line)" rows={5} value={reasons} onChange={(e) => setReasons(e.target.value)} />
        <Textarea className="mt-4" label="Extra notice for candidates" rows={4} value={s.legal_notice}
          onChange={(e) => setS({ ...s, legal_notice: e.target.value })}
          helperText="Added to the notice candidates read before they start (for example your privacy contact)." />
        <Button className="mt-4" onClick={save} isLoading={busy}>Save</Button>
      </Card>

      <Card>
        <h2 className="mb-1 flex items-center gap-2 font-semibold"><KeyRound className="h-4 w-4" /> Snazzy Pro app</h2>
        <p className="mb-3 text-sm text-secondary-600">
          Snazzy Pro on the Mac can run interviews itself and send them here. Create a token, then paste it into
          Snazzy Pro › Interviews › Connect to OpsAPI. Tokens only send interviews and read approved kits.
        </p>
        <div className="flex flex-col gap-2 sm:flex-row">
          <Input aria-label="Token name" value={tokenName} onChange={(e) => setTokenName(e.target.value)} />
          <Button onClick={createToken} disabled={!tokenName.trim()}>Create token</Button>
        </div>
        {newToken && (
          <div className="mt-3 rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm">
            <p className="font-semibold text-amber-900">Copy this token now. It won&apos;t be shown again.</p>
            <div className="mt-2 flex gap-2">
              <Input aria-label="New token" readOnly value={newToken} onFocus={(e) => e.currentTarget.select()} />
              <Button variant="outline" leftIcon={<Copy className="h-4 w-4" />}
                onClick={() => navigator.clipboard.writeText(newToken).then(() => toast.success('Copied'))}>Copy</Button>
            </div>
          </div>
        )}
        <ul className="mt-4 divide-y divide-secondary-100">
          {tokens.map((t) => (
            <li key={t.uuid} className="flex flex-wrap items-center justify-between gap-2 py-2 text-sm">
              <span><strong>{t.name}</strong> <code className="text-xs text-secondary-500">{t.token_prefix}…</code></span>
              <span className="flex items-center gap-3 text-xs text-secondary-500">
                {t.revoked_at ? <Badge variant="secondary">Revoked</Badge> : <>Last used {when(t.last_used_at)}
                  <Button size="sm" variant="ghost" aria-label={`Revoke ${t.name}`} onClick={() => setRevoking(t)}><Trash2 className="h-4 w-4" /></Button></>}
              </span>
            </li>
          ))}
        </ul>
      </Card>
      <ConfirmDialog isOpen={!!revoking} onClose={() => setRevoking(null)} title={`Revoke ${revoking?.name ?? ''}?`}
        message="Snazzy Pro apps using this token will stop sending interviews until they get a new one."
        confirmText="Revoke" onConfirm={async () => {
          if (!revoking) return;
          try { await atsService.revokeToken(revoking.uuid); load(); } catch (e) { toast.error(apiError(e, 'Could not revoke')); }
          setRevoking(null);
        }} />
    </AtsShell>
  );
}

export default function AtsSettingsPage() {
  return (
    <Suspense>
      <SettingsInner />
    </Suspense>
  );
}

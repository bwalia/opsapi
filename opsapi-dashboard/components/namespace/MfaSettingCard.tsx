'use client';

/**
 * Workspace setting: ask members for a sign-in code (MFA) after their password. On by default; only the owner
 * changes it (PUT /api/v2/namespace/security). Saves on its own, separate from the settings form's Save.
 */
import React, { useEffect, useState } from 'react';
import toast from 'react-hot-toast';
import { Loader2, ShieldCheck, ShieldOff } from 'lucide-react';
import { Card, ConfirmDialog } from '@/components/ui';
import Switch from '@/components/ui/Switch';
import { namespaceService } from '@/services';

export default function MfaSettingCard() {
  const [on, setOn] = useState<boolean | null>(null);
  const [canChange, setCanChange] = useState(false);
  const [saving, setSaving] = useState(false);
  const [confirmOff, setConfirmOff] = useState(false);

  useEffect(() => {
    namespaceService
      .getSecurity()
      .then((s) => {
        setOn(s.mfa_required);
        setCanChange(s.can_change);
      })
      .catch(() => setOn(true));
  }, []);

  const save = async (value: boolean) => {
    setSaving(true);
    try {
      const s = await namespaceService.setMfaRequired(value);
      setOn(s.mfa_required);
      toast.success(value ? 'Sign-in codes are on for this workspace' : 'Sign-in codes are off for this workspace');
    } catch (e) {
      const msg = (e as { response?: { data?: { error?: string; message?: string } } }).response?.data;
      toast.error(msg?.error || msg?.message || 'Could not change it. Try again.');
    } finally {
      setSaving(false);
      setConfirmOff(false);
    }
  };

  return (
    <Card className="p-6">
      <div className="flex items-start justify-between gap-4">
        <div className="flex items-start gap-3">
          <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-secondary-50">
            {on === false ? <ShieldOff className="h-5 w-5 text-warning-600" aria-hidden /> : <ShieldCheck className="h-5 w-5 text-success-600" aria-hidden />}
          </div>
          <div>
            <h2 id="mfa-title" className="text-base font-semibold text-secondary-900">Sign-in code (MFA)</h2>
            <p className="mt-1 text-sm text-secondary-600">
              When this is on, everyone in this workspace enters a 6-digit code from their email after their password.
              It stops someone who only has a password from getting in. On by default.
            </p>
            <p className="mt-2 text-sm font-medium text-secondary-800" role="status">
              {on === null ? 'Loading…' : on ? 'On: everyone gets a code when they sign in.' : 'Off: members sign in with their password only.'}
            </p>
            <ul className="mt-2 list-disc space-y-0.5 pl-5 text-xs text-secondary-500">
              <li>Someone who also belongs to another workspace that asks for a code still gets one.</li>
              <li>Platform administrators always get a code.</li>
              {!canChange && on !== null && <li>Only the workspace owner can change this.</li>}
            </ul>
          </div>
        </div>
        <div className="flex shrink-0 items-center gap-2 pt-1">
          {saving && <Loader2 className="h-4 w-4 animate-spin text-secondary-400" aria-hidden />}
          <Switch
            checked={on !== false}
            disabled={on === null || !canChange || saving}
            onChange={(v) => (v ? save(true) : setConfirmOff(true))}
            aria-label="Ask for a sign-in code (MFA)"
          />
        </div>
      </div>

      <ConfirmDialog
        isOpen={confirmOff}
        onClose={() => setConfirmOff(false)}
        onConfirm={() => save(false)}
        title="Turn off sign-in codes?"
        message="Members of this workspace will sign in with their password only, so anyone who learns a password can get in. Members who also belong to a workspace that asks for a code, and platform administrators, still get one."
        confirmText="Turn off"
        variant="danger"
        isLoading={saving}
      />
    </Card>
  );
}

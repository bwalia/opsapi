'use client';

/**
 * Shop → Suppliers: the supplier's own logins to the supplier portal. Nothing is emailed from here:
 * staff copy the set-password link and pass it on themselves.
 */
import React, { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import { KeyRound, Power, UserPlus } from 'lucide-react';
import toast from 'react-hot-toast';
import { Badge, Button, Input, confirmDialog } from '@/components/ui';
import { usePermissions } from '@/contexts/PermissionsContext';
import { CopyLink, fmtDateTime } from '@/components/supplier-portal/shared';
import {
  portalError,
  supplierPortalUsersService,
  type PortalUser,
  type PortalUsersResult,
} from '@/services/supplier-portal.service';

const STATUS: Record<PortalUser['status'], { label: string; variant: 'success' | 'warning' | 'secondary' }> = {
  active: { label: 'Active', variant: 'success' },
  invited: { label: 'Invited', variant: 'warning' },
  disabled: { label: 'Switched off', variant: 'secondary' },
};

const fullLink = (path: string) => (typeof window !== 'undefined' ? `${window.location.origin}${path}` : path);

export default function SupplierPortalLogins({ supplierUuid, supplierName }: { supplierUuid: string; supplierName: string }) {
  const { canUpdate } = usePermissions();
  const mayUpdate = canUpdate('shop');
  const [data, setData] = useState<PortalUsersResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [email, setEmail] = useState('');
  const [name, setName] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [issued, setIssued] = useState<{ url: string; message: string } | null>(null);

  const load = useCallback(async () => {
    try {
      setData(await supplierPortalUsersService.list(supplierUuid));
      setError(null);
    } catch (err) {
      const e = portalError(err, 'Could not load the portal logins');
      setError(e.code === 'NOT_AVAILABLE' ? 'The supplier portal isn’t set up in this deployment yet.' : e.message);
    }
  }, [supplierUuid]);

  useEffect(() => {
    setIssued(null);
    void load();
  }, [load]);

  const invite = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim())) return void toast.error('Enter the contact’s email address');
    setBusy('invite');
    try {
      const r = await supplierPortalUsersService.invite(supplierUuid, { email: email.trim(), name: name.trim() || undefined });
      setIssued(
        r.set_password_path
          ? { url: fullLink(r.set_password_path), message: `${r.message} The link works for ${r.expires_in_days} days.` }
          : { url: '', message: r.message }
      );
      setEmail('');
      setName('');
      toast.success('Login created');
      await load();
    } catch (err) {
      toast.error(portalError(err, 'Could not create the login').message);
    } finally {
      setBusy(null);
    }
  };

  const newLink = async (u: PortalUser) => {
    if (
      !(await confirmDialog({
        title: `New sign-in link for ${u.email}?`,
        message: 'Their previous link stops working. Nothing is emailed: copy the new link and pass it on.',
        confirmText: 'Create link',
      }))
    )
      return;
    setBusy(u.id);
    try {
      const r = await supplierPortalUsersService.newLink(supplierUuid, u.id);
      if (r.set_password_path) {
        setIssued({
          url: fullLink(r.set_password_path),
          message: `New sign-in link for ${u.email}. Nothing has been emailed: copy it and pass it on. It works for ${r.expires_in_days} days.`,
        });
      } else toast.error('The link could not be created');
    } catch (err) {
      toast.error(portalError(err, 'Could not create a new link').message);
    } finally {
      setBusy(null);
    }
  };

  const toggle = async (u: PortalUser) => {
    const off = u.status !== 'disabled';
    if (
      off &&
      !(await confirmDialog({
        title: `Switch off ${u.email}?`,
        message: 'They are signed out and can’t sign in to the supplier portal until you switch them back on.',
        confirmText: 'Switch off',
        danger: true,
      }))
    )
      return;
    setBusy(u.id);
    try {
      setData(off ? await supplierPortalUsersService.disable(supplierUuid, u.id) : await supplierPortalUsersService.enable(supplierUuid, u.id));
      toast.success(off ? 'Login switched off' : 'Login switched back on');
    } catch (err) {
      toast.error(portalError(err, 'Could not change the login').message);
    } finally {
      setBusy(null);
    }
  };

  if (error) return <p className="text-sm text-error-700">{error}</p>;
  if (!data) return <p className="text-sm text-secondary-500">Loading…</p>;

  return (
    <div className="space-y-4">
      <p className="text-sm text-secondary-600">
        People at {supplierName} who can sign in to see their purchase orders, upload proformas and invoices, enter dispatch and
        message you. They only ever see {supplierName}&rsquo;s purchase orders.
        {!data.portal.enabled && (
          <>
            {' '}
            <span className="font-medium text-amber-700">
              The supplier portal is off, so they will see &ldquo;not available yet&rdquo; until you switch it on in{' '}
              <Link href="/dashboard/shop/settings" className="underline">
                Shop → Settings
              </Link>
              .
            </span>
          </>
        )}
      </p>

      {issued && (issued.url ? <CopyLink url={issued.url} message={issued.message} /> : <p className="text-sm text-secondary-700">{issued.message}</p>)}

      {data.users.length === 0 ? (
        <p className="text-sm text-secondary-500">No portal logins yet.</p>
      ) : (
        <ul className="divide-y divide-secondary-100 rounded-lg border border-secondary-200 text-sm">
          {data.users.map((u) => (
            <li key={u.id} className="flex flex-wrap items-center justify-between gap-2 px-3 py-2.5">
              <div className="min-w-0">
                <p className="flex flex-wrap items-center gap-2 font-medium text-secondary-900">
                  {u.name || u.email}
                  <Badge variant={STATUS[u.status]?.variant ?? 'secondary'}>{STATUS[u.status]?.label ?? u.status}</Badge>
                </p>
                <p className="text-xs text-secondary-500">
                  {u.name ? `${u.email} · ` : ''}
                  {u.last_seen_at ? `Last seen ${fmtDateTime(u.last_seen_at)}` : u.status === 'invited' ? 'Hasn’t signed in yet' : 'Not seen yet'}
                </p>
              </div>
              {mayUpdate && (
                <div className="flex flex-wrap gap-2">
                  {u.status !== 'disabled' && (
                    <Button size="sm" variant="ghost" leftIcon={<KeyRound className="h-3.5 w-3.5" />} disabled={!!busy} isLoading={busy === u.id} onClick={() => newLink(u)}>
                      New sign-in link
                    </Button>
                  )}
                  <Button size="sm" variant="ghost" leftIcon={<Power className="h-3.5 w-3.5" />} disabled={!!busy} onClick={() => toggle(u)}>
                    {u.status === 'disabled' ? 'Enable' : 'Disable'}
                  </Button>
                </div>
              )}
            </li>
          ))}
        </ul>
      )}

      {mayUpdate && (
        <form onSubmit={invite} className="space-y-3 rounded-lg border border-secondary-200 p-4">
          <p className="text-sm font-semibold text-secondary-800">Invite a contact</p>
          <div className="grid gap-3 sm:grid-cols-2">
            <Input label="Email" id={`spu-email-${supplierUuid}`} type="email" value={email} onChange={(e) => setEmail(e.target.value)} />
            <Input label="Name" id={`spu-name-${supplierUuid}`} value={name} onChange={(e) => setName(e.target.value)} />
          </div>
          <p className="text-xs text-secondary-500">
            Use an address that isn&rsquo;t already a login here (for a test, e.g. yourname+supplier@yourdomain). Nothing is emailed:
            you get a sign-in link to copy and pass on.
          </p>
          <div className="flex justify-end">
            <Button type="submit" size="sm" leftIcon={<UserPlus className="h-4 w-4" />} isLoading={busy === 'invite'} disabled={!!busy}>
              Invite
            </Button>
          </div>
        </form>
      )}
    </div>
  );
}

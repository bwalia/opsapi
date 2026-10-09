'use client';

/**
 * Workspace invitation — /invite/[token] (the link in the invitation email).
 *
 * New to the platform: choose a name and password; the account is created and
 * joins the workspace. Already have an account: sign in, then accept (the
 * accept call needs your login, and your email must match the invitation).
 */

import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import { useParams, useRouter } from 'next/navigation';
import { CheckCircle2, Loader2, Mail } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Input } from '@/components/ui';
import { useAuthStore } from '@/store/auth.store';
import apiClient from '@/lib/api-client';
import { formsPublic, PublicFormError, type PublicInvitation } from '@/services/forms-public.service';

export default function InvitePage() {
  const params = useParams();
  const router = useRouter();
  const token = params?.token as string;
  const isAuthenticated = useAuthStore((s) => s.isAuthenticated);
  const [invite, setInvite] = useState<PublicInvitation | null>(null);
  const [failed, setFailed] = useState('');
  const [first, setFirst] = useState('');
  const [last, setLast] = useState('');
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState('');

  useEffect(() => {
    if (!token) return;
    formsPublic.invitation(token).then(setInvite).catch((e: PublicFormError) => setFailed(e.message));
  }, [token]);

  const create = async (e: React.FormEvent) => {
    e.preventDefault();
    const errs: Record<string, string> = {};
    if (!first.trim()) errs.first_name = 'Enter your first name.';
    if (password.length < 12) errs.password = 'Use at least 12 characters, with upper and lower case letters and a number.';
    if (password !== confirm) errs.confirm = "The passwords don't match.";
    setErrors(errs);
    if (Object.keys(errs).length) return;
    setBusy(true);
    try {
      const res = await formsPublic.acceptInvitation(token, { first_name: first.trim(), last_name: last.trim(), password });
      setDone(res.message);
    } catch (err) {
      const e2 = err as PublicFormError;
      if (e2.errors) setErrors(e2.errors);
      else toast.error(e2.message);
    } finally {
      setBusy(false);
    }
  };

  // Signed in already: accept with the account (POST /api/v2/invitations/:token/accept).
  const acceptSignedIn = async () => {
    setBusy(true);
    try {
      await apiClient.post(`/api/v2/invitations/${encodeURIComponent(token)}/accept`);
      toast.success(`You've joined ${invite?.workspace.name}.`);
      router.push('/dashboard');
    } catch (err) {
      const msg = (err as { response?: { data?: { error?: string; message?: string } } })?.response?.data;
      toast.error(msg?.error || msg?.message || "Couldn't accept the invitation.");
    } finally {
      setBusy(false);
    }
  };

  return (
    <main id="main-content" className="min-h-dvh bg-secondary-50 px-4 py-10 sm:py-16">
      <div className="mx-auto w-full max-w-md rounded-2xl border border-secondary-200 bg-surface p-6 shadow-sm sm:p-8">
        {!invite && !failed && (
          <div className="grid min-h-40 place-items-center" aria-busy="true">
            <Loader2 className="h-6 w-6 animate-spin text-secondary-400" />
          </div>
        )}
        {failed && <p className="text-center text-secondary-600">{failed}</p>}

        {invite && done && (
          <div className="text-center" aria-live="polite">
            <CheckCircle2 className="mx-auto h-10 w-10 text-success-500" aria-hidden="true" />
            <p className="mt-4 text-secondary-800">{done}</p>
            <Link href="/login" className="mt-6 inline-flex h-11 items-center rounded-lg bg-primary-500 px-5 font-semibold text-white hover:bg-primary-600">
              Sign in
            </Link>
          </div>
        )}

        {invite && !done && (
          <>
            <div className="text-center">
              <Mail className="mx-auto h-9 w-9 text-primary-500" aria-hidden="true" />
              <h1 className="mt-3 text-xl font-bold text-secondary-900">Join {invite.workspace.name}</h1>
              <p className="mt-2 text-sm text-secondary-600">
                {invite.invited_by ? `${invite.invited_by} invited ` : 'You have been invited as '}
                <strong>{invite.email}</strong>
                {invite.role ? ` as ${invite.role}` : ''}.
              </p>
              {invite.message && <p className="mt-3 text-sm italic text-secondary-500">“{invite.message}”</p>}
            </div>

            {invite.account_exists ? (
              <div className="mt-6 space-y-3 text-center">
                {isAuthenticated ? (
                  <Button className="w-full" size="lg" isLoading={busy} onClick={acceptSignedIn}>Accept invitation</Button>
                ) : (
                  <>
                    <p className="text-sm text-secondary-600">
                      You already have an account. Sign in as {invite.email}, then open this link again to accept.
                    </p>
                    <Link href="/login"
                      className="inline-flex h-11 w-full items-center justify-center rounded-lg bg-primary-500 font-semibold text-white hover:bg-primary-600">
                      Sign in
                    </Link>
                  </>
                )}
              </div>
            ) : (
              <form onSubmit={create} noValidate className="mt-6 space-y-4">
                <div className="grid grid-cols-2 gap-3">
                  <Input label="First name" autoComplete="given-name" value={first} onChange={(e) => setFirst(e.target.value)}
                    error={errors.first_name} />
                  <Input label="Last name" autoComplete="family-name" value={last} onChange={(e) => setLast(e.target.value)}
                    error={errors.last_name} />
                </div>
                <Input label="Email" value={invite.email} disabled readOnly />
                <Input label="Password" type="password" autoComplete="new-password" value={password}
                  onChange={(e) => setPassword(e.target.value)} error={errors.password}
                  helperText="At least 12 characters, with upper and lower case letters and a number." />
                <Input label="Confirm password" type="password" autoComplete="new-password" value={confirm}
                  onChange={(e) => setConfirm(e.target.value)} error={errors.confirm} />
                <Button type="submit" className="w-full" size="lg" isLoading={busy}>Create account and join</Button>
              </form>
            )}
          </>
        )}
      </div>
    </main>
  );
}

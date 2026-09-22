'use client';

/**
 * Reset password — /reset-password?token=…
 *
 * Consumes the token from the email link and sets a new password
 * (POST /auth/reset-password). On success the backend revokes every session,
 * so we send the user to /login to sign in fresh.
 */

import React, { Suspense, useState } from 'react';
import Link from 'next/link';
import { useRouter, useSearchParams } from 'next/navigation';
import { Lock, Eye, EyeOff, ArrowLeft } from 'lucide-react';
import { Button, Input } from '@/components/ui';
import AuthShell, { AuthLoader } from '@/components/auth/AuthShell';
import { authService, authErrorMessage } from '@/services/auth.service';
import toast from 'react-hot-toast';

function ResetPasswordPanel() {
  const router = useRouter();
  const token = useSearchParams().get('token') || '';
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [show, setShow] = useState(false);
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (password.length < 8) {
      toast.error('Password must be at least 8 characters');
      return;
    }
    if (password !== confirm) {
      toast.error('Passwords do not match');
      return;
    }
    setLoading(true);
    try {
      await authService.resetPassword(token, password);
      toast.success('Password reset. Please sign in with your new password.');
      router.push('/login');
    } catch (err) {
      toast.error(authErrorMessage(err, 'Could not reset your password — the link may have expired.'));
    } finally {
      setLoading(false);
    }
  };

  if (!token) {
    return (
      <div className="w-full max-w-sm">
        <div className="rounded-xl border border-error-200 bg-error-50 p-4">
          <p className="font-semibold text-error-700">Invalid reset link</p>
          <p className="text-sm text-error-600 mt-1">
            This link is missing its token or is malformed. Please request a new one.
          </p>
        </div>
        <Link
          href="/forgot-password"
          className="mt-6 inline-flex items-center gap-1.5 text-sm font-medium text-primary-600 hover:text-primary-700"
        >
          <ArrowLeft className="w-4 h-4" /> Request a new link
        </Link>
      </div>
    );
  }

  const toggle = (
    <button
      type="button"
      onClick={() => setShow((s) => !s)}
      className="cursor-pointer transition-colors hover:text-secondary-600 focus:outline-none"
      aria-label={show ? 'Hide password' : 'Show password'}
    >
      {show ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
    </button>
  );

  return (
    <div className="w-full max-w-sm">
      <div className="mb-8">
        <h1 className="text-2xl font-bold text-secondary-900">Set a new password</h1>
        <p className="mt-1.5 text-sm text-secondary-500">Choose a new password for your account.</p>
      </div>

      <form onSubmit={handleSubmit} className="space-y-4" data-testid="reset-password-form">
        <Input
          label="New password"
          name="new_password"
          type={show ? 'text' : 'password'}
          placeholder="At least 8 characters"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          leftIcon={<Lock className="h-4 w-4" />}
          rightIcon={toggle}
          autoComplete="new-password"
          autoFocus
          data-testid="reset-password-input"
        />
        <Input
          label="Confirm new password"
          name="confirm_password"
          type={show ? 'text' : 'password'}
          placeholder="Re-enter your new password"
          value={confirm}
          onChange={(e) => setConfirm(e.target.value)}
          leftIcon={<Lock className="h-4 w-4" />}
          autoComplete="new-password"
          data-testid="reset-password-confirm-input"
        />
        <Button
          type="submit"
          className="w-full"
          size="lg"
          isLoading={loading}
          data-testid="reset-password-submit-button"
        >
          Reset password
        </Button>
      </form>

      <Link
        href="/login"
        className="mt-6 inline-flex items-center gap-1.5 text-sm font-medium text-primary-600 hover:text-primary-700"
      >
        <ArrowLeft className="w-4 h-4" /> Back to sign in
      </Link>
    </div>
  );
}

export default function ResetPasswordPage() {
  // useSearchParams requires a Suspense boundary in the App Router.
  return (
    <AuthShell>
      <Suspense fallback={<AuthLoader />}>
        <ResetPasswordPanel />
      </Suspense>
    </AuthShell>
  );
}

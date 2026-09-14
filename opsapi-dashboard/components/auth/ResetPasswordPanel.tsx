'use client';

import React, { useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { Eye, EyeOff, Lock, ArrowLeft } from 'lucide-react';
import { Button, Input } from '@/components/ui';
import { authService, authErrorMessage } from '@/services/auth.service';
import toast from 'react-hot-toast';

/**
 * Sets a new password from a reset link. `token` is the value from
 * /reset-password?token=... . On success the backend has already revoked every
 * session, so we just send the user to sign in with the new password.
 */
export default function ResetPasswordPanel({ token }: { token: string | null }) {
  const router = useRouter();
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [show, setShow] = useState(false);
  const [isLoading, setIsLoading] = useState(false);

  // No token in the URL — the link was malformed or manually visited.
  if (!token) {
    return (
      <div className="w-full max-w-sm">
        <h1 className="text-2xl font-bold text-secondary-900">Invalid reset link</h1>
        <p className="mt-2 text-sm leading-relaxed text-secondary-500">
          This password reset link is missing or malformed. Reset links also expire after 30 minutes.
        </p>
        <Link href="/forgot-password" className="mt-6 inline-block">
          <Button size="lg">Request a new link</Button>
        </Link>
        <Link
          href="/login"
          className="mt-6 flex items-center gap-1.5 text-sm font-medium text-secondary-600 hover:text-secondary-900"
        >
          <ArrowLeft className="h-4 w-4" />
          Back to sign in
        </Link>
      </div>
    );
  }

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
    setIsLoading(true);
    try {
      await authService.resetPassword(token, password);
      toast.success('Password reset. Please sign in with your new password.');
      router.replace('/login');
    } catch (err) {
      toast.error(authErrorMessage(err, 'This reset link is invalid or has expired. Request a new one.'));
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <div className="w-full max-w-sm">
      <div className="mb-8">
        <h1 className="text-2xl font-bold text-secondary-900">Set a new password</h1>
        <p className="mt-1.5 text-sm text-secondary-500">Choose a strong password you don&apos;t use elsewhere.</p>
      </div>

      <form onSubmit={handleSubmit} className="space-y-4" data-testid="reset-form">
        <Input
          label="New password"
          name="new_password"
          type={show ? 'text' : 'password'}
          placeholder="At least 8 characters"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          leftIcon={<Lock className="h-4 w-4" />}
          rightIcon={
            <button
              type="button"
              onClick={() => setShow((s) => !s)}
              className="cursor-pointer transition-colors hover:text-secondary-600 focus:outline-none"
              aria-label={show ? 'Hide password' : 'Show password'}
            >
              {show ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
            </button>
          }
          autoComplete="new-password"
          helperText="Must be at least 8 characters"
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
          data-testid="reset-confirm-input"
        />

        <Button type="submit" className="w-full" size="lg" isLoading={isLoading} data-testid="reset-submit-button">
          Reset password
        </Button>
      </form>

      <Link
        href="/login"
        className="mt-6 inline-flex items-center gap-1.5 text-sm font-medium text-secondary-600 hover:text-secondary-900"
      >
        <ArrowLeft className="h-4 w-4" />
        Back to sign in
      </Link>
    </div>
  );
}

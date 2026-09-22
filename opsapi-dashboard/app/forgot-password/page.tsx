'use client';

/**
 * Forgot password — /forgot-password
 *
 * Enter an email; the backend (POST /auth/forgot-password, anti-enumeration) always
 * returns success and, if the account exists, emails a link to /reset-password?token=…
 */

import React, { useState } from 'react';
import Link from 'next/link';
import { Mail, ArrowLeft, CheckCircle2 } from 'lucide-react';
import { Button, Input } from '@/components/ui';
import AuthShell from '@/components/auth/AuthShell';
import { authService, authErrorMessage } from '@/services/auth.service';
import { useBrand } from '@/components/brand/Logo';
import toast from 'react-hot-toast';

function ForgotPasswordPanel() {
  const brand = useBrand();
  const [email, setEmail] = useState('');
  const [loading, setLoading] = useState(false);
  const [sent, setSent] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!email.trim()) {
      toast.error('Enter your email');
      return;
    }
    setLoading(true);
    try {
      await authService.forgotPassword(email.trim());
      // Anti-enumeration: the API returns the same response whether or not the
      // account exists, so we always show the "check your email" confirmation.
      setSent(true);
    } catch (err) {
      toast.error(authErrorMessage(err, 'Could not send the reset email. Please try again.'));
    } finally {
      setLoading(false);
    }
  };

  const backToSignIn = (
    <Link
      href="/login"
      className="mt-6 inline-flex items-center gap-1.5 text-sm font-medium text-primary-600 hover:text-primary-700"
    >
      <ArrowLeft className="w-4 h-4" /> Back to sign in
    </Link>
  );

  if (sent) {
    return (
      <div className="w-full max-w-sm">
        <div className="rounded-xl border border-emerald-200 bg-emerald-50 p-4 flex items-start gap-3">
          <CheckCircle2 className="w-5 h-5 text-emerald-600 mt-0.5 shrink-0" />
          <div>
            <p className="font-semibold text-emerald-900">Check your email</p>
            <p className="text-sm text-emerald-800 mt-1">
              If an account exists for <strong>{email.trim()}</strong>, we&apos;ve sent a link to reset your
              password. The link expires in 30 minutes.
            </p>
          </div>
        </div>
        {backToSignIn}
      </div>
    );
  }

  return (
    <div className="w-full max-w-sm">
      <div className="mb-8">
        <h1 className="text-2xl font-bold text-secondary-900">Forgot your password?</h1>
        <p className="mt-1.5 text-sm text-secondary-500">
          Enter the email for your {brand.name} account and we&apos;ll send you a link to reset it.
        </p>
      </div>

      <form onSubmit={handleSubmit} className="space-y-4" data-testid="forgot-password-form">
        <Input
          label="Email"
          name="email"
          type="email"
          placeholder="you@company.com"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          leftIcon={<Mail className="h-4 w-4" />}
          autoComplete="email"
          autoFocus
          data-testid="forgot-password-email-input"
        />
        <Button
          type="submit"
          className="w-full"
          size="lg"
          isLoading={loading}
          data-testid="forgot-password-submit-button"
        >
          Send reset link
        </Button>
      </form>

      {backToSignIn}
    </div>
  );
}

export default function ForgotPasswordPage() {
  return (
    <AuthShell>
      <ForgotPasswordPanel />
    </AuthShell>
  );
}

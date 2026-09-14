'use client';

import React, { useState } from 'react';
import Link from 'next/link';
import { Mail, ArrowLeft, CheckCircle2 } from 'lucide-react';
import { Button, Input } from '@/components/ui';
import { authService, authErrorMessage } from '@/services/auth.service';
import { useBrand } from '@/components/brand/Logo';
import toast from 'react-hot-toast';

/**
 * "Forgot your password?" — collects an email and asks the backend to send a
 * reset link. The backend is anti-enumeration (same response whether or not the
 * email exists), so on success we always show the same generic confirmation.
 */
export default function ForgotPasswordPanel() {
  const brand = useBrand();
  const [email, setEmail] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const [sent, setSent] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!email.trim()) {
      toast.error('Please enter your email address');
      return;
    }
    setIsLoading(true);
    try {
      await authService.forgotPassword(email.trim());
      setSent(true);
    } catch (err) {
      toast.error(authErrorMessage(err, 'Could not send the reset link. Please try again.'));
    } finally {
      setIsLoading(false);
    }
  };

  if (sent) {
    return (
      <div className="w-full max-w-sm">
        <div className="mb-6 flex h-12 w-12 items-center justify-center rounded-xl bg-success-50">
          <CheckCircle2 className="h-6 w-6 text-success-600" />
        </div>
        <h1 className="text-2xl font-bold text-secondary-900">Check your email</h1>
        <p className="mt-2 text-sm leading-relaxed text-secondary-500">
          If an account exists for <span className="font-medium text-secondary-700">{email}</span>,
          we&apos;ve sent a link to reset your password. It expires in 30 minutes.
        </p>
        <p className="mt-4 text-sm text-secondary-500">
          Didn&apos;t get it? Check your spam folder, or{' '}
          <button
            type="button"
            onClick={() => setSent(false)}
            className="font-medium text-primary-500 hover:text-primary-600"
          >
            try another email
          </button>
          .
        </p>
        <Link
          href="/login"
          className="mt-8 inline-flex items-center gap-1.5 text-sm font-medium text-secondary-600 hover:text-secondary-900"
        >
          <ArrowLeft className="h-4 w-4" />
          Back to sign in
        </Link>
      </div>
    );
  }

  return (
    <div className="w-full max-w-sm">
      <div className="mb-8">
        <h1 className="text-2xl font-bold text-secondary-900">Forgot your password?</h1>
        <p className="mt-1.5 text-sm text-secondary-500">
          Enter the email for your {brand.name} account and we&apos;ll send you a reset link.
        </p>
      </div>

      <form onSubmit={handleSubmit} className="space-y-4" data-testid="forgot-form">
        <Input
          label="Email address"
          name="email"
          type="email"
          placeholder="you@company.com"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          leftIcon={<Mail className="h-4 w-4" />}
          autoComplete="email"
          data-testid="forgot-email-input"
        />

        <Button type="submit" className="w-full" size="lg" isLoading={isLoading} data-testid="forgot-submit-button">
          Send reset link
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

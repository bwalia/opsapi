'use client';

import React, { useState, useRef, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { ShieldCheck, AlertCircle, ArrowLeft, RotateCw } from 'lucide-react';
import { Button } from '@/components/ui';
import { useAuthStore } from '@/store/auth.store';
import { authService } from '@/services/auth.service';
import { AUTH_TOKEN_KEY } from '@/lib/api-client';
import toast from 'react-hot-toast';

const OTP_LENGTH = 6;
const RESEND_COOLDOWN = 60;

function maskEmail(email: string): string {
  if (!email) return '';
  return email.replace(/^(.{2})(.*)(@.+)$/, (_, a, b, c) => a + '*'.repeat(Math.min(b.length, 6)) + c);
}

/**
 * The right-hand 2FA panel: a 6-digit OTP with paste + arrow-key navigation,
 * auto-submit on completion, resend with cooldown, and session-expiry recovery.
 * Session (token + email) is provided by the page; on success the app JWT is
 * adopted and we land on /dashboard.
 */
export default function OtpPanel({ sessionToken, email }: { sessionToken: string; email: string }) {
  const router = useRouter();
  const { setUser, setToken } = useAuthStore();

  const [digits, setDigits] = useState<string[]>(Array(OTP_LENGTH).fill(''));
  const [error, setError] = useState<string | null>(null);
  const [verifying, setVerifying] = useState(false);
  const [resending, setResending] = useState(false);
  const [resendCooldown, setResendCooldown] = useState(RESEND_COOLDOWN);
  const [resendMessage, setResendMessage] = useState<string | null>(null);
  const inputRefs = useRef<(HTMLInputElement | null)[]>([]);

  useEffect(() => {
    if (resendCooldown <= 0) return;
    const t = setInterval(() => setResendCooldown((p) => Math.max(0, p - 1)), 1000);
    return () => clearInterval(t);
  }, [resendCooldown]);

  useEffect(() => {
    inputRefs.current[0]?.focus();
  }, []);

  const cleanupSession = useCallback(() => {
    sessionStorage.removeItem('2fa_session_token');
    sessionStorage.removeItem('2fa_email');
  }, []);

  const submitCode = useCallback(
    async (code: string) => {
      setError(null);
      setVerifying(true);
      try {
        const response = await authService.verify2fa({ session_token: sessionToken, code });
        const token = response.token;
        if (!token) throw new Error('No token received after verification');
        cleanupSession();
        if (typeof window !== 'undefined') localStorage.setItem(AUTH_TOKEN_KEY, token);
        setToken(token);
        if (response.user) setUser(response.user);
        toast.success('Verification successful');
        router.push('/dashboard');
      } catch (err: unknown) {
        const e = err as Error & { response?: { data?: { error?: string } } };
        const message = e.response?.data?.error || e.message || 'Verification failed. Please try again.';
        if (message.includes('expired') || message.includes('login again')) {
          cleanupSession();
          setError('Session expired. Redirecting to sign in…');
          setTimeout(() => router.replace('/login'), 2000);
          return;
        }
        setError(message);
        setVerifying(false);
        setDigits(Array(OTP_LENGTH).fill(''));
        setTimeout(() => inputRefs.current[0]?.focus(), 50);
      }
    },
    [sessionToken, cleanupSession, setToken, setUser, router]
  );

  const handleChange = (index: number, value: string) => {
    const digit = value.replace(/\D/g, '').slice(-1);
    const next = [...digits];
    next[index] = digit;
    setDigits(next);
    setError(null);
    if (digit && index < OTP_LENGTH - 1) inputRefs.current[index + 1]?.focus();
    if (digit && index === OTP_LENGTH - 1) {
      const code = next.join('');
      if (code.length === OTP_LENGTH) submitCode(code);
    }
  };

  const handleKeyDown = (index: number, e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Backspace' && !digits[index] && index > 0) inputRefs.current[index - 1]?.focus();
    if (e.key === 'ArrowLeft' && index > 0) inputRefs.current[index - 1]?.focus();
    if (e.key === 'ArrowRight' && index < OTP_LENGTH - 1) inputRefs.current[index + 1]?.focus();
    if (e.key === 'Enter') {
      const code = digits.join('');
      if (code.length === OTP_LENGTH) submitCode(code);
    }
  };

  const handlePaste = (e: React.ClipboardEvent) => {
    e.preventDefault();
    const pasted = e.clipboardData.getData('text').replace(/\D/g, '').slice(0, OTP_LENGTH);
    if (!pasted) return;
    const next = Array(OTP_LENGTH).fill('');
    for (let i = 0; i < pasted.length; i++) next[i] = pasted[i];
    setDigits(next);
    setError(null);
    if (pasted.length === OTP_LENGTH) submitCode(pasted);
    else inputRefs.current[Math.min(pasted.length, OTP_LENGTH - 1)]?.focus();
  };

  const handleResend = async () => {
    if (resendCooldown > 0 || resending) return;
    setResending(true);
    setResendMessage(null);
    setError(null);
    try {
      await authService.resend2fa({ session_token: sessionToken });
      setResendMessage('A new code has been sent to your email.');
      setResendCooldown(RESEND_COOLDOWN);
      setDigits(Array(OTP_LENGTH).fill(''));
      inputRefs.current[0]?.focus();
    } catch (err: unknown) {
      const e = err as Error & { response?: { data?: { error?: string } } };
      const message = e.response?.data?.error || e.message || 'Failed to resend code.';
      if (message.includes('expired') || message.includes('login again')) {
        cleanupSession();
        setError('Session expired. Redirecting to sign in…');
        setTimeout(() => router.replace('/login'), 2000);
        return;
      }
      setError(message);
    } finally {
      setResending(false);
    }
  };

  const code = digits.join('');

  return (
    <div className="w-full">
      <div className="mb-8">
        <span className="mb-5 inline-flex h-12 w-12 items-center justify-center rounded-xl bg-primary-500/10 text-primary-500">
          <ShieldCheck className="h-6 w-6" />
        </span>
        <h1 className="text-2xl font-bold text-secondary-900">Two-factor authentication</h1>
        <p className="mt-1.5 text-sm text-secondary-500">
          Enter the 6-digit code sent to <span className="font-medium text-secondary-700">{maskEmail(email)}</span>
        </p>
      </div>

      {error && (
        <div role="alert" className="mb-5 flex items-center gap-3 rounded-lg border border-error-200 bg-error-50 p-3">
          <AlertCircle className="h-5 w-5 shrink-0 text-error-600" />
          <p className="text-sm text-error-600">{error}</p>
        </div>
      )}
      {resendMessage && (
        <div className="mb-5 rounded-lg border border-success-200 bg-success-50 p-3">
          <p className="text-sm text-success-600">{resendMessage}</p>
        </div>
      )}

      {/* OTP inputs — equal-width, responsive within the panel */}
      <div className="mb-7 flex gap-2 sm:gap-2.5" onPaste={handlePaste}>
        {digits.map((digit, idx) => (
          <input
            key={idx}
            ref={(el) => {
              inputRefs.current[idx] = el;
            }}
            type="text"
            inputMode="numeric"
            autoComplete="one-time-code"
            maxLength={1}
            value={digit}
            onChange={(e) => handleChange(idx, e.target.value)}
            onKeyDown={(e) => handleKeyDown(idx, e)}
            disabled={verifying}
            aria-label={`Digit ${idx + 1}`}
            className={`h-14 min-w-0 flex-1 rounded-xl border-2 text-center text-2xl font-bold outline-none transition-all ${
              verifying ? 'cursor-not-allowed bg-secondary-100 text-secondary-400' : 'bg-white'
            } ${
              error
                ? 'border-error-300 focus:border-error-500 focus:ring-2 focus:ring-error-200'
                : 'border-secondary-200 focus:border-primary-500 focus:ring-2 focus:ring-primary-200'
            }`}
          />
        ))}
      </div>

      <Button
        onClick={() => code.length === OTP_LENGTH && submitCode(code)}
        disabled={verifying || code.length < OTP_LENGTH}
        className="w-full"
        size="lg"
        isLoading={verifying}
      >
        {!verifying && <ShieldCheck className="mr-2 h-5 w-5" />}
        Verify code
      </Button>

      <div className="mt-6 text-center">
        <button
          type="button"
          onClick={handleResend}
          disabled={resendCooldown > 0 || resending}
          className={`inline-flex items-center gap-2 text-sm font-medium transition-colors ${
            resendCooldown > 0 || resending ? 'cursor-not-allowed text-secondary-400' : 'text-primary-500 hover:text-primary-600'
          }`}
        >
          <RotateCw className={`h-4 w-4 ${resending ? 'animate-spin' : ''}`} />
          {resendCooldown > 0 ? `Resend code in ${resendCooldown}s` : resending ? 'Sending…' : "Didn't get it? Resend"}
        </button>
      </div>

      <div className="mt-8 border-t border-secondary-100 pt-5 text-center">
        <button
          type="button"
          onClick={() => {
            cleanupSession();
            router.push('/login');
          }}
          className="inline-flex items-center gap-2 text-sm font-medium text-secondary-500 transition-colors hover:text-secondary-700"
        >
          <ArrowLeft className="h-4 w-4" />
          Back to sign in
        </button>
        <p className="mt-4 text-xs text-secondary-400">This code expires in 5 minutes. Never share it with anyone.</p>
      </div>
    </div>
  );
}

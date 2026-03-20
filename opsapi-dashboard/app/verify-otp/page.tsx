'use client';

import React, { useState, useRef, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { ShieldCheck, AlertCircle, Loader2, ArrowLeft, RotateCw } from 'lucide-react';
import { Card, Button } from '@/components/ui';
import { useAuthStore } from '@/store/auth.store';
import { authService } from '@/services/auth.service';
import { AUTH_TOKEN_KEY } from '@/lib/api-client';
import toast from 'react-hot-toast';

const OTP_LENGTH = 6;
const RESEND_COOLDOWN = 60;

export default function VerifyOtpPage() {
  const router = useRouter();
  const { setUser, setToken } = useAuthStore();

  const [sessionToken, setSessionToken] = useState('');
  const [email, setEmail] = useState('');
  const [digits, setDigits] = useState<string[]>(Array(OTP_LENGTH).fill(''));
  const [error, setError] = useState<string | null>(null);
  const [verifying, setVerifying] = useState(false);
  const [resending, setResending] = useState(false);
  const [resendCooldown, setResendCooldown] = useState(RESEND_COOLDOWN);
  const [resendMessage, setResendMessage] = useState<string | null>(null);
  const [ready, setReady] = useState(false);
  const inputRefs = useRef<(HTMLInputElement | null)[]>([]);

  // Read session data from sessionStorage on mount
  useEffect(() => {
    const token = sessionStorage.getItem('2fa_session_token') || '';
    const mail = sessionStorage.getItem('2fa_email') || '';
    if (!token || !mail) {
      router.replace('/login');
      return;
    }
    setSessionToken(token);
    setEmail(mail);
    setReady(true);
  }, [router]);

  // Resend cooldown timer
  useEffect(() => {
    if (resendCooldown <= 0) return;
    const timer = setInterval(() => {
      setResendCooldown((prev) => Math.max(0, prev - 1));
    }, 1000);
    return () => clearInterval(timer);
  }, [resendCooldown]);

  // Auto-focus first input
  useEffect(() => {
    if (ready) {
      inputRefs.current[0]?.focus();
    }
  }, [ready]);

  const cleanupSession = useCallback(() => {
    sessionStorage.removeItem('2fa_session_token');
    sessionStorage.removeItem('2fa_email');
  }, []);

  const submitCode = useCallback(async (code: string) => {
    setError(null);
    setVerifying(true);
    try {
      const response = await authService.verify2fa({ session_token: sessionToken, code });
      const token = response.token;
      if (!token) {
        throw new Error('No token received after verification');
      }

      cleanupSession();

      // Set auth state via Zustand store
      if (typeof window !== 'undefined') {
        localStorage.setItem(AUTH_TOKEN_KEY, token);
      }
      setToken(token);
      if (response.user) {
        setUser(response.user);
      }

      toast.success('Verification successful');
      router.push('/dashboard');
    } catch (err: unknown) {
      const error = err as Error & { response?: { data?: { error?: string } } };
      const apiError = error.response?.data?.error;
      const message = apiError || error.message || 'Verification failed. Please try again.';

      if (message.includes('expired') || message.includes('login again')) {
        cleanupSession();
        setError('Session expired. Redirecting to login...');
        setTimeout(() => router.replace('/login'), 2000);
        return;
      }

      setError(message);
      setVerifying(false);
      setDigits(Array(OTP_LENGTH).fill(''));
      setTimeout(() => inputRefs.current[0]?.focus(), 50);
    }
  }, [sessionToken, cleanupSession, setToken, setUser, router]);

  const handleChange = (index: number, value: string) => {
    const digit = value.replace(/\D/g, '').slice(-1);
    const newDigits = [...digits];
    newDigits[index] = digit;
    setDigits(newDigits);
    setError(null);

    if (digit && index < OTP_LENGTH - 1) {
      inputRefs.current[index + 1]?.focus();
    }

    if (digit && index === OTP_LENGTH - 1) {
      const code = newDigits.join('');
      if (code.length === OTP_LENGTH) {
        submitCode(code);
      }
    }
  };

  const handleKeyDown = (index: number, e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Backspace' && !digits[index] && index > 0) {
      inputRefs.current[index - 1]?.focus();
    }
    if (e.key === 'Enter') {
      const code = digits.join('');
      if (code.length === OTP_LENGTH) {
        submitCode(code);
      }
    }
  };

  const handlePaste = (e: React.ClipboardEvent) => {
    e.preventDefault();
    const pasted = e.clipboardData.getData('text').replace(/\D/g, '').slice(0, OTP_LENGTH);
    if (!pasted) return;

    const newDigits = Array(OTP_LENGTH).fill('');
    for (let i = 0; i < pasted.length; i++) {
      newDigits[i] = pasted[i];
    }
    setDigits(newDigits);
    setError(null);

    if (pasted.length === OTP_LENGTH) {
      submitCode(pasted);
    } else {
      inputRefs.current[Math.min(pasted.length, OTP_LENGTH - 1)]?.focus();
    }
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
      const error = err as Error & { response?: { data?: { error?: string } } };
      const apiError = error.response?.data?.error;
      const message = apiError || error.message || 'Failed to resend code.';
      if (message.includes('expired') || message.includes('login again')) {
        cleanupSession();
        setError('Session expired. Redirecting to login...');
        setTimeout(() => router.replace('/login'), 2000);
        return;
      }
      setError(message);
    } finally {
      setResending(false);
    }
  };

  // Mask email
  const maskedEmail = email
    ? email.replace(/^(.{2})(.*)(@.+)$/, (_, a, b, c) => a + '*'.repeat(Math.min(b.length, 6)) + c)
    : '';

  // Show loading until session data is read
  if (!ready) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-gradient-to-br from-secondary-900 via-secondary-800 to-primary-900">
        <Loader2 className="w-10 h-10 text-primary-500 animate-spin" />
      </div>
    );
  }

  return (
    <div className="min-h-screen flex items-center justify-center bg-gradient-to-br from-secondary-900 via-secondary-800 to-primary-900 p-4">
      {/* Background Pattern */}
      <div className="absolute inset-0 overflow-hidden">
        <div className="absolute -top-1/2 -right-1/2 w-full h-full bg-primary-500/10 rounded-full blur-3xl" />
        <div className="absolute -bottom-1/2 -left-1/2 w-full h-full bg-primary-500/5 rounded-full blur-3xl" />
      </div>

      <div className="relative z-10 w-full max-w-md">
        <Card variant="elevated" padding="lg">
          {/* Header */}
          <div className="text-center mb-8">
            <div className="w-16 h-16 gradient-primary rounded-2xl flex items-center justify-center mx-auto mb-4 shadow-lg shadow-primary-500/25">
              <ShieldCheck className="w-8 h-8 text-white" />
            </div>
            <h1 className="text-2xl font-bold text-secondary-900">Two-Factor Authentication</h1>
            <p className="text-secondary-500 mt-2">
              Enter the 6-digit code sent to <strong className="text-secondary-700">{maskedEmail}</strong>
            </p>
          </div>

          {/* Error */}
          {error && (
            <div className="mb-6 p-3 bg-error-50 border border-error-200 rounded-lg flex items-center gap-3">
              <AlertCircle className="w-5 h-5 text-error-600 flex-shrink-0" />
              <p className="text-sm text-error-600">{error}</p>
            </div>
          )}

          {/* Success (resend) */}
          {resendMessage && (
            <div className="mb-6 p-3 bg-success-50 border border-success-200 rounded-lg">
              <p className="text-sm text-success-600">{resendMessage}</p>
            </div>
          )}

          {/* OTP Input */}
          <div className="flex justify-center gap-3 mb-8" onPaste={handlePaste}>
            {digits.map((digit, idx) => (
              <input
                key={idx}
                ref={(el) => { inputRefs.current[idx] = el; }}
                type="text"
                inputMode="numeric"
                autoComplete="one-time-code"
                maxLength={1}
                value={digit}
                onChange={(e) => handleChange(idx, e.target.value)}
                onKeyDown={(e) => handleKeyDown(idx, e)}
                disabled={verifying}
                className={`
                  w-12 h-14 text-center text-2xl font-bold border-2 rounded-lg transition-all outline-none
                  ${verifying ? 'bg-secondary-100 border-secondary-200 text-secondary-400 cursor-not-allowed' : ''}
                  ${error
                    ? 'border-error-300 focus:border-error-500 focus:ring-2 focus:ring-error-200'
                    : 'border-secondary-300 focus:border-primary-500 focus:ring-2 focus:ring-primary-200'
                  }
                `}
              />
            ))}
          </div>

          {/* Verify Button */}
          <Button
            onClick={() => {
              const code = digits.join('');
              if (code.length === OTP_LENGTH) submitCode(code);
            }}
            disabled={verifying || digits.join('').length < OTP_LENGTH}
            className="w-full"
            size="lg"
            isLoading={verifying}
          >
            {!verifying && <ShieldCheck className="w-5 h-5 mr-2" />}
            Verify Code
          </Button>

          {/* Resend */}
          <div className="mt-6 text-center">
            <button
              onClick={handleResend}
              disabled={resendCooldown > 0 || resending}
              className={`inline-flex items-center gap-2 text-sm font-medium transition-colors ${
                resendCooldown > 0 || resending
                  ? 'text-secondary-400 cursor-not-allowed'
                  : 'text-primary-500 hover:text-primary-600'
              }`}
            >
              <RotateCw className={`w-4 h-4 ${resending ? 'animate-spin' : ''}`} />
              {resendCooldown > 0
                ? `Resend code in ${resendCooldown}s`
                : resending
                  ? 'Sending...'
                  : "Didn't receive the code? Resend"}
            </button>
          </div>

          {/* Back to login */}
          <div className="mt-6 text-center">
            <button
              onClick={() => {
                cleanupSession();
                router.push('/login');
              }}
              className="inline-flex items-center gap-2 text-sm text-secondary-500 hover:text-secondary-700 font-medium transition-colors"
            >
              <ArrowLeft className="w-4 h-4" />
              Back to Sign In
            </button>
          </div>
        </Card>

        {/* Security note */}
        <div className="mt-4 p-3 bg-white/10 backdrop-blur-sm border border-white/20 rounded-lg">
          <p className="text-sm text-white/80 text-center">
            <strong>Security check.</strong> This code expires in 5 minutes. Do not share it with anyone.
          </p>
        </div>
      </div>
    </div>
  );
}

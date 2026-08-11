'use client';

import React, { useState } from 'react';
import { useRouter } from 'next/navigation';
import { Eye, EyeOff, Lock, User } from 'lucide-react';
import { Button, Input } from '@/components/ui';
import { useAuthStore } from '@/store/auth.store';
import toast from 'react-hot-toast';

const API_BASE = process.env.NEXT_PUBLIC_API_URL || 'http://127.0.0.1:4010';

/**
 * The right-hand sign-in panel. Username/email + password (with 2FA redirect),
 * plus "Continue with Google" which hands off to the backend OAuth flow
 * (GET /auth/google) — the callback returns to /auth/callback?token=... .
 */
export default function LoginPanel() {
  const router = useRouter();
  const { login, isLoading, error, clearError } = useAuthStore();
  const [formData, setFormData] = useState({ username: '', password: '' });
  const [showPassword, setShowPassword] = useState(false);
  const [googleLoading, setGoogleLoading] = useState(false);

  const handleChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const { name, value } = e.target;
    setFormData((prev) => ({ ...prev, [name]: value }));
    if (error) clearError();
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!formData.username || !formData.password) {
      toast.error('Please fill in all fields');
      return;
    }
    try {
      await login(formData);
      toast.success('Login successful');
      router.push('/dashboard');
    } catch (err: unknown) {
      const error = err as Error & { requires_2fa?: boolean; session_token?: string; email?: string };
      if (error.requires_2fa && error.session_token) {
        sessionStorage.setItem('2fa_session_token', error.session_token);
        sessionStorage.setItem('2fa_email', error.email || '');
        router.push('/verify-otp');
        return;
      }
      toast.error(err instanceof Error ? err.message : 'Login failed');
    }
  };

  const handleGoogle = () => {
    setGoogleLoading(true);
    const params = new URLSearchParams({
      frontend_url: window.location.origin,
      from: '/dashboard',
    });
    const projectCode = process.env.NEXT_PUBLIC_PROJECT_CODE;
    if (projectCode) params.set('project_code', projectCode);
    // Full-page redirect to the backend OAuth initiator.
    window.location.href = `${API_BASE}/auth/google?${params.toString()}`;
  };

  return (
    <div className="w-full max-w-sm">
      <div className="mb-8">
        <h1 className="text-2xl font-bold text-secondary-900">Welcome back</h1>
        <p className="mt-1.5 text-sm text-secondary-500">Sign in to your OpsAPI workspace</p>
      </div>

      {/* Google */}
      <button
        type="button"
        onClick={handleGoogle}
        disabled={googleLoading}
        className="flex w-full items-center justify-center gap-3 rounded-xl border border-secondary-200 bg-white px-4 py-3 text-sm font-medium text-secondary-700 shadow-sm transition-all hover:border-secondary-300 hover:bg-secondary-50 hover:shadow disabled:opacity-60 cursor-pointer"
        data-testid="login-google-button"
      >
        <GoogleGlyph />
        {googleLoading ? 'Redirecting…' : 'Continue with Google'}
      </button>

      <div className="my-6 flex items-center gap-3">
        <div className="h-px flex-1 bg-secondary-200" />
        <span className="text-xs font-medium uppercase tracking-wide text-secondary-400">or</span>
        <div className="h-px flex-1 bg-secondary-200" />
      </div>

      <form onSubmit={handleSubmit} className="space-y-4" data-testid="login-form">
        <Input
          label="Username or Email"
          name="username"
          type="text"
          placeholder="you@company.com"
          value={formData.username}
          onChange={handleChange}
          leftIcon={<User className="h-4 w-4" />}
          autoComplete="username"
          data-testid="login-username-input"
        />
        <Input
          label="Password"
          name="password"
          type={showPassword ? 'text' : 'password'}
          placeholder="Enter your password"
          value={formData.password}
          onChange={handleChange}
          leftIcon={<Lock className="h-4 w-4" />}
          rightIcon={
            <button
              type="button"
              onClick={() => setShowPassword((s) => !s)}
              className="cursor-pointer transition-colors hover:text-secondary-600 focus:outline-none"
              aria-label={showPassword ? 'Hide password' : 'Show password'}
              data-testid="login-toggle-password"
            >
              {showPassword ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
            </button>
          }
          autoComplete="current-password"
          data-testid="login-password-input"
        />

        {error && (
          <div
            role="alert"
            className="rounded-lg border border-error-200 bg-error-50 p-3 text-sm text-error-600"
            data-testid="login-error-message"
          >
            {error}
          </div>
        )}

        <Button
          type="submit"
          className="w-full"
          size="lg"
          isLoading={isLoading}
          data-testid="login-submit-button"
        >
          Sign in
        </Button>
      </form>

      <div className="mt-6 text-center text-sm">
        <a href="/forgot-password" className="font-medium text-primary-500 hover:text-primary-600">
          Forgot your password?
        </a>
      </div>
    </div>
  );
}

/** Google "G" mark (official four-colour glyph). */
function GoogleGlyph() {
  return (
    <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true">
      <path
        fill="#4285F4"
        d="M17.64 9.2c0-.637-.057-1.251-.164-1.84H9v3.481h4.844a4.14 4.14 0 0 1-1.796 2.716v2.259h2.908c1.702-1.567 2.684-3.875 2.684-6.615z"
      />
      <path
        fill="#34A853"
        d="M9 18c2.43 0 4.467-.806 5.956-2.184l-2.908-2.259c-.806.54-1.837.86-3.048.86-2.344 0-4.328-1.584-5.036-3.711H.957v2.332A8.997 8.997 0 0 0 9 18z"
      />
      <path
        fill="#FBBC05"
        d="M3.964 10.706A5.41 5.41 0 0 1 3.682 9c0-.593.102-1.17.282-1.706V4.962H.957A8.997 8.997 0 0 0 0 9c0 1.452.348 2.827.957 4.038l3.007-2.332z"
      />
      <path
        fill="#EA4335"
        d="M9 3.58c1.321 0 2.508.454 3.44 1.345l2.582-2.58C13.463.891 11.426 0 9 0A8.997 8.997 0 0 0 .957 4.962L3.964 7.294C4.672 5.167 6.656 3.58 9 3.58z"
      />
    </svg>
  );
}

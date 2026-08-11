'use client';

import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { Loader2 } from 'lucide-react';
import { useAuthStore } from '@/store/auth.store';
import { Logo } from '@/components/brand/Logo';
import type { User } from '@/types';

/**
 * Google OAuth landing.
 *
 * The backend (`/auth/google/callback`) completes the OAuth exchange, mints the
 * app JWT, and redirects here as `?token=<jwt>&redirect=<path>` (or `?error=`).
 * We adopt the session and bounce to the destination — no second login.
 */

function decodeJwtUserinfo(token: string): Record<string, unknown> | null {
  try {
    const part = token.split('.')[1];
    if (!part) return null;
    let b64 = part.replace(/-/g, '+').replace(/_/g, '/');
    while (b64.length % 4) b64 += '=';
    const payload = JSON.parse(atob(b64)) as { userinfo?: Record<string, unknown> };
    return payload.userinfo ?? null;
  } catch {
    return null;
  }
}

function userFromUserinfo(info: Record<string, unknown>): User {
  return {
    id: Number(info.id ?? 0),
    uuid: String(info.uuid ?? ''),
    email: String(info.email ?? ''),
    username: String(info.username ?? ''),
    first_name: String(info.first_name ?? ''),
    last_name: String(info.last_name ?? ''),
    active: true,
    created_at: '',
    updated_at: '',
    role: typeof info.role === 'string' ? info.role : undefined,
  };
}

export default function GoogleCallbackPage(): React.ReactElement {
  const router = useRouter();
  const ranRef = useRef(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (ranRef.current) return;
    ranRef.current = true;

    const params = new URLSearchParams(window.location.search);
    const errParam = params.get('error');
    if (errParam) {
      setError(decodeURIComponent(errParam));
      return;
    }

    const token = params.get('token');
    const redirect = params.get('redirect') || '/dashboard';

    if (!token) {
      setError('Missing sign-in token. Please try again.');
      return;
    }
    const info = decodeJwtUserinfo(token);
    if (!info || !info.uuid) {
      setError('Invalid sign-in token. Please try again.');
      return;
    }

    // Adopt the session, then strip the token from the address bar.
    useAuthStore.getState().setToken(token);
    useAuthStore.getState().setUser(userFromUserinfo(info));
    window.history.replaceState(null, '', window.location.pathname);

    const dest = redirect.startsWith('/') ? redirect : '/dashboard';
    // Full navigation so all providers (namespace, permissions, menu) hydrate.
    window.location.assign(dest);
  }, [router]);

  return (
    <div className="flex min-h-dvh flex-col items-center justify-center gap-6 bg-secondary-950 px-6 text-center">
      <Logo size={38} tone="light" />
      {error ? (
        <div className="max-w-sm">
          <p className="mb-4 text-sm text-error-400">{error}</p>
          <button
            onClick={() => router.push('/login')}
            className="cursor-pointer rounded-lg bg-primary-500 px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-primary-600"
          >
            Back to sign in
          </button>
        </div>
      ) : (
        <div className="flex items-center gap-3 text-secondary-300">
          <Loader2 className="h-5 w-5 animate-spin text-primary-500" />
          <span className="text-sm">Signing you in…</span>
        </div>
      )}
    </div>
  );
}

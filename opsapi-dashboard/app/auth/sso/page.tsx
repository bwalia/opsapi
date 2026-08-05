'use client';

import { useEffect, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useAuthStore } from '@/store/auth.store';
import { useNamespaceStore } from '@/store/namespace.store';
import { namespaceService } from '@/services/namespace.service';
import type { User } from '@/types';

/**
 * SSO landing page.
 *
 * The academy site (a separate app) creates the opsapi account + session, then
 * hands the user here with the freshly-issued JWT in the URL *fragment* (never a
 * query string, so it isn't logged or sent to servers). We adopt that session —
 * store the token, hydrate the user, and switch into the academy namespace so the
 * instructor's RBAC permissions (courses only) load — then bounce to the target
 * page. No second login.
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

export default function SsoAcceptPage(): React.ReactElement {
  const router = useRouter();
  const ranRef = useRef(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (ranRef.current) return;
    ranRef.current = true;

    void (async () => {
      const hash = window.location.hash.startsWith('#')
        ? window.location.hash.slice(1)
        : window.location.hash;
      const params = new URLSearchParams(hash);
      const token = params.get('token');
      const ns = params.get('ns');
      const next = params.get('next') || '/dashboard/academy';

      if (!token) {
        setError('Missing sign-in token. Please sign in.');
        return;
      }

      const info = decodeJwtUserinfo(token);
      if (!info || !info.uuid) {
        setError('Invalid sign-in token. Please sign in.');
        return;
      }

      // Clear the token from the address bar as soon as we've read it.
      window.history.replaceState(null, '', window.location.pathname);

      // 1. Adopt the session.
      useAuthStore.getState().setToken(token);
      useAuthStore.getState().setUser(userFromUserinfo(info));

      // 2. Enter the academy namespace so the instructor's permissions load.
      //    switchNamespace returns namespace + permissions + a namespace-scoped
      //    token and persists them; a full navigation then applies the context.
      try {
        const list = await namespaceService.getUserNamespacesList();
        const academy = ns
          ? list.find((n) => n.slug === ns)
          : list.find((n) => n.slug === 'academy');
        if (academy?.uuid) {
          await useNamespaceStore.getState().switchNamespace(academy.uuid);
        }
      } catch {
        // Non-fatal: the target page can still resolve namespace context itself.
      }

      // 3. Land on the destination with a full load so all context hydrates.
      const dest = next.startsWith('/') ? next : '/dashboard/academy';
      window.location.assign(dest);
    })();
  }, [router]);

  return (
    <div className="flex min-h-screen items-center justify-center bg-secondary-50">
      <div className="text-center">
        {error ? (
          <>
            <p className="mb-4 text-sm text-error-600">{error}</p>
            <button
              onClick={() => router.push('/login')}
              className="rounded-lg bg-primary-500 px-4 py-2 text-sm font-medium text-white hover:bg-primary-600"
            >
              Go to sign in
            </button>
          </>
        ) : (
          <>
            <div className="mx-auto mb-4 h-10 w-10 animate-spin rounded-full border-2 border-secondary-200 border-t-primary-500" />
            <p className="text-sm text-secondary-500">Signing you in…</p>
          </>
        )}
      </div>
    </div>
  );
}

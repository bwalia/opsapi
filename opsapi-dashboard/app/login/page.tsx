'use client';

import { useEffect } from 'react';
import { useRouter } from 'next/navigation';
import LoginPanel from '@/components/auth/LoginPanel';
import AuthShell, { AuthLoader } from '@/components/auth/AuthShell';
import { useAuthStore } from '@/store/auth.store';
import { AUTH_TOKEN_KEY } from '@/lib/api-client';

export default function LoginPage() {
  const router = useRouter();
  const { isAuthenticated, token, _hasHydrated, setToken } = useAuthStore();

  useEffect(() => {
    if (!_hasHydrated) return;
    const actualToken = localStorage.getItem(AUTH_TOKEN_KEY);
    if (isAuthenticated && !actualToken) {
      setToken(null);
      return;
    }
    if (isAuthenticated && token && actualToken) {
      router.push('/dashboard');
    }
  }, [isAuthenticated, token, _hasHydrated, router, setToken]);

  if (!_hasHydrated) return <AuthLoader />;

  return (
    <AuthShell>
      <LoginPanel />
    </AuthShell>
  );
}

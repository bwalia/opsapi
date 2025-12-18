'use client';

import { useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { LoginForm } from '@/components/auth';
import { useAuthStore } from '@/store/auth.store';
import { AUTH_TOKEN_KEY } from '@/lib/api-client';
import { Loader2 } from 'lucide-react';

export default function LoginPage() {
  const router = useRouter();
  const { isAuthenticated, token, _hasHydrated, setToken } = useAuthStore();

  useEffect(() => {
    // Wait for hydration before redirecting
    if (!_hasHydrated) return;

    // Verify actual localStorage token matches Zustand state
    // This prevents redirect loops when 401 clears localStorage but Zustand still thinks authenticated
    const actualToken = localStorage.getItem(AUTH_TOKEN_KEY);

    // If Zustand thinks we're authenticated but localStorage has no token, clear Zustand state
    if (isAuthenticated && !actualToken) {
      setToken(null);
      return;
    }

    // Only redirect if both Zustand state AND localStorage have valid token
    if (isAuthenticated && token && actualToken) {
      router.push('/dashboard');
    }
  }, [isAuthenticated, token, _hasHydrated, router, setToken]);

  // Show loading while hydrating
  if (!_hasHydrated) {
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

      <div className="relative z-10">
        <LoginForm />
      </div>
    </div>
  );
}

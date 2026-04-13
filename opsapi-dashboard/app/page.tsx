'use client';

import { useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { useAuthStore } from '@/store/auth.store';
import { Loader2 } from 'lucide-react';

export default function HomePage() {
  const router = useRouter();
  const { isAuthenticated, token, _hasHydrated } = useAuthStore();

  useEffect(() => {
    // Wait for hydration before making redirect decision
    if (!_hasHydrated) return;

    if (isAuthenticated && token) {
      router.push('/dashboard');
    } else {
      router.push('/login');
    }
  }, [isAuthenticated, token, _hasHydrated, router]);

  return (
    <div className="min-h-screen flex items-center justify-center bg-secondary-50">
      <div className="flex flex-col items-center gap-4">
        <div className="w-16 h-16 gradient-primary rounded-2xl flex items-center justify-center shadow-lg shadow-primary-500/25">
          <Loader2 className="w-8 h-8 text-white animate-spin" />
        </div>
        <p className="text-secondary-500 font-medium">Redirecting...</p>
      </div>
    </div>
  );
}

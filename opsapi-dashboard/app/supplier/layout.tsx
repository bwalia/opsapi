'use client';

/**
 * The supplier portal: a small app of its own for supplier logins. Deliberately NOT the staff
 * DashboardLayout: that one loads menus, chat, the AI assistant and more, all of which a supplier
 * login is refused. Everything here talks only to /api/v2/supplier-portal.
 */
import React, { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import { usePathname, useRouter } from 'next/navigation';
import { Building2, FileText, Loader2, LogOut, MessageSquare, PoundSterling, ClipboardList } from 'lucide-react';
import { useAuthStore } from '@/store/auth.store';
import { AUTH_TOKEN_KEY } from '@/lib/api-client';
import { cn } from '@/lib/utils';
import { isSupplierToken } from '@/lib/supplier-portal';
import { DialogHost } from '@/components/ui/Dialogs';
import { SupplierPortalContext } from '@/components/supplier-portal/SupplierPortalContext';
import { portalError, supplierPortalService, type SupplierMe } from '@/services/supplier-portal.service';

const NAV = [
  { href: '/supplier', label: 'Purchase orders', icon: ClipboardList },
  { href: '/supplier/documents', label: 'Documents', icon: FileText },
  { href: '/supplier/payments', label: 'Payments', icon: PoundSterling },
  { href: '/supplier/messages', label: 'Messages', icon: MessageSquare },
];

function FullPage({ children }: { children: React.ReactNode }) {
  return <div className="flex min-h-screen items-center justify-center bg-secondary-50 p-4">{children}</div>;
}

function Loading({ message }: { message: string }) {
  return (
    <FullPage>
      <div className="flex flex-col items-center gap-3">
        <Loader2 className="h-8 w-8 animate-spin text-primary-600" />
        <p className="font-medium text-secondary-500">{message}</p>
      </div>
    </FullPage>
  );
}

export default function SupplierLayout({ children }: { children: React.ReactNode }) {
  const router = useRouter();
  const pathname = usePathname();
  const { isAuthenticated, token, _hasHydrated, setToken, logout } = useAuthStore();
  const [me, setMe] = useState<SupplierMe | null>(null);
  const [notice, setNotice] = useState<{ title: string; message: string } | null>(null);
  const [signingOut, setSigningOut] = useState(false);

  // Same token checks as the staff DashboardLayout.
  const actualToken = typeof window !== 'undefined' ? localStorage.getItem(AUTH_TOKEN_KEY) : null;
  const signedIn = _hasHydrated && isAuthenticated && !!token && !!actualToken;

  useEffect(() => {
    if (!_hasHydrated) return;
    const stored = localStorage.getItem(AUTH_TOKEN_KEY);
    if (isAuthenticated && !stored) {
      setToken(null);
      return;
    }
    if (!token || !isAuthenticated || !stored) router.push('/login');
  }, [token, isAuthenticated, _hasHydrated, router, setToken]);

  const loadMe = useCallback(async () => {
    try {
      setMe(await supplierPortalService.me());
      setNotice(null);
    } catch (err) {
      const e = portalError(err, 'The supplier portal could not be opened. Please try again.');
      if (e.status === 401) return; // the API client sends them to /login
      if (e.code === 'NOT_A_SUPPLIER' && !isSupplierToken(localStorage.getItem(AUTH_TOKEN_KEY))) {
        router.replace('/dashboard');
        return;
      }
      setNotice({
        title:
          e.code === 'ACCOUNT_DISABLED'
            ? 'Your supplier portal access is switched off'
            : e.code === 'PORTAL_NOT_AVAILABLE' || e.code === 'NOT_AVAILABLE'
              ? 'The supplier portal isn’t available yet'
              : 'The supplier portal couldn’t be opened',
        message: e.message,
      });
    }
  }, [router]);

  useEffect(() => {
    if (signedIn) void loadMe();
  }, [signedIn, loadMe]);

  const signOut = async () => {
    setSigningOut(true);
    try {
      await logout();
    } finally {
      router.replace('/login');
    }
  };

  if (!_hasHydrated) return <Loading message="Loading…" />;
  if (!signedIn) return <Loading message="Redirecting to sign in…" />;

  if (notice) {
    return (
      <FullPage>
        <div className="w-full max-w-md rounded-2xl border border-secondary-200 bg-surface p-6 text-center shadow-sm">
          <Building2 className="mx-auto mb-3 h-10 w-10 text-secondary-400" />
          <h1 className="text-lg font-semibold text-secondary-900">{notice.title}</h1>
          <p className="mt-2 text-sm text-secondary-600">{notice.message}</p>
          <div className="mt-5 flex flex-wrap justify-center gap-2">
            <button
              type="button"
              onClick={() => void loadMe()}
              className="rounded-lg border border-secondary-300 bg-surface px-4 py-2 text-sm font-medium text-secondary-700 hover:bg-secondary-50"
            >
              Try again
            </button>
            <button
              type="button"
              onClick={signOut}
              disabled={signingOut}
              className="inline-flex items-center gap-2 rounded-lg bg-primary-600 px-4 py-2 text-sm font-medium text-white hover:bg-primary-700 disabled:opacity-50"
            >
              <LogOut className="h-4 w-4" />
              Sign out
            </button>
          </div>
        </div>
      </FullPage>
    );
  }

  if (!me) return <Loading message="Opening the supplier portal…" />;

  const isActive = (href: string) =>
    href === '/supplier' ? pathname === '/supplier' || pathname.startsWith('/supplier/purchase-orders') : pathname.startsWith(href);

  return (
    <SupplierPortalContext.Provider value={me}>
      <div className="min-h-screen bg-secondary-50">
        <header className="sticky top-0 z-30 border-b border-secondary-200 bg-surface">
          <div className="mx-auto flex max-w-6xl items-center justify-between gap-3 px-4 py-3">
            <div className="min-w-0">
              <p className="truncate text-base font-semibold text-secondary-900">{me.supplier.name}</p>
              <p className="truncate text-xs text-secondary-500">
                Supplier portal for {me.buyer.name} · {me.user.name}
              </p>
            </div>
            <button
              type="button"
              onClick={signOut}
              disabled={signingOut}
              className="inline-flex shrink-0 items-center gap-2 rounded-lg border border-secondary-300 px-3 py-1.5 text-sm font-medium text-secondary-700 hover:bg-secondary-50 disabled:opacity-50"
            >
              <LogOut className="h-4 w-4" />
              <span>Sign out</span>
            </button>
          </div>
          <nav className="mx-auto flex max-w-6xl gap-1 overflow-x-auto px-2 sm:px-4" aria-label="Supplier portal">
            {NAV.map(({ href, label, icon: Icon }) => (
              <Link
                key={href}
                href={href}
                className={cn(
                  'inline-flex shrink-0 items-center gap-2 border-b-2 px-3 py-2.5 text-sm font-medium transition-colors',
                  isActive(href)
                    ? 'border-primary-600 text-primary-700'
                    : 'border-transparent text-secondary-600 hover:text-secondary-900'
                )}
              >
                <Icon className="h-4 w-4" />
                {label}
              </Link>
            ))}
          </nav>
        </header>
        <main id="main-content" className="mx-auto max-w-6xl p-4 sm:p-6">
          {children}
        </main>
      </div>
      <DialogHost />
    </SupplierPortalContext.Provider>
  );
}

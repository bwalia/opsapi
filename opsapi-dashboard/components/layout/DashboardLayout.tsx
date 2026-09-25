'use client';

import React, { useState, useEffect, useCallback, memo } from 'react';
import { useRouter } from 'next/navigation';
import Sidebar from './Sidebar';
import Header from './Header';
import ThemeStyles from './ThemeStyles';
import BuildFooter from './BuildFooter';
import GlobalSearch from './GlobalSearch';
import { GlobalTimerWidget } from '@/components/time-tracking';
import { useAuthStore } from '@/store/auth.store';
import { PermissionsProvider } from '@/contexts/PermissionsContext';
import { NamespaceProvider } from '@/contexts/NamespaceContext';
import { Loader2 } from 'lucide-react';
import { cn } from '@/lib/utils';
import { AUTH_TOKEN_KEY } from '@/lib/api-client';

interface DashboardLayoutProps {
  children: React.ReactNode;
}

// Loading component - memoized
const LoadingScreen = memo(function LoadingScreen({ message }: { message: string }) {
  return (
    <div className="min-h-screen flex items-center justify-center bg-secondary-50">
      <div className="flex flex-col items-center gap-4">
        <div className="w-12 h-12 gradient-primary rounded-xl flex items-center justify-center shadow-lg shadow-primary-500/25">
          <Loader2 className="w-6 h-6 text-white animate-spin" />
        </div>
        <p className="text-secondary-500 font-medium">{message}</p>
      </div>
    </div>
  );
});

const DashboardLayout: React.FC<DashboardLayoutProps> = memo(function DashboardLayout({
  children,
}) {
  const router = useRouter();
  const [isSidebarOpen, setIsSidebarOpen] = useState(false);
  const [isSidebarCollapsed, setIsSidebarCollapsed] = useState(false);
  const { isAuthenticated, token, _hasHydrated, setToken } = useAuthStore();

  // Load sidebar collapsed state from localStorage
  useEffect(() => {
    const savedCollapsed = localStorage.getItem('sidebar-collapsed');
    if (savedCollapsed === 'true') {
      setIsSidebarCollapsed(true);
    }
  }, []);

  // Auth check - verify both Zustand state AND actual localStorage token
  useEffect(() => {
    if (!_hasHydrated) return;

    // Check actual localStorage token to prevent state mismatch after 401 errors
    const actualToken = localStorage.getItem(AUTH_TOKEN_KEY);

    // If localStorage token was cleared (e.g., by 401 interceptor) but Zustand still thinks authenticated
    if (isAuthenticated && !actualToken) {
      setToken(null); // This will trigger clearAllAuthStorage and update state
      return;
    }

    // Redirect to login if not authenticated or no token
    if (!token || !isAuthenticated || !actualToken) {
      router.push('/login');
    }
  }, [token, isAuthenticated, _hasHydrated, router, setToken]);

  // Close sidebar on route change (mobile)
  useEffect(() => {
    setIsSidebarOpen(false);
  }, []);

  // Handle escape key to close mobile sidebar
  useEffect(() => {
    const handleEscape = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && isSidebarOpen) {
        setIsSidebarOpen(false);
      }
    };
    document.addEventListener('keydown', handleEscape);
    return () => document.removeEventListener('keydown', handleEscape);
  }, [isSidebarOpen]);

  // Prevent body scroll when mobile sidebar is open
  useEffect(() => {
    if (isSidebarOpen) {
      document.body.style.overflow = 'hidden';
    } else {
      document.body.style.overflow = '';
    }
    return () => {
      document.body.style.overflow = '';
    };
  }, [isSidebarOpen]);

  const handleSidebarOpen = useCallback(() => {
    setIsSidebarOpen(true);
  }, []);

  const handleSidebarClose = useCallback(() => {
    setIsSidebarOpen(false);
  }, []);

  const handleSidebarToggleCollapse = useCallback(() => {
    setIsSidebarCollapsed((prev) => {
      const newValue = !prev;
      localStorage.setItem('sidebar-collapsed', String(newValue));
      return newValue;
    });
  }, []);

  // Show loading while hydrating
  if (!_hasHydrated) {
    return <LoadingScreen message="Loading..." />;
  }

  // After hydration, if not authenticated, show redirect message
  // Also verify actual localStorage token exists to handle 401 race conditions
  const actualToken = typeof window !== 'undefined' ? localStorage.getItem(AUTH_TOKEN_KEY) : null;
  if (!isAuthenticated || !token || !actualToken) {
    return <LoadingScreen message="Redirecting to login..." />;
  }

  return (
    <NamespaceProvider>
      <PermissionsProvider>
        <ThemeStyles />
        <div className="min-h-screen bg-secondary-50">
          {/* Sidebar */}
          <Sidebar
            isOpen={isSidebarOpen}
            isCollapsed={isSidebarCollapsed}
            onClose={handleSidebarClose}
            onToggleCollapse={handleSidebarToggleCollapse}
          />

          {/* Main content wrapper — a full-height flex column so the footer
              sticks to the bottom of the viewport on short pages and sits after
              the content on long ones. */}
          <div
            className={cn(
              'flex min-h-screen flex-col transition-all duration-300',
              // Desktop: adjust margin based on sidebar state
              isSidebarCollapsed ? 'lg:ml-20' : 'lg:ml-64',
              // Mobile: no margin (sidebar overlays)
              'ml-0'
            )}
          >
            {/* Header */}
            <Header onMenuClick={handleSidebarOpen} />

            {/* Main content — grows to fill, pushing the footer down */}
            <main id="main-content" className="flex-1 p-4 sm:p-6">{children}</main>

            {/* Build/version stamp — so it's obvious which build is live */}
            <BuildFooter />
          </div>
        </div>

        {/* Floating running-timer widget (self-hides when no timer runs) */}
        <GlobalTimerWidget />

        {/* ⌘K / Ctrl+K command palette — search any page/module */}
        <GlobalSearch />
      </PermissionsProvider>
    </NamespaceProvider>
  );
});

export default DashboardLayout;

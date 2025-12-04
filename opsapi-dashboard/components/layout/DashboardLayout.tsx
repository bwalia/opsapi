'use client';

import React, { useState, useEffect, useCallback, memo } from 'react';
import { useRouter } from 'next/navigation';
import Sidebar from './Sidebar';
import Header from './Header';
import { useAuthStore } from '@/store/auth.store';
import { PermissionsProvider } from '@/contexts/PermissionsContext';
import { NamespaceProvider } from '@/contexts/NamespaceContext';
import { Loader2 } from 'lucide-react';
import { cn } from '@/lib/utils';

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
  const { isAuthenticated, token, _hasHydrated } = useAuthStore();

  // Load sidebar collapsed state from localStorage
  useEffect(() => {
    const savedCollapsed = localStorage.getItem('sidebar-collapsed');
    if (savedCollapsed === 'true') {
      setIsSidebarCollapsed(true);
    }
  }, []);

  // Auth check
  useEffect(() => {
    if (!_hasHydrated) return;
    if (!token || !isAuthenticated) {
      router.push('/login');
    }
  }, [token, isAuthenticated, _hasHydrated, router]);

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
  if (!isAuthenticated || !token) {
    return <LoadingScreen message="Redirecting to login..." />;
  }

  return (
    <NamespaceProvider>
      <PermissionsProvider>
        <div className="min-h-screen bg-secondary-50">
          {/* Sidebar */}
          <Sidebar
            isOpen={isSidebarOpen}
            isCollapsed={isSidebarCollapsed}
            onClose={handleSidebarClose}
            onToggleCollapse={handleSidebarToggleCollapse}
          />

          {/* Main content wrapper */}
          <div
            className={cn(
              'transition-all duration-300',
              // Desktop: adjust margin based on sidebar state
              isSidebarCollapsed ? 'lg:ml-20' : 'lg:ml-64',
              // Mobile: no margin (sidebar overlays)
              'ml-0'
            )}
          >
            {/* Header */}
            <Header onMenuClick={handleSidebarOpen} />

            {/* Main content */}
            <main className="p-4 sm:p-6">{children}</main>
          </div>
        </div>
      </PermissionsProvider>
    </NamespaceProvider>
  );
});

export default DashboardLayout;

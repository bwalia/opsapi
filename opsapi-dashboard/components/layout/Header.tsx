'use client';

import React, { useState, useCallback, memo } from 'react';
import { Menu, Search, ChevronDown, Settings, LogOut, User } from 'lucide-react';
import { cn, getInitials } from '@/lib/utils';
import { useAuthStore } from '@/store/auth.store';
import { NamespaceSwitcher } from '@/components/namespace/NamespaceSwitcher';
import { InvitationNotificationBell } from '@/components/namespace/invitations';
import { NotificationBell } from '@/components/notifications';
import { ThemeToggle } from './ThemeToggle';

interface HeaderProps {
  onMenuClick?: () => void;
}

// Profile dropdown component - memoized
const ProfileDropdown = memo(function ProfileDropdown({
  isOpen,
  onClose,
  user,
  onLogout,
}: {
  isOpen: boolean;
  onClose: () => void;
  user: { first_name?: string; last_name?: string; email?: string } | null;
  onLogout: () => void;
}) {
  if (!isOpen) return null;

  return (
    <>
      <div className="fixed inset-0 z-10" onClick={onClose} aria-hidden="true" />
      <div className="absolute right-0 mt-2 w-56 bg-surface-elevated rounded-xl shadow-xl border border-secondary-200 py-2 z-20" role="menu" aria-label="User menu">
        <div className="px-4 py-3 border-b border-secondary-100">
          <p className="text-sm font-medium text-secondary-900">
            {user?.first_name} {user?.last_name}
          </p>
          <p className="text-xs text-secondary-500 truncate">{user?.email}</p>
        </div>

        <div className="py-1">
          <a
            href="/dashboard/settings"
            role="menuitem"
            className="flex items-center gap-3 px-4 py-2.5 text-sm text-secondary-700 hover:bg-secondary-50"
          >
            <User className="w-4 h-4" aria-hidden="true" />
            Profile
          </a>
          <a
            href="/dashboard/settings"
            role="menuitem"
            className="flex items-center gap-3 px-4 py-2.5 text-sm text-secondary-700 hover:bg-secondary-50"
          >
            <Settings className="w-4 h-4" aria-hidden="true" />
            Settings
          </a>
        </div>

        <div className="border-t border-secondary-100 pt-1">
          <button
            onClick={onLogout}
            role="menuitem"
            className="flex items-center gap-3 px-4 py-2.5 text-sm text-error-600 hover:bg-error-50 w-full"
          >
            <LogOut className="w-4 h-4" aria-hidden="true" />
            Sign out
          </button>
        </div>
      </div>
    </>
  );
});

// Open the global command palette (rendered once in DashboardLayout). Used by
// the header's search box + the mobile search button.
function openCommandPalette() {
  if (typeof window !== 'undefined') {
    window.dispatchEvent(new Event('opsapi:open-search'));
  }
}

const Header: React.FC<HeaderProps> = memo(function Header({ onMenuClick }) {
  const [isProfileOpen, setIsProfileOpen] = useState(false);
  const { user, logout } = useAuthStore();

  const handleLogout = useCallback(async () => {
    await logout();
    window.location.href = '/login';
  }, [logout]);

  const handleProfileToggle = useCallback(() => {
    setIsProfileOpen((prev) => !prev);
  }, []);

  const handleProfileClose = useCallback(() => {
    setIsProfileOpen(false);
  }, []);

  return (
    <>
      <header className="sticky top-0 z-30 h-16 bg-surface border-b border-secondary-200">
        <div className="flex items-center justify-between h-full px-4 sm:px-6">
          {/* Left Section */}
          <div className="flex items-center gap-2 sm:gap-4">
            {/* Mobile Menu Button */}
            <button
              onClick={onMenuClick}
              className="p-2 text-secondary-500 hover:text-secondary-700 hover:bg-secondary-100 rounded-lg lg:hidden"
              aria-label="Open menu"
            >
              <Menu className="w-5 h-5" />
            </button>

            {/* Mobile Search Button */}
            <button
              onClick={openCommandPalette}
              className="p-2 text-secondary-500 hover:text-secondary-700 hover:bg-secondary-100 rounded-lg sm:hidden"
              aria-label="Search"
            >
              <Search className="w-5 h-5" />
            </button>

            {/* Desktop Search Bar */}
            <div className="hidden sm:flex items-center">
              <div className="relative">
                <label htmlFor="desktop-search" className="sr-only">Search</label>
                <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-secondary-400" aria-hidden="true" />
                <input
                  id="desktop-search"
                  type="text"
                  readOnly
                  placeholder="Search anything..."
                  onClick={openCommandPalette}
                  onFocus={openCommandPalette}
                  className="w-48 md:w-64 lg:w-80 cursor-pointer pl-10 pr-14 py-2 bg-secondary-50 border border-secondary-200 rounded-lg text-sm placeholder:text-secondary-400 focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 transition-all"
                />
                <kbd className="pointer-events-none absolute right-2.5 top-1/2 -translate-y-1/2 rounded border border-secondary-200 bg-surface px-1.5 py-0.5 font-sans text-[10px] text-secondary-400">
                  ⌘K
                </kbd>
              </div>
            </div>
          </div>

          {/* Right Section */}
          <div className="flex items-center gap-2 sm:gap-3">
            {/* Namespace Switcher */}
            <div className="hidden sm:block">
              <NamespaceSwitcher variant="header" />
            </div>

            {/* Theme toggle */}
            <ThemeToggle />

            {/* Invitation Notifications */}
            <InvitationNotificationBell />

            {/* Kanban Notifications */}
            <NotificationBell />

            {/* Profile Dropdown */}
            <div className="relative">
              <button
                onClick={handleProfileToggle}
                className="flex items-center gap-2 sm:gap-3 p-1.5 rounded-lg hover:bg-secondary-100 transition-colors"
                aria-expanded={isProfileOpen}
                aria-haspopup="true"
              >
                <div className="w-8 h-8 sm:w-9 sm:h-9 gradient-primary rounded-lg flex items-center justify-center text-white font-semibold text-sm shadow-md shadow-primary-500/25">
                  {getInitials(user?.first_name, user?.last_name)}
                </div>
                <div className="hidden md:block text-left">
                  <p className="text-sm font-medium text-secondary-900 truncate max-w-[120px]">
                    {user?.first_name} {user?.last_name}
                  </p>
                  <p className="text-xs text-secondary-500 truncate max-w-[120px]">{user?.email}</p>
                </div>
                <ChevronDown
                  className={cn(
                    'w-4 h-4 text-secondary-400 transition-transform hidden md:block',
                    isProfileOpen && 'rotate-180'
                  )}
                />
              </button>

              <ProfileDropdown
                isOpen={isProfileOpen}
                onClose={handleProfileClose}
                user={user}
                onLogout={handleLogout}
              />
            </div>
          </div>
        </div>
      </header>
    </>
  );
});

export default Header;

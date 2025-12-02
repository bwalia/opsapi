'use client';

import React, { useState, useCallback, memo } from 'react';
import { Menu, Search, Bell, ChevronDown, Settings, LogOut, User, X } from 'lucide-react';
import { cn, getInitials } from '@/lib/utils';
import { useAuthStore } from '@/store/auth.store';

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
      <div className="absolute right-0 mt-2 w-56 bg-white rounded-xl shadow-xl border border-secondary-200 py-2 z-20">
        <div className="px-4 py-3 border-b border-secondary-100">
          <p className="text-sm font-medium text-secondary-900">
            {user?.first_name} {user?.last_name}
          </p>
          <p className="text-xs text-secondary-500 truncate">{user?.email}</p>
        </div>

        <div className="py-1">
          <a
            href="/dashboard/settings"
            className="flex items-center gap-3 px-4 py-2.5 text-sm text-secondary-700 hover:bg-secondary-50"
          >
            <User className="w-4 h-4" />
            Profile
          </a>
          <a
            href="/dashboard/settings"
            className="flex items-center gap-3 px-4 py-2.5 text-sm text-secondary-700 hover:bg-secondary-50"
          >
            <Settings className="w-4 h-4" />
            Settings
          </a>
        </div>

        <div className="border-t border-secondary-100 pt-1">
          <button
            onClick={onLogout}
            className="flex items-center gap-3 px-4 py-2.5 text-sm text-error-600 hover:bg-error-50 w-full"
          >
            <LogOut className="w-4 h-4" />
            Sign out
          </button>
        </div>
      </div>
    </>
  );
});

// Mobile search modal - memoized
const MobileSearchModal = memo(function MobileSearchModal({
  isOpen,
  onClose,
}: {
  isOpen: boolean;
  onClose: () => void;
}) {
  if (!isOpen) return null;

  return (
    <div className="fixed inset-0 z-50 sm:hidden">
      <div className="absolute inset-0 bg-secondary-900/50 backdrop-blur-sm" onClick={onClose} />
      <div className="absolute top-0 left-0 right-0 bg-white p-4 shadow-lg">
        <div className="flex items-center gap-3">
          <div className="relative flex-1">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-secondary-400" />
            <input
              type="text"
              placeholder="Search anything..."
              autoFocus
              className="w-full pl-10 pr-4 py-2.5 bg-secondary-50 border border-secondary-200 rounded-lg text-sm placeholder:text-secondary-400 focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
            />
          </div>
          <button
            onClick={onClose}
            className="p-2 text-secondary-500 hover:text-secondary-700 hover:bg-secondary-100 rounded-lg"
          >
            <X className="w-5 h-5" />
          </button>
        </div>
      </div>
    </div>
  );
});

const Header: React.FC<HeaderProps> = memo(function Header({ onMenuClick }) {
  const [isProfileOpen, setIsProfileOpen] = useState(false);
  const [isMobileSearchOpen, setIsMobileSearchOpen] = useState(false);
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

  const handleMobileSearchOpen = useCallback(() => {
    setIsMobileSearchOpen(true);
  }, []);

  const handleMobileSearchClose = useCallback(() => {
    setIsMobileSearchOpen(false);
  }, []);

  return (
    <>
      <header className="sticky top-0 z-30 h-16 bg-white border-b border-secondary-200">
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
              onClick={handleMobileSearchOpen}
              className="p-2 text-secondary-500 hover:text-secondary-700 hover:bg-secondary-100 rounded-lg sm:hidden"
              aria-label="Search"
            >
              <Search className="w-5 h-5" />
            </button>

            {/* Desktop Search Bar */}
            <div className="hidden sm:flex items-center">
              <div className="relative">
                <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-secondary-400" />
                <input
                  type="text"
                  placeholder="Search anything..."
                  className="w-48 md:w-64 lg:w-80 pl-10 pr-4 py-2 bg-secondary-50 border border-secondary-200 rounded-lg text-sm placeholder:text-secondary-400 focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 transition-all"
                />
              </div>
            </div>
          </div>

          {/* Right Section */}
          <div className="flex items-center gap-2 sm:gap-3">
            {/* Notifications */}
            <button
              className="relative p-2 text-secondary-500 hover:text-secondary-700 hover:bg-secondary-100 rounded-lg"
              aria-label="Notifications"
            >
              <Bell className="w-5 h-5" />
              <span className="absolute top-1.5 right-1.5 w-2 h-2 bg-primary-500 rounded-full" />
            </button>

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

      {/* Mobile Search Modal */}
      <MobileSearchModal isOpen={isMobileSearchOpen} onClose={handleMobileSearchClose} />
    </>
  );
});

export default Header;

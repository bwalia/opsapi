'use client';

import React, { memo, useCallback, useMemo } from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import {
  LayoutDashboard,
  Users,
  ShoppingCart,
  Package,
  Store,
  Settings,
  FileText,
  Truck,
  MessageSquare,
  BarChart3,
  LogOut,
  UserCircle,
  X,
  ChevronLeft,
  Shield,
  Building2,
} from 'lucide-react';
import { cn } from '@/lib/utils';
import { useAuthStore } from '@/store/auth.store';
import { usePermissions } from '@/contexts/PermissionsContext';
import { RoleBadge } from '@/components/permissions';
import type { DashboardModule } from '@/types';

interface NavItem {
  name: string;
  href: string;
  icon: React.ElementType;
  badge?: number;
  module?: DashboardModule; // Permission module to check
  adminOnly?: boolean; // Show only for admins
}

const navigation: NavItem[] = [
  { name: 'Dashboard', href: '/dashboard', icon: LayoutDashboard, module: 'dashboard' },
  { name: 'My Workspace', href: '/dashboard/namespace', icon: Building2 },
  { name: 'All Namespaces', href: '/dashboard/namespaces', icon: Building2, module: 'namespaces', adminOnly: true },
  { name: 'Users', href: '/dashboard/users', icon: Users, module: 'users' },
  { name: 'Roles', href: '/dashboard/roles', icon: Shield, module: 'roles', adminOnly: true },
  { name: 'Orders', href: '/dashboard/orders', icon: ShoppingCart, module: 'orders' },
  { name: 'Products', href: '/dashboard/products', icon: Package, module: 'products' },
  { name: 'Stores', href: '/dashboard/stores', icon: Store, module: 'stores' },
  { name: 'Customers', href: '/dashboard/customers', icon: UserCircle, module: 'customers' },
  { name: 'Delivery', href: '/dashboard/delivery', icon: Truck },
  { name: 'Chat', href: '/dashboard/chat', icon: MessageSquare },
  { name: 'Reports', href: '/dashboard/reports', icon: BarChart3 },
  { name: 'Documents', href: '/dashboard/documents', icon: FileText },
];

const secondaryNavigation: NavItem[] = [
  { name: 'Settings', href: '/dashboard/settings', icon: Settings, module: 'settings' },
];

interface SidebarProps {
  isOpen: boolean;
  isCollapsed: boolean;
  onClose: () => void;
  onToggleCollapse: () => void;
}

// Memoized nav item component
const NavItemLink = memo(function NavItemLink({
  item,
  isActive,
  isCollapsed,
  onClick,
}: {
  item: NavItem;
  isActive: boolean;
  isCollapsed: boolean;
  onClick?: () => void;
}) {
  const Icon = item.icon;

  return (
    <Link
      href={item.href}
      onClick={onClick}
      className={cn(
        'flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium transition-all duration-200',
        isCollapsed && 'justify-center px-2',
        isActive
          ? 'bg-primary-500/10 text-primary-500 border-l-4 border-primary-500 ml-0 pl-2'
          : 'text-secondary-600 hover:bg-secondary-100 hover:text-secondary-900'
      )}
      title={isCollapsed ? item.name : undefined}
    >
      <Icon className={cn('w-5 h-5 flex-shrink-0', isActive && 'text-primary-500')} />
      {!isCollapsed && (
        <>
          <span className="flex-1 truncate">{item.name}</span>
          {item.badge !== undefined && (
            <span className="px-2 py-0.5 text-xs font-medium bg-primary-500 text-white rounded-full">
              {item.badge}
            </span>
          )}
        </>
      )}
    </Link>
  );
});

const Sidebar: React.FC<SidebarProps> = memo(function Sidebar({
  isOpen,
  isCollapsed,
  onClose,
  onToggleCollapse,
}) {
  const pathname = usePathname();
  const { user } = useAuthStore();
  const logout = useAuthStore((state) => state.logout);
  const { canAccess, isAdmin, userRole, isLoading } = usePermissions();

  // Filter navigation items based on permissions
  const filteredNavigation = useMemo(() => {
    if (isLoading) return [];

    return navigation.filter((item) => {
      // Admin-only items
      if (item.adminOnly && !isAdmin) return false;

      // Items without module requirement are always shown
      if (!item.module) return true;

      // Check if user can access the module
      return canAccess(item.module);
    });
  }, [canAccess, isAdmin, isLoading]);

  const filteredSecondaryNav = useMemo(() => {
    if (isLoading) return [];

    return secondaryNavigation.filter((item) => {
      if (!item.module) return true;
      return canAccess(item.module);
    });
  }, [canAccess, isLoading]);

  const handleLogout = useCallback(async () => {
    await logout();
    window.location.href = '/login';
  }, [logout]);

  const handleNavClick = useCallback(() => {
    // Close mobile menu on navigation
    if (window.innerWidth < 1024) {
      onClose();
    }
  }, [onClose]);

  return (
    <>
      {/* Mobile Overlay */}
      <div
        className={cn(
          'fixed inset-0 bg-secondary-900/50 backdrop-blur-sm z-40 lg:hidden transition-opacity duration-300',
          isOpen ? 'opacity-100' : 'opacity-0 pointer-events-none'
        )}
        onClick={onClose}
        aria-hidden="true"
      />

      {/* Sidebar */}
      <aside
        className={cn(
          'fixed left-0 top-0 z-50 h-screen bg-white border-r border-secondary-200 transition-all duration-300 flex flex-col',
          // Mobile: slide in/out
          'lg:translate-x-0',
          isOpen ? 'translate-x-0' : '-translate-x-full',
          // Desktop: collapsed or expanded
          isCollapsed ? 'lg:w-20' : 'lg:w-64',
          // Mobile always full width sidebar
          'w-72'
        )}
      >
        {/* Logo Header */}
        <div className="flex items-center justify-between h-16 px-4 border-b border-secondary-200 flex-shrink-0">
          <Link href="/dashboard" className="flex items-center gap-3" onClick={handleNavClick}>
            <div className="w-10 h-10 gradient-primary rounded-xl flex items-center justify-center shadow-lg shadow-primary-500/25 flex-shrink-0">
              <span className="text-white font-bold text-xl">O</span>
            </div>
            {!isCollapsed && (
              <div className="hidden lg:block">
                <span className="text-lg font-bold text-secondary-900">OpsAPI</span>
                <p className="text-xs text-secondary-400">Dashboard</p>
              </div>
            )}
            {/* Always show title on mobile */}
            <div className="lg:hidden">
              <span className="text-lg font-bold text-secondary-900">OpsAPI</span>
              <p className="text-xs text-secondary-400">Dashboard</p>
            </div>
          </Link>

          {/* Mobile Close Button */}
          <button
            onClick={onClose}
            className="lg:hidden p-2 text-secondary-500 hover:text-secondary-700 hover:bg-secondary-100 rounded-lg"
            aria-label="Close menu"
          >
            <X className="w-5 h-5" />
          </button>

          {/* Desktop Collapse Toggle */}
          <button
            onClick={onToggleCollapse}
            className="hidden lg:flex p-1.5 text-secondary-400 hover:text-secondary-600 hover:bg-secondary-100 rounded-lg transition-colors"
            aria-label={isCollapsed ? 'Expand sidebar' : 'Collapse sidebar'}
          >
            <ChevronLeft
              className={cn('w-4 h-4 transition-transform duration-300', isCollapsed && 'rotate-180')}
            />
          </button>
        </div>

        {/* User Role Badge (visible when not collapsed) */}
        {!isCollapsed && userRole && (
          <div className="px-4 py-3 border-b border-secondary-100">
            <div className="flex items-center gap-2">
              <div className="w-8 h-8 gradient-primary rounded-lg flex items-center justify-center text-white text-xs font-semibold">
                {user?.first_name?.[0]}{user?.last_name?.[0]}
              </div>
              <div className="flex-1 min-w-0">
                <p className="text-sm font-medium text-secondary-900 truncate">
                  {user?.first_name} {user?.last_name}
                </p>
                <RoleBadge roleName={userRole} size="sm" showIcon={false} />
              </div>
            </div>
          </div>
        )}

        {/* Navigation */}
        <nav className="flex flex-col flex-1 p-4 overflow-hidden">
          <div className="flex-1 space-y-1 overflow-y-auto scrollbar-thin">
            {!isCollapsed && (
              <p className="px-3 mb-2 text-xs font-semibold text-secondary-400 uppercase tracking-wider">
                Main Menu
              </p>
            )}
            {filteredNavigation.map((item) => (
              <NavItemLink
                key={item.name}
                item={item}
                isActive={pathname === item.href}
                isCollapsed={isCollapsed}
                onClick={handleNavClick}
              />
            ))}
          </div>

          {/* Secondary Navigation */}
          <div className="pt-4 mt-4 border-t border-secondary-200 space-y-1 flex-shrink-0">
            {!isCollapsed && (
              <p className="px-3 mb-2 text-xs font-semibold text-secondary-400 uppercase tracking-wider">
                Settings
              </p>
            )}
            {filteredSecondaryNav.map((item) => (
              <NavItemLink
                key={item.name}
                item={item}
                isActive={pathname === item.href}
                isCollapsed={isCollapsed}
                onClick={handleNavClick}
              />
            ))}

            <button
              onClick={handleLogout}
              className={cn(
                'flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium transition-all duration-200 w-full',
                'text-secondary-600 hover:bg-error-50 hover:text-error-600',
                isCollapsed && 'justify-center px-2'
              )}
              title={isCollapsed ? 'Logout' : undefined}
            >
              <LogOut className="w-5 h-5 flex-shrink-0" />
              {!isCollapsed && <span>Logout</span>}
            </button>
          </div>
        </nav>
      </aside>
    </>
  );
});

export default Sidebar;

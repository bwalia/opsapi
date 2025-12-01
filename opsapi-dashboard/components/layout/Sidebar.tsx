'use client';

import React from 'react';
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
} from 'lucide-react';
import { cn } from '@/lib/utils';
import { useAuthStore } from '@/store/auth.store';

interface NavItem {
  name: string;
  href: string;
  icon: React.ElementType;
  badge?: number;
}

const navigation: NavItem[] = [
  { name: 'Dashboard', href: '/dashboard', icon: LayoutDashboard },
  { name: 'Users', href: '/dashboard/users', icon: Users },
  { name: 'Orders', href: '/dashboard/orders', icon: ShoppingCart },
  { name: 'Products', href: '/dashboard/products', icon: Package },
  { name: 'Stores', href: '/dashboard/stores', icon: Store },
  { name: 'Customers', href: '/dashboard/customers', icon: UserCircle },
  { name: 'Delivery', href: '/dashboard/delivery', icon: Truck },
  { name: 'Chat', href: '/dashboard/chat', icon: MessageSquare },
  { name: 'Reports', href: '/dashboard/reports', icon: BarChart3 },
  { name: 'Documents', href: '/dashboard/documents', icon: FileText },
];

const secondaryNavigation: NavItem[] = [
  { name: 'Settings', href: '/dashboard/settings', icon: Settings },
];

interface SidebarProps {
  isCollapsed?: boolean;
}

const Sidebar: React.FC<SidebarProps> = ({ isCollapsed = false }) => {
  const pathname = usePathname();
  const logout = useAuthStore((state) => state.logout);

  const handleLogout = async () => {
    await logout();
    window.location.href = '/login';
  };

  const renderNavItem = (item: NavItem) => {
    const isActive = pathname === item.href;
    const Icon = item.icon;

    return (
      <Link
        key={item.name}
        href={item.href}
        className={cn(
          'flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium transition-all duration-200',
          isActive
            ? 'bg-primary-500/10 text-primary-500 border-l-4 border-primary-500 ml-0 pl-2'
            : 'text-secondary-600 hover:bg-secondary-100 hover:text-secondary-900'
        )}
      >
        <Icon className={cn('w-5 h-5 flex-shrink-0', isActive && 'text-primary-500')} />
        {!isCollapsed && (
          <>
            <span className="flex-1">{item.name}</span>
            {item.badge !== undefined && (
              <span className="px-2 py-0.5 text-xs font-medium bg-primary-500 text-white rounded-full">
                {item.badge}
              </span>
            )}
          </>
        )}
      </Link>
    );
  };

  return (
    <aside
      className={cn(
        'fixed left-0 top-0 z-40 h-screen bg-white border-r border-secondary-200 transition-all duration-300',
        isCollapsed ? 'w-20' : 'w-64'
      )}
    >
      {/* Logo */}
      <div className="flex items-center h-16 px-6 border-b border-secondary-200">
        <Link href="/dashboard" className="flex items-center gap-3">
          <div className="w-10 h-10 gradient-primary rounded-xl flex items-center justify-center shadow-lg shadow-primary-500/25">
            <span className="text-white font-bold text-xl">O</span>
          </div>
          {!isCollapsed && (
            <div>
              <span className="text-lg font-bold text-secondary-900">OpsAPI</span>
              <p className="text-xs text-secondary-400">Dashboard</p>
            </div>
          )}
        </Link>
      </div>

      {/* Navigation */}
      <nav className="flex flex-col h-[calc(100vh-4rem)] p-4">
        <div className="flex-1 space-y-1 overflow-y-auto">
          <p className="px-3 mb-2 text-xs font-semibold text-secondary-400 uppercase tracking-wider">
            Main Menu
          </p>
          {navigation.map(renderNavItem)}
        </div>

        {/* Secondary Navigation */}
        <div className="pt-4 mt-4 border-t border-secondary-200 space-y-1">
          <p className="px-3 mb-2 text-xs font-semibold text-secondary-400 uppercase tracking-wider">
            Settings
          </p>
          {secondaryNavigation.map(renderNavItem)}

          <button
            onClick={handleLogout}
            className={cn(
              'flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium transition-all duration-200 w-full',
              'text-secondary-600 hover:bg-error-50 hover:text-error-600'
            )}
          >
            <LogOut className="w-5 h-5 flex-shrink-0" />
            {!isCollapsed && <span>Logout</span>}
          </button>
        </div>
      </nav>
    </aside>
  );
};

export default Sidebar;

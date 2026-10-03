'use client';

import React from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import {
  LayoutDashboard,
  Package,
  FolderTree,
  Boxes,
  ShoppingCart,
  FileText,
  MessageSquare,
  BookOpen,
  LineChart,
} from 'lucide-react';
import { cn } from '@/lib/utils';

export const SHOP_SECTIONS = [
  { href: '/dashboard/shop', label: 'Overview', icon: LayoutDashboard, exact: true },
  { href: '/dashboard/shop/products', label: 'Products', icon: Package },
  { href: '/dashboard/shop/categories', label: 'Categories', icon: FolderTree },
  { href: '/dashboard/shop/stock', label: 'Stock', icon: Boxes },
  { href: '/dashboard/shop/market', label: 'Market', icon: LineChart },
  { href: '/dashboard/shop/orders', label: 'Orders', icon: ShoppingCart },
  { href: '/dashboard/shop/quotes', label: 'Quotes', icon: FileText },
  { href: '/dashboard/shop/chats', label: 'Chats', icon: MessageSquare },
  { href: '/dashboard/shop/knowledge', label: 'Knowledge', icon: BookOpen },
] as const;

/** In-section sub-navigation shared by every /dashboard/shop page. */
export function ShopNav() {
  const pathname = usePathname() || '';
  return (
    <div className="border-b border-secondary-200 print:hidden">
      <nav className="-mb-px flex gap-1 overflow-x-auto" aria-label="Shop sections">
        {SHOP_SECTIONS.map((s) => {
          const active = 'exact' in s && s.exact ? pathname === s.href : pathname.startsWith(s.href);
          const Icon = s.icon;
          return (
            <Link
              key={s.href}
              href={s.href}
              aria-current={active ? 'page' : undefined}
              className={cn(
                'inline-flex shrink-0 items-center gap-2 border-b-2 px-4 py-2.5 text-sm font-medium transition-colors',
                active
                  ? 'border-primary-500 text-primary-600'
                  : 'border-transparent text-secondary-500 hover:border-secondary-300 hover:text-secondary-700'
              )}
            >
              <Icon className="h-4 w-4" aria-hidden="true" />
              {s.label}
            </Link>
          );
        })}
      </nav>
    </div>
  );
}

export default ShopNav;

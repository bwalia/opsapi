/**
 * useMenu Hook
 *
 * Custom hook for accessing and managing the backend-driven menu.
 * Automatically fetches menu on mount and when namespace changes.
 *
 * The backend is the SINGLE SOURCE OF TRUTH for navigation.
 * No permission filtering logic should exist on the frontend.
 *
 * @module hooks/useMenu
 */

'use client';

import { useEffect, useCallback, useMemo, useState } from 'react';
import { useMenuStore, useMenuHydrated } from '@/store/menu.store';
import { useNamespaceStore } from '@/store/namespace.store';
import { useAuthStore } from '@/store/auth.store';
import type { MenuItem, MenuNamespaceContext } from '@/types';

// Import only the type and default icon - other icons loaded dynamically
import { HelpCircle, type LucideIcon } from 'lucide-react';

// Default fallback icon (imported statically as it's always needed)
const DEFAULT_ICON: LucideIcon = HelpCircle;

// Lazy-loaded icon map - icons are loaded on first use
// This prevents the entire Lucide library from being bundled on initial load
let ICON_MAP: Record<string, LucideIcon> | null = null;

// Async icon loader - populated on first call
async function loadIconMap(): Promise<Record<string, LucideIcon>> {
  if (ICON_MAP) return ICON_MAP;

  const icons = await import('lucide-react');
  ICON_MAP = {
    LayoutDashboard: icons.LayoutDashboard,
    Users: icons.Users,
    ShoppingCart: icons.ShoppingCart,
    Package: icons.Package,
    Store: icons.Store,
    Settings: icons.Settings,
    Truck: icons.Truck,
    MessageSquare: icons.MessageSquare,
    BarChart3: icons.BarChart3,
    UserCircle: icons.UserCircle,
    Shield: icons.Shield,
    Building2: icons.Building2,
    Rocket: icons.Rocket,
    Kanban: icons.Kanban,
    HelpCircle: icons.HelpCircle,
  };
  return ICON_MAP;
}

// Synchronous icon getter - returns default if map not loaded yet
function getIconFromMap(iconName: string): LucideIcon {
  if (!ICON_MAP) return DEFAULT_ICON;
  return ICON_MAP[iconName] ?? DEFAULT_ICON;
}

/**
 * Extended menu item with resolved icon component
 */
export interface MenuItemWithIcon extends MenuItem {
  IconComponent: LucideIcon;
}

/**
 * Hook return type
 */
export interface UseMenuReturn {
  // Menu items with resolved icons
  mainMenu: MenuItemWithIcon[];
  secondaryMenu: MenuItemWithIcon[];
  allMenu: MenuItemWithIcon[];

  // Loading states
  isLoading: boolean;
  isHydrated: boolean;

  // Error state
  error: string | null;

  // Context - explicitly typed
  namespaceContext: MenuNamespaceContext | null;
  isAdmin: boolean;

  // Actions
  refreshMenu: () => Promise<void>;
  clearError: () => void;

  // Utilities
  getIconForKey: (key: string) => LucideIcon;
  canAccessPath: (path: string) => boolean;
}

/**
 * Get Lucide icon component from icon name
 * @param iconName - The icon name from the backend
 * @returns The corresponding Lucide icon component or default icon
 */
function getIconComponent(iconName: string | null | undefined): LucideIcon {
  try {
    if (!iconName || typeof iconName !== 'string') {
      return DEFAULT_ICON;
    }
    return getIconFromMap(iconName);
  } catch {
    return DEFAULT_ICON;
  }
}

/**
 * Transform menu items to include resolved icon components
 * Handles edge cases like undefined/null items
 * @param items - Array of menu items from the API
 * @returns Array of menu items with resolved icon components
 */
function transformMenuItems(items: MenuItem[] | null | undefined): MenuItemWithIcon[] {
  try {
    if (!items || !Array.isArray(items)) {
      return [];
    }

    return items
      .filter((item): item is MenuItem => {
        // Filter out invalid items
        return item !== null && item !== undefined && typeof item === 'object' && 'key' in item;
      })
      .map((item) => ({
        ...item,
        IconComponent: getIconComponent(item.icon),
      }));
  } catch {
    // Return empty array on any transformation error
    return [];
  }
}

/**
 * Main menu hook
 *
 * Usage:
 * ```tsx
 * const { mainMenu, secondaryMenu, isLoading, error } = useMenu();
 *
 * return (
 *   <nav>
 *     {mainMenu.map((item) => (
 *       <Link key={item.key} href={item.path}>
 *         <item.IconComponent />
 *         {item.name}
 *       </Link>
 *     ))}
 *   </nav>
 * );
 * ```
 */
export function useMenu(): UseMenuReturn {
  // Track if icons are loaded (for re-rendering after lazy load)
  const [iconsLoaded, setIconsLoaded] = useState(!!ICON_MAP);

  // Get menu state from store with safe defaults
  const rawMainMenu = useMenuStore((state) => state.mainMenu ?? []);
  const rawSecondaryMenu = useMenuStore((state) => state.secondaryMenu ?? []);
  const rawMenu = useMenuStore((state) => state.menu ?? []);
  const isLoading = useMenuStore((state) => state.isLoading ?? false);
  const error = useMenuStore((state) => state.error ?? null);
  const namespaceContext = useMenuStore((state) => state.namespaceContext ?? null);
  const isAdmin = useMenuStore((state) => state.isAdmin ?? false);
  const fetchMenu = useMenuStore((state) => state.fetchMenu);
  const isCacheStale = useMenuStore((state) => state.isCacheStale);
  const clearErrorFn = useMenuStore((state) => state.clearError);

  // Get namespace state to detect changes
  const currentNamespace = useNamespaceStore((state) => state.currentNamespace);
  const namespaceHydrated = useNamespaceStore((state) => state._hasHydrated ?? false);

  // Get current user to detect user changes (for cache invalidation)
  const currentUser = useAuthStore((state) => state.user);
  const authHydrated = useAuthStore((state) => state._hasHydrated ?? false);

  // Get menu hydration state
  const menuHydrated = useMenuHydrated();

  // Lazy load icons on mount (deferred to avoid blocking initial render)
  useEffect(() => {
    if (!iconsLoaded) {
      // Use requestIdleCallback if available, otherwise setTimeout
      const loadIcons = () => {
        loadIconMap().then(() => setIconsLoaded(true));
      };

      if ('requestIdleCallback' in window) {
        (window as Window & { requestIdleCallback: (cb: () => void) => number }).requestIdleCallback(loadIcons);
      } else {
        setTimeout(loadIcons, 100);
      }
    }
  }, [iconsLoaded]);

  // Transform menu items to include icon components (memoized)
  // Include iconsLoaded to trigger re-render when icons finish loading
  const mainMenu = useMemo(
    () => transformMenuItems(rawMainMenu),
    [rawMainMenu, iconsLoaded]
  );

  const secondaryMenu = useMemo(
    () => transformMenuItems(rawSecondaryMenu),
    [rawSecondaryMenu, iconsLoaded]
  );

  const allMenu = useMemo(
    () => transformMenuItems(rawMenu),
    [rawMenu, iconsLoaded]
  );

  // Refresh menu handler with error handling
  const refreshMenu = useCallback(async (): Promise<void> => {
    try {
      if (typeof fetchMenu === 'function') {
        await fetchMenu({ force: true, userUuid: currentUser?.uuid });
      }
    } catch (err) {
      // Error is handled in the store, but we catch here to prevent unhandled promise rejections
      console.error('[useMenu] Failed to refresh menu:', err);
    }
  }, [fetchMenu, currentUser?.uuid]);

  // Get icon for a menu key
  const getIconForKey = useCallback((key: string): LucideIcon => {
    try {
      if (!key || typeof key !== 'string') {
        return DEFAULT_ICON;
      }
      const item = rawMenu.find((m) => m?.key === key);
      return getIconComponent(item?.icon);
    } catch {
      return DEFAULT_ICON;
    }
  }, [rawMenu]);

  // Check if user can access a path (for programmatic use)
  const canAccessPath = useCallback((path: string): boolean => {
    try {
      if (!path || typeof path !== 'string') {
        return false;
      }
      return rawMenu.some((item) => item?.path === path);
    } catch {
      return false;
    }
  }, [rawMenu]);

  // Clear error handler
  const clearError = useCallback((): void => {
    try {
      if (typeof clearErrorFn === 'function') {
        clearErrorFn();
      }
    } catch {
      // Silently ignore errors when clearing error state
    }
  }, [clearErrorFn]);

  // Fetch menu on mount and when namespace or user changes
  useEffect(() => {
    // Wait for all stores to hydrate
    if (!menuHydrated || !namespaceHydrated || !authHydrated) {
      return;
    }

    // Fetch if cache is stale, namespace changed, or user changed
    const namespaceUuid = currentNamespace?.uuid;
    const userUuid = currentUser?.uuid;

    try {
      const shouldFetch = typeof isCacheStale === 'function'
        ? isCacheStale(namespaceUuid, userUuid)
        : true;

      if (shouldFetch && typeof fetchMenu === 'function') {
        // Pass userUuid to fetchMenu so it can be stored for cache invalidation
        fetchMenu({ force: true, userUuid }).catch((err) => {
          // Error is handled in the store
          console.error('[useMenu] Error fetching menu on mount:', err);
        });
      }
    } catch (err) {
      console.error('[useMenu] Error checking cache staleness:', err);
    }
  }, [
    menuHydrated,
    namespaceHydrated,
    authHydrated,
    currentNamespace?.uuid,
    currentUser?.uuid,
    isCacheStale,
    fetchMenu,
  ]);

  return {
    mainMenu,
    secondaryMenu,
    allMenu,
    isLoading,
    isHydrated: Boolean(menuHydrated && namespaceHydrated && authHydrated),
    error,
    namespaceContext,
    isAdmin,
    refreshMenu,
    clearError,
    getIconForKey,
    canAccessPath,
  };
}

export default useMenu;

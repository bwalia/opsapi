/**
 * Menu Store (Backend-Driven Navigation)
 *
 * Manages the user's menu state fetched from the backend.
 * The backend is the SINGLE SOURCE OF TRUTH for menu items.
 * All permission filtering happens on the server, not the client.
 *
 * Features:
 * - Caches menu items with automatic refresh on namespace change
 * - Supports stale-while-revalidate pattern for fast loading
 * - Integrates with namespace store for context awareness
 * - Comprehensive error handling for production stability
 *
 * @module store/menu.store
 */

import { create } from 'zustand';
import { persist } from 'zustand/middleware';
import type {
  MenuItem,
  MenuResponse,
  MenuNamespaceContext,
  NamespacePermissions,
} from '@/types';
import { menuService } from '@/services/menu.service';

// Cache duration: 5 minutes (menus don't change frequently)
const CACHE_DURATION_MS = 5 * 60 * 1000;

/**
 * Menu store state interface
 */
export interface MenuState {
  // Menu items
  menu: MenuItem[];
  mainMenu: MenuItem[];
  secondaryMenu: MenuItem[];

  // Loading and error states
  isLoading: boolean;
  error: string | null;

  // Cache management
  lastFetched: number | null;
  lastNamespaceUuid: string | null;
  lastUserUuid: string | null; // Track user to invalidate cache on user change

  // Context from API response
  namespaceContext: MenuNamespaceContext | null;
  permissions: NamespacePermissions | null;
  isAdmin: boolean;

  // Hydration state
  _hasHydrated: boolean;
}

/**
 * Menu store actions interface
 */
export interface MenuActions {
  // Set hydration state
  setHasHydrated: (state: boolean) => void;

  // Fetch menu from API
  fetchMenu: (options?: { force?: boolean; userUuid?: string }) => Promise<void>;

  // Clear menu (on logout or namespace switch)
  clearMenu: () => void;

  // Check if cache is stale
  isCacheStale: (namespaceUuid?: string, userUuid?: string) => boolean;

  // Get menu item by key
  getMenuItemByKey: (key: string) => MenuItem | undefined;

  // Check if user can access a specific menu
  canAccessMenu: (key: string) => boolean;

  // Clear error
  clearError: () => void;
}

/**
 * Combined menu store type
 */
export type MenuStore = MenuState & MenuActions;

/**
 * Initial state for the menu store
 */
const initialState: MenuState = {
  menu: [],
  mainMenu: [],
  secondaryMenu: [],
  isLoading: false,
  error: null,
  lastFetched: null,
  lastNamespaceUuid: null,
  lastUserUuid: null,
  namespaceContext: null,
  permissions: null,
  isAdmin: false,
  _hasHydrated: false,
};

/**
 * Safely extract error message from unknown error
 */
function getErrorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }
  if (typeof error === 'string') {
    return error;
  }
  if (error && typeof error === 'object' && 'message' in error) {
    return String((error as { message: unknown }).message);
  }
  return 'An unexpected error occurred while fetching the menu';
}

/**
 * Safely parse menu response with fallbacks
 */
function parseMenuResponse(response: MenuResponse | null | undefined): Partial<MenuState> {
  if (!response || typeof response !== 'object') {
    return {
      menu: [],
      mainMenu: [],
      secondaryMenu: [],
      namespaceContext: null,
      permissions: null,
      isAdmin: false,
    };
  }

  return {
    menu: Array.isArray(response.menu) ? response.menu : [],
    mainMenu: Array.isArray(response.main_menu) ? response.main_menu : [],
    secondaryMenu: Array.isArray(response.secondary_menu) ? response.secondary_menu : [],
    namespaceContext: response.namespace ?? null,
    permissions: response.permissions ?? null,
    isAdmin: Boolean(response.is_admin),
    lastNamespaceUuid: response.namespace?.uuid ?? null,
  };
}

/**
 * Menu store using Zustand with persistence
 */
export const useMenuStore = create<MenuStore>()(
  persist(
    (set, get) => ({
      // Initial state
      ...initialState,

      setHasHydrated: (state: boolean): void => {
        try {
          set({ _hasHydrated: Boolean(state) });
        } catch (err) {
          console.error('[MenuStore] Failed to set hydration state:', err);
        }
      },

      fetchMenu: async (options = {}): Promise<void> => {
        const { force = false, userUuid } = options ?? {};

        try {
          const state = get();

          // Skip if already loading
          if (state.isLoading) {
            return;
          }

          // Skip if cache is still valid and not forced
          if (!force) {
            try {
              if (!state.isCacheStale()) {
                return;
              }
            } catch {
              // If isCacheStale fails, proceed with fetch
            }
          }

          set({ isLoading: true, error: null });

          try {
            const response = await menuService.getUserMenu();
            const parsedResponse = parseMenuResponse(response);

            set({
              ...parsedResponse,
              lastFetched: Date.now(),
              lastUserUuid: userUuid ?? state.lastUserUuid, // Track user UUID for cache invalidation
              isLoading: false,
              error: null,
            });
          } catch (fetchError) {
            const errorMessage = getErrorMessage(fetchError);
            set({
              error: errorMessage,
              isLoading: false,
            });
            // Don't clear existing menu on error - keep stale data for better UX
          }
        } catch (outerError) {
          // Catch any unexpected errors in the outer try block
          console.error('[MenuStore] Unexpected error in fetchMenu:', outerError);
          set({
            error: 'Failed to fetch menu. Please try again.',
            isLoading: false,
          });
        }
      },

      clearMenu: (): void => {
        try {
          set({
            menu: [],
            mainMenu: [],
            secondaryMenu: [],
            lastFetched: null,
            lastNamespaceUuid: null,
            lastUserUuid: null,
            namespaceContext: null,
            permissions: null,
            isAdmin: false,
            error: null,
          });
        } catch (err) {
          console.error('[MenuStore] Failed to clear menu:', err);
        }
      },

      isCacheStale: (namespaceUuid?: string, userUuid?: string): boolean => {
        try {
          const { lastFetched, lastNamespaceUuid, lastUserUuid } = get();

          // No cache exists
          if (!lastFetched || typeof lastFetched !== 'number') {
            return true;
          }

          // User changed (different user logged in)
          if (userUuid && typeof userUuid === 'string') {
            if (userUuid !== lastUserUuid) {
              return true;
            }
          }

          // Namespace changed
          if (namespaceUuid && typeof namespaceUuid === 'string') {
            if (namespaceUuid !== lastNamespaceUuid) {
              return true;
            }
          }

          // Cache expired
          const age = Date.now() - lastFetched;
          return age > CACHE_DURATION_MS;
        } catch (err) {
          console.error('[MenuStore] Error checking cache staleness:', err);
          return true; // Assume stale on error
        }
      },

      getMenuItemByKey: (key: string): MenuItem | undefined => {
        try {
          if (!key || typeof key !== 'string') {
            return undefined;
          }
          const { menu } = get();
          if (!Array.isArray(menu)) {
            return undefined;
          }
          return menu.find((item) => item?.key === key);
        } catch (err) {
          console.error('[MenuStore] Error getting menu item by key:', err);
          return undefined;
        }
      },

      canAccessMenu: (key: string): boolean => {
        try {
          if (!key || typeof key !== 'string') {
            return false;
          }
          const { menu } = get();
          if (!Array.isArray(menu)) {
            return false;
          }
          return menu.some((item) => item?.key === key);
        } catch (err) {
          console.error('[MenuStore] Error checking menu access:', err);
          return false;
        }
      },

      clearError: (): void => {
        try {
          set({ error: null });
        } catch (err) {
          console.error('[MenuStore] Failed to clear error:', err);
        }
      },
    }),
    {
      name: 'menu-storage',
      partialize: (state): Partial<MenuState> => ({
        menu: state.menu,
        mainMenu: state.mainMenu,
        secondaryMenu: state.secondaryMenu,
        lastFetched: state.lastFetched,
        lastNamespaceUuid: state.lastNamespaceUuid,
        lastUserUuid: state.lastUserUuid,
        namespaceContext: state.namespaceContext,
        permissions: state.permissions,
        isAdmin: state.isAdmin,
      }),
      onRehydrateStorage: () => (state): void => {
        try {
          if (state && typeof state.setHasHydrated === 'function') {
            state.setHasHydrated(true);
          }
        } catch (err) {
          console.error('[MenuStore] Error during rehydration:', err);
        }
      },
    }
  )
);

/**
 * Hook to check if menu store has hydrated from localStorage
 */
export const useMenuHydrated = (): boolean => {
  try {
    return useMenuStore((state) => state._hasHydrated ?? false);
  } catch {
    return false;
  }
};

export default useMenuStore;

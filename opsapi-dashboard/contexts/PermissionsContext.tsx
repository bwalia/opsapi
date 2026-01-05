'use client';

import React, {
  createContext,
  useContext,
  useState,
  useEffect,
  useCallback,
  useMemo,
  ReactNode,
} from 'react';
import { useAuthStore } from '@/store/auth.store';
import { useNamespaceStore } from '@/store/namespace.store';
import { permissionsService } from '@/services';
import type { User, UserPermissions, DashboardModule, PermissionAction, NamespacePermissions, NamespaceModule } from '@/types';

// Subscribe to namespace store hydration state
const useNamespaceHydrated = () => {
  const [hydrated, setHydrated] = useState(false);

  useEffect(() => {
    // Check initial state
    const state = useNamespaceStore.getState();
    if (state._hasHydrated) {
      setHydrated(true);
      return;
    }

    // Subscribe to changes
    const unsubscribe = useNamespaceStore.subscribe((state) => {
      if (state._hasHydrated) {
        setHydrated(true);
      }
    });

    return () => unsubscribe();
  }, []);

  return hydrated;
};

interface PermissionsContextValue {
  permissions: UserPermissions;
  namespacePermissions: NamespacePermissions | null;
  isLoading: boolean;
  userRole: string | null;
  namespaceRole: string | null;
  isNamespaceOwner: boolean;
  hasPermission: (module: DashboardModule | NamespaceModule, action: PermissionAction) => boolean;
  canAccess: (module: DashboardModule | NamespaceModule) => boolean;
  canCreate: (module: DashboardModule | NamespaceModule) => boolean;
  canRead: (module: DashboardModule | NamespaceModule) => boolean;
  canUpdate: (module: DashboardModule | NamespaceModule) => boolean;
  canDelete: (module: DashboardModule | NamespaceModule) => boolean;
  canManage: (module: DashboardModule | NamespaceModule) => boolean;
  isAdmin: boolean;
  refreshPermissions: () => Promise<void>;
}

const defaultPermissions: UserPermissions = {
  dashboard: [],
  users: [],
  roles: [],
  stores: [],
  products: [],
  orders: [],
  customers: [],
  settings: [],
  namespaces: [],
  services: [],
};

const PermissionsContext = createContext<PermissionsContextValue>({
  permissions: defaultPermissions,
  namespacePermissions: null,
  isLoading: true,
  userRole: null,
  namespaceRole: null,
  isNamespaceOwner: false,
  hasPermission: () => false,
  canAccess: () => false,
  canCreate: () => false,
  canRead: () => false,
  canUpdate: () => false,
  canDelete: () => false,
  canManage: () => false,
  isAdmin: false,
  refreshPermissions: async () => {},
});

export function PermissionsProvider({ children }: { children: ReactNode }) {
  const { user, isAuthenticated } = useAuthStore();
  const {
    namespacePermissions: storeNamespacePermissions,
    isNamespaceOwner,
    currentNamespace
  } = useNamespaceStore();
  const [permissions, setPermissions] = useState<UserPermissions>(defaultPermissions);
  const [legacyPermissionsLoading, setLegacyPermissionsLoading] = useState(true);

  // Wait for namespace store to hydrate from localStorage
  const namespaceStoreHydrated = useNamespaceHydrated();

  // isLoading is true until BOTH legacy permissions are loaded AND namespace store is hydrated
  const isLoading = legacyPermissionsLoading || !namespaceStoreHydrated;

  // Extract primary role from user - handle multiple formats
  const userRole = useMemo(() => {
    if (!user) return null;

    // Cast user to handle various role formats from API/JWT
    const userData = user as User & {
      role?: string;
      roles?: Array<{ role_name?: string; name?: string }> | string;
    };

    // Handle roles as array (new format from API)
    if (userData.roles && Array.isArray(userData.roles) && userData.roles.length > 0) {
      const primaryRole = userData.roles[0];
      if (typeof primaryRole === 'string') {
        return primaryRole;
      }
      return primaryRole.role_name || primaryRole.name || null;
    }

    // Handle roles as comma-separated string (from JWT token)
    if (typeof userData.roles === 'string' && userData.roles.length > 0) {
      const firstRole = userData.roles.split(',')[0].trim();
      return firstRole || null;
    }

    // Handle role as string (legacy format)
    if (typeof userData.role === 'string' && userData.role.length > 0) {
      return userData.role;
    }

    return null;
  }, [user]);

  // Extract namespace role from user/JWT
  const namespaceRole = useMemo(() => {
    if (!user) return null;

    // Check if user has namespace info from JWT
    const userData = user as User & {
      namespace?: { role?: string };
    };

    if (userData.namespace?.role) {
      return userData.namespace.role;
    }

    return null;
  }, [user]);

  // Check if user is platform admin (has administrative role globally)
  const isAdmin = useMemo(() => {
    // First check derived userRole
    if (userRole?.toLowerCase() === 'administrative' || userRole?.toLowerCase() === 'admin') {
      return true;
    }

    // Also check user.roles directly for admin role
    if (user?.roles) {
      const roles = user.roles as unknown;
      if (Array.isArray(roles)) {
        const found = roles.some((r: unknown) => {
          const roleName = typeof r === 'string' ? r : ((r as { role_name?: string; name?: string })?.role_name || (r as { name?: string })?.name || '');
          return roleName.toLowerCase() === 'administrative' || roleName.toLowerCase() === 'admin';
        });
        if (found) {
          return true;
        }
      }
      if (typeof roles === 'string') {
        if (roles.toLowerCase().includes('administrative') || roles.toLowerCase().includes('admin')) {
          return true;
        }
      }
    }

    return false;
  }, [userRole, user]);

  // Load legacy permissions based on user role (fallback)
  const loadPermissions = useCallback(async () => {
    if (!isAuthenticated || !userRole) {
      setPermissions(defaultPermissions);
      setLegacyPermissionsLoading(false);
      return;
    }

    setLegacyPermissionsLoading(true);
    try {
      const userPermissions = await permissionsService.getPermissionsForRole(userRole);
      setPermissions(userPermissions);
    } catch (error) {
      console.error('Failed to load permissions:', error);
      // Fall back to default permissions
      setPermissions(permissionsService.getDefaultPermissions(userRole));
    } finally {
      setLegacyPermissionsLoading(false);
    }
  }, [isAuthenticated, userRole]);

  // Load permissions on mount and when role changes
  useEffect(() => {
    loadPermissions();
  }, [loadPermissions]);

  // Permission check - prioritizes namespace permissions over legacy permissions
  const hasPermission = useCallback(
    (module: DashboardModule | NamespaceModule, action: PermissionAction): boolean => {
      // Platform admin has all permissions
      if (isAdmin) return true;

      // Namespace owner has all permissions within their namespace
      if (isNamespaceOwner && currentNamespace) return true;

      // Check namespace permissions first (from store/JWT)
      if (storeNamespacePermissions) {
        const modulePerms = storeNamespacePermissions[module as NamespaceModule];
        if (modulePerms) {
          // Has manage = has all permissions
          if (modulePerms.includes('manage')) return true;
          // Check specific action
          if (modulePerms.includes(action)) return true;
        }
        // If we have namespace context, use namespace permissions exclusively
        if (currentNamespace) {
          return false;
        }
      }

      // Fall back to legacy permissions
      return permissionsService.hasPermission(permissions, module as DashboardModule, action);
    },
    [permissions, storeNamespacePermissions, isAdmin, isNamespaceOwner, currentNamespace]
  );

  const canAccess = useCallback(
    (module: DashboardModule | NamespaceModule): boolean => {
      if (isAdmin) return true;
      if (isNamespaceOwner && currentNamespace) return true;

      // When in namespace context, use namespace permissions exclusively
      if (currentNamespace) {
        // If we have namespace permissions, check them
        if (storeNamespacePermissions) {
          const modulePerms = storeNamespacePermissions[module as NamespaceModule];
          return Array.isArray(modulePerms) && modulePerms.length > 0;
        }
        // In namespace context but no permissions loaded = no access
        return false;
      }

      // Fall back to legacy permissions only when not in namespace context
      return permissionsService.canAccessModule(permissions, module as DashboardModule);
    },
    [permissions, storeNamespacePermissions, isAdmin, isNamespaceOwner, currentNamespace]
  );

  const canCreate = useCallback(
    (module: DashboardModule | NamespaceModule): boolean => hasPermission(module, 'create'),
    [hasPermission]
  );

  const canRead = useCallback(
    (module: DashboardModule | NamespaceModule): boolean => hasPermission(module, 'read'),
    [hasPermission]
  );

  const canUpdate = useCallback(
    (module: DashboardModule | NamespaceModule): boolean => hasPermission(module, 'update'),
    [hasPermission]
  );

  const canDelete = useCallback(
    (module: DashboardModule | NamespaceModule): boolean => hasPermission(module, 'delete'),
    [hasPermission]
  );

  const canManage = useCallback(
    (module: DashboardModule | NamespaceModule): boolean => hasPermission(module, 'manage'),
    [hasPermission]
  );

  const refreshPermissions = useCallback(async () => {
    await loadPermissions();
  }, [loadPermissions]);

  const value = useMemo(
    () => ({
      permissions,
      namespacePermissions: storeNamespacePermissions,
      isLoading,
      userRole,
      namespaceRole,
      isNamespaceOwner,
      hasPermission,
      canAccess,
      canCreate,
      canRead,
      canUpdate,
      canDelete,
      canManage,
      isAdmin,
      refreshPermissions,
    }),
    [
      permissions,
      storeNamespacePermissions,
      isLoading,
      userRole,
      namespaceRole,
      isNamespaceOwner,
      hasPermission,
      canAccess,
      canCreate,
      canRead,
      canUpdate,
      canDelete,
      canManage,
      isAdmin,
      refreshPermissions,
    ]
  );

  return <PermissionsContext.Provider value={value}>{children}</PermissionsContext.Provider>;
}

/**
 * Hook to access permissions context
 */
export function usePermissions() {
  const context = useContext(PermissionsContext);
  if (!context) {
    throw new Error('usePermissions must be used within a PermissionsProvider');
  }
  return context;
}

/**
 * Hook to check a specific permission
 */
export function useHasPermission(module: DashboardModule | NamespaceModule, action: PermissionAction): boolean {
  const { hasPermission } = usePermissions();
  return hasPermission(module, action);
}

/**
 * Hook to check module access
 */
export function useCanAccess(module: DashboardModule | NamespaceModule): boolean {
  const { canAccess } = usePermissions();
  return canAccess(module);
}

export default PermissionsContext;

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
import { permissionsService } from '@/services';
import type { UserPermissions, DashboardModule, PermissionAction } from '@/types';

interface PermissionsContextValue {
  permissions: UserPermissions;
  isLoading: boolean;
  userRole: string | null;
  hasPermission: (module: DashboardModule, action: PermissionAction) => boolean;
  canAccess: (module: DashboardModule) => boolean;
  canCreate: (module: DashboardModule) => boolean;
  canRead: (module: DashboardModule) => boolean;
  canUpdate: (module: DashboardModule) => boolean;
  canDelete: (module: DashboardModule) => boolean;
  canManage: (module: DashboardModule) => boolean;
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
};

const PermissionsContext = createContext<PermissionsContextValue>({
  permissions: defaultPermissions,
  isLoading: true,
  userRole: null,
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
  const [permissions, setPermissions] = useState<UserPermissions>(defaultPermissions);
  const [isLoading, setIsLoading] = useState(true);

  // Extract primary role from user - handle both array and string formats
  const userRole = useMemo(() => {
    if (!user) return null;

    // Handle roles as array (new format from API)
    if (user.roles && Array.isArray(user.roles) && user.roles.length > 0) {
      const primaryRole = user.roles[0];
      return primaryRole.role_name || primaryRole.name || null;
    }

    // Handle role as string (legacy format or from JWT token)
    if (typeof (user as unknown as { role?: string }).role === 'string') {
      return (user as unknown as { role: string }).role;
    }

    return null;
  }, [user]);

  // Check if user is admin
  const isAdmin = useMemo(() => {
    return userRole?.toLowerCase() === 'administrative' || userRole?.toLowerCase() === 'admin';
  }, [userRole]);

  // Load permissions based on user role
  const loadPermissions = useCallback(async () => {
    if (!isAuthenticated || !userRole) {
      setPermissions(defaultPermissions);
      setIsLoading(false);
      return;
    }

    setIsLoading(true);
    try {
      const userPermissions = await permissionsService.getPermissionsForRole(userRole);
      setPermissions(userPermissions);
    } catch (error) {
      console.error('Failed to load permissions:', error);
      // Fall back to default permissions
      setPermissions(permissionsService.getDefaultPermissions(userRole));
    } finally {
      setIsLoading(false);
    }
  }, [isAuthenticated, userRole]);

  // Load permissions on mount and when role changes
  useEffect(() => {
    loadPermissions();
  }, [loadPermissions]);

  // Permission check helpers
  const hasPermission = useCallback(
    (module: DashboardModule, action: PermissionAction): boolean => {
      // Admin has all permissions
      if (isAdmin) return true;
      return permissionsService.hasPermission(permissions, module, action);
    },
    [permissions, isAdmin]
  );

  const canAccess = useCallback(
    (module: DashboardModule): boolean => {
      if (isAdmin) return true;
      return permissionsService.canAccessModule(permissions, module);
    },
    [permissions, isAdmin]
  );

  const canCreate = useCallback(
    (module: DashboardModule): boolean => hasPermission(module, 'create'),
    [hasPermission]
  );

  const canRead = useCallback(
    (module: DashboardModule): boolean => hasPermission(module, 'read'),
    [hasPermission]
  );

  const canUpdate = useCallback(
    (module: DashboardModule): boolean => hasPermission(module, 'update'),
    [hasPermission]
  );

  const canDelete = useCallback(
    (module: DashboardModule): boolean => hasPermission(module, 'delete'),
    [hasPermission]
  );

  const canManage = useCallback(
    (module: DashboardModule): boolean => hasPermission(module, 'manage'),
    [hasPermission]
  );

  const refreshPermissions = useCallback(async () => {
    await loadPermissions();
  }, [loadPermissions]);

  const value = useMemo(
    () => ({
      permissions,
      isLoading,
      userRole,
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
      isLoading,
      userRole,
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
export function useHasPermission(module: DashboardModule, action: PermissionAction): boolean {
  const { hasPermission } = usePermissions();
  return hasPermission(module, action);
}

/**
 * Hook to check module access
 */
export function useCanAccess(module: DashboardModule): boolean {
  const { canAccess } = usePermissions();
  return canAccess(module);
}

export default PermissionsContext;

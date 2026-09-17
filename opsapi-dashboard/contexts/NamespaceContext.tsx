'use client';

import React, {
  createContext,
  useContext,
  useEffect,
  useCallback,
  useMemo,
  useRef,
  ReactNode,
} from 'react';
import { useAuthStore } from '@/store/auth.store';
import { useNamespaceStore } from '@/store/namespace.store';
import type {
  Namespace,
  NamespaceWithMembership,
  NamespacePermissions,
  NamespaceModule,
  PermissionAction,
  UserNamespaceSettings,
  CreateNamespaceDto,
} from '@/types';

interface NamespaceContextValue {
  // Current namespace
  currentNamespace: Namespace | null;
  namespacePermissions: NamespacePermissions | null;
  isNamespaceOwner: boolean;

  // Available namespaces
  namespaces: NamespaceWithMembership[];
  namespacesLoading: boolean;
  namespacesError: string | null;

  // User namespace settings (USER-FIRST Architecture)
  userSettings: UserNamespaceSettings | null;
  userSettingsLoading: boolean;
  defaultNamespaceInfo: { uuid?: string; name?: string; slug?: string } | null;
  lastActiveNamespaceInfo: { uuid?: string; name?: string; slug?: string } | null;

  // State flags
  hasNamespace: boolean;
  isSwitching: boolean;
  switchError: string | null;

  // Actions
  switchNamespace: (namespaceId: string) => Promise<boolean>;
  createNamespace: (data: CreateNamespaceDto) => Promise<Namespace | null>;
  refreshNamespaces: () => Promise<void>;
  setDefaultNamespace: (namespaceId: number | string) => Promise<boolean>;

  // Permission helpers
  hasPermission: (module: NamespaceModule, action: PermissionAction) => boolean;
  canAccess: (module: NamespaceModule) => boolean;
  canCreate: (module: NamespaceModule) => boolean;
  canRead: (module: NamespaceModule) => boolean;
  canUpdate: (module: NamespaceModule) => boolean;
  canDelete: (module: NamespaceModule) => boolean;
  canManage: (module: NamespaceModule) => boolean;
}

const NamespaceContext = createContext<NamespaceContextValue | undefined>(undefined);

interface NamespaceProviderProps {
  children: ReactNode;
}

export function NamespaceProvider({ children }: NamespaceProviderProps) {
  const { isAuthenticated, user } = useAuthStore();
  const {
    currentNamespace,
    namespacePermissions,
    isNamespaceOwner,
    namespaces,
    namespacesLoading,
    namespacesError,
    userSettings,
    userSettingsLoading,
    isSwitching,
    switchError,
    loadNamespaces,
    loadUserSettings,
    switchNamespace: switchNamespaceAction,
    createNamespace: createNamespaceAction,
    setDefaultNamespace: setDefaultNamespaceAction,
    setCurrentNamespace,
    setUserSettings,
    hasPermission: storeHasPermission,
    getDefaultNamespaceInfo,
    getLastActiveNamespaceInfo,
    _hasHydrated,
  } = useNamespaceStore();

  // Load namespaces and user settings when user is authenticated
  useEffect(() => {
    if (isAuthenticated && _hasHydrated) {
      loadNamespaces();
      loadUserSettings();
    }
  }, [isAuthenticated, _hasHydrated, loadNamespaces, loadUserSettings]);

  // Set namespace from login response if available (USER-FIRST flow)
  useEffect(() => {
    if (user && _hasHydrated && !currentNamespace) {
      // Check if user has namespace info from JWT (set during login)
      const userAny = user as unknown as {
        namespace?: {
          uuid: string;
          name: string;
          slug: string;
          id?: number;
          is_owner?: boolean;
          role?: string;
          permissions?: NamespacePermissions;
        };
        namespace_settings?: UserNamespaceSettings;
      };

      if (userAny.namespace) {
        // Extract permissions from the JWT namespace object
        const namespacePermissions = userAny.namespace.permissions || null;
        const isOwner = userAny.namespace.is_owner || userAny.namespace.role === 'owner' || false;

        setCurrentNamespace(
          userAny.namespace as Namespace,
          namespacePermissions,
          isOwner
        );
      }

      // Set user namespace settings if available
      if (userAny.namespace_settings) {
        setUserSettings(userAny.namespace_settings);
      }
    }
  }, [user, _hasHydrated, currentNamespace, setCurrentNamespace, setUserSettings]);

  // Reconcile a stale/leaked selection against the user's real memberships.
  // The effect above only fills an EMPTY selection, so a namespace persisted from
  // a previous session (even a different user's) survives login and wins over the
  // one the backend chose. If the selected namespace isn't one this user actually
  // belongs to, drop it and adopt the login default (or first available). A
  // deliberately switched namespace is always in the member list, so this never
  // fights a real switch; a platform admin's list is comprehensive for the same
  // reason. Reconciled once per stale uuid to avoid loops on a failed switch.
  const reconciledStaleRef = useRef<string | null>(null);
  useEffect(() => {
    if (!isAuthenticated || !_hasHydrated) return;
    if (namespacesLoading || isSwitching) return;
    if (!currentNamespace || namespaces.length === 0) return;

    if (namespaces.some((n) => n.uuid === currentNamespace.uuid)) {
      reconciledStaleRef.current = null;
      return;
    }
    if (reconciledStaleRef.current === currentNamespace.uuid) return;
    reconciledStaleRef.current = currentNamespace.uuid;

    const jwtUuid = (user as unknown as { namespace?: { uuid?: string } } | null)?.namespace?.uuid;
    const target = (jwtUuid && namespaces.find((n) => n.uuid === jwtUuid)) || namespaces[0];
    if (target?.uuid) {
      switchNamespaceAction(target.uuid);
    }
  }, [
    isAuthenticated,
    _hasHydrated,
    namespacesLoading,
    isSwitching,
    currentNamespace,
    namespaces,
    user,
    switchNamespaceAction,
  ]);

  // Permission check helpers
  const hasPermission = useCallback(
    (module: NamespaceModule, action: PermissionAction): boolean => {
      return storeHasPermission(module, action);
    },
    [storeHasPermission]
  );

  const canAccess = useCallback(
    (module: NamespaceModule): boolean => {
      // Role-driven: an owner's access comes from their role permissions
      // (seeded by the backend), not from ownership itself.
      if (!namespacePermissions) return false;
      const modulePerms = namespacePermissions[module];
      return Array.isArray(modulePerms) && modulePerms.length > 0;
    },
    [namespacePermissions]
  );

  const canCreate = useCallback(
    (module: NamespaceModule): boolean => hasPermission(module, 'create'),
    [hasPermission]
  );

  const canRead = useCallback(
    (module: NamespaceModule): boolean => hasPermission(module, 'read'),
    [hasPermission]
  );

  const canUpdate = useCallback(
    (module: NamespaceModule): boolean => hasPermission(module, 'update'),
    [hasPermission]
  );

  const canDelete = useCallback(
    (module: NamespaceModule): boolean => hasPermission(module, 'delete'),
    [hasPermission]
  );

  const canManage = useCallback(
    (module: NamespaceModule): boolean => hasPermission(module, 'manage'),
    [hasPermission]
  );

  const refreshNamespaces = useCallback(async () => {
    await loadNamespaces();
  }, [loadNamespaces]);

  const defaultNamespaceInfo = useMemo(() => getDefaultNamespaceInfo(), [getDefaultNamespaceInfo]);
  const lastActiveNamespaceInfo = useMemo(() => getLastActiveNamespaceInfo(), [getLastActiveNamespaceInfo]);

  const value = useMemo<NamespaceContextValue>(
    () => ({
      currentNamespace,
      namespacePermissions,
      isNamespaceOwner,
      namespaces,
      namespacesLoading,
      namespacesError,
      userSettings,
      userSettingsLoading,
      defaultNamespaceInfo,
      lastActiveNamespaceInfo,
      hasNamespace: !!currentNamespace,
      isSwitching,
      switchError,
      switchNamespace: switchNamespaceAction,
      createNamespace: createNamespaceAction,
      refreshNamespaces,
      setDefaultNamespace: setDefaultNamespaceAction,
      hasPermission,
      canAccess,
      canCreate,
      canRead,
      canUpdate,
      canDelete,
      canManage,
    }),
    [
      currentNamespace,
      namespacePermissions,
      isNamespaceOwner,
      namespaces,
      namespacesLoading,
      namespacesError,
      userSettings,
      userSettingsLoading,
      defaultNamespaceInfo,
      lastActiveNamespaceInfo,
      isSwitching,
      switchError,
      switchNamespaceAction,
      createNamespaceAction,
      refreshNamespaces,
      setDefaultNamespaceAction,
      hasPermission,
      canAccess,
      canCreate,
      canRead,
      canUpdate,
      canDelete,
      canManage,
    ]
  );

  return (
    <NamespaceContext.Provider value={value}>
      {children}
    </NamespaceContext.Provider>
  );
}

/**
 * Hook to access namespace context
 */
export function useNamespace() {
  const context = useContext(NamespaceContext);
  if (!context) {
    throw new Error('useNamespace must be used within a NamespaceProvider');
  }
  return context;
}

/**
 * Hook to check a specific namespace permission
 */
export function useNamespacePermission(
  module: NamespaceModule,
  action: PermissionAction
): boolean {
  const { hasPermission } = useNamespace();
  return hasPermission(module, action);
}

/**
 * Hook to check if user can access a module
 */
export function useCanAccessModule(module: NamespaceModule): boolean {
  const { canAccess } = useNamespace();
  return canAccess(module);
}

/**
 * Hook to get current namespace
 */
export function useCurrentNamespace(): Namespace | null {
  const { currentNamespace } = useNamespace();
  return currentNamespace;
}

/**
 * Hook to check if user is namespace owner
 */
export function useIsNamespaceOwner(): boolean {
  const { isNamespaceOwner } = useNamespace();
  return isNamespaceOwner;
}

/**
 * Hook to get user namespace settings
 */
export function useUserNamespaceSettings(): UserNamespaceSettings | null {
  const { userSettings } = useNamespace();
  return userSettings;
}

/**
 * Hook to get default namespace info
 */
export function useDefaultNamespace(): { uuid?: string; name?: string; slug?: string } | null {
  const { defaultNamespaceInfo } = useNamespace();
  return defaultNamespaceInfo;
}

export default NamespaceContext;

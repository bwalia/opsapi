import { create } from 'zustand';
import { persist } from 'zustand/middleware';
import type {
  Namespace,
  NamespaceWithMembership,
  NamespacePermissions,
  UserNamespaceSettings,
  CreateNamespaceDto,
} from '@/types';
import { namespaceService } from '@/services/namespace.service';

interface NamespaceState {
  // Current namespace context
  currentNamespace: Namespace | null;
  namespacePermissions: NamespacePermissions | null;
  isNamespaceOwner: boolean;

  // User's available namespaces
  namespaces: NamespaceWithMembership[];
  namespacesLoading: boolean;
  namespacesError: string | null;

  // User namespace settings (USER-FIRST Architecture)
  userSettings: UserNamespaceSettings | null;
  userSettingsLoading: boolean;

  // Switching state
  isSwitching: boolean;
  switchError: string | null;

  // Hydration
  _hasHydrated: boolean;
}

interface NamespaceActions {
  // Set hydration state
  setHasHydrated: (state: boolean) => void;

  // Load user's namespaces with settings
  loadNamespaces: () => Promise<void>;

  // Load user's namespace settings
  loadUserSettings: () => Promise<void>;

  // Set current namespace (from login response)
  setCurrentNamespace: (
    namespace: Namespace | null,
    permissions?: NamespacePermissions | null,
    isOwner?: boolean
  ) => void;

  // Set user settings (from login response)
  setUserSettings: (settings: UserNamespaceSettings | null) => void;

  // Set user's default namespace
  setDefaultNamespace: (namespaceId: number | string) => Promise<boolean>;

  // Switch to a different namespace
  switchNamespace: (namespaceId: string) => Promise<boolean>;

  // Create a new namespace
  createNamespace: (data: CreateNamespaceDto) => Promise<Namespace | null>;

  // Clear namespace state
  clearNamespace: () => void;

  // Check permission in current namespace
  hasPermission: (module: keyof NamespacePermissions, action: string) => boolean;

  // Clear errors
  clearErrors: () => void;

  // Get default namespace info from settings
  getDefaultNamespaceInfo: () => { uuid?: string; name?: string; slug?: string } | null;

  // Get last active namespace info from settings
  getLastActiveNamespaceInfo: () => { uuid?: string; name?: string; slug?: string } | null;
}

type NamespaceStore = NamespaceState & NamespaceActions;

export const useNamespaceStore = create<NamespaceStore>()(
  persist(
    (set, get) => ({
      // Initial state
      currentNamespace: null,
      namespacePermissions: null,
      isNamespaceOwner: false,
      namespaces: [],
      namespacesLoading: false,
      namespacesError: null,
      userSettings: null,
      userSettingsLoading: false,
      isSwitching: false,
      switchError: null,
      _hasHydrated: false,

      setHasHydrated: (state: boolean) => {
        set({ _hasHydrated: state });
      },

      loadNamespaces: async () => {
        set({ namespacesLoading: true, namespacesError: null });
        try {
          const response = await namespaceService.getUserNamespaces();
          set({
            namespaces: response.data || [],
            namespacesLoading: false,
          });
          // Update user settings if included in response
          if (response.settings) {
            const currentSettings = get().userSettings;
            set({
              userSettings: {
                ...currentSettings,
                default_namespace_id: response.settings.default_namespace_id,
                default_namespace_uuid: response.settings.default_namespace_uuid,
                default_namespace_slug: response.settings.default_namespace_slug,
                last_active_namespace_id: response.settings.last_active_namespace_id,
                last_active_namespace_uuid: response.settings.last_active_namespace_uuid,
                last_active_namespace_slug: response.settings.last_active_namespace_slug,
              } as UserNamespaceSettings,
            });
          }
        } catch (error) {
          const message = error instanceof Error ? error.message : 'Failed to load namespaces';
          set({ namespacesError: message, namespacesLoading: false });
        }
      },

      loadUserSettings: async () => {
        set({ userSettingsLoading: true });
        try {
          const settings = await namespaceService.getUserNamespaceSettings();
          set({ userSettings: settings, userSettingsLoading: false });
        } catch {
          set({ userSettingsLoading: false });
        }
      },

      setCurrentNamespace: (namespace, permissions = null, isOwner = false) => {
        set({
          currentNamespace: namespace,
          namespacePermissions: permissions,
          isNamespaceOwner: isOwner,
        });
        // Also update local storage for API client
        namespaceService.setCurrentNamespace(namespace);
      },

      setUserSettings: (settings) => {
        set({ userSettings: settings });
        namespaceService.setUserNamespaceSettingsInStorage(settings);
      },

      setDefaultNamespace: async (namespaceId) => {
        try {
          const settings = await namespaceService.setDefaultNamespace(namespaceId);
          set({ userSettings: settings });
          return true;
        } catch {
          return false;
        }
      },

      switchNamespace: async (namespaceId: string) => {
        set({ isSwitching: true, switchError: null });
        try {
          const response = await namespaceService.switchNamespace(namespaceId);

          // Parse permissions if needed
          let permissions: NamespacePermissions | null = null;
          if (response.permissions) {
            permissions = namespaceService.parsePermissions(response.permissions);
          }

          set({
            currentNamespace: response.namespace,
            namespacePermissions: permissions,
            isNamespaceOwner: response.membership?.is_owner || false,
            isSwitching: false,
          });

          // Update last active in user settings
          const { userSettings } = get();
          if (userSettings && response.namespace) {
            set({
              userSettings: {
                ...userSettings,
                last_active_namespace_id: response.namespace.id,
                last_active_namespace_uuid: response.namespace.uuid,
                last_active_namespace_name: response.namespace.name,
                last_active_namespace_slug: response.namespace.slug,
              },
            });
          }

          return true;
        } catch (error) {
          const message = error instanceof Error ? error.message : 'Failed to switch namespace';
          set({ switchError: message, isSwitching: false });
          return false;
        }
      },

      createNamespace: async (data) => {
        set({ isSwitching: true, switchError: null });
        try {
          const response = await namespaceService.createNamespace(data);

          // Set as current namespace (user is owner)
          set({
            currentNamespace: response.namespace,
            isNamespaceOwner: true,
            namespacePermissions: null, // Owner has all permissions
            isSwitching: false,
          });

          // Refresh namespaces list
          get().loadNamespaces();

          return response.namespace;
        } catch (error) {
          const message = error instanceof Error ? error.message : 'Failed to create namespace';
          set({ switchError: message, isSwitching: false });
          return null;
        }
      },

      clearNamespace: () => {
        set({
          currentNamespace: null,
          namespacePermissions: null,
          isNamespaceOwner: false,
          namespaces: [],
          namespacesError: null,
          switchError: null,
          userSettings: null,
        });
        namespaceService.clearAllNamespaceData();
      },

      hasPermission: (module, action) => {
        const { isNamespaceOwner, namespacePermissions } = get();

        // Owners have all permissions
        if (isNamespaceOwner) return true;

        // No permissions loaded
        if (!namespacePermissions) return false;

        return namespaceService.hasPermission(namespacePermissions, module, action);
      },

      clearErrors: () => {
        set({ namespacesError: null, switchError: null });
      },

      getDefaultNamespaceInfo: () => {
        const { userSettings } = get();
        if (!userSettings?.default_namespace_uuid) return null;
        return {
          uuid: userSettings.default_namespace_uuid,
          name: userSettings.default_namespace_name,
          slug: userSettings.default_namespace_slug,
        };
      },

      getLastActiveNamespaceInfo: () => {
        const { userSettings } = get();
        if (!userSettings?.last_active_namespace_uuid) return null;
        return {
          uuid: userSettings.last_active_namespace_uuid,
          name: userSettings.last_active_namespace_name,
          slug: userSettings.last_active_namespace_slug,
        };
      },
    }),
    {
      name: 'namespace-storage',
      partialize: (state) => ({
        currentNamespace: state.currentNamespace,
        namespacePermissions: state.namespacePermissions,
        isNamespaceOwner: state.isNamespaceOwner,
        userSettings: state.userSettings,
      }),
      onRehydrateStorage: () => (state) => {
        state?.setHasHydrated(true);
      },
    }
  )
);

export default useNamespaceStore;

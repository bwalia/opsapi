import { create } from 'zustand';
import { persist } from 'zustand/middleware';
import type {
  KanbanNotification,
  NotificationPreferences,
  NotificationType,
} from '@/types';
import { notificationService } from '@/services/notification.service';

// ============================================
// State Types
// ============================================

interface NotificationState {
  // Notifications
  notifications: KanbanNotification[];
  notificationsLoading: boolean;
  notificationsError: string | null;
  unreadCount: number;
  totalCount: number;
  hasMore: boolean;

  // Preferences
  preferences: NotificationPreferences | null;
  preferencesLoading: boolean;

  // UI State
  isNotificationPanelOpen: boolean;
  selectedNotification: KanbanNotification | null;

  // Filters
  filters: {
    unread_only?: boolean;
    type?: NotificationType;
    project_id?: number;
  };

  // Pagination
  page: number;
  perPage: number;

  // WebSocket connection state
  isConnected: boolean;

  // Hydration
  _hasHydrated: boolean;
}

interface NotificationActions {
  // Hydration
  setHasHydrated: (state: boolean) => void;

  // Notifications
  loadNotifications: (reset?: boolean) => Promise<void>;
  loadMoreNotifications: () => Promise<void>;
  markAsRead: (uuid: string) => Promise<void>;
  markAllAsRead: (projectId?: number) => Promise<void>;
  deleteNotification: (uuid: string) => Promise<void>;
  clearReadNotifications: () => Promise<void>;

  // Real-time updates
  addNotification: (notification: KanbanNotification) => void;
  updateUnreadCount: (count: number) => void;
  setConnected: (connected: boolean) => void;

  // Preferences
  loadPreferences: (projectId?: number) => Promise<void>;
  updatePreferences: (params: Partial<NotificationPreferences>, projectId?: number) => Promise<void>;

  // UI State
  toggleNotificationPanel: () => void;
  openNotificationPanel: () => void;
  closeNotificationPanel: () => void;
  setSelectedNotification: (notification: KanbanNotification | null) => void;

  // Filters
  setFilters: (filters: NotificationState['filters']) => void;
  clearFilters: () => void;

  // Clear
  clearNotificationState: () => void;
}

type NotificationStore = NotificationState & NotificationActions;

// ============================================
// Initial State
// ============================================

const initialState: NotificationState = {
  notifications: [],
  notificationsLoading: false,
  notificationsError: null,
  unreadCount: 0,
  totalCount: 0,
  hasMore: false,

  preferences: null,
  preferencesLoading: false,

  isNotificationPanelOpen: false,
  selectedNotification: null,

  filters: {},

  page: 1,
  perPage: 20,

  isConnected: false,

  _hasHydrated: false,
};

// ============================================
// Store
// ============================================

export const useNotificationStore = create<NotificationStore>()(
  persist(
    (set, get) => ({
      ...initialState,

      // ============================================
      // Hydration
      // ============================================

      setHasHydrated: (state: boolean) => {
        set({ _hasHydrated: state });
      },

      // ============================================
      // Notifications
      // ============================================

      loadNotifications: async (reset = true) => {
        const { filters, perPage } = get();

        if (reset) {
          set({ notificationsLoading: true, notificationsError: null, page: 1 });
        }

        try {
          const response = await notificationService.getNotifications({
            page: 1,
            perPage,
            ...filters,
          });

          set({
            notifications: response.data,
            unreadCount: response.unread_count,
            totalCount: response.total,
            hasMore: response.data.length >= perPage,
            notificationsLoading: false,
            page: 1,
          });
        } catch (error) {
          const message = error instanceof Error ? error.message : 'Failed to load notifications';
          set({ notificationsError: message, notificationsLoading: false });
        }
      },

      loadMoreNotifications: async () => {
        const { page, perPage, filters, notifications, hasMore, notificationsLoading } = get();

        if (notificationsLoading || !hasMore) return;

        set({ notificationsLoading: true });

        try {
          const nextPage = page + 1;
          const response = await notificationService.getNotifications({
            page: nextPage,
            perPage,
            ...filters,
          });

          set({
            notifications: [...notifications, ...response.data],
            hasMore: response.data.length >= perPage,
            notificationsLoading: false,
            page: nextPage,
          });
        } catch (error) {
          console.error('Failed to load more notifications:', error);
          set({ notificationsLoading: false });
        }
      },

      markAsRead: async (uuid: string) => {
        // Optimistic update
        set((state) => ({
          notifications: state.notifications.map((n) =>
            n.uuid === uuid ? { ...n, is_read: true, read_at: new Date().toISOString() } : n
          ),
          unreadCount: Math.max(0, state.unreadCount - 1),
        }));

        try {
          await notificationService.markAsRead(uuid);
        } catch (error) {
          console.error('Failed to mark notification as read:', error);
          // Revert on error
          await get().loadNotifications();
        }
      },

      markAllAsRead: async (projectId?: number) => {
        const previousState = {
          notifications: get().notifications,
          unreadCount: get().unreadCount,
        };

        // Optimistic update
        set((state) => ({
          notifications: state.notifications.map((n) => {
            if (projectId && n.project_id !== projectId) return n;
            return { ...n, is_read: true, read_at: new Date().toISOString() };
          }),
          unreadCount: projectId ? state.unreadCount : 0,
        }));

        try {
          await notificationService.markAllAsRead(projectId);
          // Reload to get accurate count
          await get().loadNotifications();
        } catch (error) {
          console.error('Failed to mark all as read:', error);
          // Revert on error
          set(previousState);
        }
      },

      deleteNotification: async (uuid: string) => {
        const notification = get().notifications.find((n) => n.uuid === uuid);

        // Optimistic update
        set((state) => ({
          notifications: state.notifications.filter((n) => n.uuid !== uuid),
          unreadCount: notification && !notification.is_read
            ? Math.max(0, state.unreadCount - 1)
            : state.unreadCount,
          totalCount: Math.max(0, state.totalCount - 1),
        }));

        try {
          await notificationService.deleteNotification(uuid);
        } catch (error) {
          console.error('Failed to delete notification:', error);
          await get().loadNotifications();
        }
      },

      clearReadNotifications: async () => {
        const previousNotifications = get().notifications;

        // Optimistic update
        set((state) => ({
          notifications: state.notifications.filter((n) => !n.is_read),
        }));

        try {
          await notificationService.deleteAllRead();
        } catch (error) {
          console.error('Failed to clear read notifications:', error);
          set({ notifications: previousNotifications });
        }
      },

      // ============================================
      // Real-time Updates
      // ============================================

      addNotification: (notification: KanbanNotification) => {
        set((state) => ({
          notifications: [notification, ...state.notifications],
          unreadCount: state.unreadCount + 1,
          totalCount: state.totalCount + 1,
        }));
      },

      updateUnreadCount: (count: number) => {
        set({ unreadCount: count });
      },

      setConnected: (connected: boolean) => {
        set({ isConnected: connected });
      },

      // ============================================
      // Preferences
      // ============================================

      loadPreferences: async (projectId?: number) => {
        set({ preferencesLoading: true });
        try {
          const preferences = await notificationService.getPreferences(projectId);
          set({ preferences, preferencesLoading: false });
        } catch (error) {
          console.error('Failed to load preferences:', error);
          set({ preferencesLoading: false });
        }
      },

      updatePreferences: async (params: Partial<NotificationPreferences>, projectId?: number) => {
        const previousPreferences = get().preferences;

        // Optimistic update
        set((state) => ({
          preferences: state.preferences ? { ...state.preferences, ...params } : null,
        }));

        try {
          const updated = await notificationService.updatePreferences(params, projectId);
          set({ preferences: updated });
        } catch (error) {
          console.error('Failed to update preferences:', error);
          set({ preferences: previousPreferences });
        }
      },

      // ============================================
      // UI State
      // ============================================

      toggleNotificationPanel: () => {
        set((state) => ({ isNotificationPanelOpen: !state.isNotificationPanelOpen }));
      },

      openNotificationPanel: () => {
        set({ isNotificationPanelOpen: true });
      },

      closeNotificationPanel: () => {
        set({ isNotificationPanelOpen: false });
      },

      setSelectedNotification: (notification: KanbanNotification | null) => {
        set({ selectedNotification: notification });
      },

      // ============================================
      // Filters
      // ============================================

      setFilters: (filters) => {
        set({ filters });
        get().loadNotifications(true);
      },

      clearFilters: () => {
        set({ filters: {} });
        get().loadNotifications(true);
      },

      // ============================================
      // Clear
      // ============================================

      clearNotificationState: () => {
        set(initialState);
      },
    }),
    {
      name: 'notification-storage',
      partialize: (state) => ({
        // Only persist preferences
        filters: state.filters,
      }),
      onRehydrateStorage: () => (state) => {
        state?.setHasHydrated(true);
      },
    }
  )
);

export default useNotificationStore;

'use client';

import React, { useEffect, useCallback, useState, memo, useRef } from 'react';
import { useRouter } from 'next/navigation';
import {
  Bell,
  Check,
  CheckCheck,
  Trash2,
  Settings,
  X,
  UserPlus,
  UserMinus,
  MessageSquare,
  AtSign,
  CheckCircle,
  RefreshCw,
  Clock,
  AlertTriangle,
  Shield,
  Play,
  Square,
  CheckSquare,
  Reply,
  Loader2,
  WifiOff,
  Wifi,
} from 'lucide-react';
import { cn } from '@/lib/utils';
import { useNotificationStore } from '@/store/notification.store';
import { useNotificationSocket } from '@/hooks/useWebSocket';
import {
  formatNotificationTime,
  getNotificationTypeLabel,
  groupNotificationsByDate,
} from '@/services/notification.service';
import type { KanbanNotification, NotificationType } from '@/types';

// ============================================
// Icon Map
// ============================================

const NOTIFICATION_ICONS: Record<NotificationType, React.ComponentType<{ className?: string }>> = {
  task_assigned: UserPlus,
  task_unassigned: UserMinus,
  task_commented: MessageSquare,
  task_mentioned: AtSign,
  task_completed: CheckCircle,
  task_status_changed: RefreshCw,
  task_due_soon: Clock,
  task_overdue: AlertTriangle,
  project_invited: UserPlus,
  project_removed: UserMinus,
  project_role_changed: Shield,
  sprint_started: Play,
  sprint_ended: Square,
  checklist_completed: CheckSquare,
  comment_reply: Reply,
  comment_mentioned: AtSign,
  general: Bell,
};

// ============================================
// Notification Item Component
// ============================================

interface NotificationItemProps {
  notification: KanbanNotification;
  onMarkAsRead: (uuid: string) => void;
  onDelete: (uuid: string) => void;
  onClick: (notification: KanbanNotification) => void;
}

const NotificationItem = memo(function NotificationItem({
  notification,
  onMarkAsRead,
  onDelete,
  onClick,
}: NotificationItemProps) {
  const IconComponent = NOTIFICATION_ICONS[notification.type as NotificationType] || Bell;

  const priorityStyles = {
    urgent: 'border-l-4 border-l-red-500',
    high: 'border-l-4 border-l-orange-500',
    normal: '',
    low: '',
  };

  return (
    <div
      className={cn(
        'group relative px-4 py-3 hover:bg-secondary-50 transition-colors cursor-pointer',
        !notification.is_read && 'bg-primary-50/30',
        priorityStyles[notification.priority || 'normal']
      )}
      onClick={() => onClick(notification)}
    >
      <div className="flex items-start gap-3">
        {/* Icon */}
        <div
          className={cn(
            'flex-shrink-0 w-9 h-9 rounded-lg flex items-center justify-center',
            notification.is_read
              ? 'bg-secondary-100 text-secondary-500'
              : 'bg-primary-100 text-primary-600'
          )}
        >
          <IconComponent className="w-4 h-4" />
        </div>

        {/* Content */}
        <div className="flex-1 min-w-0">
          <div className="flex items-start justify-between gap-2">
            <div className="flex-1 min-w-0">
              <p
                className={cn(
                  'text-sm line-clamp-1',
                  notification.is_read ? 'text-secondary-600' : 'text-secondary-900 font-medium'
                )}
              >
                {notification.title}
              </p>
              <p className="text-xs text-secondary-500 line-clamp-2 mt-0.5">
                {notification.message}
              </p>
            </div>

            {/* Unread indicator */}
            {!notification.is_read && (
              <span className="flex-shrink-0 w-2 h-2 rounded-full bg-primary-500 mt-1.5" />
            )}
          </div>

          <div className="flex items-center gap-2 mt-1.5">
            <span className="text-xs text-secondary-400">
              {formatNotificationTime(notification.created_at)}
            </span>
            {notification.project_name && (
              <>
                <span className="text-secondary-300">·</span>
                <span className="text-xs text-secondary-500 truncate max-w-[120px]">
                  {notification.project_name}
                </span>
              </>
            )}
          </div>
        </div>
      </div>

      {/* Actions (visible on hover) */}
      <div className="absolute right-2 top-1/2 -translate-y-1/2 flex items-center gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
        {!notification.is_read && (
          <button
            onClick={(e) => {
              e.stopPropagation();
              onMarkAsRead(notification.uuid);
            }}
            className="p-1.5 text-secondary-400 hover:text-primary-600 hover:bg-primary-50 rounded-lg transition-colors"
            title="Mark as read"
          >
            <Check className="w-3.5 h-3.5" />
          </button>
        )}
        <button
          onClick={(e) => {
            e.stopPropagation();
            onDelete(notification.uuid);
          }}
          className="p-1.5 text-secondary-400 hover:text-error-600 hover:bg-error-50 rounded-lg transition-colors"
          title="Delete"
        >
          <Trash2 className="w-3.5 h-3.5" />
        </button>
      </div>
    </div>
  );
});

// ============================================
// Notification Panel Component
// ============================================

interface NotificationPanelProps {
  isOpen: boolean;
  onClose: () => void;
}

const NotificationPanel = memo(function NotificationPanel({
  isOpen,
  onClose,
}: NotificationPanelProps) {
  const router = useRouter();
  const panelRef = useRef<HTMLDivElement>(null);

  const {
    notifications,
    notificationsLoading,
    unreadCount,
    hasMore,
    isConnected,
    loadNotifications,
    loadMoreNotifications,
    markAsRead,
    markAllAsRead,
    deleteNotification,
  } = useNotificationStore();

  // Load notifications when panel opens
  useEffect(() => {
    if (isOpen) {
      loadNotifications(true);
    }
  }, [isOpen, loadNotifications]);

  // Close on click outside
  useEffect(() => {
    const handleClickOutside = (event: MouseEvent) => {
      if (panelRef.current && !panelRef.current.contains(event.target as Node)) {
        onClose();
      }
    };

    if (isOpen) {
      document.addEventListener('mousedown', handleClickOutside);
    }

    return () => {
      document.removeEventListener('mousedown', handleClickOutside);
    };
  }, [isOpen, onClose]);

  // Close on escape
  useEffect(() => {
    const handleEscape = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };

    if (isOpen) {
      document.addEventListener('keydown', handleEscape);
    }

    return () => {
      document.removeEventListener('keydown', handleEscape);
    };
  }, [isOpen, onClose]);

  const handleNotificationClick = useCallback(
    (notification: KanbanNotification) => {
      if (!notification.is_read) {
        markAsRead(notification.uuid);
      }
      if (notification.action_url) {
        router.push(notification.action_url);
        onClose();
      }
    },
    [markAsRead, router, onClose]
  );

  const handleScroll = useCallback(
    (e: React.UIEvent<HTMLDivElement>) => {
      const { scrollTop, scrollHeight, clientHeight } = e.currentTarget;
      if (scrollHeight - scrollTop <= clientHeight * 1.5 && hasMore && !notificationsLoading) {
        loadMoreNotifications();
      }
    },
    [hasMore, notificationsLoading, loadMoreNotifications]
  );

  const groupedNotifications = groupNotificationsByDate(notifications);

  if (!isOpen) return null;

  return (
    <>
      {/* Backdrop */}
      <div className="fixed inset-0 z-40" aria-hidden="true" />

      {/* Panel */}
      <div
        ref={panelRef}
        className="absolute right-0 mt-2 w-96 max-w-[calc(100vw-2rem)] bg-white rounded-xl shadow-xl border border-secondary-200 z-50 overflow-hidden"
      >
        {/* Header */}
        <div className="flex items-center justify-between px-4 py-3 border-b border-secondary-200">
          <div className="flex items-center gap-2">
            <h3 className="text-base font-semibold text-secondary-900">Notifications</h3>
            {unreadCount > 0 && (
              <span className="px-2 py-0.5 text-xs font-medium bg-primary-100 text-primary-700 rounded-full">
                {unreadCount}
              </span>
            )}
          </div>
          <div className="flex items-center gap-1">
            {/* Connection status */}
            <div
              className={cn(
                'p-1.5 rounded-lg',
                isConnected ? 'text-success-500' : 'text-secondary-400'
              )}
              title={isConnected ? 'Real-time connected' : 'Connecting...'}
            >
              {isConnected ? <Wifi className="w-4 h-4" /> : <WifiOff className="w-4 h-4" />}
            </div>

            {/* Mark all as read */}
            {unreadCount > 0 && (
              <button
                onClick={() => markAllAsRead()}
                className="p-1.5 text-secondary-500 hover:text-primary-600 hover:bg-primary-50 rounded-lg transition-colors"
                title="Mark all as read"
              >
                <CheckCheck className="w-4 h-4" />
              </button>
            )}

            {/* Settings */}
            <button
              onClick={() => {
                router.push('/dashboard/settings/notifications');
                onClose();
              }}
              className="p-1.5 text-secondary-500 hover:text-secondary-700 hover:bg-secondary-100 rounded-lg transition-colors"
              title="Notification settings"
            >
              <Settings className="w-4 h-4" />
            </button>

            {/* Close */}
            <button
              onClick={onClose}
              className="p-1.5 text-secondary-500 hover:text-secondary-700 hover:bg-secondary-100 rounded-lg transition-colors"
            >
              <X className="w-4 h-4" />
            </button>
          </div>
        </div>

        {/* Notification List */}
        <div className="max-h-[420px] overflow-y-auto" onScroll={handleScroll}>
          {notificationsLoading && notifications.length === 0 ? (
            <div className="flex items-center justify-center py-12">
              <Loader2 className="w-6 h-6 text-primary-500 animate-spin" />
            </div>
          ) : notifications.length === 0 ? (
            <div className="flex flex-col items-center justify-center py-12 px-4 text-center">
              <div className="w-14 h-14 bg-secondary-100 rounded-full flex items-center justify-center mb-3">
                <Bell className="w-7 h-7 text-secondary-400" />
              </div>
              <p className="text-sm font-medium text-secondary-700">No notifications</p>
              <p className="text-xs text-secondary-500 mt-1">
                You&apos;re all caught up! We&apos;ll notify you when something new happens.
              </p>
            </div>
          ) : (
            <div className="divide-y divide-secondary-100">
              {Array.from(groupedNotifications.entries()).map(([date, items]) => (
                <div key={date}>
                  <div className="px-4 py-2 bg-secondary-50 border-y border-secondary-100">
                    <p className="text-xs font-medium text-secondary-500 uppercase tracking-wide">
                      {date}
                    </p>
                  </div>
                  {items.map((notification) => (
                    <NotificationItem
                      key={notification.uuid}
                      notification={notification}
                      onMarkAsRead={markAsRead}
                      onDelete={deleteNotification}
                      onClick={handleNotificationClick}
                    />
                  ))}
                </div>
              ))}
            </div>
          )}

          {/* Load more indicator */}
          {notificationsLoading && notifications.length > 0 && (
            <div className="flex items-center justify-center py-4">
              <Loader2 className="w-5 h-5 text-primary-500 animate-spin" />
            </div>
          )}
        </div>

        {/* Footer */}
        {notifications.length > 0 && (
          <div className="border-t border-secondary-200 p-2">
            <button
              onClick={() => {
                router.push('/dashboard/notifications');
                onClose();
              }}
              className="w-full py-2 text-sm font-medium text-primary-600 hover:bg-primary-50 rounded-lg transition-colors"
            >
              View all notifications
            </button>
          </div>
        )}
      </div>
    </>
  );
});

// ============================================
// Notification Bell Component (Export)
// ============================================

export const NotificationBell = memo(function NotificationBell() {
  const [isPanelOpen, setIsPanelOpen] = useState(false);
  const { unreadCount, addNotification, setConnected, loadNotifications } = useNotificationStore();

  // Connect to WebSocket for real-time notifications
  const { isConnected } = useNotificationSocket({
    enabled: true,
    onNotification: (notification) => {
      addNotification(notification as KanbanNotification);
    },
  });

  // Update connection status in store
  useEffect(() => {
    setConnected(isConnected);
  }, [isConnected, setConnected]);

  // Load initial notifications on mount
  useEffect(() => {
    loadNotifications(true);
  }, [loadNotifications]);

  const togglePanel = useCallback(() => {
    setIsPanelOpen((prev) => !prev);
  }, []);

  const closePanel = useCallback(() => {
    setIsPanelOpen(false);
  }, []);

  return (
    <div className="relative">
      <button
        onClick={togglePanel}
        className={cn(
          'relative p-2 text-secondary-500 hover:text-secondary-700 hover:bg-secondary-100 rounded-lg transition-colors',
          isPanelOpen && 'bg-secondary-100 text-secondary-700'
        )}
        aria-label={`Notifications${unreadCount > 0 ? ` (${unreadCount} unread)` : ''}`}
        aria-expanded={isPanelOpen}
        aria-haspopup="true"
      >
        <Bell className="w-5 h-5" />

        {/* Unread badge */}
        {unreadCount > 0 && (
          <span className="absolute -top-0.5 -right-0.5 flex items-center justify-center min-w-[18px] h-[18px] px-1 text-[10px] font-semibold text-white bg-error-500 rounded-full shadow-sm">
            {unreadCount > 99 ? '99+' : unreadCount}
          </span>
        )}

        {/* Connection indicator */}
        {isConnected && (
          <span className="absolute bottom-0.5 right-0.5 w-2 h-2 bg-success-500 rounded-full border border-white" />
        )}
      </button>

      <NotificationPanel isOpen={isPanelOpen} onClose={closePanel} />
    </div>
  );
});

export default NotificationBell;

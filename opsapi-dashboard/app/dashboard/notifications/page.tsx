'use client';

/**
 * All notifications for the signed-in user, server-side paginated
 * (GET /api/v2/kanban/notifications?page=&per_page=&unread_only=). Opening one marks
 * it read and jumps to its target — switching workspace first when it belongs to another,
 * exactly like the notification bell.
 */
import React, { useCallback, useState } from 'react';
import { useRouter } from 'next/navigation';
import { Bell, CheckCheck, RefreshCw, Loader2 } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Card, Pagination } from '@/components/ui';
import { PageHeader } from '@/components/layout/PageHeader';
import { useDataFetch } from '@/hooks';
import {
  notificationService,
  formatNotificationTime,
  getNotificationTypeLabel,
} from '@/services/notification.service';
import { NOTIFICATION_ICONS } from '@/components/notifications/NotificationCenter';
import { useNamespaceStore } from '@/store/namespace.store';
import { cn } from '@/lib/utils';
import type { KanbanNotification, NotificationType } from '@/types';

const PER_PAGE = 20;

function NotificationsContent() {
  const router = useRouter();
  const [page, setPage] = useState(1);
  const [filter, setFilter] = useState<'all' | 'unread'>('all');

  const fetcher = useCallback(
    () => notificationService.getNotifications({ page, perPage: PER_PAGE, unread_only: filter === 'unread' || undefined }),
    [page, filter]
  );
  const { data, isLoading, error, refetch } = useDataFetch(fetcher);
  const items = data?.data ?? [];
  const total = data?.total ?? 0;
  const unread = data?.unread_count ?? 0;
  const perPage = data?.per_page || PER_PAGE;
  const totalPages = Math.max(1, Math.ceil(total / perPage));

  const open = useCallback(
    async (n: KanbanNotification) => {
      if (!n.is_read) {
        try { await notificationService.markAsRead(n.uuid); } catch { /* best-effort */ }
      }
      if (!n.action_url) { void refetch(); return; }
      // The notification may belong to a different workspace; switch first so the target loads.
      const ns = useNamespaceStore.getState();
      if (n.namespace_id && n.namespace_id !== ns.currentNamespace?.id) {
        const target = ns.namespaces.find((x) => x.id === n.namespace_id);
        if (target?.uuid) await ns.switchNamespace(target.uuid);
      }
      router.push(n.action_url);
    },
    [router, refetch]
  );

  const markAll = useCallback(async () => {
    try {
      await notificationService.markAllAsRead();
      toast.success('All marked as read');
      void refetch();
    } catch {
      toast.error('Couldn’t mark all as read');
    }
  }, [refetch]);

  const choose = (f: 'all' | 'unread') => { setFilter(f); setPage(1); };

  return (
    <div className="space-y-5">
      <PageHeader
        title="Notifications"
        description="Everything that's happened across your workspaces, newest first."
        icon={<Bell className="h-5 w-5" />}
        actions={
          <div className="flex items-center gap-2">
            {unread > 0 && (
              <Button variant="outline" size="sm" leftIcon={<CheckCheck className="h-4 w-4" />} onClick={markAll}>
                Mark all read
              </Button>
            )}
            <Button variant="ghost" size="sm" onClick={() => void refetch()} disabled={isLoading} aria-label="Refresh">
              <RefreshCw className={isLoading ? 'h-4 w-4 animate-spin' : 'h-4 w-4'} />
            </Button>
          </div>
        }
      />

      <div role="group" aria-label="Filter" className="inline-flex rounded-lg border border-secondary-200 bg-surface p-1">
        {(['all', 'unread'] as const).map((f) => (
          <button
            key={f}
            type="button"
            onClick={() => choose(f)}
            aria-pressed={filter === f}
            className={cn(
              'rounded-md px-3 py-1.5 text-sm font-medium transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary-500',
              filter === f ? 'bg-primary-500 text-white' : 'text-secondary-600 hover:bg-secondary-100'
            )}
          >
            {f === 'all' ? 'All' : `Unread${unread ? ` (${unread})` : ''}`}
          </button>
        ))}
      </div>

      <Card padding="none" aria-busy={isLoading}>
        {error ? (
          <div className="flex flex-col items-center gap-3 p-10 text-center" role="alert">
            <p className="text-sm text-secondary-600">Couldn&apos;t load notifications.</p>
            <Button variant="outline" size="sm" onClick={() => void refetch()}>Try again</Button>
          </div>
        ) : isLoading && !data ? (
          <div className="flex justify-center p-10 text-secondary-400">
            <Loader2 className="h-6 w-6 animate-spin" aria-label="Loading" />
          </div>
        ) : items.length === 0 ? (
          <p className="p-10 text-center text-sm text-secondary-500">
            {filter === 'unread' ? 'No unread notifications.' : 'No notifications yet.'}
          </p>
        ) : (
          <ul className="divide-y divide-secondary-100">
            {items.map((n) => {
              const Icon = NOTIFICATION_ICONS[n.type as NotificationType] || Bell;
              return (
                <li key={n.uuid}>
                  <button
                    type="button"
                    onClick={() => void open(n)}
                    className={cn(
                      'flex w-full items-start gap-3 px-4 py-3 text-left transition hover:bg-secondary-50 focus-visible:bg-secondary-50 focus-visible:outline-none',
                      !n.is_read && 'bg-primary-50/40'
                    )}
                  >
                    <span className={cn(
                      'mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center rounded-full',
                      n.is_read ? 'bg-secondary-100 text-secondary-500' : 'bg-primary-100 text-primary-600'
                    )}>
                      <Icon className="h-4 w-4" />
                    </span>
                    <span className="min-w-0 flex-1">
                      <span className="flex items-center gap-2">
                        <span className={cn('truncate text-sm', n.is_read ? 'font-medium text-secondary-800' : 'font-semibold text-secondary-900')}>
                          {n.title}
                        </span>
                        {!n.is_read && <span className="h-2 w-2 shrink-0 rounded-full bg-primary-500" aria-label="Unread" />}
                      </span>
                      {n.message && <span className="mt-0.5 block text-sm text-secondary-600 line-clamp-2">{n.message}</span>}
                      <span className="mt-1 block text-xs text-secondary-400">
                        {getNotificationTypeLabel(n.type)} · {formatNotificationTime(n.created_at)}
                        {n.project_name ? ` · ${n.project_name}` : ''}
                      </span>
                    </span>
                  </button>
                </li>
              );
            })}
          </ul>
        )}
      </Card>

      {totalPages > 1 && (
        <Pagination
          currentPage={page}
          totalPages={totalPages}
          totalItems={total}
          perPage={perPage}
          onPageChange={setPage}
        />
      )}
    </div>
  );
}

export default function NotificationsPage() {
  return <NotificationsContent />;
}

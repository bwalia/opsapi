'use client';

import { useCallback, useEffect, useRef } from 'react';
import { useWebSocket, type ConnectionStatus } from './useWebSocket';
import { useKanbanStore } from '@/store/kanban.store';
import { useAuthStore } from '@/store/auth.store';
import type { WebSocketEventType } from '@/types';

// Board data events pushed by the backend hub (lib/kanban-ws.lua).
const BOARD_EVENTS: WebSocketEventType[] = ['task:created', 'task:updated', 'task:deleted', 'task:moved'];

interface UseKanbanSocketOptions {
  enabled?: boolean;
}

/**
 * Live board sync for a project.
 *
 * Subscribes to the project's WebSocket channel and refetches the current board
 * (debounced) whenever another user creates/updates/moves/deletes a task, so the
 * board stays in sync without a manual refresh. Events triggered by the current
 * user are ignored — the local optimistic update already applied them.
 *
 * DORMANT until `NEXT_PUBLIC_WS_URL` is set (e.g.
 * `ws://127.0.0.1:4010/api/v2/kanban/ws`). With it unset the hook is a no-op, so
 * it is safe to ship before the socket endpoint is reachable in an environment.
 * The backend appends board changes; the connection carries the JWT (added by
 * useWebSocket) and the `project` uuid as query params.
 */
export function useKanbanSocket(projectUuid?: string, options: UseKanbanSocketOptions = {}) {
  const enabled = options.enabled ?? true;
  const wsBase = process.env.NEXT_PUBLIC_WS_URL || '';
  const shouldConnect = enabled && Boolean(wsBase) && Boolean(projectUuid);

  const url = shouldConnect
    ? `${wsBase}${wsBase.includes('?') ? '&' : '?'}project=${encodeURIComponent(projectUuid as string)}`
    : 'ws://disabled';

  const refreshBoardData = useKanbanStore((s) => s.refreshBoardData);
  const currentUserUuid = useAuthStore((s) => s.user?.uuid);

  // Coalesce bursts of events (e.g. someone dragging several cards) into one refetch.
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const scheduleRefresh = useCallback(() => {
    if (debounceRef.current) clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(() => {
      void refreshBoardData();
    }, 400);
  }, [refreshBoardData]);

  const { status, isConnected, subscribe, connect, disconnect } = useWebSocket(url, {
    autoConnect: shouldConnect,
    reconnect: shouldConnect,
    maxReconnectAttempts: shouldConnect ? 8 : 0,
  });

  useEffect(() => {
    if (!shouldConnect) return;
    const unsubscribes = BOARD_EVENTS.map((evt) =>
      subscribe(evt, (data) => {
        const actor = (data as { actor_uuid?: string } | null)?.actor_uuid;
        if (actor && currentUserUuid && actor === currentUserUuid) return; // skip our own echo
        scheduleRefresh();
      })
    );
    return () => {
      unsubscribes.forEach((u) => u());
      if (debounceRef.current) clearTimeout(debounceRef.current);
    };
  }, [shouldConnect, subscribe, scheduleRefresh, currentUserUuid]);

  return {
    status: shouldConnect ? status : ('disconnected' as ConnectionStatus),
    isConnected: shouldConnect ? isConnected : false,
    connect,
    disconnect,
  };
}

export default useKanbanSocket;

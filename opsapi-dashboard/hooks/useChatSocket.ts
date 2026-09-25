'use client';

import { useCallback, useEffect, useRef } from 'react';
import { useWebSocket } from './useWebSocket';
import type { WebSocketMessage } from '@/types';
import type { ChatReaction } from '@/services/chat.service';

/** Derive the ws(s):// base from the http(s) API URL, so chat real-time works
 *  wherever the API host does — no extra env needed. */
function wsBaseFromApi(): string {
  const api = process.env.NEXT_PUBLIC_API_URL || '';
  if (!api) return '';
  try {
    const u = new URL(api);
    return `${u.protocol === 'https:' ? 'wss:' : 'ws:'}//${u.host}`;
  } catch {
    return '';
  }
}

export interface ChatWsNewMessage {
  channel_uuid: string;
  namespace_id?: number;
  message: {
    uuid: string;
    user_uuid: string;
    content: string;
    created_at: string;
    first_name?: string | null;
    last_name?: string | null;
    sender_username?: string | null;
    email?: string | null;
  };
}

export interface ChatWsReaction {
  channel_uuid: string;
  namespace_id?: number;
  message_uuid: string;
  reactions: ChatReaction[];
}

export interface ChatSocketHandlers {
  onMessage?: (data: ChatWsNewMessage) => void;
  onReaction?: (data: ChatWsReaction) => void;
}

/**
 * Live chat delivery over the backend WebSocket hub (lib/chat-ws.lua).
 *
 * Calls `onNewMessage` whenever any channel or DM you belong to receives a
 * message, so the UI can append it (active channel) or bump unread + toast.
 * The page's channel/message polling stays as a silent fallback for when the
 * socket can't connect (e.g. an edge that doesn't upgrade WebSockets).
 *
 * The connection is per-user (one socket serves you across all your
 * conversations and namespace switches); the JWT is added as `?token=` by
 * useWebSocket. `onNewMessage` is read through a ref so it always sees fresh
 * state without reconnecting.
 */
export function useChatSocket(
  handlers: ChatSocketHandlers,
  options: { enabled?: boolean } = {}
) {
  const base = wsBaseFromApi();
  // Only connect once we can (a WS base exists) AND the caller is ready (auth
  // hydrated) — avoids opening a socket before the token is available, which
  // would just fail and reconnect.
  const shouldConnect = (options.enabled ?? true) && Boolean(base);
  const url = shouldConnect ? `${base}/api/chat/ws` : 'ws://disabled';

  const handlersRef = useRef(handlers);
  useEffect(() => {
    handlersRef.current = handlers;
  }, [handlers]);

  const onMessage = useCallback((msg: WebSocketMessage) => {
    if (!msg || !msg.data) return;
    if (msg.type === 'message:new') {
      handlersRef.current.onMessage?.(msg.data as ChatWsNewMessage);
    } else if (msg.type === 'reaction:update') {
      handlersRef.current.onReaction?.(msg.data as ChatWsReaction);
    }
  }, []);

  const { status, isConnected } = useWebSocket(url, {
    autoConnect: shouldConnect,
    reconnect: shouldConnect,
    maxReconnectAttempts: shouldConnect ? 6 : 0,
    onMessage,
  });

  return { status, isConnected };
}

export default useChatSocket;

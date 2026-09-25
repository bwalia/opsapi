'use client';

import { useCallback, useEffect, useRef } from 'react';
import { useWebSocket } from './useWebSocket';
import type { WebSocketMessage } from '@/types';

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
export function useChatSocket(onNewMessage: (data: ChatWsNewMessage) => void) {
  const base = wsBaseFromApi();
  const shouldConnect = Boolean(base);
  const url = shouldConnect ? `${base}/api/chat/ws` : 'ws://disabled';

  const handlerRef = useRef(onNewMessage);
  useEffect(() => {
    handlerRef.current = onNewMessage;
  }, [onNewMessage]);

  const onMessage = useCallback((msg: WebSocketMessage) => {
    if (msg && msg.type === 'message:new' && msg.data) {
      handlerRef.current(msg.data as ChatWsNewMessage);
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

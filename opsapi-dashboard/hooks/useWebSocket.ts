import { useEffect, useRef, useCallback, useState } from 'react';
import type { WebSocketMessage, WebSocketEventType } from '@/types';

// ============================================
// Types
// ============================================

export type ConnectionStatus = 'connecting' | 'connected' | 'disconnected' | 'reconnecting';

interface UseWebSocketOptions {
  /** Auto-connect on mount (default: true) */
  autoConnect?: boolean;
  /** Reconnect on disconnect (default: true) */
  reconnect?: boolean;
  /** Max reconnection attempts (default: 10) */
  maxReconnectAttempts?: number;
  /** Initial reconnect delay in ms (default: 1000) */
  reconnectDelay?: number;
  /** Max reconnect delay in ms (default: 30000) */
  maxReconnectDelay?: number;
  /** Heartbeat interval in ms (default: 30000) */
  heartbeatInterval?: number;
  /** Message handler callback */
  onMessage?: (message: WebSocketMessage) => void;
  /** Connection opened callback */
  onOpen?: () => void;
  /** Connection closed callback */
  onClose?: (event: CloseEvent) => void;
  /** Error callback */
  onError?: (error: Event) => void;
  /** Status change callback */
  onStatusChange?: (status: ConnectionStatus) => void;
}

interface UseWebSocketReturn {
  /** Current connection status */
  status: ConnectionStatus;
  /** Whether the socket is connected */
  isConnected: boolean;
  /** Send a message through the socket */
  sendMessage: (message: WebSocketMessage) => void;
  /** Manually connect to the socket */
  connect: () => void;
  /** Manually disconnect from the socket */
  disconnect: () => void;
  /** Subscribe to specific event types */
  subscribe: (eventType: WebSocketEventType, handler: (data: unknown) => void) => () => void;
  /** Last received message */
  lastMessage: WebSocketMessage | null;
}

// ============================================
// WebSocket Hook
// ============================================

/**
 * Custom hook for WebSocket connection management
 *
 * FEATURES:
 * - Automatic reconnection with exponential backoff
 * - Heartbeat/ping-pong to detect stale connections
 * - Event subscription system
 * - Connection status tracking
 * - Graceful cleanup on unmount
 */
export function useWebSocket(
  url: string,
  options: UseWebSocketOptions = {}
): UseWebSocketReturn {
  const {
    autoConnect = true,
    reconnect = true,
    maxReconnectAttempts = 10,
    reconnectDelay = 1000,
    maxReconnectDelay = 30000,
    heartbeatInterval = 30000,
    onMessage,
    onOpen,
    onClose,
    onError,
    onStatusChange,
  } = options;

  const [status, setStatus] = useState<ConnectionStatus>('disconnected');
  const [lastMessage, setLastMessage] = useState<WebSocketMessage | null>(null);

  const socketRef = useRef<WebSocket | null>(null);
  const reconnectAttemptsRef = useRef(0);
  const reconnectTimeoutRef = useRef<NodeJS.Timeout | null>(null);
  const heartbeatTimeoutRef = useRef<NodeJS.Timeout | null>(null);
  const subscribersRef = useRef<Map<WebSocketEventType, Set<(data: unknown) => void>>>(new Map());
  const isMountedRef = useRef(true);

  // Update status with callback
  const updateStatus = useCallback((newStatus: ConnectionStatus) => {
    if (isMountedRef.current) {
      setStatus(newStatus);
      onStatusChange?.(newStatus);
    }
  }, [onStatusChange]);

  // Clear all timeouts
  const clearTimeouts = useCallback(() => {
    if (reconnectTimeoutRef.current) {
      clearTimeout(reconnectTimeoutRef.current);
      reconnectTimeoutRef.current = null;
    }
    if (heartbeatTimeoutRef.current) {
      clearTimeout(heartbeatTimeoutRef.current);
      heartbeatTimeoutRef.current = null;
    }
  }, []);

  // Start heartbeat
  const startHeartbeat = useCallback(() => {
    if (heartbeatTimeoutRef.current) {
      clearTimeout(heartbeatTimeoutRef.current);
    }

    heartbeatTimeoutRef.current = setTimeout(() => {
      if (socketRef.current?.readyState === WebSocket.OPEN) {
        socketRef.current.send(JSON.stringify({ type: 'ping' }));
        startHeartbeat();
      }
    }, heartbeatInterval);
  }, [heartbeatInterval]);

  // Calculate reconnect delay with exponential backoff
  const getReconnectDelay = useCallback(() => {
    const delay = Math.min(
      reconnectDelay * Math.pow(2, reconnectAttemptsRef.current),
      maxReconnectDelay
    );
    return delay + Math.random() * 1000; // Add jitter
  }, [reconnectDelay, maxReconnectDelay]);

  // Connect to WebSocket
  const connect = useCallback(() => {
    if (socketRef.current?.readyState === WebSocket.OPEN) {
      return;
    }

    // Get auth token for connection
    const token = typeof window !== 'undefined'
      ? localStorage.getItem('auth_token')
      : null;

    if (!token) {
      console.warn('[WebSocket] No auth token available');
      return;
    }

    try {
      updateStatus('connecting');
      const wsUrl = new URL(url);
      wsUrl.searchParams.set('token', token);

      socketRef.current = new WebSocket(wsUrl.toString());

      socketRef.current.onopen = () => {
        if (isMountedRef.current) {
          reconnectAttemptsRef.current = 0;
          updateStatus('connected');
          startHeartbeat();
          onOpen?.();
        }
      };

      socketRef.current.onmessage = (event) => {
        if (!isMountedRef.current) return;

        try {
          const message: WebSocketMessage = JSON.parse(event.data);

          // Handle pong response
          if (message.type === 'pong') {
            return;
          }

          setLastMessage(message);
          onMessage?.(message);

          // Notify subscribers
          const handlers = subscribersRef.current.get(message.type as WebSocketEventType);
          if (handlers) {
            handlers.forEach((handler) => handler(message.data));
          }
        } catch (error) {
          console.error('[WebSocket] Failed to parse message:', error);
        }
      };

      socketRef.current.onclose = (event) => {
        if (!isMountedRef.current) return;

        clearTimeouts();
        onClose?.(event);

        // Attempt reconnection if enabled and not a normal close
        if (reconnect && !event.wasClean && reconnectAttemptsRef.current < maxReconnectAttempts) {
          updateStatus('reconnecting');
          const delay = getReconnectDelay();
          reconnectAttemptsRef.current++;

          console.log(`[WebSocket] Reconnecting in ${Math.round(delay)}ms (attempt ${reconnectAttemptsRef.current}/${maxReconnectAttempts})`);

          reconnectTimeoutRef.current = setTimeout(() => {
            connect();
          }, delay);
        } else {
          updateStatus('disconnected');
        }
      };

      socketRef.current.onerror = (event) => {
        if (isMountedRef.current) {
          console.error('[WebSocket] Error:', event);
          onError?.(event);
        }
      };
    } catch (error) {
      console.error('[WebSocket] Connection error:', error);
      updateStatus('disconnected');
    }
  }, [url, updateStatus, startHeartbeat, onOpen, onMessage, onClose, onError, reconnect, maxReconnectAttempts, getReconnectDelay, clearTimeouts]);

  // Disconnect from WebSocket
  const disconnect = useCallback(() => {
    clearTimeouts();
    if (socketRef.current) {
      socketRef.current.close(1000, 'Client disconnect');
      socketRef.current = null;
    }
    updateStatus('disconnected');
  }, [clearTimeouts, updateStatus]);

  // Send message
  const sendMessage = useCallback((message: WebSocketMessage) => {
    if (socketRef.current?.readyState === WebSocket.OPEN) {
      socketRef.current.send(JSON.stringify(message));
    } else {
      console.warn('[WebSocket] Cannot send message - not connected');
    }
  }, []);

  // Subscribe to event type
  const subscribe = useCallback((
    eventType: WebSocketEventType,
    handler: (data: unknown) => void
  ): (() => void) => {
    if (!subscribersRef.current.has(eventType)) {
      subscribersRef.current.set(eventType, new Set());
    }
    subscribersRef.current.get(eventType)!.add(handler);

    // Return unsubscribe function
    return () => {
      subscribersRef.current.get(eventType)?.delete(handler);
    };
  }, []);

  // Auto-connect on mount
  useEffect(() => {
    isMountedRef.current = true;

    if (autoConnect) {
      connect();
    }

    return () => {
      isMountedRef.current = false;
      disconnect();
    };
  }, [autoConnect, connect, disconnect]);

  return {
    status,
    isConnected: status === 'connected',
    sendMessage,
    connect,
    disconnect,
    subscribe,
    lastMessage,
  };
}

// ============================================
// Notification-specific WebSocket Hook
// ============================================

interface UseNotificationSocketOptions {
  /** Whether to connect automatically */
  enabled?: boolean;
  /** Callback when new notification arrives */
  onNotification?: (notification: unknown) => void;
  /** Callback when task is updated */
  onTaskUpdate?: (data: unknown) => void;
  /** Callback when timer event occurs */
  onTimerEvent?: (data: unknown) => void;
}

/**
 * Specialized WebSocket hook for notifications
 * Provides a simpler API for common notification patterns
 */
export function useNotificationSocket(options: UseNotificationSocketOptions = {}) {
  const {
    enabled = true,
    onNotification,
    onTaskUpdate,
    onTimerEvent,
  } = options;

  const wsUrl = process.env.NEXT_PUBLIC_WS_URL ||
    (typeof window !== 'undefined'
      ? `${window.location.protocol === 'https:' ? 'wss:' : 'ws:'}//${window.location.host}/ws`
      : 'ws://localhost:4010/ws');

  const {
    status,
    isConnected,
    subscribe,
    connect,
    disconnect,
  } = useWebSocket(wsUrl, {
    autoConnect: enabled,
    onMessage: (message) => {
      // Handle notification events
      if (message.type === 'notification:new' && onNotification) {
        onNotification(message.data);
      }
      if (message.type === 'task:updated' && onTaskUpdate) {
        onTaskUpdate(message.data);
      }
      if ((message.type === 'timer:started' || message.type === 'timer:stopped') && onTimerEvent) {
        onTimerEvent(message.data);
      }
    },
  });

  return {
    status,
    isConnected,
    subscribe,
    connect,
    disconnect,
  };
}

export default useWebSocket;

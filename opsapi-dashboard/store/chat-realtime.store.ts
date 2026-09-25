/**
 * Chat real-time state shared between the app-wide ChatNotifier (which owns the
 * single chat WebSocket) and the chat page (which renders it).
 *
 * - `status`        socket state for the Live/Connecting/Offline badge
 * - `activeChannel` what the chat page has open, so the notifier stays quiet for it
 * - `openRequest`   a channel a notification click asked the chat page to open
 * - `onChatEvent()` subscribe to raw socket events (message:new / reaction:update / agent:done)
 */
import { create } from 'zustand';
import type { ConnectionStatus } from '@/hooks/useWebSocket';
import type { ChatWsNewMessage, ChatWsReaction, ChatWsAgentDone } from '@/hooks/useChatSocket';

export type ChatEvent =
  | { type: 'message'; data: ChatWsNewMessage }
  | { type: 'reaction'; data: ChatWsReaction }
  | { type: 'agent'; data: ChatWsAgentDone };

interface ChatRealtimeState {
  status: ConnectionStatus;
  activeChannel: string;
  openRequest: string | null;
}

/** Rail/notification id for the AI-assistant conversation. */
export const AGENT_ID = '__agent__';

export const useChatRealtime = create<ChatRealtimeState>(() => ({
  status: 'disconnected',
  activeChannel: '',
  openRequest: null,
}));

const listeners = new Set<(e: ChatEvent) => void>();

export function onChatEvent(fn: (e: ChatEvent) => void) {
  listeners.add(fn);
  return () => {
    listeners.delete(fn);
  };
}

export function emitChatEvent(e: ChatEvent) {
  listeners.forEach((fn) => fn(e));
}

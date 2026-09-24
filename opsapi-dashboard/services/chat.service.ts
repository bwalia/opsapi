import apiClient, { buildQueryString } from '@/lib/api-client';

/**
 * Chat API client — Slack-like messaging, backed by the Lua `chat-*` routes
 * (`/api/chat/*`). The backend is a full system (channels, DMs, threads,
 * reactions, mentions, presence, files); this MVP covers channels + messages +
 * membership. Real-time is polling for now (no WS endpoint wired yet).
 */

export interface ChatChannel {
  uuid: string;
  name: string;
  description?: string | null;
  topic?: string | null;
  channel_type?: string; // 'public' | 'private' | 'direct' | 'business'
  is_private?: boolean;
  member_count?: number;
  unread_count?: number;
  last_message_at?: string | null;
  created_at?: string;
  // Present on direct channels — the other participant's display name.
  peer_name?: string | null;
}

export interface ChatMessage {
  uuid: string;
  channel_uuid?: string;
  user_uuid: string;
  content: string;
  content_type?: string;
  created_at: string;
  updated_at?: string;
  is_edited?: boolean;
  is_pinned?: boolean;
  reply_count?: number;
  parent_message_uuid?: string | null;
  // Joined sender info (see ChatMessageQueries.getByChannel).
  first_name?: string | null;
  last_name?: string | null;
  email?: string | null;
  sender_username?: string | null;
  reactions?: Array<{ emoji: string; count: number; users?: string[] }>;
  // Client-only marker for an optimistically-sent message.
  _pending?: boolean;
}

export interface ChatMentionableUser {
  uuid: string;
  first_name?: string | null;
  last_name?: string | null;
  email?: string | null;
  username?: string | null;
}

const JSON_BODY = { headers: { 'Content-Type': 'application/json' } } as const;

function unwrap<T>(res: { data: unknown }): T {
  const body = res.data as { data?: T };
  return (body?.data ?? body) as T;
}

function toList<T>(res: { data: unknown }): T[] {
  const body = res.data as { data?: T[] } | T[];
  if (Array.isArray(body)) return body;
  return Array.isArray((body as { data?: T[] })?.data) ? ((body as { data?: T[] }).data as T[]) : [];
}

/** Best-effort display name for a message sender. */
export function senderName(m: Pick<ChatMessage, 'first_name' | 'last_name' | 'sender_username' | 'email'>): string {
  const full = `${m.first_name || ''} ${m.last_name || ''}`.trim();
  return full || m.sender_username || m.email || 'Unknown';
}

export const chatService = {
  async listChannels(): Promise<ChatChannel[]> {
    return toList<ChatChannel>(await apiClient.get('/api/chat/channels'));
  },

  async getDefaults(): Promise<ChatChannel[]> {
    return toList<ChatChannel>(await apiClient.get('/api/chat/channels/defaults'));
  },

  async createChannel(data: {
    name: string;
    description?: string;
    channel_type?: string;
    is_private?: boolean;
  }): Promise<ChatChannel> {
    return unwrap<ChatChannel>(await apiClient.post('/api/chat/channels', data, JSON_BODY));
  },

  async joinChannel(uuid: string): Promise<void> {
    await apiClient.post(`/api/chat/channels/${uuid}/join`, {}, JSON_BODY);
  },

  async markRead(uuid: string): Promise<void> {
    await apiClient.post(`/api/chat/channels/${uuid}/read`, {}, JSON_BODY);
  },

  // Messages are returned oldest-or-newest first depending on the query; the UI
  // sorts by created_at, so order here doesn't matter.
  async listMessages(channelUuid: string, params: Record<string, unknown> = {}): Promise<ChatMessage[]> {
    return toList<ChatMessage>(
      await apiClient.get(`/api/chat/channels/${channelUuid}/messages${buildQueryString(params)}`)
    );
  },

  async sendMessage(channelUuid: string, content: string): Promise<ChatMessage> {
    return unwrap<ChatMessage>(
      await apiClient.post(
        `/api/chat/channels/${channelUuid}/messages`,
        { content, content_type: 'text' },
        JSON_BODY
      )
    );
  },

  async searchUsers(q: string): Promise<ChatMentionableUser[]> {
    if (!q.trim()) return [];
    return toList<ChatMentionableUser>(await apiClient.get(`/api/chat/users/search${buildQueryString({ q })}`));
  },

  async createDirect(userUuid: string): Promise<ChatChannel> {
    return unwrap<ChatChannel>(
      await apiClient.post('/api/chat/channels/direct', { user_uuid: userUuid }, JSON_BODY)
    );
  },
};

export default chatService;

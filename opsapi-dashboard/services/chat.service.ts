import apiClient, { buildQueryString } from '@/lib/api-client';

/**
 * Chat API client — Slack-like messaging, backed by the Lua `chat-*` routes
 * (`/api/chat/*`). Covers channels, direct messages, members, message list +
 * send, user search and presence. Everything is namespace-gated server-side
 * (channels are filtered to the current namespace; user search is scoped to
 * namespace members) via the `X-Namespace-Id` header the api-client injects.
 * Real-time is polling for now (no WS endpoint wired yet).
 */

export type ChannelType = 'public' | 'private' | 'direct' | 'business';

export interface ChatChannel {
  uuid: string;
  name: string;
  description?: string | null;
  topic?: string | null;
  type?: ChannelType;
  channel_type?: string; // legacy alias some responses use
  is_private?: boolean;
  member_role?: string | null; // caller's role in this channel (admin|moderator|member)
  member_count?: number;
  unread_count?: number;
  last_message_at?: string | null;
  created_at?: string;
  // Present on direct channels — the other participant (relative to caller).
  other_user_uuid?: string | null;
  other_user_first_name?: string | null;
  other_user_last_name?: string | null;
  other_user_email?: string | null;
  other_user_username?: string | null;
  other_user_status?: PresenceStatus | null;
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

export interface ChatMember {
  user_uuid: string;
  role?: string;
  joined_at?: string;
  is_muted?: boolean;
  first_name?: string | null;
  last_name?: string | null;
  email?: string | null;
  username?: string | null;
}

export type PresenceStatus = 'online' | 'away' | 'dnd' | 'offline';

export interface ChatUser {
  uuid: string;
  username?: string | null;
  display_name?: string | null;
  first_name?: string | null;
  last_name?: string | null;
  email?: string | null;
  status?: PresenceStatus;
  is_chat_active?: boolean;
  // Can this person actually be pulled into chat here? (RBAC + tenancy —
  // active member of this namespace with a chat-module grant.) false ⇒ the UI
  // blocks selecting them and prompts to grant Chat access.
  has_chat_access?: boolean;
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

function fullName(p: {
  first_name?: string | null;
  last_name?: string | null;
}): string {
  return `${p.first_name || ''} ${p.last_name || ''}`.trim();
}

/** Best-effort display name for a message sender. */
export function senderName(
  m: Pick<ChatMessage, 'first_name' | 'last_name' | 'sender_username' | 'email'>
): string {
  return fullName(m) || m.sender_username || m.email || 'Unknown';
}

/** Best-effort display name for a channel member or searchable user. */
export function personName(p: {
  first_name?: string | null;
  last_name?: string | null;
  display_name?: string | null;
  username?: string | null;
  email?: string | null;
}): string {
  return p.display_name || fullName(p) || p.username || p.email || 'Unknown';
}

/** Is this a 1:1 direct-message channel? */
export function isDirect(c: ChatChannel): boolean {
  return (c.type || c.channel_type) === 'direct';
}

/** What to show as the channel's title — the peer's name for a DM. */
export function channelTitle(c: ChatChannel): string {
  if (isDirect(c)) {
    return (
      fullName({ first_name: c.other_user_first_name, last_name: c.other_user_last_name }) ||
      c.other_user_username ||
      c.other_user_email ||
      'Direct message'
    );
  }
  return c.name || 'channel';
}

export const chatService = {
  async listChannels(): Promise<ChatChannel[]> {
    return toList<ChatChannel>(await apiClient.get('/api/chat/channels'));
  },

  /** Seed the default channels for this workspace (best-effort; needs a business). */
  async createDefaults(): Promise<ChatChannel[]> {
    const res = await apiClient.post('/api/chat/channels/defaults', {}, JSON_BODY);
    const body = res.data as { channels?: ChatChannel[] };
    return body?.channels ?? [];
  },

  async getChannel(uuid: string): Promise<ChatChannel> {
    return unwrap<ChatChannel>(await apiClient.get(`/api/chat/channels/${uuid}`));
  },

  async createChannel(data: {
    name: string;
    description?: string;
    type?: ChannelType;
    members?: string[];
  }): Promise<ChatChannel> {
    // Backend keys on `type` (public|private|direct) — NOT channel_type/is_private.
    return unwrap<ChatChannel>(await apiClient.post('/api/chat/channels', data, JSON_BODY));
  },

  async joinChannel(uuid: string): Promise<void> {
    await apiClient.post(`/api/chat/channels/${uuid}/join`, {}, JSON_BODY);
  },

  async markRead(uuid: string): Promise<void> {
    await apiClient.post(`/api/chat/channels/${uuid}/read`, {}, JSON_BODY);
  },

  async listMembers(channelUuid: string): Promise<ChatMember[]> {
    return toList<ChatMember>(await apiClient.get(`/api/chat/channels/${channelUuid}/members`));
  },

  async addMembers(channelUuid: string, userUuids: string[], role = 'member'): Promise<void> {
    await apiClient.post(
      `/api/chat/channels/${channelUuid}/members`,
      { user_uuids: userUuids, role },
      JSON_BODY
    );
  },

  async removeMember(channelUuid: string, userUuid: string): Promise<void> {
    await apiClient.delete(`/api/chat/channels/${channelUuid}/members/${userUuid}`);
  },

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

  /** Search users in the current namespace (min 2 chars). */
  async searchUsers(q: string): Promise<ChatUser[]> {
    if (q.trim().length < 2) return [];
    return toList<ChatUser>(await apiClient.get(`/api/chat/users/search${buildQueryString({ q })}`));
  },

  /** Open (or reuse) a direct-message channel with another user. */
  async createDirect(userUuid: string): Promise<ChatChannel> {
    const res = await apiClient.post('/api/chat/channels/direct', { user_uuid: userUuid }, JSON_BODY);
    const body = res.data as { channel?: ChatChannel };
    return (body?.channel ?? unwrap<ChatChannel>(res)) as ChatChannel;
  },

  /** Advertise the caller's presence (best-effort). */
  async setPresence(status: PresenceStatus): Promise<void> {
    await apiClient.put('/api/chat/presence', { status }, JSON_BODY);
  },
};

export default chatService;

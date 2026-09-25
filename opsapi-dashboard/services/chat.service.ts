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

export interface ChatAttachment {
  file_name: string;
  file_url: string;
  file_type?: string | null;
  file_size?: number | null;
  thumbnail_url?: string | null;
}

export interface ChatReaction {
  emoji: string;
  count: number;
  user_uuids?: string[];
}

/** A quoted message a reply points back to (self-contained so it renders even
 *  after the original scrolls out of the loaded window). Rides in metadata. */
export interface ChatReplyRef {
  uuid: string;
  sender: string;
  preview: string;
}

export interface ChatMessageMetadata {
  reply_to?: ChatReplyRef;
  [k: string]: unknown;
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
  attachments?: ChatAttachment[];
  // Joined sender info (see ChatMessageQueries.getByChannel).
  first_name?: string | null;
  last_name?: string | null;
  email?: string | null;
  sender_username?: string | null;
  reactions?: ChatReaction[];
  metadata?: ChatMessageMetadata | null;
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

// A tool the agent invoked during a turn (create_timesheet, create_customer, …).
export interface AgentAction {
  name: string;
  args?: Record<string, unknown>;
  result?: unknown;
  error?: string | null;
}

// One turn in the agent conversation (client-side only — the agent is not a
// persisted channel; the whole history is sent on each request).
export interface AgentTurn {
  role: 'user' | 'assistant';
  content: string;
  actions?: AgentAction[];
}

export interface AgentConversation {
  run_uuid?: string;
  status: 'idle' | 'running' | 'done' | 'error';
  turns: AgentTurn[];
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

  async sendMessage(
    channelUuid: string,
    content: string,
    attachments?: ChatAttachment[],
    metadata?: ChatMessageMetadata
  ): Promise<ChatMessage> {
    return unwrap<ChatMessage>(
      await apiClient.post(
        `/api/chat/channels/${channelUuid}/messages`,
        {
          content,
          content_type: 'text',
          attachments: attachments && attachments.length ? attachments : undefined,
          metadata: metadata && Object.keys(metadata).length ? metadata : undefined,
        },
        JSON_BODY
      )
    );
  },

  /** Add/remove an emoji reaction on a message; returns the full new set. */
  async toggleReaction(messageUuid: string, emoji: string): Promise<ChatReaction[]> {
    const res = await apiClient.post(
      `/api/chat/messages/${messageUuid}/reactions/toggle`,
      { emoji },
      JSON_BODY
    );
    const body = res.data as { all_reactions?: ChatReaction[] };
    return body?.all_reactions ?? [];
  },

  /**
   * Upload a file to MinIO via the shared uploader and return an attachment
   * reference (the binary goes to storage; messages carry file_url references,
   * not bytes). Mirrors the kanban attachment flow.
   */
  async uploadFile(file: File): Promise<ChatAttachment> {
    const fd = new FormData();
    fd.append('file', file);
    fd.append('prefix', 'chat-attachments');
    const res = await apiClient.post('/api/v2/documents/upload', fd);
    const body = res.data as {
      data?: { url: string; filename?: string; content_type?: string; size?: number };
      url?: string;
      filename?: string;
      content_type?: string;
      size?: number;
    };
    const d = body?.data ?? body;
    return {
      file_name: file.name || d.filename || 'file',
      file_url: d.url as string,
      file_type: d.content_type || file.type || undefined,
      file_size: d.size ?? file.size,
    };
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

  /**
   * Grant the Chat module to namespace members who lack it (owner/admin only —
   * enforced server-side). Powers the "grant + add in one click" flow. Targets
   * must already be members of the current namespace.
   */
  async grantChatAccess(userUuids: string[]): Promise<void> {
    if (userUuids.length === 0) return;
    await apiClient.post('/api/chat/access/grant', { user_uuids: userUuids }, JSON_BODY);
  },

  /**
   * AI assistant. The conversation lives server-side and each turn runs in the
   * background (survives reloads / page changes / closed tabs); completion is
   * pushed as the "agent:done" WebSocket event, with polling as a fallback.
   */
  async getAgentConversation(): Promise<AgentConversation> {
    const res = await apiClient.get('/api/chat/agent/conversation');
    const b = res.data as Partial<AgentConversation>;
    return { run_uuid: b?.run_uuid, status: b?.status ?? 'idle', turns: b?.turns ?? [] };
  },

  /** Start a turn. Resolves as soon as the run is queued (202). */
  async sendAgentMessage(message: string): Promise<AgentConversation> {
    const res = await apiClient.post('/api/chat/agent', { message }, JSON_BODY);
    const b = res.data as Partial<AgentConversation>;
    return { run_uuid: b?.run_uuid, status: b?.status ?? 'running', turns: b?.turns ?? [] };
  },

  /** "New chat" — archive the current conversation. */
  async resetAgentConversation(): Promise<void> {
    await apiClient.delete('/api/chat/agent/conversation');
  },
};

export default chatService;

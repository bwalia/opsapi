'use client';

// Chat — a modern, Slack/Discord-style workspace messenger over the Lua
// `/api/chat/*` backend. Three panes: channels + DMs rail · conversation ·
// members. Namespace-gated end to end (the api-client sends X-Namespace-Id and
// the backend scopes channels + user search to the current tenant), so the rail
// reloads when the active namespace changes.
import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import toast from 'react-hot-toast';
import {
  Hash,
  Lock,
  Send,
  Plus,
  MessageSquare,
  MessagesSquare,
  Loader2,
  RefreshCw,
  Users,
  UserPlus,
  X,
  Search,
  ChevronLeft,
  Trash2,
  Shield,
  Paperclip,
  FileText,
  Download,
} from 'lucide-react';
import { ProtectedPage } from '@/components/permissions';
import { Modal, Button } from '@/components/ui';
import { useAuthStore } from '@/store/auth.store';
import { useNamespace } from '@/contexts/NamespaceContext';
import { usePermissions } from '@/contexts/PermissionsContext';
import { useChatSocket, type ChatWsNewMessage } from '@/hooks/useChatSocket';
import type { ConnectionStatus } from '@/hooks/useWebSocket';
import {
  chatService,
  senderName,
  personName,
  channelTitle,
  isDirect,
  type ChatChannel,
  type ChatMessage,
  type ChatMember,
  type ChatUser,
  type ChatAttachment,
  type PresenceStatus,
} from '@/services/chat.service';

const POLL_MS = 4000;
const GROUP_WINDOW_MS = 5 * 60 * 1000; // group consecutive messages within 5 min

const NO_CHAT_ACCESS_MSG =
  "This person doesn't have access to the Chat module in this workspace. Ask a namespace owner or admin to grant them Chat access first.";

/** Prefer a backend-supplied message (e.g. the RBAC 403) over a generic one. */
function errMessage(e: unknown, fallback: string): string {
  const m = (e as { response?: { data?: { message?: string; error?: string } } })?.response?.data;
  return m?.message || fallback;
}

/**
 * "Grant + add in one click": before adding, grant Chat access to any selected
 * people who don't have it yet (only an owner/admin `canGrant` reaches here;
 * the backend re-checks). Returns how many were granted.
 */
async function grantSelected(users: ChatUser[], canGrant: boolean): Promise<number> {
  if (!canGrant) return 0;
  const need = users.filter((u) => u.has_chat_access === false).map((u) => u.uuid);
  if (need.length > 0) await chatService.grantChatAccess(need);
  return need.length;
}

// ---------- small helpers ----------

function initials(name: string): string {
  const parts = name.trim().split(/\s+/);
  return ((parts[0]?.[0] || '') + (parts[1]?.[0] || '')).toUpperCase() || '?';
}

function timeLabel(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

function dayLabel(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  const today = new Date();
  const yst = new Date();
  yst.setDate(today.getDate() - 1);
  if (d.toDateString() === today.toDateString()) return 'Today';
  if (d.toDateString() === yst.toDateString()) return 'Yesterday';
  return d.toLocaleDateString([], { month: 'short', day: 'numeric', year: 'numeric' });
}

// Fixed, vivid avatar colours read well on both light and dark surfaces.
const AVATAR_COLORS = [
  'bg-rose-500',
  'bg-orange-500',
  'bg-amber-500',
  'bg-emerald-500',
  'bg-teal-500',
  'bg-sky-500',
  'bg-indigo-500',
  'bg-violet-500',
  'bg-fuchsia-500',
];
function avatarColor(key: string): string {
  let h = 0;
  for (let i = 0; i < key.length; i++) h = (h * 31 + key.charCodeAt(i)) >>> 0;
  return AVATAR_COLORS[h % AVATAR_COLORS.length];
}

const PRESENCE: Record<PresenceStatus, { dot: string; label: string }> = {
  online: { dot: 'bg-emerald-500', label: 'Online' },
  away: { dot: 'bg-amber-500', label: 'Away' },
  dnd: { dot: 'bg-rose-500', label: 'Do not disturb' },
  offline: { dot: 'bg-secondary-300', label: 'Offline' },
};

function Avatar({
  name,
  status,
  size = 'md',
  seed,
}: {
  name: string;
  status?: PresenceStatus | null;
  size?: 'sm' | 'md' | 'lg';
  seed?: string;
}) {
  const dim = size === 'lg' ? 'h-10 w-10 text-sm' : size === 'sm' ? 'h-7 w-7 text-[10px]' : 'h-9 w-9 text-xs';
  const dotDim = size === 'lg' ? 'h-3 w-3' : 'h-2.5 w-2.5';
  const p = status ? PRESENCE[status] : null;
  return (
    <span className="relative inline-flex shrink-0">
      <span
        className={`inline-flex items-center justify-center rounded-full font-semibold text-white ${dim} ${avatarColor(
          seed || name
        )}`}
        aria-hidden="true"
      >
        {initials(name)}
      </span>
      {p && (
        <span
          className={`absolute -bottom-0.5 -right-0.5 rounded-full ring-2 ring-surface ${dotDim} ${p.dot}`}
          title={p.label}
        />
      )}
    </span>
  );
}

function ChannelGlyph({ channel, className = '' }: { channel: ChatChannel; className?: string }) {
  const priv = channel.is_private || channel.type === 'private';
  const Icon = priv ? Lock : Hash;
  return <Icon className={`h-4 w-4 shrink-0 ${className}`} aria-hidden="true" />;
}

// Live real-time status: green = socket connected, amber pulse = (re)connecting,
// grey = no socket (delivery falls back to polling — not an error).
function ConnBadge({ status }: { status: ConnectionStatus }) {
  const map: Record<ConnectionStatus, { dot: string; label: string; title: string; pulse: boolean }> = {
    connected: { dot: 'bg-emerald-500', label: 'Live', title: 'Real-time connected', pulse: false },
    connecting: { dot: 'bg-amber-500', label: 'Connecting', title: 'Connecting…', pulse: true },
    reconnecting: { dot: 'bg-amber-500', label: 'Connecting', title: 'Reconnecting…', pulse: true },
    disconnected: {
      dot: 'bg-secondary-300',
      label: 'Offline',
      title: 'Real-time unavailable — messages still sync by polling',
      pulse: false,
    },
  };
  const s = map[status] ?? map.disconnected;
  return (
    <span
      className="hidden items-center gap-1.5 rounded-full px-2 py-0.5 text-[11px] font-medium text-secondary-500 sm:inline-flex"
      title={s.title}
    >
      <span className={`h-2 w-2 rounded-full ${s.dot} ${s.pulse ? 'animate-pulse' : ''}`} aria-hidden="true" />
      {s.label}
    </span>
  );
}

function isImageAttachment(a: ChatAttachment): boolean {
  return !!a.file_type && a.file_type.startsWith('image/');
}

function formatFileSize(bytes?: number | null): string {
  if (!bytes || bytes <= 0) return '';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

// One attachment inside a message bubble: an inline thumbnail for images,
// otherwise a downloadable file chip. `mine` tints it to sit on the sender bubble.
function AttachmentView({ a, mine }: { a: ChatAttachment; mine: boolean }) {
  if (isImageAttachment(a)) {
    return (
      <a href={a.file_url} target="_blank" rel="noopener noreferrer" className="block">
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          src={a.file_url}
          alt={a.file_name}
          loading="lazy"
          className="max-h-56 max-w-full rounded-lg object-cover"
        />
      </a>
    );
  }
  return (
    <a
      href={a.file_url}
      target="_blank"
      rel="noopener noreferrer"
      className={`flex items-center gap-2 rounded-lg border px-3 py-2 ${
        mine ? 'border-white/30 hover:bg-white/10' : 'border-secondary-200 hover:bg-secondary-50'
      }`}
    >
      <FileText className="h-5 w-5 shrink-0 opacity-80" />
      <span className="min-w-0 flex-1">
        <span className="block truncate font-medium">{a.file_name}</span>
        {a.file_size ? <span className="block text-xs opacity-70">{formatFileSize(a.file_size)}</span> : null}
      </span>
      <Download className="h-4 w-4 shrink-0 opacity-70" />
    </a>
  );
}

// ---------- user picker (search + select), reused by 3 modals ----------

function UserPicker({
  mode,
  selected = [],
  onToggle,
  onPick,
  excludeUuids = [],
  autoFocus,
  canGrant = false,
}: {
  mode: 'single' | 'multi';
  selected?: ChatUser[];
  onToggle?: (u: ChatUser) => void;
  onPick?: (u: ChatUser) => void;
  excludeUuids?: string[];
  autoFocus?: boolean;
  canGrant?: boolean;
}) {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<ChatUser[]>([]);
  const [loading, setLoading] = useState(false);
  const selectedUuids = useMemo(() => new Set(selected.map((u) => u.uuid)), [selected]);

  useEffect(() => {
    const q = query.trim();
    if (q.length < 2) {
      setResults([]);
      setLoading(false);
      return;
    }
    setLoading(true);
    const id = setTimeout(async () => {
      try {
        const users = await chatService.searchUsers(q);
        setResults(users.filter((u) => !excludeUuids.includes(u.uuid)));
      } catch {
        setResults([]);
      } finally {
        setLoading(false);
      }
    }, 300);
    return () => clearTimeout(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [query]);

  return (
    <div className="space-y-3">
      {mode === 'multi' && selected.length > 0 && (
        <div className="flex flex-wrap gap-1.5">
          {selected.map((u) => (
            <span
              key={u.uuid}
              className="inline-flex items-center gap-1 rounded-full bg-primary-100 py-1 pl-1 pr-2 text-xs font-medium text-primary-800"
            >
              <Avatar name={personName(u)} size="sm" seed={u.uuid} />
              {personName(u)}
              <button
                type="button"
                onClick={() => onToggle?.(u)}
                className="rounded-full p-0.5 hover:bg-primary-200"
                aria-label={`Remove ${personName(u)}`}
              >
                <X className="h-3 w-3" />
              </button>
            </span>
          ))}
        </div>
      )}

      <div className="relative">
        <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-secondary-400" />
        <input
          type="text"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          autoFocus={autoFocus}
          placeholder="Search people by name or email…"
          className="w-full rounded-lg border border-secondary-300 bg-surface py-2.5 pl-9 pr-3 text-sm text-secondary-900 placeholder:text-secondary-400 focus:border-transparent focus:outline-none focus-visible:outline-none focus:ring-2 focus:ring-primary-500"
        />
      </div>

      <div className="max-h-64 overflow-y-auto rounded-lg border border-secondary-100">
        {loading ? (
          <div className="flex justify-center py-6 text-secondary-400">
            <Loader2 className="h-4 w-4 animate-spin" />
          </div>
        ) : query.trim().length < 2 ? (
          <p className="px-3 py-6 text-center text-xs text-secondary-400">
            Type at least 2 characters to search your workspace.
          </p>
        ) : results.length === 0 ? (
          <p className="px-3 py-6 text-center text-xs text-secondary-400">No people found.</p>
        ) : (
          results.map((u) => {
            const picked = selectedUuids.has(u.uuid);
            const noAccess = u.has_chat_access === false;
            const willGrant = noAccess && canGrant; // selectable; access granted on add
            const blocked = noAccess && !canGrant; // can't select; must ask an admin
            const onRowClick = () => {
              if (blocked) {
                toast.error(NO_CHAT_ACCESS_MSG);
                return;
              }
              return mode === 'single' ? onPick?.(u) : onToggle?.(u);
            };
            return (
              <button
                key={u.uuid}
                type="button"
                onClick={onRowClick}
                aria-disabled={blocked}
                title={blocked ? NO_CHAT_ACCESS_MSG : willGrant ? 'Will be granted Chat access' : undefined}
                className={`flex w-full items-center gap-3 px-3 py-2 text-left transition hover:bg-secondary-50 ${
                  picked ? 'bg-primary-50' : ''
                } ${blocked ? 'opacity-70' : ''}`}
              >
                <Avatar name={personName(u)} status={noAccess ? undefined : u.status} size="sm" seed={u.uuid} />
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-sm font-medium text-secondary-900">
                    {personName(u)}
                  </span>
                  {willGrant ? (
                    <span className="block truncate text-xs text-amber-600">
                      No Chat access yet — will be granted
                    </span>
                  ) : (
                    u.email && <span className="block truncate text-xs text-secondary-400">{u.email}</span>
                  )}
                </span>
                {blocked ? (
                  <span className="inline-flex shrink-0 items-center gap-1 rounded-full bg-secondary-100 px-2 py-0.5 text-[10px] font-semibold text-secondary-500">
                    <Lock className="h-3 w-3" />
                    No access
                  </span>
                ) : (
                  mode === 'multi' && (
                    <span
                      className={`flex h-5 w-5 shrink-0 items-center justify-center rounded-md border ${
                        picked ? 'border-primary-500 bg-primary-500 text-white' : 'border-secondary-300'
                      }`}
                    >
                      {picked && <span className="text-[11px] leading-none">✓</span>}
                    </span>
                  )
                )}
              </button>
            );
          })
        )}
      </div>
    </div>
  );
}

// ---------- members panel ----------

function MembersList({
  members,
  loading,
  myUuid,
  canManage,
  onRemove,
  onAdd,
}: {
  members: ChatMember[];
  loading: boolean;
  myUuid?: string;
  canManage: boolean;
  onRemove: (m: ChatMember) => void;
  onAdd: () => void;
}) {
  const roleBadge = (role?: string) => {
    if (role === 'admin') return { label: 'Admin', cls: 'bg-primary-100 text-primary-700' };
    if (role === 'moderator') return { label: 'Mod', cls: 'bg-amber-100 text-amber-700' };
    return null;
  };
  return (
    <div className="flex h-full flex-col">
      <div className="flex items-center justify-between px-4 py-3">
        <h3 className="flex items-center gap-1.5 text-sm font-semibold text-secondary-800">
          <Users className="h-4 w-4" /> Members
          <span className="text-secondary-400">· {members.length}</span>
        </h3>
        {canManage && (
          <button
            type="button"
            onClick={onAdd}
            className="rounded-md p-1 text-secondary-500 hover:bg-secondary-100 hover:text-secondary-700"
            title="Add members"
            aria-label="Add members"
          >
            <UserPlus className="h-4 w-4" />
          </button>
        )}
      </div>
      <div className="flex-1 overflow-y-auto px-2 pb-3">
        {loading ? (
          <div className="flex justify-center py-6 text-secondary-400">
            <Loader2 className="h-4 w-4 animate-spin" />
          </div>
        ) : members.length === 0 ? (
          <p className="px-2 py-4 text-xs text-secondary-400">No members yet.</p>
        ) : (
          members.map((m) => {
            const name = personName(m);
            const badge = roleBadge(m.role);
            const isMe = !!myUuid && m.user_uuid === myUuid;
            return (
              <div
                key={m.user_uuid}
                className="group flex items-center gap-2.5 rounded-lg px-2 py-1.5 hover:bg-secondary-50"
              >
                <Avatar name={name} size="sm" seed={m.user_uuid} />
                <span className="min-w-0 flex-1">
                  <span className="flex items-center gap-1.5">
                    <span className="truncate text-sm font-medium text-secondary-800">
                      {name}
                      {isMe && <span className="ml-1 text-xs font-normal text-secondary-400">(you)</span>}
                    </span>
                    {badge && (
                      <span
                        className={`inline-flex items-center gap-0.5 rounded px-1.5 py-0.5 text-[10px] font-semibold ${badge.cls}`}
                      >
                        {m.role === 'admin' && <Shield className="h-2.5 w-2.5" />}
                        {badge.label}
                      </span>
                    )}
                  </span>
                  {m.email && <span className="block truncate text-xs text-secondary-400">{m.email}</span>}
                </span>
                {canManage && !isMe && (
                  <button
                    type="button"
                    onClick={() => onRemove(m)}
                    className="rounded-md p-1 text-secondary-400 opacity-0 transition hover:bg-rose-50 hover:text-rose-600 group-hover:opacity-100"
                    title={`Remove ${name}`}
                    aria-label={`Remove ${name}`}
                  >
                    <Trash2 className="h-3.5 w-3.5" />
                  </button>
                )}
              </div>
            );
          })
        )}
      </div>
    </div>
  );
}

// ---------- main page ----------

export default function ChatPage() {
  const user = useAuthStore((s) => s.user);
  const myUuid = (user as { uuid?: string } | null)?.uuid;
  const { currentNamespace, isNamespaceOwner, hasPermission } = useNamespace();
  const { isAdmin } = usePermissions();
  const nsKey = currentNamespace?.uuid || '';
  // Can this actor grant Chat access to others? (platform admin, namespace
  // owner, or a role that can manage namespace roles/permissions). Enables the
  // "grant + add in one click" path; the backend re-checks either way.
  const canGrant =
    isAdmin ||
    isNamespaceOwner ||
    hasPermission('namespace', 'manage') ||
    hasPermission('roles', 'manage');

  const [channels, setChannels] = useState<ChatChannel[]>([]);
  const [activeUuid, setActiveUuid] = useState<string>('');
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [members, setMembers] = useState<ChatMember[]>([]);
  const [loadingChannels, setLoadingChannels] = useState(true);
  const [loadingMessages, setLoadingMessages] = useState(false);
  const [loadingMembers, setLoadingMembers] = useState(false);
  const [sending, setSending] = useState(false);
  const [draft, setDraft] = useState('');
  const [filter, setFilter] = useState('');
  const [showMembers, setShowMembers] = useState(true);
  const [createOpen, setCreateOpen] = useState(false);
  const [addOpen, setAddOpen] = useState(false);
  const [dmOpen, setDmOpen] = useState(false);
  const [membersModalOpen, setMembersModalOpen] = useState(false);
  const [pendingFiles, setPendingFiles] = useState<ChatAttachment[]>([]);
  const [uploading, setUploading] = useState(0);

  const listRef = useRef<HTMLDivElement>(null);
  const composerRef = useRef<HTMLTextAreaElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);

  // Optimization signals. `tabActive` (state) gates the WebSocket so it's held
  // only while the tab is in use; the refs let the poll timers read the latest
  // tab/socket status without being re-created every tick.
  const [tabActive, setTabActive] = useState(true);
  const tabActiveRef = useRef(true);
  const wsConnectedRef = useRef(false);

  const activeChannel = useMemo(
    () => channels.find((c) => c.uuid === activeUuid),
    [channels, activeUuid]
  );
  const canManage = !!activeChannel && !isDirect(activeChannel) &&
    (activeChannel.member_role === 'admin' || activeChannel.member_role === 'moderator');

  const { groupChannels, dms } = useMemo(() => {
    const f = filter.trim().toLowerCase();
    const match = (c: ChatChannel) => !f || channelTitle(c).toLowerCase().includes(f);
    return {
      groupChannels: channels.filter((c) => !isDirect(c) && match(c)),
      dms: channels.filter((c) => isDirect(c) && match(c)),
    };
  }, [channels, filter]);

  // Load channels for the current namespace; reset when the namespace changes.
  const loadChannels = useCallback(async (preserveActive: string) => {
    setLoadingChannels(true);
    try {
      let list = await chatService.listChannels();
      if (list.length === 0) {
        try {
          await chatService.createDefaults();
          list = await chatService.listChannels();
        } catch {
          /* no business / not allowed — fine, just show empty */
        }
      }
      setChannels(list);
      setActiveUuid((prev) => {
        const keep = preserveActive || prev;
        return list.some((c) => c.uuid === keep) ? keep : list[0]?.uuid || '';
      });
    } catch {
      toast.error('Failed to load channels');
      setChannels([]);
      setActiveUuid('');
    } finally {
      setLoadingChannels(false);
    }
  }, []);

  useEffect(() => {
    setActiveUuid('');
    void loadChannels('');
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [nsKey]);

  // Silent refresh of the channel/DM list (new conversations + unread counts).
  // Never shows a spinner or changes the active selection.
  const refreshChannels = useCallback(async () => {
    try {
      const list = await chatService.listChannels();
      setChannels((prev) => (list.length ? list : prev));
    } catch {
      /* silent */
    }
  }, []);

  // Channel-list poll — a safety net behind the WebSocket. It backs off hard
  // when the socket is delivering (or the tab is backgrounded) and only polls
  // fast when the socket is down AND the tab is focused.
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout>;
    const nextDelay = () => (!tabActiveRef.current ? 60000 : wsConnectedRef.current ? 30000 : 8000);
    const tick = () => {
      void refreshChannels();
      timer = setTimeout(tick, nextDelay());
    };
    timer = setTimeout(tick, nextDelay());
    return () => clearTimeout(timer);
  }, [nsKey, refreshChannels]);

  // Presence heartbeat (best-effort).
  useEffect(() => {
    void chatService.setPresence('online').catch(() => undefined);
    const id = setInterval(() => chatService.setPresence('online').catch(() => undefined), 60_000);
    return () => {
      clearInterval(id);
      void chatService.setPresence('offline').catch(() => undefined);
    };
  }, []);

  // Messages for the active channel + poll.
  const loadMessages = useCallback(async (uuid: string, showSpinner = false) => {
    if (!uuid) return;
    if (showSpinner) setLoadingMessages(true);
    try {
      const msgs = await chatService.listMessages(uuid, { limit: 50 });
      msgs.sort((a, b) => new Date(a.created_at).getTime() - new Date(b.created_at).getTime());
      setMessages(msgs);
    } catch {
      if (showSpinner) toast.error('Failed to load messages');
    } finally {
      if (showSpinner) setLoadingMessages(false);
    }
  }, []);

  const loadMembers = useCallback(async (uuid: string) => {
    if (!uuid) return;
    setLoadingMembers(true);
    try {
      setMembers(await chatService.listMembers(uuid));
    } catch {
      setMembers([]);
    } finally {
      setLoadingMembers(false);
    }
  }, []);

  // Tab visibility: hold the WebSocket (and poll at full rate) only while the
  // tab is in use. A short grace period avoids churn when you flick between
  // tabs; sustained-hidden (45s) drops the socket + slows polling, cutting idle
  // authenticated connections and background traffic. Returning restores both.
  useEffect(() => {
    if (typeof document === 'undefined') return;
    let hideTimer: ReturnType<typeof setTimeout> | null = null;
    const apply = (v: boolean) => {
      tabActiveRef.current = v;
      setTabActive(v);
    };
    const onVis = () => {
      if (document.visibilityState === 'visible') {
        if (hideTimer) {
          clearTimeout(hideTimer);
          hideTimer = null;
        }
        apply(true);
      } else {
        if (hideTimer) clearTimeout(hideTimer);
        hideTimer = setTimeout(() => apply(false), 45000);
      }
    };
    document.addEventListener('visibilitychange', onVis);
    return () => {
      document.removeEventListener('visibilitychange', onVis);
      if (hideTimer) clearTimeout(hideTimer);
    };
  }, []);

  // On refocus (or first mount), catch up immediately rather than waiting for
  // the next poll / socket message.
  useEffect(() => {
    if (!tabActive) return;
    void refreshChannels();
    if (activeUuid) void loadMessages(activeUuid, false);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tabActive]);

  useEffect(() => {
    if (!activeUuid) {
      setMessages([]);
      setMembers([]);
      return;
    }
    void loadMessages(activeUuid, true);
    void loadMembers(activeUuid);
    void chatService.markRead(activeUuid).catch(() => undefined);
    // Message poll — same adaptive backoff as the channel poll: fast only when
    // the socket is down and the tab is focused, otherwise a slow safety net.
    let timer: ReturnType<typeof setTimeout>;
    const nextDelay = () => (!tabActiveRef.current ? 30000 : wsConnectedRef.current ? 25000 : POLL_MS);
    const tick = () => {
      void loadMessages(activeUuid, false);
      timer = setTimeout(tick, nextDelay());
    };
    timer = setTimeout(tick, nextDelay());
    return () => clearTimeout(timer);
  }, [activeUuid, loadMessages, loadMembers]);

  // Auto-scroll to newest.
  useEffect(() => {
    const el = listRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [messages]);

  // Auto-grow composer.
  useEffect(() => {
    const el = composerRef.current;
    if (!el) return;
    el.style.height = 'auto';
    el.style.height = `${Math.min(el.scrollHeight, 160)}px`;
  }, [draft]);

  // Upload picked files to MinIO and stage them as pending attachments.
  const onPickFiles = useCallback(async (files: FileList | null) => {
    if (!files || files.length === 0) return;
    const list = Array.from(files);
    for (const file of list) {
      if (file.size > 25 * 1024 * 1024) {
        toast.error(`${file.name} is larger than 25MB`);
        continue;
      }
      setUploading((n) => n + 1);
      try {
        const att = await chatService.uploadFile(file);
        setPendingFiles((prev) => [...prev, att]);
      } catch {
        toast.error(`Failed to upload ${file.name}`);
      } finally {
        setUploading((n) => n - 1);
      }
    }
  }, []);

  const send = useCallback(async () => {
    const content = draft.trim();
    const atts = pendingFiles;
    if ((!content && atts.length === 0) || !activeUuid || sending) return;
    setSending(true);
    const optimistic: ChatMessage = {
      uuid: `pending-${Date.now()}`,
      user_uuid: myUuid || '',
      content,
      created_at: new Date().toISOString(),
      first_name: (user as { first_name?: string } | null)?.first_name,
      last_name: (user as { last_name?: string } | null)?.last_name,
      attachments: atts.length ? atts : undefined,
      _pending: true,
    };
    setMessages((m) => [...m, optimistic]);
    setDraft('');
    setPendingFiles([]);
    try {
      await chatService.sendMessage(activeUuid, content, atts);
      await loadMessages(activeUuid, false);
    } catch {
      toast.error('Failed to send');
      setMessages((m) => m.filter((x) => x.uuid !== optimistic.uuid));
      setDraft(content);
      setPendingFiles(atts);
    } finally {
      setSending(false);
    }
  }, [draft, pendingFiles, activeUuid, sending, myUuid, user, loadMessages]);

  const onKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      void send();
    }
  };

  const removeMember = useCallback(
    async (m: ChatMember) => {
      if (!activeUuid) return;
      if (!confirm(`Remove ${personName(m)} from this channel?`)) return;
      try {
        await chatService.removeMember(activeUuid, m.user_uuid);
        setMembers((list) => list.filter((x) => x.user_uuid !== m.user_uuid));
        toast.success('Member removed');
      } catch {
        toast.error('Failed to remove member');
      }
    },
    [activeUuid]
  );

  const openDirect = useCallback(
    async (u: ChatUser) => {
      try {
        if (u.has_chat_access === false && canGrant) {
          await chatService.grantChatAccess([u.uuid]);
        }
        const channel = await chatService.createDirect(u.uuid);
        setDmOpen(false);
        // Ensure it's in the rail, then open it.
        setChannels((list) => (list.some((c) => c.uuid === channel.uuid) ? list : [channel, ...list]));
        setActiveUuid(channel.uuid);
        // Re-sync so the peer info/ordering is authoritative.
        void loadChannels(channel.uuid);
      } catch (e) {
        toast.error(errMessage(e, 'Failed to open direct message'));
      }
    },
    [loadChannels, canGrant]
  );

  // Real-time delivery over the WebSocket hub. A message to any conversation you
  // belong to arrives here: append it if that channel is open, else refresh the
  // rail (unread + surface a new DM) and toast when it's from someone else.
  const { isConnected: wsConnected, status: wsStatus } = useChatSocket(
    useCallback(
      (data: ChatWsNewMessage) => {
        // You can belong to channels in several namespaces; the rail only shows
        // the active one, so ignore events for other tenants.
        if (data.namespace_id && currentNamespace?.id && data.namespace_id !== currentNamespace.id) {
          return;
        }
        if (data.channel_uuid === activeUuid) {
          void loadMessages(data.channel_uuid, false);
          void chatService.markRead(data.channel_uuid).catch(() => undefined);
        } else {
          void refreshChannels();
          if (data.message?.user_uuid && data.message.user_uuid !== myUuid) {
            toast(`New message from ${senderName(data.message)}`, { icon: '💬' });
          }
        }
      },
      [activeUuid, currentNamespace?.id, myUuid, loadMessages, refreshChannels]
    ),
    { enabled: !!myUuid && tabActive }
  );

  // Let the poll timers see the live socket status without re-creating them.
  useEffect(() => {
    wsConnectedRef.current = wsConnected;
  }, [wsConnected]);

  const headerTitle = activeChannel ? channelTitle(activeChannel) : '';
  const memberCount = members.length || activeChannel?.member_count || 0;

  return (
    <ProtectedPage module="chat" title="Chat">
      <div className="flex h-[calc(100dvh-9rem)] min-h-[520px] overflow-hidden rounded-xl border border-secondary-200 bg-surface shadow-sm">
        {/* ---------- Left rail: channels + DMs ---------- */}
        <aside
          className={`w-full flex-col border-r border-secondary-200 bg-secondary-50 md:w-64 md:flex ${
            activeUuid ? 'hidden' : 'flex'
          }`}
        >
          <div className="border-b border-secondary-200/70 px-3 py-3">
            <div className="mb-2 flex items-center gap-2">
              <MessagesSquare className="h-5 w-5 text-primary-600" />
              <div className="min-w-0">
                <p className="truncate text-sm font-bold text-secondary-900">Messages</p>
                <p className="truncate text-[11px] text-secondary-400">
                  {currentNamespace?.name || 'Workspace'}
                </p>
              </div>
            </div>
            <div className="relative">
              <Search className="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-secondary-400" />
              <input
                type="text"
                value={filter}
                onChange={(e) => setFilter(e.target.value)}
                placeholder="Jump to…"
                className="w-full rounded-md border border-secondary-200 bg-surface py-1.5 pl-8 pr-2 text-sm text-secondary-800 placeholder:text-secondary-400 focus:border-transparent focus:outline-none focus-visible:outline-none focus:ring-2 focus:ring-primary-500"
              />
            </div>
          </div>

          <div className="flex-1 overflow-y-auto px-2 py-3">
            {loadingChannels ? (
              <div className="flex justify-center py-6 text-secondary-400">
                <Loader2 className="h-4 w-4 animate-spin" />
              </div>
            ) : (
              <>
                {/* Channels */}
                <div className="mb-1 flex items-center justify-between px-2">
                  <span className="text-[11px] font-semibold uppercase tracking-wide text-secondary-400">
                    Channels
                  </span>
                  <button
                    type="button"
                    onClick={() => setCreateOpen(true)}
                    className="rounded p-0.5 text-secondary-400 hover:bg-secondary-200 hover:text-secondary-700"
                    title="Create channel"
                    aria-label="Create channel"
                  >
                    <Plus className="h-4 w-4" />
                  </button>
                </div>
                {groupChannels.length === 0 ? (
                  <p className="px-2 py-2 text-xs text-secondary-400">No channels.</p>
                ) : (
                  groupChannels.map((c) => (
                    <RailItem
                      key={c.uuid}
                      active={c.uuid === activeUuid}
                      unread={c.unread_count || 0}
                      onClick={() => setActiveUuid(c.uuid)}
                    >
                      <ChannelGlyph
                        channel={c}
                        className={c.uuid === activeUuid ? 'text-primary-700' : 'text-secondary-400'}
                      />
                      <span className="min-w-0 flex-1 truncate">{channelTitle(c)}</span>
                    </RailItem>
                  ))
                )}

                {/* Direct messages */}
                <div className="mb-1 mt-4 flex items-center justify-between px-2">
                  <span className="text-[11px] font-semibold uppercase tracking-wide text-secondary-400">
                    Direct Messages
                  </span>
                  <button
                    type="button"
                    onClick={() => setDmOpen(true)}
                    className="rounded p-0.5 text-secondary-400 hover:bg-secondary-200 hover:text-secondary-700"
                    title="New message"
                    aria-label="New direct message"
                  >
                    <Plus className="h-4 w-4" />
                  </button>
                </div>
                {dms.length === 0 ? (
                  <button
                    type="button"
                    onClick={() => setDmOpen(true)}
                    className="mt-0.5 flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-sm font-medium text-primary-600 transition hover:bg-primary-50"
                  >
                    <Plus className="h-4 w-4" />
                    New message
                  </button>
                ) : (
                  dms.map((c) => (
                    <RailItem
                      key={c.uuid}
                      active={c.uuid === activeUuid}
                      unread={c.unread_count || 0}
                      onClick={() => setActiveUuid(c.uuid)}
                    >
                      <Avatar
                        name={channelTitle(c)}
                        status={c.other_user_status || 'offline'}
                        size="sm"
                        seed={c.other_user_uuid || c.uuid}
                      />
                      <span className="min-w-0 flex-1 truncate">{channelTitle(c)}</span>
                    </RailItem>
                  ))
                )}
              </>
            )}
          </div>
        </aside>

        {/* ---------- Center: conversation ---------- */}
        <section className={`min-w-0 flex-1 flex-col ${activeUuid ? 'flex' : 'hidden md:flex'}`}>
          {activeChannel ? (
            <>
              <header className="flex items-center gap-2 border-b border-secondary-200 px-3 py-2.5 sm:px-4">
                <button
                  type="button"
                  onClick={() => setActiveUuid('')}
                  className="rounded-md p-1 text-secondary-500 hover:bg-secondary-100 md:hidden"
                  aria-label="Back to conversations"
                >
                  <ChevronLeft className="h-5 w-5" />
                </button>
                {isDirect(activeChannel) ? (
                  <Avatar
                    name={headerTitle}
                    status={activeChannel.other_user_status || 'offline'}
                    size="sm"
                    seed={activeChannel.other_user_uuid || activeChannel.uuid}
                  />
                ) : (
                  <ChannelGlyph channel={activeChannel} className="text-secondary-500" />
                )}
                <div className="min-w-0">
                  <h1 className="truncate text-sm font-bold text-secondary-900">{headerTitle}</h1>
                  {activeChannel.description && !isDirect(activeChannel) && (
                    <p className="truncate text-xs text-secondary-400">{activeChannel.description}</p>
                  )}
                </div>

                <div className="ml-auto flex items-center gap-1">
                  <ConnBadge status={wsStatus} />
                  {!isDirect(activeChannel) && (
                    <button
                      type="button"
                      onClick={() => {
                        // On large screens toggle the side panel; on small, a modal.
                        if (window.matchMedia('(min-width: 1024px)').matches) setShowMembers((v) => !v);
                        else setMembersModalOpen(true);
                      }}
                      className="flex items-center gap-1.5 rounded-md px-2 py-1 text-xs font-medium text-secondary-600 hover:bg-secondary-100"
                      title="Members"
                    >
                      <Users className="h-4 w-4" />
                      {memberCount}
                    </button>
                  )}
                  {canManage && (
                    <button
                      type="button"
                      onClick={() => setAddOpen(true)}
                      className="hidden items-center gap-1.5 rounded-md px-2 py-1 text-xs font-medium text-primary-600 hover:bg-primary-50 sm:flex"
                      title="Add people"
                    >
                      <UserPlus className="h-4 w-4" />
                      Add
                    </button>
                  )}
                  <button
                    type="button"
                    onClick={() => loadMessages(activeUuid, true)}
                    className="rounded-md p-1.5 text-secondary-400 hover:bg-secondary-100 hover:text-secondary-600"
                    title="Refresh"
                    aria-label="Refresh messages"
                  >
                    <RefreshCw className={`h-4 w-4 ${loadingMessages ? 'animate-spin' : ''}`} />
                  </button>
                </div>
              </header>

              {/* Messages */}
              <div ref={listRef} className="flex-1 overflow-y-auto px-3 py-4 sm:px-5">
                {loadingMessages && messages.length === 0 ? (
                  <div className="flex h-full items-center justify-center text-secondary-400">
                    <Loader2 className="h-5 w-5 animate-spin" />
                  </div>
                ) : messages.length === 0 ? (
                  <div className="flex h-full flex-col items-center justify-center text-center text-secondary-400">
                    <MessageSquare className="mb-2 h-9 w-9" />
                    <p className="text-sm font-medium text-secondary-500">This is the start of the conversation</p>
                    <p className="text-xs">Say hello 👋</p>
                  </div>
                ) : (
                  // Bottom-anchored: a short conversation sits at the bottom and
                  // grows upward; the newest message is always last.
                  <div className="flex min-h-full flex-col justify-end">
                    {messages.map((m, i) => {
                      const name = senderName(m);
                      const mine = !!myUuid && m.user_uuid === myUuid;
                      const prev = messages[i - 1];
                      const newDay = !prev || dayLabel(prev.created_at) !== dayLabel(m.created_at);
                      const grouped =
                        !newDay &&
                        !!prev &&
                        prev.user_uuid === m.user_uuid &&
                        new Date(m.created_at).getTime() - new Date(prev.created_at).getTime() < GROUP_WINDOW_MS;
                      return (
                        <React.Fragment key={m.uuid}>
                          {newDay && (
                            <div className="my-3 flex items-center gap-3">
                              <div className="h-px flex-1 bg-secondary-100" />
                              <span className="rounded-full bg-secondary-100 px-2.5 py-0.5 text-[11px] font-medium text-secondary-500">
                                {dayLabel(m.created_at)}
                              </span>
                              <div className="h-px flex-1 bg-secondary-100" />
                            </div>
                          )}
                          <div
                            className={`flex ${mine ? 'justify-end' : 'justify-start'} ${
                              grouped ? 'mt-0.5' : 'mt-3'
                            }`}
                          >
                            {/* Avatar gutter — only for other people, only on the group's first line */}
                            {!mine && (
                              <div className="mr-2 w-8 shrink-0 self-end">
                                {!grouped && <Avatar name={name} seed={m.user_uuid} size="sm" />}
                              </div>
                            )}
                            <div
                              className={`flex max-w-[78%] flex-col sm:max-w-[70%] ${
                                mine ? 'items-end' : 'items-start'
                              }`}
                            >
                              {!grouped && !mine && (
                                <span className="mb-1 ml-1 text-xs font-semibold text-secondary-700">{name}</span>
                              )}
                              <div
                                className={`rounded-2xl px-3.5 py-2 text-sm leading-relaxed shadow-sm ${
                                  mine
                                    ? 'rounded-br-md bg-primary-600 text-white'
                                    : 'rounded-bl-md bg-secondary-100 text-secondary-900'
                                } ${m._pending ? 'opacity-70' : ''}`}
                              >
                                {m.content && (
                                  <p className="whitespace-pre-wrap break-words">{m.content}</p>
                                )}
                                {m.attachments && m.attachments.length > 0 && (
                                  <div className={`flex flex-col gap-1.5 ${m.content ? 'mt-1.5' : ''}`}>
                                    {m.attachments.map((a, ai) => (
                                      <AttachmentView key={ai} a={a} mine={mine} />
                                    ))}
                                  </div>
                                )}
                              </div>
                              <span
                                className={`mt-0.5 text-[10px] text-secondary-400 ${mine ? 'mr-1' : 'ml-1'}`}
                              >
                                {timeLabel(m.created_at)}
                                {m.is_edited && ' · edited'}
                                {m._pending && ' · sending…'}
                              </span>
                            </div>
                          </div>
                        </React.Fragment>
                      );
                    })}
                  </div>
                )}
              </div>

              {/* Composer */}
              <div className="border-t border-secondary-200 px-3 py-3 sm:px-5">
                {/* Single border that colors on focus — no ring. The textarea's
                    own outline is killed inline so the app-wide *:focus-visible
                    outline can't stack a second line on top. */}
                {(pendingFiles.length > 0 || uploading > 0) && (
                  <div className="mb-2 flex flex-wrap gap-2">
                    {pendingFiles.map((a, i) => (
                      <span
                        key={i}
                        className="inline-flex items-center gap-1.5 rounded-lg border border-secondary-200 bg-secondary-50 py-1 pl-1.5 pr-1 text-xs text-secondary-700"
                      >
                        {isImageAttachment(a) ? (
                          // eslint-disable-next-line @next/next/no-img-element
                          <img src={a.file_url} alt="" className="h-6 w-6 rounded object-cover" />
                        ) : (
                          <FileText className="h-4 w-4 text-secondary-500" />
                        )}
                        <span className="max-w-[140px] truncate">{a.file_name}</span>
                        <button
                          type="button"
                          onClick={() => setPendingFiles((p) => p.filter((_, j) => j !== i))}
                          className="rounded p-0.5 hover:bg-secondary-200"
                          aria-label={`Remove ${a.file_name}`}
                        >
                          <X className="h-3 w-3" />
                        </button>
                      </span>
                    ))}
                    {uploading > 0 && (
                      <span className="inline-flex items-center gap-1.5 rounded-lg border border-secondary-200 px-2 py-1 text-xs text-secondary-500">
                        <Loader2 className="h-3.5 w-3.5 animate-spin" />
                        Uploading…
                      </span>
                    )}
                  </div>
                )}
                <div className="flex items-end gap-2 rounded-xl border border-secondary-300 bg-surface px-2 py-2 transition-colors focus-within:border-primary-500">
                  <button
                    type="button"
                    onClick={() => fileInputRef.current?.click()}
                    className="shrink-0 rounded-md p-1.5 text-secondary-400 hover:bg-secondary-100 hover:text-secondary-600"
                    title="Attach files"
                    aria-label="Attach files"
                  >
                    <Paperclip className="h-5 w-5" />
                  </button>
                  <input
                    ref={fileInputRef}
                    type="file"
                    multiple
                    hidden
                    onChange={(e) => {
                      void onPickFiles(e.target.files);
                      e.target.value = '';
                    }}
                  />
                  <textarea
                    ref={composerRef}
                    value={draft}
                    onChange={(e) => setDraft(e.target.value)}
                    onKeyDown={onKeyDown}
                    rows={1}
                    placeholder={`Message ${isDirect(activeChannel) ? headerTitle : '#' + headerTitle}`}
                    style={{ outline: 'none', boxShadow: 'none' }}
                    className="max-h-40 min-h-6 flex-1 resize-none bg-transparent py-1 text-sm text-secondary-900 placeholder:text-secondary-400"
                  />
                  <Button
                    onClick={send}
                    isLoading={sending}
                    disabled={(!draft.trim() && pendingFiles.length === 0) || uploading > 0}
                    size="sm"
                    className="px-2.5!"
                    aria-label="Send message"
                  >
                    <Send className="h-4 w-4" />
                  </Button>
                </div>
                <p className="mt-1 px-1 text-[11px] text-secondary-400">
                  <kbd className="font-sans">Enter</kbd> to send · <kbd className="font-sans">Shift</kbd>+
                  <kbd className="font-sans">Enter</kbd> for a new line
                </p>
              </div>
            </>
          ) : (
            <div className="flex h-full flex-col items-center justify-center text-center text-secondary-400">
              <MessagesSquare className="mb-3 h-12 w-12" />
              <p className="text-sm font-medium text-secondary-500">Select a conversation</p>
              <p className="text-xs">Pick a channel or start a direct message</p>
            </div>
          )}
        </section>

        {/* ---------- Right: members panel (lg+) ---------- */}
        {activeChannel && !isDirect(activeChannel) && showMembers && (
          <aside className="hidden w-64 shrink-0 border-l border-secondary-200 bg-secondary-50 lg:block">
            <MembersList
              members={members}
              loading={loadingMembers}
              myUuid={myUuid}
              canManage={canManage}
              onRemove={removeMember}
              onAdd={() => setAddOpen(true)}
            />
          </aside>
        )}
      </div>

      {/* ---------- Modals ---------- */}
      <CreateChannelModal
        isOpen={createOpen}
        canGrant={canGrant}
        onClose={() => setCreateOpen(false)}
        onCreated={(c) => {
          setChannels((list) => [c, ...list]);
          setActiveUuid(c.uuid);
          setCreateOpen(false);
          void loadChannels(c.uuid);
        }}
      />

      {activeChannel && (
        <AddMembersModal
          isOpen={addOpen}
          channel={activeChannel}
          existing={members.map((m) => m.user_uuid)}
          canGrant={canGrant}
          onClose={() => setAddOpen(false)}
          onAdded={() => {
            setAddOpen(false);
            void loadMembers(activeUuid);
          }}
        />
      )}

      <StartDirectModal
        isOpen={dmOpen}
        canGrant={canGrant}
        onClose={() => setDmOpen(false)}
        onPick={openDirect}
      />

      {/* Members on small screens */}
      <Modal isOpen={membersModalOpen} onClose={() => setMembersModalOpen(false)} title="Members" size="sm">
        <div className="-mx-2 max-h-[60vh]">
          <MembersList
            members={members}
            loading={loadingMembers}
            myUuid={myUuid}
            canManage={canManage}
            onRemove={removeMember}
            onAdd={() => {
              setMembersModalOpen(false);
              setAddOpen(true);
            }}
          />
        </div>
      </Modal>
    </ProtectedPage>
  );
}

// ---------- rail item ----------

function RailItem({
  active,
  unread,
  onClick,
  children,
}: {
  active: boolean;
  unread: number;
  onClick: () => void;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={`mb-0.5 flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-sm transition ${
        active
          ? 'bg-primary-100 font-semibold text-primary-800'
          : `text-secondary-700 hover:bg-secondary-200/70 ${unread > 0 ? 'font-semibold text-secondary-900' : ''}`
      }`}
    >
      {children}
      {unread > 0 && !active && (
        <span className="rounded-full bg-primary-500 px-1.5 text-[10px] font-semibold leading-5 text-white">
          {unread > 99 ? '99+' : unread}
        </span>
      )}
    </button>
  );
}

// ---------- modals ----------

function CreateChannelModal({
  isOpen,
  canGrant,
  onClose,
  onCreated,
}: {
  isOpen: boolean;
  canGrant: boolean;
  onClose: () => void;
  onCreated: (c: ChatChannel) => void;
}) {
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [isPrivate, setIsPrivate] = useState(false);
  const [selected, setSelected] = useState<ChatUser[]>([]);
  const [saving, setSaving] = useState(false);

  const reset = () => {
    setName('');
    setDescription('');
    setIsPrivate(false);
    setSelected([]);
  };

  const toggle = (u: ChatUser) =>
    setSelected((s) => (s.some((x) => x.uuid === u.uuid) ? s.filter((x) => x.uuid !== u.uuid) : [...s, u]));

  const submit = async () => {
    const clean = name.trim().replace(/\s+/g, '-').toLowerCase();
    if (!clean) return;
    setSaving(true);
    try {
      await grantSelected(selected, canGrant);
      const channel = await chatService.createChannel({
        name: clean,
        description: description.trim() || undefined,
        type: isPrivate ? 'private' : 'public',
        members: selected.map((u) => u.uuid),
      });
      toast.success('Channel created');
      onCreated(channel);
      reset();
    } catch (e) {
      toast.error(errMessage(e, 'Failed to create channel'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title="Create a channel"
      description="Channels are where your team communicates. Best around a topic — #marketing or #project-x."
      size="md"
      footer={
        <div className="flex justify-end gap-2">
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button onClick={submit} isLoading={saving} disabled={!name.trim()}>
            Create channel
          </Button>
        </div>
      }
    >
      <div className="space-y-4">
        <div>
          <label className="mb-1 block text-sm font-medium text-secondary-700">Name</label>
          <div className="flex items-center rounded-lg border border-secondary-300 bg-surface px-3 focus-within:border-transparent focus-within:ring-2 focus-within:ring-primary-500">
            <Hash className="h-4 w-4 text-secondary-400" />
            <input
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="e.g. marketing"
              autoFocus
              className="w-full bg-transparent px-2 py-2.5 text-sm text-secondary-900 placeholder:text-secondary-400 focus:outline-none focus-visible:outline-none"
            />
          </div>
        </div>

        <div>
          <label className="mb-1 block text-sm font-medium text-secondary-700">
            Description <span className="font-normal text-secondary-400">(optional)</span>
          </label>
          <input
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            placeholder="What's this channel about?"
            className="w-full rounded-lg border border-secondary-300 bg-surface px-3 py-2.5 text-sm text-secondary-900 placeholder:text-secondary-400 focus:border-transparent focus:outline-none focus-visible:outline-none focus:ring-2 focus:ring-primary-500"
          />
        </div>

        <label className="flex items-start gap-3 rounded-lg border border-secondary-200 p-3">
          <input
            type="checkbox"
            checked={isPrivate}
            onChange={(e) => setIsPrivate(e.target.checked)}
            className="mt-0.5 h-4 w-4 rounded border-secondary-300 text-primary-600 focus:ring-primary-500"
          />
          <span>
            <span className="flex items-center gap-1.5 text-sm font-medium text-secondary-800">
              <Lock className="h-3.5 w-3.5" /> Make private
            </span>
            <span className="text-xs text-secondary-500">
              Only invited members can see and join this channel.
            </span>
          </span>
        </label>

        <div>
          <label className="mb-1.5 block text-sm font-medium text-secondary-700">
            Add people <span className="font-normal text-secondary-400">(optional)</span>
          </label>
          <UserPicker mode="multi" selected={selected} onToggle={toggle} canGrant={canGrant} />
        </div>
      </div>
    </Modal>
  );
}

function AddMembersModal({
  isOpen,
  channel,
  existing,
  canGrant,
  onClose,
  onAdded,
}: {
  isOpen: boolean;
  channel: ChatChannel;
  existing: string[];
  canGrant: boolean;
  onClose: () => void;
  onAdded: () => void;
}) {
  const [selected, setSelected] = useState<ChatUser[]>([]);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!isOpen) setSelected([]);
  }, [isOpen]);

  const toggle = (u: ChatUser) =>
    setSelected((s) => (s.some((x) => x.uuid === u.uuid) ? s.filter((x) => x.uuid !== u.uuid) : [...s, u]));

  const submit = async () => {
    if (selected.length === 0) return;
    setSaving(true);
    try {
      const granted = await grantSelected(selected, canGrant);
      await chatService.addMembers(channel.uuid, selected.map((u) => u.uuid));
      toast.success(
        granted > 0
          ? `Granted Chat access to ${granted} and added ${selected.length}`
          : `Added ${selected.length} ${selected.length === 1 ? 'person' : 'people'}`
      );
      onAdded();
    } catch (e) {
      toast.error(errMessage(e, 'Failed to add members'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={`Add people to #${channelTitle(channel)}`}
      size="md"
      footer={
        <div className="flex justify-end gap-2">
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button onClick={submit} isLoading={saving} disabled={selected.length === 0}>
            Add {selected.length > 0 ? `(${selected.length})` : ''}
          </Button>
        </div>
      }
    >
      <UserPicker
        mode="multi"
        selected={selected}
        onToggle={toggle}
        excludeUuids={existing}
        autoFocus
        canGrant={canGrant}
      />
    </Modal>
  );
}

function StartDirectModal({
  isOpen,
  canGrant,
  onClose,
  onPick,
}: {
  isOpen: boolean;
  canGrant: boolean;
  onClose: () => void;
  onPick: (u: ChatUser) => void;
}) {
  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title="New direct message"
      description="Search for someone in your workspace to start a private 1:1 chat."
      size="md"
    >
      <UserPicker mode="single" onPick={onPick} autoFocus canGrant={canGrant} />
    </Modal>
  );
}

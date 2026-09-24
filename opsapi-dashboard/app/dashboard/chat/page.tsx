'use client';

// Chat — Slack-style messaging over the Lua `/api/chat/*` backend.
// MVP scope: channels (+ create), message list, composer, polling refresh.
// Follow-ups: DMs, threads, reactions, mentions, presence, files, WebSocket.
import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import toast from 'react-hot-toast';
import { Hash, Lock, Send, Plus, MessageSquare, Loader2, RefreshCw } from 'lucide-react';
import { ProtectedPage } from '@/components/permissions';
import { Modal, Button, Input } from '@/components/ui';
import { useAuthStore } from '@/store/auth.store';
import {
  chatService,
  senderName,
  type ChatChannel,
  type ChatMessage,
} from '@/services/chat.service';

const POLL_MS = 4000;

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
  const same = d.toDateString() === today.toDateString();
  return same ? 'Today' : d.toLocaleDateString([], { month: 'short', day: 'numeric', year: 'numeric' });
}

function ChannelIcon({ channel }: { channel: ChatChannel }) {
  const priv = channel.is_private || channel.channel_type === 'private';
  const Icon = priv ? Lock : Hash;
  return <Icon className="h-4 w-4 shrink-0 text-secondary-400" aria-hidden="true" />;
}

export default function ChatPage() {
  const user = useAuthStore((s) => s.user);
  const myUuid = (user as { uuid?: string } | null)?.uuid;

  const [channels, setChannels] = useState<ChatChannel[]>([]);
  const [activeUuid, setActiveUuid] = useState<string>('');
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [loadingChannels, setLoadingChannels] = useState(true);
  const [loadingMessages, setLoadingMessages] = useState(false);
  const [sending, setSending] = useState(false);
  const [draft, setDraft] = useState('');
  const [createOpen, setCreateOpen] = useState(false);

  const listRef = useRef<HTMLDivElement>(null);
  const activeChannel = useMemo(
    () => channels.find((c) => c.uuid === activeUuid),
    [channels, activeUuid]
  );

  // Load channels once.
  const loadChannels = useCallback(async () => {
    setLoadingChannels(true);
    try {
      let list = await chatService.listChannels();
      if (list.length === 0) list = await chatService.getDefaults();
      setChannels(list);
      setActiveUuid((prev) => prev || list[0]?.uuid || '');
    } catch {
      toast.error('Failed to load channels');
    } finally {
      setLoadingChannels(false);
    }
  }, []);

  useEffect(() => {
    void loadChannels();
  }, [loadChannels]);

  // Load messages for the active channel + poll.
  const loadMessages = useCallback(
    async (uuid: string, showSpinner = false) => {
      if (!uuid) return;
      if (showSpinner) setLoadingMessages(true);
      try {
        const msgs = await chatService.listMessages(uuid, { limit: 50 });
        msgs.sort((a, b) => new Date(a.created_at).getTime() - new Date(b.created_at).getTime());
        setMessages(msgs);
      } catch {
        // Silent on poll; only surface on the initial load.
        if (showSpinner) toast.error('Failed to load messages');
      } finally {
        if (showSpinner) setLoadingMessages(false);
      }
    },
    []
  );

  useEffect(() => {
    if (!activeUuid) {
      setMessages([]);
      return;
    }
    void loadMessages(activeUuid, true);
    void chatService.markRead(activeUuid).catch(() => undefined);
    const id = setInterval(() => loadMessages(activeUuid, false), POLL_MS);
    return () => clearInterval(id);
  }, [activeUuid, loadMessages]);

  // Auto-scroll to newest.
  useEffect(() => {
    const el = listRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [messages]);

  const send = useCallback(async () => {
    const content = draft.trim();
    if (!content || !activeUuid || sending) return;
    setSending(true);
    const optimistic: ChatMessage = {
      uuid: `pending-${Date.now()}`,
      user_uuid: myUuid || '',
      content,
      created_at: new Date().toISOString(),
      first_name: (user as { first_name?: string } | null)?.first_name,
      last_name: (user as { last_name?: string } | null)?.last_name,
      _pending: true,
    };
    setMessages((m) => [...m, optimistic]);
    setDraft('');
    try {
      await chatService.sendMessage(activeUuid, content);
      await loadMessages(activeUuid, false);
    } catch {
      toast.error('Failed to send');
      setMessages((m) => m.filter((x) => x.uuid !== optimistic.uuid));
      setDraft(content);
    } finally {
      setSending(false);
    }
  }, [draft, activeUuid, sending, myUuid, user, loadMessages]);

  const onKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      void send();
    }
  };

  return (
    <ProtectedPage module="chat" title="Chat">
      <div className="flex h-full min-h-[560px] overflow-hidden rounded-xl border border-secondary-200 bg-surface">
        {/* Channel sidebar */}
        <aside className="flex w-60 shrink-0 flex-col border-r border-secondary-200 bg-secondary-50">
          <div className="flex items-center justify-between px-3 py-3">
            <h2 className="text-sm font-semibold text-secondary-800">Channels</h2>
            <button
              type="button"
              onClick={() => setCreateOpen(true)}
              className="rounded-md p-1 text-secondary-500 hover:bg-secondary-200 hover:text-secondary-700"
              title="New channel"
              aria-label="New channel"
            >
              <Plus className="h-4 w-4" />
            </button>
          </div>
          <div className="flex-1 overflow-y-auto px-2 pb-3">
            {loadingChannels ? (
              <div className="flex justify-center py-6 text-secondary-400">
                <Loader2 className="h-4 w-4 animate-spin" />
              </div>
            ) : channels.length === 0 ? (
              <p className="px-2 py-4 text-xs text-secondary-400">No channels yet.</p>
            ) : (
              channels.map((c) => {
                const active = c.uuid === activeUuid;
                const unread = c.unread_count || 0;
                return (
                  <button
                    key={c.uuid}
                    type="button"
                    onClick={() => setActiveUuid(c.uuid)}
                    className={`mb-0.5 flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-sm transition ${
                      active
                        ? 'bg-primary-100 font-medium text-primary-800'
                        : 'text-secondary-700 hover:bg-secondary-200'
                    }`}
                  >
                    <ChannelIcon channel={c} />
                    <span className="min-w-0 flex-1 truncate">{c.name || c.peer_name || 'channel'}</span>
                    {unread > 0 && !active && (
                      <span className="rounded-full bg-primary-500 px-1.5 text-[10px] font-semibold text-white">
                        {unread}
                      </span>
                    )}
                  </button>
                );
              })
            )}
          </div>
        </aside>

        {/* Message pane */}
        <section className="flex min-w-0 flex-1 flex-col">
          {activeChannel ? (
            <>
              <header className="flex items-center gap-2 border-b border-secondary-200 px-4 py-3">
                <ChannelIcon channel={activeChannel} />
                <h1 className="truncate text-sm font-semibold text-secondary-900">
                  {activeChannel.name || activeChannel.peer_name}
                </h1>
                {activeChannel.topic && (
                  <span className="truncate text-xs text-secondary-400">— {activeChannel.topic}</span>
                )}
                <button
                  type="button"
                  onClick={() => loadMessages(activeUuid, true)}
                  className="ml-auto rounded-md p-1 text-secondary-400 hover:bg-secondary-100 hover:text-secondary-600"
                  title="Refresh"
                  aria-label="Refresh messages"
                >
                  <RefreshCw className={`h-4 w-4 ${loadingMessages ? 'animate-spin' : ''}`} />
                </button>
              </header>

              {/* Messages */}
              <div ref={listRef} className="flex-1 overflow-y-auto px-4 py-4">
                {loadingMessages && messages.length === 0 ? (
                  <div className="flex justify-center py-10 text-secondary-400">
                    <Loader2 className="h-5 w-5 animate-spin" />
                  </div>
                ) : messages.length === 0 ? (
                  <div className="flex h-full flex-col items-center justify-center text-secondary-400">
                    <MessageSquare className="mb-2 h-8 w-8" />
                    <p className="text-sm">No messages yet — say hello 👋</p>
                  </div>
                ) : (
                  messages.map((m, i) => {
                    const name = senderName(m);
                    const mine = !!myUuid && m.user_uuid === myUuid;
                    const prev = messages[i - 1];
                    const newDay = !prev || dayLabel(prev.created_at) !== dayLabel(m.created_at);
                    return (
                      <React.Fragment key={m.uuid}>
                        {newDay && (
                          <div className="my-3 flex items-center gap-3">
                            <div className="h-px flex-1 bg-secondary-100" />
                            <span className="text-[11px] font-medium text-secondary-400">
                              {dayLabel(m.created_at)}
                            </span>
                            <div className="h-px flex-1 bg-secondary-100" />
                          </div>
                        )}
                        <div className={`flex gap-3 py-1 ${m._pending ? 'opacity-60' : ''}`}>
                          <div
                            className={`flex h-8 w-8 shrink-0 items-center justify-center rounded-full text-xs font-semibold ${
                              mine ? 'bg-primary-100 text-primary-700' : 'bg-secondary-200 text-secondary-600'
                            }`}
                          >
                            {initials(name)}
                          </div>
                          <div className="min-w-0 flex-1">
                            <div className="flex items-baseline gap-2">
                              <span className="text-sm font-semibold text-secondary-900">{name}</span>
                              <span className="text-[11px] text-secondary-400">{timeLabel(m.created_at)}</span>
                              {m.is_edited && <span className="text-[11px] text-secondary-300">(edited)</span>}
                            </div>
                            <p className="whitespace-pre-wrap break-words text-sm text-secondary-700">
                              {m.content}
                            </p>
                          </div>
                        </div>
                      </React.Fragment>
                    );
                  })
                )}
              </div>

              {/* Composer */}
              <div className="border-t border-secondary-200 p-3">
                <div className="flex items-end gap-2">
                  <textarea
                    value={draft}
                    onChange={(e) => setDraft(e.target.value)}
                    onKeyDown={onKeyDown}
                    rows={1}
                    placeholder={`Message ${activeChannel.name ? '#' + activeChannel.name : activeChannel.peer_name || ''}`}
                    className="max-h-40 min-h-[2.5rem] flex-1 resize-none rounded-lg border border-secondary-300 px-3 py-2 text-sm focus:border-transparent focus:outline-none focus:ring-2 focus:ring-primary-500"
                  />
                  <Button onClick={send} isLoading={sending} disabled={!draft.trim()} className="min-h-[2.5rem]">
                    <Send className="h-4 w-4" />
                  </Button>
                </div>
                <p className="mt-1 px-1 text-[11px] text-secondary-400">
                  Enter to send · Shift+Enter for a new line
                </p>
              </div>
            </>
          ) : (
            <div className="flex h-full flex-col items-center justify-center text-secondary-400">
              <MessageSquare className="mb-2 h-10 w-10" />
              <p className="text-sm">Select a channel to start chatting</p>
            </div>
          )}
        </section>
      </div>

      <CreateChannelModal
        isOpen={createOpen}
        onClose={() => setCreateOpen(false)}
        onCreated={(c) => {
          setChannels((list) => [c, ...list]);
          setActiveUuid(c.uuid);
          setCreateOpen(false);
        }}
      />
    </ProtectedPage>
  );
}

function CreateChannelModal({
  isOpen,
  onClose,
  onCreated,
}: {
  isOpen: boolean;
  onClose: () => void;
  onCreated: (c: ChatChannel) => void;
}) {
  const [name, setName] = useState('');
  const [isPrivate, setIsPrivate] = useState(false);
  const [saving, setSaving] = useState(false);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    const clean = name.trim().replace(/\s+/g, '-').toLowerCase();
    if (!clean) return;
    setSaving(true);
    try {
      const channel = await chatService.createChannel({
        name: clean,
        channel_type: isPrivate ? 'private' : 'public',
        is_private: isPrivate,
      });
      toast.success('Channel created');
      onCreated(channel);
      setName('');
      setIsPrivate(false);
    } catch {
      toast.error('Failed to create channel');
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Create a channel" size="sm">
      <form onSubmit={submit} className="space-y-4">
        <Input
          label="Channel name"
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="e.g. general"
          autoFocus
        />
        <label className="flex items-center gap-2 text-sm text-secondary-700">
          <input
            type="checkbox"
            checked={isPrivate}
            onChange={(e) => setIsPrivate(e.target.checked)}
            className="h-4 w-4 rounded border-secondary-300"
          />
          Private channel (invite only)
        </label>
        <div className="flex justify-end gap-2">
          <Button type="button" variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button type="submit" isLoading={saving} disabled={!name.trim()}>
            Create
          </Button>
        </div>
      </form>
    </Modal>
  );
}

'use client';

/**
 * AgentPane — the AI assistant conversation. The conversation lives on the
 * server and each turn runs there in the BACKGROUND (routes/chat-agent.lua), so
 * reloading, changing page or closing the tab never loses or stops a task.
 * This pane just shows the server's conversation: it re-fetches on the
 * "agent:done" WebSocket event (via ChatNotifier), with a poll as fallback.
 *
 * Two homes: the chat page (no `path` — the all-round assistant) and the page
 * assistant panel on every dashboard page (`path` = the page; the server picks
 * that page's guide, tools and its own separate history).
 *
 * Voice (operators and QA testers): an animated face, a mic (speech-to-text on our
 * own voice server) and "speak replies" (our text-to-speech, else a voice on this
 * device). The typed transcript stays the record.
 */

import React, { useCallback, useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import { Sparkles, Send, Loader2, Check, AlertCircle, X, Trash2, Mic, Square, Volume2, VolumeX } from 'lucide-react';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import toast from 'react-hot-toast';
import { chatService, type AgentTurn, type AgentAction, type AgentScope } from '@/services/chat.service';
import { onChatEvent } from '@/store/chat-realtime.store';
import { useAssistant } from '@/store/assistant.store';
import { useVoice, useVoiceLevel, type LevelStore } from '@/hooks/useVoice';
import AvatarFace, { type FaceMood } from './AvatarFace';
import { AgentTaskCards, tasksFromActions } from './AgentTaskCards';
import { StartWithAIButton } from '@/components/ai-runner/StartWithAIDialog';

/** A same-origin or relative link -> its in-app path (client navigation); anything else -> null. */
function inAppPath(href?: string): string | null {
  if (!href) return null;
  if (typeof window === 'undefined') return href.startsWith('/') && !href.startsWith('//') ? href : null;
  try {
    const url = new URL(href, window.location.href);
    return url.origin === window.location.origin ? url.pathname + url.search + url.hash : null;
  } catch {
    return null;
  }
}

// Render the agent's reply as markdown (lists, bold, tables, links, code) with
// styling that sits on the neutral assistant bubble.
// Memoised: the pane re-renders while a run streams in; old messages needn't re-parse.
const MarkdownMessage = React.memo(function MarkdownMessage({ text }: { text: string }) {
  return (
    <div className="space-y-1.5">
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        components={{
          p: ({ children }) => <p className="whitespace-pre-wrap break-words">{children}</p>,
          ul: ({ children }) => <ul className="ml-4 list-disc space-y-0.5">{children}</ul>,
          ol: ({ children }) => <ol className="ml-4 list-decimal space-y-0.5">{children}</ol>,
          strong: ({ children }) => <strong className="font-semibold">{children}</strong>,
          // In-app pages navigate inside the dashboard; other sites open in a new tab.
          a: ({ href, children }) => {
            const path = inAppPath(href);
            return path ? (
              <Link href={path} className="text-primary-600 underline">
                {children}
              </Link>
            ) : (
              <a href={href} target="_blank" rel="noopener noreferrer" className="text-primary-600 underline">
                {children}
              </a>
            );
          },
          code: ({ children }) => (
            <code className="rounded bg-secondary-200 px-1 py-0.5 text-[0.85em]">{children}</code>
          ),
          table: ({ children }) => (
            <div className="overflow-x-auto">
              <table className="w-full border-collapse text-xs">{children}</table>
            </div>
          ),
          th: ({ children }) => (
            <th className="border border-secondary-300 px-1.5 py-0.5 text-left font-semibold">{children}</th>
          ),
          td: ({ children }) => <td className="border border-secondary-300 px-1.5 py-0.5">{children}</td>,
        }}
      >
        {text}
      </ReactMarkdown>
    </div>
  );
});

/** The face, fed by the voice level store: only this re-renders per audio frame, not the pane. */
function LiveFace({ level, ...props }: { level: LevelStore; mood: FaceMood; size: number; label: string }) {
  return <AvatarFace {...props} level={useVoiceLevel(level)} />;
}

const WELCOME =
  "Hi! I'm your OpsAPI assistant. Tell me what you need and I'll do it in your workspace — customers, CRM leads & deals, projects & tasks, timesheets, invoices, inviting teammates and more. If a detail is missing, I'll ask.";

const SUGGESTIONS = [
  'What are my tasks today?',
  'Show my open tasks and log 2 hours on one of them',
  'Create a lead for Jane Smith at Globex, jane@globex.com',
  'Draft an invoice for Acme Corp: 10 hours consulting at £80',
  'Invite sam@example.com to this workspace',
];

// Fallback poll while a run is in progress (the socket only exists where Chat does).
const POLL_MS = 6000;
const PAGE_POLL_MS = 2500;

// "PUT /api/v2/kanban/tasks/<uuid>/move" -> "PUT kanban/tasks/…/move" for the chips.
function actionLabel(a: AgentAction): string {
  const label = a.label || a.name;
  return label
    .replace(/ \/api\/v\d+\//, ' ')
    .replace(/ \/api\//, ' ')
    .replace(/[0-9a-f]{8}-[0-9a-f-]{20,}/gi, '…');
}

interface AgentPaneProps {
  namespaceName?: string;
  namespaceKey?: string;
  /** Dashboard path of the page the assistant serves; omitted on the chat page. */
  path?: string;
  /** Shown as a close button in the header (the page panel). */
  onClose?: () => void;
  /** A finished run created or changed data — reload the page's data. */
  onChanged?: () => void;
}

export function AgentPane({ namespaceName, namespaceKey, path, onClose, onChanged }: AgentPaneProps) {
  const [turns, setTurns] = useState<AgentTurn[]>([]);
  const [scope, setScope] = useState<AgentScope | undefined>();
  const [pending, setPending] = useState<{ summary: string } | null>(null);
  const [loaded, setLoaded] = useState(false);
  const [draft, setDraft] = useState('');
  const [thinking, setThinking] = useState(false);
  const [deciding, setDeciding] = useState(false);
  const listRef = useRef<HTMLDivElement>(null);
  const composerRef = useRef<HTMLTextAreaElement>(null);
  // The run this pane started; when it finishes having changed data, tell the page.
  const watching = useRef<string | null>(null);
  const onChangedRef = useRef(onChanged);
  onChangedRef.current = onChanged;
  const voice = useVoice();
  const [speakReplies, setSpeakReplies] = useState<boolean>(() =>
    typeof window !== 'undefined' && window.localStorage.getItem('assistant-speak-replies') === '1');
  // How many assistant replies we've already heard (or that were there when the pane opened).
  const spokenRef = useRef<number | null>(null);

  const refresh = useCallback(async () => {
    try {
      const conv = await chatService.getAgentConversation(path);
      setTurns(conv.turns);
      setScope(conv.scope);
      setPending(conv.pending ?? null);
      setThinking(conv.status === 'running');
      if (watching.current && conv.run_uuid === watching.current && conv.status !== 'running') {
        watching.current = null;
        if (conv.changed) onChangedRef.current?.();
      }
    } catch {
      /* keep what we have; the next event/poll retries */
    } finally {
      setLoaded(true);
    }
  }, [path]);

  // Load the server conversation (also picks up a run still in progress from
  // before a reload / from another tab). Re-runs when the page changes.
  useEffect(() => {
    void refresh();
  }, [refresh, namespaceKey]);

  // Run finished → re-fetch. Poll slowly as a fallback while one is running.
  useEffect(() => onChatEvent((e) => e.type === 'agent' && void refresh()), [refresh]);
  useEffect(() => {
    if (!thinking) return;
    const id = setInterval(() => void refresh(), path ? PAGE_POLL_MS : POLL_MS);
    return () => clearInterval(id);
  }, [thinking, refresh, path]);

  useEffect(() => {
    const el = listRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [turns, thinking, pending]);

  // Speak each new reply when "speak replies" is on (never the history already on screen).
  const { speak } = voice;
  useEffect(() => {
    if (!loaded || thinking) return;
    const replies = turns.filter((t) => t.role === 'assistant');
    if (spokenRef.current === null) { spokenRef.current = replies.length; return; }
    if (replies.length > spokenRef.current) {
      spokenRef.current = replies.length;
      if (speakReplies) void speak(replies[replies.length - 1].content);
    }
  }, [turns, thinking, loaded, speakReplies, speak]);

  const toggleSpeak = () => {
    const next = !speakReplies;
    setSpeakReplies(next);
    window.localStorage.setItem('assistant-speak-replies', next ? '1' : '0');
    if (!next) voice.stopSpeaking();
  };

  const newChat = async () => {
    if (thinking) return;
    try {
      await chatService.resetAgentConversation(path);
      setTurns([]);
      setPending(null);
    } catch {
      toast.error('Could not start a new chat');
    }
    composerRef.current?.focus();
  };

  const send = useCallback(
    async (text: string) => {
      const content = text.trim();
      if (!content || thinking) return;
      setTurns((t) => [...t, { role: 'user', content }]);
      setDraft('');
      setPending(null);
      setThinking(true);
      try {
        // Returns immediately; the run continues on the server regardless of
        // what happens to this page. (Replying "yes" to a pending delete is
        // settled synchronously and comes back already done.)
        const conv = await chatService.sendAgentMessage(content, path);
        if (conv.turns.length) setTurns(conv.turns);
        if (conv.scope) setScope(conv.scope);
        if (conv.status === 'running') {
          watching.current = conv.run_uuid ?? null;
        } else {
          setThinking(false);
          if (conv.changed) onChangedRef.current?.();
        }
      } catch (e) {
        const status = (e as { response?: { status?: number } })?.response?.status;
        toast.error(
          status === 409 ? 'The assistant is still working on your last request.' : "Couldn't reach the assistant."
        );
        void refresh();
      } finally {
        composerRef.current?.focus();
      }
    },
    [thinking, refresh, path]
  );

  // "Ask AI to do it" buttons on the page queue a message: send it once the pane is ready.
  const queued = useAssistant((st) => st.queued);
  useEffect(() => {
    if (!path || !loaded || thinking || !queued) return;
    useAssistant.getState().clearQueued();
    void send(queued);
  }, [path, loaded, thinking, queued, send]);

  const decide = async (approve: boolean) => {
    if (deciding) return;
    setDeciding(true);
    try {
      const conv = await chatService.confirmAgentAction(approve, path);
      setTurns(conv.turns);
      setPending(null);
      if (conv.changed) onChangedRef.current?.();
    } catch {
      toast.error('Could not reach the assistant.');
      void refresh();
    } finally {
      setDeciding(false);
    }
  };

  const pageTitle = path && scope && scope.key !== 'general' ? scope.title : undefined;
  const welcome = pageTitle
    ? `I'm your ${pageTitle} assistant. Ask me how anything on this page works, or tell me what to do and I'll do it here — with your permissions. Each page keeps its own conversation.`
    : WELCOME;
  const suggestions = scope?.suggestions?.length ? scope.suggestions : SUGGESTIONS;

  const onKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      void send(draft);
    }
  };

  const mic = async () => {
    if (voice.state === 'listening') {
      try {
        const text = await voice.finish();
        if (text) void send(text);
        else toast("Didn't catch that — try again", { icon: '🎙️' });
      } catch {
        toast.error('Could not turn that into text');
      }
      return;
    }
    try {
      await voice.listen();
    } catch {
      toast.error(window.isSecureContext ? 'Microphone not available — allow it in the browser' : 'The microphone needs a secure (https) page');
    }
  };

  const mood: FaceMood = voice.state === 'listening' || voice.state === 'transcribing' || voice.state === 'speaking'
    ? voice.state : thinking ? 'thinking' : 'idle';

  const AgentAvatar = ({ size = 'md' }: { size?: 'sm' | 'md' }) => (
    <span
      className={`flex shrink-0 items-center justify-center rounded-full bg-gradient-to-br from-primary-500 to-primary-700 text-white ${
        size === 'sm' ? 'h-7 w-7' : 'h-8 w-8'
      }`}
    >
      <Sparkles className={size === 'sm' ? 'h-3.5 w-3.5' : 'h-4 w-4'} />
    </span>
  );

  return (
    // min-h-0: without it this flex child grows to fit its messages instead of
    // letting the list scroll, pushing the composer off-screen.
    <section className="flex min-h-0 min-w-0 flex-1 flex-col">
      <header className="flex items-center gap-2 border-b border-secondary-200 px-4 py-2.5">
        <LiveFace mood={mood} level={voice.level} size={44} label={pageTitle || 'Assistant'} />
        <div className="min-w-0">
          <h1 className="truncate text-sm font-bold text-secondary-900">
            AI Assistant{pageTitle ? ` · ${pageTitle}` : ''}
          </h1>
          <p className="truncate text-xs text-secondary-400">
            Acts in {namespaceName || 'your workspace'} with your permissions
          </p>
        </div>
        <div className="ml-auto flex shrink-0 items-center gap-1">
          <button
            type="button"
            onClick={toggleSpeak}
            aria-pressed={speakReplies}
            aria-label={speakReplies ? 'Stop speaking replies' : 'Speak replies'}
            title={speakReplies ? 'Replies are read aloud' : 'Read replies aloud'}
            className={`flex h-8 w-8 items-center justify-center rounded-md transition hover:bg-secondary-100 ${speakReplies ? 'text-primary-600' : 'text-secondary-500'}`}
          >
            {speakReplies ? <Volume2 className="h-4 w-4" /> : <VolumeX className="h-4 w-4" />}
          </button>
          {turns.length > 0 && (
            <button
              type="button"
              onClick={newChat}
              disabled={thinking}
              className="rounded-md border border-secondary-200 px-2.5 py-1 text-xs font-medium text-secondary-600 transition hover:bg-secondary-100 disabled:opacity-50"
            >
              New chat
            </button>
          )}
          {onClose && (
            <button
              type="button"
              onClick={onClose}
              aria-label="Close assistant"
              className="flex h-8 w-8 items-center justify-center rounded-md text-secondary-500 transition hover:bg-secondary-100 hover:text-secondary-800"
            >
              <X className="h-4 w-4" />
            </button>
          )}
        </div>
      </header>

      <div ref={listRef} className="scrollbar-hidden min-h-0 flex-1 overflow-y-auto overscroll-contain px-3 py-4 sm:px-5">
        {!loaded ? (
          <div className="flex h-full items-center justify-center text-secondary-400">
            <Loader2 className="h-5 w-5 animate-spin" />
          </div>
        ) : turns.length === 0 ? (
          <div className="mx-auto max-w-md py-6 text-center">
            <span className="mx-auto mb-3 flex h-12 w-12 items-center justify-center rounded-2xl bg-primary-100 text-primary-600">
              <Sparkles className="h-6 w-6" />
            </span>
            <p className="text-sm leading-relaxed text-secondary-600">{welcome}</p>
            <div className="mt-4 flex flex-col gap-2">
              {suggestions.map((s) => (
                <button
                  key={s}
                  type="button"
                  onClick={() => send(s)}
                  className="rounded-lg border border-secondary-200 px-3 py-2 text-left text-sm text-secondary-700 transition hover:border-primary-300 hover:bg-primary-50"
                >
                  {s}
                </button>
              ))}
            </div>
          </div>
        ) : (
          turns.map((t, i) => {
            const mine = t.role === 'user';
            const acted = (t.actions || []).filter((a) => a.name !== 'ask_user');
            const taskList = mine ? null : tasksFromActions(t.actions);
            return (
              <div key={i} className={`mt-3 flex ${mine ? 'justify-end' : 'justify-start'}`}>
                {!mine && (
                  <div className="mr-2 mt-0.5">
                    <AgentAvatar size="sm" />
                  </div>
                )}
                <div className="flex max-w-[80%] flex-col">
                  <div
                    className={`rounded-2xl px-3.5 py-2 text-sm leading-relaxed shadow-sm ${
                      mine
                        ? 'rounded-br-md bg-primary-600 text-white'
                        : 'rounded-bl-md bg-secondary-100 text-secondary-900'
                    }`}
                  >
                    {mine ? (
                      <p className="whitespace-pre-wrap break-words">{t.content}</p>
                    ) : (
                      <MarkdownMessage text={t.content} />
                    )}
                  </div>
                  {taskList && (
                    <AgentTaskCards
                      tasks={taskList.tasks}
                      today={taskList.today}
                      renderStartWithAI={(task) => (
                        <StartWithAIButton compact taskUuid={task.uuid}
                          taskLabel={`${task.task_number != null ? `#${task.task_number} ` : ''}${task.title}`} />
                      )}
                    />
                  )}
                  {!mine && (
                    <button
                      type="button"
                      onClick={() => (voice.state === 'speaking' ? voice.stopSpeaking() : void voice.speak(t.content))}
                      className="mt-0.5 self-start text-[11px] text-secondary-400 transition hover:text-primary-600"
                    >
                      {voice.state === 'speaking' ? 'Stop' : 'Read aloud'}
                    </button>
                  )}
                  {acted.length > 0 && (
                    <div className="mt-1 flex flex-wrap gap-1">
                      {acted.map((a, ai) => (
                        <span
                          key={ai}
                          className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[11px] font-medium ${
                            a.error ? 'bg-rose-50 text-rose-600' : 'bg-emerald-50 text-emerald-700'
                          }`}
                          title={a.error || undefined}
                        >
                          {a.error ? <AlertCircle className="h-3 w-3" /> : <Check className="h-3 w-3" />}
                          {actionLabel(a)}
                        </span>
                      ))}
                    </div>
                  )}
                </div>
              </div>
            );
          })
        )}
        {pending && !thinking && (
          <div
            role="alertdialog"
            aria-label="Confirm the assistant's action"
            className="ml-9 mt-3 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm"
          >
            <p className="flex items-start gap-2 text-rose-800">
              <Trash2 className="mt-0.5 h-4 w-4 shrink-0" />
              <span>{pending.summary}</span>
            </p>
            <div className="mt-2.5 flex gap-2">
              <button
                type="button"
                onClick={() => decide(true)}
                disabled={deciding}
                className="inline-flex min-h-9 items-center gap-1.5 rounded-lg bg-rose-600 px-3 text-xs font-semibold text-white transition hover:bg-rose-700 disabled:opacity-60"
              >
                {deciding && <Loader2 className="h-3.5 w-3.5 animate-spin" />}
                Confirm delete
              </button>
              <button
                type="button"
                onClick={() => decide(false)}
                disabled={deciding}
                className="min-h-9 rounded-lg border border-secondary-300 bg-surface px-3 text-xs font-medium text-secondary-700 transition hover:bg-secondary-100 disabled:opacity-60"
              >
                Cancel
              </button>
            </div>
          </div>
        )}
        {thinking && (
          <div className="mt-3 flex justify-start">
            <div className="mr-2">
              <AgentAvatar size="sm" />
            </div>
            <div className="flex items-center gap-1.5 rounded-2xl rounded-bl-md bg-secondary-100 px-3.5 py-2.5 text-sm text-secondary-500">
              <Loader2 className="h-4 w-4 shrink-0 animate-spin" />
              <span>
                Working on it…
                <span className="block text-[11px] text-secondary-400">
                  You can leave this page — I&apos;ll notify you when it&apos;s done.
                </span>
              </span>
            </div>
          </div>
        )}
      </div>

      <div className="border-t border-secondary-200 px-3 py-3 sm:px-5">
        <div className="flex items-end gap-2 rounded-xl border border-secondary-300 bg-surface px-3 py-2 transition-colors focus-within:border-primary-500">
          <textarea
            ref={composerRef}
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={onKeyDown}
            rows={1}
            disabled={thinking}
            placeholder={pageTitle ? `Ask about ${pageTitle}, or tell me what to do…` : 'Ask the assistant to do something…'}
            style={{ outline: 'none', boxShadow: 'none' }}
            className="max-h-40 min-h-6 flex-1 resize-none bg-transparent py-1 text-sm text-secondary-900 placeholder:text-secondary-400 disabled:opacity-60"
          />
          {voice.status?.stt && (
            <button
              type="button"
              onClick={mic}
              disabled={thinking || voice.state === 'transcribing'}
              aria-label={voice.state === 'listening' ? 'Stop and send what I said' : 'Speak to the assistant'}
              title={voice.state === 'listening' ? 'Stop and send' : 'Speak'}
              className={`flex h-8 w-8 shrink-0 items-center justify-center rounded-lg transition disabled:opacity-50 ${
                voice.state === 'listening' ? 'bg-error-600 text-white hover:bg-error-700' : 'text-secondary-500 hover:bg-secondary-100 hover:text-primary-600'
              }`}
            >
              {voice.state === 'transcribing' ? <Loader2 className="h-4 w-4 animate-spin" /> : voice.state === 'listening' ? <Square className="h-3.5 w-3.5" /> : <Mic className="h-4 w-4" />}
            </button>
          )}
          <button
            type="button"
            onClick={() => send(draft)}
            disabled={!draft.trim() || thinking}
            aria-label="Send"
            className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-primary-600 text-white transition hover:bg-primary-700 disabled:opacity-50"
          >
            {thinking ? <Loader2 className="h-4 w-4 animate-spin" /> : <Send className="h-4 w-4" />}
          </button>
        </div>
        <p className="mt-1 px-1 text-[11px] text-secondary-400">
          The assistant can create and change data in your workspace — review what it does.
          {voice.state === 'listening' && ' · Listening… press ■ to send.'}
        </p>
      </div>
    </section>
  );
}

export default AgentPane;

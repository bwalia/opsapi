'use client';

/**
 * AgentPane — the "Chat with AI Assistant" conversation. Unlike channels/DMs the
 * agent is not a persisted conversation: the whole turn history lives in local
 * state and is sent on each request, and the backend runs a tool-calling loop
 * (create customer / add team member / log timesheet / …) scoped to the user's
 * namespace + RBAC. The agent asks for missing details instead of guessing.
 */

import React, { useCallback, useEffect, useRef, useState } from 'react';
import { Sparkles, Send, Loader2, Check, AlertCircle } from 'lucide-react';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { chatService, type AgentTurn } from '@/services/chat.service';

// Render the agent's reply as markdown (lists, bold, tables, links, code) with
// styling that sits on the neutral assistant bubble.
function MarkdownMessage({ text }: { text: string }) {
  return (
    <div className="space-y-1.5">
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        components={{
          p: ({ children }) => <p className="whitespace-pre-wrap break-words">{children}</p>,
          ul: ({ children }) => <ul className="ml-4 list-disc space-y-0.5">{children}</ul>,
          ol: ({ children }) => <ol className="ml-4 list-decimal space-y-0.5">{children}</ol>,
          strong: ({ children }) => <strong className="font-semibold">{children}</strong>,
          a: ({ href, children }) => (
            <a href={href} target="_blank" rel="noopener noreferrer" className="text-primary-600 underline">
              {children}
            </a>
          ),
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
}

const WELCOME =
  "Hi! I'm your OpsAPI assistant. Tell me what you need and I'll do it in your workspace — customers, CRM leads & deals, projects & tasks, timesheets, invoices, inviting teammates and more. If a detail is missing, I'll ask.";

const SUGGESTIONS = [
  'Show my open tasks and log 2 hours on one of them',
  'Create a lead for Jane Smith at Globex, jane@globex.com',
  'Draft an invoice for Acme Corp: 10 hours consulting at £80',
  'Invite sam@example.com to this workspace',
];

// Per-workspace conversation, kept for the browser session so switching pages
// doesn't lose it. Best-effort — storage can be unavailable.
const storageKey = (ns?: string) => `opsapi:agent-chat:${ns || 'default'}`;

function loadTurns(ns?: string): AgentTurn[] {
  try {
    const raw = sessionStorage.getItem(storageKey(ns));
    return raw ? (JSON.parse(raw) as AgentTurn[]) : [];
  } catch {
    return [];
  }
}

export function AgentPane({ namespaceName, namespaceKey }: { namespaceName?: string; namespaceKey?: string }) {
  const [turns, setTurns] = useState<AgentTurn[]>(() =>
    typeof window === 'undefined' ? [] : loadTurns(namespaceKey)
  );
  const [draft, setDraft] = useState('');
  const [thinking, setThinking] = useState(false);
  const listRef = useRef<HTMLDivElement>(null);
  const composerRef = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    const el = listRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [turns, thinking]);

  useEffect(() => {
    try {
      sessionStorage.setItem(storageKey(namespaceKey), JSON.stringify(turns.slice(-40)));
    } catch {
      /* storage unavailable — fine */
    }
  }, [turns, namespaceKey]);

  const newChat = () => {
    if (thinking) return;
    setTurns([]);
    composerRef.current?.focus();
  };

  const send = useCallback(
    async (text: string) => {
      const content = text.trim();
      if (!content || thinking) return;
      const history = [...turns, { role: 'user', content } as AgentTurn];
      setTurns(history);
      setDraft('');
      setThinking(true);
      try {
        const { reply, actions } = await chatService.askAgent(history);
        setTurns((t) => [...t, { role: 'assistant', content: reply, actions }]);
      } catch {
        setTurns((t) => [
          ...t,
          { role: 'assistant', content: "Sorry — I couldn't reach the assistant. Please try again." },
        ]);
      } finally {
        setThinking(false);
        composerRef.current?.focus();
      }
    },
    [turns, thinking]
  );

  const onKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      void send(draft);
    }
  };

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
    <section className="flex min-w-0 flex-1 flex-col">
      <header className="flex items-center gap-2 border-b border-secondary-200 px-4 py-2.5">
        <AgentAvatar />
        <div className="min-w-0">
          <h1 className="text-sm font-bold text-secondary-900">AI Assistant</h1>
          <p className="truncate text-xs text-secondary-400">
            Acts in {namespaceName || 'your workspace'} with your permissions
          </p>
        </div>
        {turns.length > 0 && (
          <button
            type="button"
            onClick={newChat}
            disabled={thinking}
            className="ml-auto rounded-md border border-secondary-200 px-2.5 py-1 text-xs font-medium text-secondary-600 transition hover:bg-secondary-100 disabled:opacity-50"
          >
            New chat
          </button>
        )}
      </header>

      <div ref={listRef} className="flex-1 overflow-y-auto px-3 py-4 sm:px-5">
        {turns.length === 0 ? (
          <div className="mx-auto max-w-md py-6 text-center">
            <span className="mx-auto mb-3 flex h-12 w-12 items-center justify-center rounded-2xl bg-primary-100 text-primary-600">
              <Sparkles className="h-6 w-6" />
            </span>
            <p className="text-sm leading-relaxed text-secondary-600">{WELCOME}</p>
            <div className="mt-4 flex flex-col gap-2">
              {SUGGESTIONS.map((s) => (
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
                          {a.name}
                        </span>
                      ))}
                    </div>
                  )}
                </div>
              </div>
            );
          })
        )}
        {thinking && (
          <div className="mt-3 flex justify-start">
            <div className="mr-2">
              <AgentAvatar size="sm" />
            </div>
            <div className="flex items-center gap-1.5 rounded-2xl rounded-bl-md bg-secondary-100 px-3.5 py-2.5 text-sm text-secondary-500">
              <Loader2 className="h-4 w-4 animate-spin" /> Working on it…
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
            placeholder="Ask the assistant to do something…"
            style={{ outline: 'none', boxShadow: 'none' }}
            className="max-h-40 min-h-6 flex-1 resize-none bg-transparent py-1 text-sm text-secondary-900 placeholder:text-secondary-400 disabled:opacity-60"
          />
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
        </p>
      </div>
    </section>
  );
}

export default AgentPane;

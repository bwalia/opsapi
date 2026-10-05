'use client';

/**
 * The page AI assistant: an "Ask AI" launcher on every dashboard page that opens
 * a side panel. The panel is the same AgentPane as the chat page, given the
 * current URL, so the server answers as THAT page's assistant (its guide,
 * tools, the user's permissions there) and keeps a separate history per page
 * area — timesheet work never mixes with project work.
 *
 * Desktop: a docked panel that leaves the page usable beside it. Mobile: full
 * screen. ⌘J / Ctrl+J toggles it. Hidden on /dashboard/chat (it has its own).
 */
import { useCallback, useEffect } from 'react';
import { usePathname } from 'next/navigation';
import { AnimatePresence, motion, useReducedMotion } from 'framer-motion';
import { Sparkles } from 'lucide-react';
import AgentPane from '@/components/chat/AgentPane';
import { useNamespace } from '@/contexts/NamespaceContext';
import { useAssistant } from '@/store/assistant.store';

export default function PageAssistant({ onChanged }: { onChanged?: () => void }) {
  const pathname = usePathname() || '/dashboard';
  const { open, setOpen, toggle } = useAssistant();
  const { currentNamespace } = useNamespace();
  const reduce = useReducedMotion();
  const hidden = pathname.startsWith('/dashboard/chat');

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (!hidden && (e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'j') {
        e.preventDefault();
        toggle();
      }
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [toggle, hidden]);

  const close = useCallback(() => setOpen(false), [setOpen]);

  if (hidden) return null;

  return (
    <>
      {!open && (
        <button
          type="button"
          onClick={() => setOpen(true)}
          aria-label="Ask AI about this page (Ctrl+J)"
          title="Ask AI about this page (⌘J)"
          className="fixed bottom-5 right-5 z-40 inline-flex min-h-11 items-center gap-2 rounded-full bg-gradient-to-br from-primary-500 to-primary-700 px-4 text-sm font-semibold text-white shadow-lg shadow-primary-500/30 transition hover:shadow-xl hover:shadow-primary-500/40 focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-primary-300 active:scale-95"
        >
          <Sparkles className="h-4 w-4" />
          Ask AI
        </button>
      )}

      <AnimatePresence>
        {open && (
          <motion.aside
            key="page-assistant"
            role="dialog"
            aria-label="AI assistant"
            initial={{ x: reduce ? 0 : 40, opacity: 0 }}
            animate={{ x: 0, opacity: 1 }}
            exit={{ x: reduce ? 0 : 40, opacity: 0 }}
            transition={{ duration: 0.22, ease: [0.16, 1, 0.3, 1] }}
            // Escape closes it only while focus is inside (page modals keep theirs).
            onKeyDown={(e) => e.key === 'Escape' && close()}
            className="fixed inset-0 z-50 flex flex-col bg-surface sm:inset-y-0 sm:left-auto sm:right-0 sm:w-[420px] sm:border-l sm:border-secondary-200 sm:shadow-2xl"
          >
            <AgentPane
              key={currentNamespace?.uuid || 'default'}
              namespaceName={currentNamespace?.name}
              namespaceKey={currentNamespace?.uuid}
              path={pathname}
              onClose={close}
              onChanged={onChanged}
            />
          </motion.aside>
        )}
      </AnimatePresence>
    </>
  );
}

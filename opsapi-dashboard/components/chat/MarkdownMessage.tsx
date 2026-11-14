'use client';

/**
 * Renders an assistant reply as markdown (bold, lists, tables, links, code),
 * styled for the neutral assistant bubble. Shared by every AI chat.
 */

import React from 'react';
import Link from 'next/link';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';

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

export default MarkdownMessage;

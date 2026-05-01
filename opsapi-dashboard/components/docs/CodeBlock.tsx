'use client';

import { useState } from 'react';
import { Check, Copy } from 'lucide-react';

export interface CodeTab {
  label: string;
  language: string;
  code: string;
}

export function CodeBlock({ tabs }: { tabs: CodeTab[] }) {
  const [active, setActive] = useState(0);
  const [copied, setCopied] = useState(false);
  const current = tabs[active];

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(current.code);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // clipboard unavailable — silently ignore
    }
  };

  return (
    <div className="overflow-hidden rounded-lg border border-secondary-800 bg-secondary-950 text-xs">
      <div className="flex items-center justify-between border-b border-secondary-800 bg-secondary-900 px-2 py-1">
        <div className="flex gap-1">
          {tabs.map((t, i) => (
            <button
              key={t.label}
              type="button"
              onClick={() => setActive(i)}
              className={`rounded px-2 py-1 text-xs ${
                i === active
                  ? 'bg-secondary-800 text-white'
                  : 'text-secondary-400 hover:text-secondary-200'
              }`}
            >
              {t.label}
            </button>
          ))}
        </div>
        <button
          type="button"
          onClick={copy}
          className="flex items-center gap-1 rounded px-2 py-1 text-xs text-secondary-400 hover:bg-secondary-800 hover:text-secondary-100"
        >
          {copied ? (
            <Check className="h-3.5 w-3.5" />
          ) : (
            <Copy className="h-3.5 w-3.5" />
          )}
          {copied ? 'Copied' : 'Copy'}
        </button>
      </div>
      <pre className="overflow-x-auto p-4 text-[12.5px] leading-relaxed text-secondary-100">
        <code>{current.code}</code>
      </pre>
    </div>
  );
}

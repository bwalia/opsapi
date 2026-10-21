'use client';

import React, { useEffect, useRef, useState } from 'react';
import { Check, Copy } from 'lucide-react';
import { Button } from '@/components/ui';

async function copyText(text: string): Promise<boolean> {
  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch {
    // Clipboard API blocked (insecure context / permissions) — try the legacy path.
  }
  try {
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    const ok = document.execCommand('copy');
    document.body.removeChild(ta);
    return ok;
  } catch {
    return false;
  }
}

export function CopyButton({ text, label = 'Copy' }: { text: string; label?: string }) {
  const [state, setState] = useState<'idle' | 'copied' | 'failed'>('idle');
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(
    () => () => {
      if (timer.current) clearTimeout(timer.current);
    },
    [],
  );

  const onCopy = async () => {
    const ok = await copyText(text);
    setState(ok ? 'copied' : 'failed');
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(() => setState('idle'), 2000);
  };

  return (
    <Button
      size="sm"
      variant="outline"
      leftIcon={state === 'copied' ? <Check className="h-4 w-4" /> : <Copy className="h-4 w-4" />}
      onClick={() => void onCopy()}
      aria-live="polite"
    >
      {state === 'copied' ? 'Copied' : state === 'failed' ? 'Copy failed' : label}
    </Button>
  );
}

export function CodeBlock({ code, title, label }: { code: string; title?: string; label?: string }) {
  return (
    <div className="space-y-2">
      <div className="flex items-center justify-between gap-2">
        {title ? <span className="text-xs font-medium text-secondary-500">{title}</span> : <span />}
        <CopyButton text={code} label={label} />
      </div>
      <pre
        className="max-h-80 overflow-auto rounded border border-secondary-200 bg-secondary-100 p-3 font-mono text-xs leading-relaxed whitespace-pre"
        aria-label={title ? `${title} code` : 'Code snippet'}
        tabIndex={0}
      >
        <code>{code}</code>
      </pre>
    </div>
  );
}

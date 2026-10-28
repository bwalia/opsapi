'use client';

/**
 * "Your terminal" — for the person a manager made a terminal key for (Web terminals → People): plain steps for
 * working on a task there and for opening it on its own with the key file + passphrase they were given.
 * Shows nothing when they have no key, or when the AI Runs plugin is off (its API isn't there).
 */
import React from 'react';
import { ExternalLink, TerminalSquare } from 'lucide-react';
import { Card } from '@/components/ui';
import { aiRunner, type MyTerminal } from '@/services/ai-runner.service';
import { toDate, useAiData } from './ui';

const day = (v: string) => toDate(v)?.toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' });

/** "Mac Studio" → "Mac Studio terminal"; a name that already says terminal stays as it is. */
export const terminalLabel = (name: string) => (/\bterminal$/i.test(name.trim()) ? name.trim() : `${name.trim()} terminal`);

export function signInLink(t: Pick<MyTerminal, 'url' | 'terminal_user'>) {
  return `${t.url.replace(/\/+$/, '')}/?user=${encodeURIComponent(t.terminal_user)}`;
}

export default function MyTerminalAccess() {
  const { data } = useAiData(() => aiRunner.myTerminals(), []);
  if (!data?.length) return null;
  return (
    <>
      {data.map((t) => (
        <Card key={t.uuid} className="p-4 sm:p-5" data-testid="my-terminal">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div className="flex items-start gap-3">
              <TerminalSquare className="mt-0.5 h-5 w-5 shrink-0 text-primary-600" aria-hidden />
              <div>
                <h2 className="font-semibold text-secondary-900">You can work in the {terminalLabel(t.name)}</h2>
                <p className="text-sm text-secondary-600">
                  Your user name there is <strong className="font-mono">{t.terminal_user}</strong>. Your key works until{' '}
                  {day(t.expires_at)}.
                </p>
              </div>
            </div>
            <a
              href={signInLink(t)}
              target="_blank"
              rel="noopener noreferrer"
              className="inline-flex items-center gap-1.5 rounded-lg border border-secondary-300 px-3 py-1.5 text-sm font-medium text-secondary-800 hover:bg-secondary-50"
            >
              Open the terminal <ExternalLink className="h-3.5 w-3.5" aria-hidden />
            </a>
          </div>
          <div className="mt-4 grid gap-4 text-sm text-secondary-700 md:grid-cols-2">
            <div>
              <p className="font-medium text-secondary-900">To work on a task</p>
              <ol className="mt-1 list-decimal space-y-1 pl-5">
                <li>Open the task below and click Start with AI.</li>
                <li>Choose to work on it in the terminal, then click Open the terminal.</li>
                <li>
                  {t.autologin
                    ? 'The first time (then every 12 hours) type the code we email you. The terminal opens on your task.'
                    : 'If it asks you to sign in, do the steps on the right. The terminal then opens on your task.'}
                </li>
              </ol>
            </div>
            <div>
              <p className="font-medium text-secondary-900">To open the terminal on its own</p>
              <ol className="mt-1 list-decimal space-y-1 pl-5">
                <li>Have the key file your manager sent you (it ends in .key) and the passphrase they told you.</li>
                <li>Click Open the terminal. Your user name is filled in for you.</li>
                <li>Click Choose file and pick the key file, type the passphrase, then click Sign in.</li>
              </ol>
              <p className="mt-1 text-xs text-secondary-500">
                Lost the file or the passphrase? Ask your manager for a new key. Never share them.
              </p>
            </div>
          </div>
        </Card>
      ))}
    </>
  );
}

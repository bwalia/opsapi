'use client';

/**
 * BuildFooter — shows exactly which dashboard build is live and what it's
 * connected to. Values are baked at `next build` from NEXT_PUBLIC_BUILD_* (see
 * Dockerfile + deploy-workstation-dashboard.yml), so they reflect the deployed
 * image, not the repo's shared git tag. In local dev they're unset → "dev".
 *
 * The commit SHA (+ build time) is the unambiguous identifier of this build —
 * the version string is the release tag it was cut from. The relative time is
 * computed after mount (refreshed each minute) to avoid a hydration mismatch.
 */

import React, { useEffect, useState } from 'react';
import apiClient from '@/lib/api-client';
import { formatRelativeTime } from '@/lib/utils';

const VERSION = process.env.NEXT_PUBLIC_BUILD_VERSION || 'dev';
const SHA = process.env.NEXT_PUBLIC_BUILD_SHA || '';
const BUILT_AT = process.env.NEXT_PUBLIC_BUILD_TIME || '';
const API_URL = process.env.NEXT_PUBLIC_API_URL || '';

function apiHost(): string {
  try {
    return new URL(API_URL).host;
  } catch {
    return API_URL.replace(/^https?:\/\//, '').replace(/\/.*$/, '');
  }
}

/** Derive the environment from the backend host it talks to. */
function envBadge(): { label: string; cls: string } {
  const h = apiHost().toLowerCase();
  if (!h || h.includes('localhost') || h.includes('127.0.0.1'))
    return { label: 'DEV', cls: 'bg-secondary-200 text-secondary-700' };
  if (h.startsWith('int-')) return { label: 'INT', cls: 'bg-blue-100 text-blue-700' };
  if (h.startsWith('acc-')) return { label: 'ACC', cls: 'bg-amber-100 text-amber-700' };
  if (h.startsWith('test-')) return { label: 'TEST', cls: 'bg-purple-100 text-purple-700' };
  return { label: 'PROD', cls: 'bg-green-100 text-green-700' };
}

interface AiStatus {
  model: string;
  status: 'ok' | 'slow' | 'down' | 'checking' | 'off';
  latency_ms?: number;
  reason?: string;
  checked_at?: number;
}

const AI_DOT: Record<AiStatus['status'], string> = {
  ok: 'bg-success-500',
  slow: 'bg-amber-500',
  down: 'bg-error-500',
  checking: 'bg-secondary-300 animate-pulse',
  off: 'bg-secondary-300',
};

function aiLabel(ai: AiStatus): string {
  if (ai.status === 'ok' || ai.status === 'slow') {
    const ms = ai.latency_ms ?? 0;
    return ms >= 1000 ? `${(ms / 1000).toFixed(1)} s` : `${ms} ms`;
  }
  return ai.status === 'checking' ? '…' : ai.status;
}

/**
 * The model behind the chat assistant and how it's answering right now:
 * green under 3s, amber when slower, red when down. The backend measures one
 * real request a minute, shared by all users (lapis/lib/agent/agent).
 * Hidden if this API doesn't expose it.
 */
function AiStatusBadge() {
  const [ai, setAi] = useState<AiStatus | null>(null);

  useEffect(() => {
    let alive = true;
    const load = () => {
      if (document.visibilityState !== 'visible') return;
      apiClient
        .get('/api/chat/agent/status')
        .then((res) => alive && setAi((res.data as { data: AiStatus }).data))
        .catch(() => alive && setAi(null));
    };
    load();
    const id = setInterval(load, 60_000);
    document.addEventListener('visibilitychange', load);
    return () => {
      alive = false;
      clearInterval(id);
      document.removeEventListener('visibilitychange', load);
    };
  }, []);

  if (!ai) return null;
  const up = ai.status === 'ok' || ai.status === 'slow';
  const detail = up ? `answered in ${ai.latency_ms} ms` : (ai.reason ?? ai.status);
  const checked = ai.checked_at ? ` · checked ${formatRelativeTime(new Date(ai.checked_at * 1000))}` : '';

  return (
    <>
      <span className="text-secondary-300" aria-hidden>|</span>
      <span
        className="inline-flex items-center gap-1.5"
        title={`AI assistant model ${ai.model}: ${detail}${checked}`}
        aria-label={`AI model ${ai.model}: ${ai.status === 'ok' ? 'healthy' : ai.status}, ${detail}`}
      >
        <span className={`h-2 w-2 rounded-full ${AI_DOT[ai.status]}`} aria-hidden />
        <span className="text-secondary-400">AI</span>
        <span className="font-mono text-secondary-700">{ai.model}</span>
        <span className={ai.status === 'down' ? 'font-medium text-error-600' : 'font-mono text-secondary-500'}>
          {aiLabel(ai)}
        </span>
      </span>
    </>
  );
}

export function BuildFooter() {
  const [ago, setAgo] = useState('');

  useEffect(() => {
    if (!BUILT_AT) return;
    const tick = () => setAgo(formatRelativeTime(BUILT_AT));
    tick();
    const id = setInterval(tick, 60_000);
    return () => clearInterval(id);
  }, []);

  const env = envBadge();
  const host = apiHost();
  const commitUrl = SHA ? `https://github.com/bwalia/opsapi/commit/${SHA}` : '';
  const builtExact = BUILT_AT ? new Date(BUILT_AT).toLocaleString() : '';

  return (
    <footer className="border-t border-secondary-200 bg-surface py-3 pl-4 pr-32 text-xs text-secondary-500 sm:pl-6">
      <div className="flex flex-wrap items-center gap-x-4 gap-y-1.5">
        <span className="inline-flex items-center gap-1.5 font-semibold text-secondary-700">
          <span className="h-2 w-2 rounded-full bg-primary-500" aria-hidden />
          OpsAPI Dashboard
        </span>

        <span className={`inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-bold tracking-wide ${env.cls}`}>
          {env.label}
        </span>

        <span className="text-secondary-300" aria-hidden>|</span>

        <span title="Dashboard build tag (release + dashboard build number)">
          <span className="text-secondary-400">build</span>{' '}
          <span className="font-mono text-secondary-700">{VERSION}</span>
        </span>

        {SHA && (
          <span title="The git commit this dashboard build was made from">
            <span className="text-secondary-400">commit</span>{' '}
            <a
              href={commitUrl}
              target="_blank"
              rel="noopener noreferrer"
              className="font-mono text-primary-600 hover:underline"
            >
              {SHA}
            </a>
          </span>
        )}

        {BUILT_AT && (
          <span title={builtExact}>
            <span className="text-secondary-400">built</span> {ago || 'recently'}
          </span>
        )}

        {host && (
          <>
            <span className="hidden text-secondary-300 sm:inline" aria-hidden>|</span>
            <span className="hidden sm:inline" title="Backend API this dashboard is connected to">
              <span className="text-secondary-400">API</span>{' '}
              <span className="font-mono text-secondary-600">{host}</span>
            </span>
          </>
        )}

        <AiStatusBadge />

        <span className="ml-auto hidden text-secondary-400 md:inline">
          © {new Date().getFullYear()} Workstation
        </span>
      </div>
    </footer>
  );
}

export default BuildFooter;

'use client';

/**
 * Hosts a plugin's custom page (manifest `pages`, PLUGINS.md §6.2) and
 * answers its bridge calls (page side: lapis/static/plugin-ui/opsapi-ui.js).
 *
 * The page runs in a sandboxed frame without allow-same-origin: an opaque
 * origin with no cookies, storage or DOM access to the dashboard. It can only
 * ask, by postMessage carrying this mount's random token, for:
 *   - API calls, made here as the signed-in user in the current workspace,
 *     limited to the plugin's API and the prefixes its manifest lists;
 *   - dashboard navigation, toasts, a confirm dialog, URL params, its height.
 * A document the frame navigates to never learns the token, so it can't use
 * the bridge.
 */

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { usePathname, useRouter, useSearchParams } from 'next/navigation';
import toast from 'react-hot-toast';
import { AlertTriangle } from 'lucide-react';
import type { AxiosError } from 'axios';
import apiClient from '@/lib/api-client';
import { Button, Card, ConfirmDialog } from '@/components/ui';
import { useNamespace } from '@/contexts/NamespaceContext';
import { usePermissions } from '@/contexts/PermissionsContext';
import { useAuthStore } from '@/store/auth.store';
import {
  BRIDGE_METHODS,
  BRIDGE_VERSION,
  errorMessage,
  resolveApiPath,
  themeSnapshot,
} from '@/lib/plugin-bridge';
import type { PluginPageSchema } from '@/services/plugins.service';

const CONNECT_TIMEOUT_MS = 10_000;
const MIN_HEIGHT = 240;
const MAX_HEIGHT = 50_000;

type FrameState = 'loading' | 'ready' | 'timeout';
type BridgeMessage = { __opsapi?: number; token?: string; type?: string; id?: number } & Record<string, unknown>;
interface PendingConfirm {
  id: number;
  title: string;
  message: string;
  confirmLabel: string;
  danger: boolean;
}

function newToken() {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

const text = (v: unknown, max: number, fallback = '') => (typeof v === 'string' && v ? v.slice(0, max) : fallback);

export function PluginPageFrame({ schema }: { schema: PluginPageSchema }) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const { currentNamespace } = useNamespace();
  const { namespacePermissions, isAdmin } = usePermissions();
  const user = useAuthStore((s) => s.user);

  const frameRef = useRef<HTMLIFrameElement>(null);
  const [attempt, setAttempt] = useState(0);
  const token = useMemo(() => newToken(), [attempt]); // eslint-disable-line react-hooks/exhaustive-deps
  const [state, setState] = useState<FrameState>('loading');
  const [height, setHeight] = useState(600);
  const [confirm, setConfirm] = useState<PendingConfirm | null>(null);

  const src = `${(apiClient.defaults.baseURL || '').replace(/\/+$/, '')}${schema.url}#opsapi=${token}`;
  const params = useMemo(() => Object.fromEntries(searchParams.entries()), [searchParams]);

  // Latest values for the message handler without re-subscribing it.
  const live = useRef({ params, namespacePermissions, isAdmin, user, currentNamespace });
  useEffect(() => {
    live.current = { params, namespacePermissions, isAdmin, user, currentNamespace };
  }, [params, namespacePermissions, isAdmin, user, currentNamespace]);

  const post = useCallback((msg: Record<string, unknown>) => {
    frameRef.current?.contentWindow?.postMessage({ __opsapi: BRIDGE_VERSION, ...msg }, '*');
  }, []);
  const reply = useCallback(
    (id: unknown, ok: boolean, payload: Record<string, unknown> = {}) => post({ type: 'reply', id, ok, ...payload }),
    [post]
  );

  const request = useCallback(
    async (m: BridgeMessage) => {
      const method = String(m.method || 'GET').toUpperCase();
      const url = resolveApiPath(m.path, schema.plugin.api_prefix, schema.api);
      if (!BRIDGE_METHODS.has(method)) return reply(m.id, false, { status: 405, error: `${method} isn't allowed` });
      if (!url) {
        return reply(m.id, false, {
          status: 403,
          error: `This page may not call ${String(m.path)}. Add its prefix to the page's api list in project.lua.`,
        });
      }
      try {
        const res = await apiClient.request({
          method,
          url,
          data: m.body,
          headers: m.body !== undefined ? { 'Content-Type': 'application/json' } : undefined,
        });
        reply(m.id, true, { status: res.status, result: res.data });
      } catch (err) {
        const res = (err as AxiosError).response;
        reply(m.id, false, {
          status: res?.status ?? 0,
          body: res?.data,
          error: errorMessage(res?.data) ?? (res ? `Request failed (${res.status})` : 'Network error'),
        });
      }
    },
    [reply, schema]
  );

  const onMessage = useCallback(
    (e: MessageEvent) => {
      if (!frameRef.current || e.source !== frameRef.current.contentWindow) return;
      const m = e.data as BridgeMessage;
      if (!m || m.__opsapi !== BRIDGE_VERSION || m.token !== token) return;

      switch (m.type) {
        case 'hello': {
          const { params: p, namespacePermissions: perms, isAdmin: admin, user: u, currentNamespace: ns } = live.current;
          reply(m.id, true, {
            result: {
              plugin: schema.plugin,
              page: { key: schema.key, label: schema.label, module: schema.module },
              user: u
                ? { uuid: u.uuid, email: u.email, name: [u.first_name, u.last_name].filter(Boolean).join(' ') }
                : null,
              namespace: ns ? { uuid: ns.uuid, name: ns.name, slug: ns.slug } : null,
              can: schema.can, // the page's module, as the API decided
              permissions: perms ?? {},
              isAdmin: admin,
              params: p,
              theme: themeSnapshot(),
            },
          });
          setState('ready');
          break;
        }
        case 'request':
          void request(m);
          break;
        case 'resize': {
          const h = Number(m.height);
          if (Number.isFinite(h)) setHeight(Math.min(MAX_HEIGHT, Math.max(MIN_HEIGHT, Math.ceil(h))));
          break;
        }
        case 'navigate': {
          const path = text(m.path, 2000);
          if (path.startsWith('/dashboard') && !path.startsWith('//')) router.push(path);
          break;
        }
        case 'toast': {
          const message = text(m.message, 300);
          if (!message) break;
          if (m.toastType === 'error') toast.error(message);
          else if (m.toastType === 'info') toast(message);
          else toast.success(message);
          break;
        }
        case 'confirm': {
          const o = (m.options ?? {}) as Record<string, unknown>;
          setConfirm({
            id: Number(m.id),
            title: text(o.title, 120, 'Are you sure?'),
            message: text(o.message, 600),
            confirmLabel: text(o.confirmLabel, 40, 'Confirm'),
            danger: o.danger === true,
          });
          break;
        }
        case 'setParams': {
          const next = new URLSearchParams();
          const given = (m.params ?? {}) as Record<string, unknown>;
          for (const [k, v] of Object.entries(given).slice(0, 50)) {
            if (v !== undefined && v !== null && v !== '') next.set(k.slice(0, 100), String(v).slice(0, 500));
          }
          const qs = next.toString();
          router.replace(qs ? `${pathname}?${qs}` : pathname, { scroll: false });
          break;
        }
      }
    },
    [token, reply, request, router, pathname, schema]
  );

  useEffect(() => {
    window.addEventListener('message', onMessage);
    return () => window.removeEventListener('message', onMessage);
  }, [onMessage]);

  // Give up waiting for the page's bridge after a while.
  useEffect(() => {
    if (state !== 'loading') return;
    const t = setTimeout(() => setState((s) => (s === 'loading' ? 'timeout' : s)), CONNECT_TIMEOUT_MS);
    return () => clearTimeout(t);
  }, [state, attempt]);

  // Follow light/dark and branding changes.
  useEffect(() => {
    if (state !== 'ready') return;
    const observer = new MutationObserver(() => post({ type: 'event', name: 'theme', data: themeSnapshot() }));
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ['class', 'style'] });
    return () => observer.disconnect();
  }, [state, post]);

  // Back/forward changes the URL params: tell the page.
  const paramsKey = searchParams.toString();
  const sentParams = useRef(paramsKey);
  useEffect(() => {
    if (state !== 'ready' || sentParams.current === paramsKey) return;
    sentParams.current = paramsKey;
    post({ type: 'event', name: 'params', data: params });
  }, [paramsKey, params, state, post]);

  const answer = (ok: boolean) => {
    if (!confirm) return;
    reply(confirm.id, true, { result: ok });
    setConfirm(null);
  };

  if (state === 'timeout') {
    return (
      <Card padding="lg">
        <div className="flex flex-col items-center text-center py-10 gap-3" role="alert">
          <div className="w-12 h-12 rounded-xl bg-warning-500/10 text-warning-600 flex items-center justify-center">
            <AlertTriangle className="w-6 h-6" aria-hidden="true" />
          </div>
          <h2 className="text-lg font-semibold text-secondary-900">This page didn&apos;t load</h2>
          <p className="text-sm text-secondary-500 max-w-md">
            {schema.plugin.name} didn&apos;t respond. If you develop this plugin: the page must load
            /plugin-ui/_sdk/opsapi-ui.js and call OpsAPI.connect(). Check the browser console for errors.
          </p>
          <Button
            variant="outline"
            onClick={() => {
              setState('loading');
              setAttempt((n) => n + 1);
            }}
          >
            Try again
          </Button>
        </div>
      </Card>
    );
  }

  return (
    <div className="relative" data-plugin-page={schema.key} data-state={state}>
      {state === 'loading' && (
        <div className="absolute inset-0 space-y-4" aria-busy="true" aria-label={`Loading ${schema.label}`}>
          <div className="h-24 rounded-xl bg-secondary-100 animate-pulse" />
          <div className="h-72 rounded-xl bg-secondary-100 animate-pulse" />
        </div>
      )}
      <iframe
        key={attempt}
        ref={frameRef}
        src={src}
        title={schema.label}
        sandbox="allow-scripts allow-forms allow-popups allow-popups-to-escape-sandbox allow-downloads"
        referrerPolicy="no-referrer"
        className={`block w-full border-0 bg-transparent transition-opacity duration-200 ${
          state === 'ready' ? 'opacity-100' : 'opacity-0'
        }`}
        style={{ height }}
      />
      <ConfirmDialog
        isOpen={!!confirm}
        onClose={() => answer(false)}
        onConfirm={() => answer(true)}
        title={confirm?.title ?? ''}
        message={confirm?.message ?? ''}
        confirmText={confirm?.confirmLabel}
        variant={confirm?.danger ? 'danger' : 'info'}
      />
    </div>
  );
}

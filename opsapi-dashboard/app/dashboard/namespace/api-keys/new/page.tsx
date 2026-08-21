'use client';

import React, { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import {
  Key,
  ArrowLeft,
  Search,
  ShieldCheck,
  ShieldAlert,
  AlertTriangle,
  Lock,
  Copy,
  Check,
  Loader2,
  RotateCw,
  Sparkles,
} from 'lucide-react';
import { Button, Card, Badge } from '@/components/ui';
import { useNamespace } from '@/contexts/NamespaceContext';
import { apiKeysService, rolesService } from '@/services';
import type {
  CreatedApiKey,
  ApiKeyScopes,
  NamespaceModuleMeta,
  NamespaceActionMeta,
} from '@/types';
import toast from 'react-hot-toast';

const KEYS_PATH = '/dashboard/namespace/api-keys';

export default function NewApiKeyPage() {
  const router = useRouter();
  const { currentNamespace, isNamespaceOwner, hasPermission } = useNamespace();
  const canManage = isNamespaceOwner || hasPermission('api_keys', 'manage');

  const [name, setName] = useState('');
  const [scopes, setScopes] = useState<ApiKeyScopes>({});
  const [scopeQuery, setScopeQuery] = useState('');
  const [expiresAt, setExpiresAt] = useState('');
  const [modules, setModules] = useState<NamespaceModuleMeta[]>([]);
  const [actions, setActions] = useState<NamespaceActionMeta[]>([]);
  const [metaLoading, setMetaLoading] = useState(true);
  const [metaError, setMetaError] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [created, setCreated] = useState<CreatedApiKey | null>(null);

  const loadMeta = useCallback(async () => {
    setMetaLoading(true);
    setMetaError(false);
    try {
      const meta = (await rolesService.getPermissionsMeta()) as unknown as {
        modules: NamespaceModuleMeta[];
        actions: NamespaceActionMeta[];
      };
      // Backend forbids the "namespace" module on API keys (no self-escalation).
      setModules((meta.modules || []).filter((m) => m && m.name && m.name !== 'namespace'));
      setActions(meta.actions || []);
    } catch {
      setMetaError(true);
    } finally {
      setMetaLoading(false);
    }
  }, []);

  useEffect(() => {
    if (canManage) loadMeta();
  }, [canManage, loadMeta]);

  const toggle = (mod: string, action: string) =>
    setScopes((prev) => {
      const set = new Set(prev[mod] || []);
      if (set.has(action)) set.delete(action);
      else set.add(action);
      const next = { ...prev };
      if (set.size === 0) delete next[mod];
      else next[mod] = Array.from(set);
      return next;
    });

  const toggleAll = (mod: string) =>
    setScopes((prev) => {
      const all = actions.map((a) => a.name as string);
      const has = (prev[mod] || []).length === all.length && all.length > 0;
      const next = { ...prev };
      if (has) delete next[mod];
      else next[mod] = all;
      return next;
    });

  const moduleLabel = (n: string) => modules.find((m) => m.name === n)?.display_name || n;
  const scopeEntries = Object.entries(scopes);
  const scopeCount = scopeEntries.length;
  const grantCount = scopeEntries.reduce((sum, [, acts]) => sum + acts.length, 0);

  const q = scopeQuery.trim().toLowerCase();
  const filteredModules = q
    ? modules.filter((m) =>
        [m.display_name, m.name, m.category, m.description]
          .filter(Boolean)
          .some((v) => String(v).toLowerCase().includes(q)),
      )
    : modules;

  const today = new Date().toISOString().slice(0, 10);

  const submit = async () => {
    if (!name.trim()) return toast.error('Give the key a name');
    if (scopeCount === 0) return toast.error('Grant at least one permission');
    if (expiresAt && expiresAt < today) return toast.error('Expiry cannot be in the past');
    setSubmitting(true);
    try {
      const result = await apiKeysService.create({
        name: name.trim(),
        scopes,
        expires_at: expiresAt || undefined,
      });
      setCreated(result);
      toast.success('API key created');
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Failed to create API key');
    } finally {
      setSubmitting(false);
    }
  };

  // ---- Guards --------------------------------------------------------------
  if (!currentNamespace) {
    return (
      <Card className="p-8 text-center text-secondary-500">Select a namespace to create an API key.</Card>
    );
  }
  if (!canManage) {
    return (
      <div className="max-w-xl mx-auto">
        <Card className="p-10 text-center">
          <ShieldAlert className="w-10 h-10 text-secondary-300 mx-auto mb-3" />
          <h3 className="text-secondary-900 font-semibold">Not authorised</h3>
          <p className="text-secondary-500 text-sm mt-1">
            You need owner or namespace-manage rights to create API keys.
          </p>
          <Button className="mt-4" variant="outline" onClick={() => router.push(KEYS_PATH)}>
            Back to API keys
          </Button>
        </Card>
      </div>
    );
  }

  if (created) return <RevealCreated created={created} onDone={() => router.push(KEYS_PATH)} />;

  // ---- Create form (full-width two-panel) ---------------------------------
  return (
    <div className="space-y-6">
      <div className="flex items-center gap-4">
        <button
          onClick={() => router.push(KEYS_PATH)}
          className="inline-flex items-center justify-center w-9 h-9 rounded-lg border border-secondary-200 text-secondary-500 hover:text-secondary-800 hover:border-secondary-300 transition-colors"
          aria-label="Back to API keys"
        >
          <ArrowLeft className="w-4 h-4" />
        </button>
        <div className="flex items-center gap-3">
          <div className="w-11 h-11 rounded-xl bg-primary-500/10 flex items-center justify-center">
            <Key className="w-5 h-5 text-primary-600" />
          </div>
          <div>
            <h1 className="text-xl font-bold text-secondary-900">Create API key</h1>
            <p className="text-sm text-secondary-500">
              A machine credential — scoped to this namespace and the exact permissions you choose.
            </p>
          </div>
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-12 gap-6 items-start">
        {/* Main column */}
        <div className="lg:col-span-8 space-y-6">
          {/* Name */}
          <Card className="p-6 space-y-2">
            <label htmlFor="key-name" className="block text-sm font-semibold text-secondary-800">
              Name
            </label>
            <input
              id="key-name"
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="e.g. blog-importer, ci-deploy"
              className="w-full rounded-lg border border-secondary-300 px-3.5 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-primary-500 transition"
              autoFocus
            />
            <p className="text-xs text-secondary-500">A label to recognise this key later — not secret.</p>
          </Card>

          {/* Permissions */}
          <Card className="p-6 space-y-4">
            <div className="flex items-start justify-between gap-3">
              <div>
                <h2 className="text-sm font-semibold text-secondary-800">Permissions</h2>
                <p className="text-xs text-secondary-500 mt-0.5">
                  Pick a module, then the actions this key may perform. Least privilege — grant only what it needs.
                </p>
              </div>
              {grantCount > 0 && (
                <Badge variant="info">
                  {grantCount} action{grantCount > 1 ? 's' : ''}
                </Badge>
              )}
            </div>

            {metaLoading ? (
              <div className="flex justify-center py-12">
                <Loader2 className="w-6 h-6 animate-spin text-primary-500" />
              </div>
            ) : metaError ? (
              <div className="text-center py-10">
                <p className="text-sm text-secondary-500">Couldn’t load available permissions.</p>
                <Button className="mt-3" variant="outline" size="sm" onClick={loadMeta} leftIcon={<RotateCw className="w-4 h-4" />}>
                  Retry
                </Button>
              </div>
            ) : modules.length === 0 ? (
              <p className="text-sm text-secondary-500 py-4">No scopable modules are enabled in this namespace.</p>
            ) : (
              <>
                <div className="relative">
                  <Search className="w-4 h-4 text-secondary-400 absolute left-3.5 top-1/2 -translate-y-1/2 pointer-events-none" />
                  <input
                    value={scopeQuery}
                    onChange={(e) => setScopeQuery(e.target.value)}
                    placeholder={`Search ${modules.length} modules…`}
                    className="w-full rounded-lg border border-secondary-300 pl-10 pr-3 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-primary-500 transition"
                    aria-label="Search permissions"
                  />
                </div>

                {filteredModules.length === 0 ? (
                  <p className="text-sm text-secondary-500 text-center py-10">No modules match “{scopeQuery}”.</p>
                ) : (
                  <div className="grid gap-3 sm:grid-cols-2 2xl:grid-cols-3">
                    {filteredModules.map((mod) => {
                      const selected = scopes[mod.name] || [];
                      const allOn = selected.length === actions.length && actions.length > 0;
                      return (
                        <div
                          key={mod.name}
                          className={`rounded-xl border p-4 transition-colors ${
                            selected.length
                              ? 'border-primary-300 bg-primary-500/[0.04]'
                              : 'border-secondary-200 hover:border-secondary-300'
                          }`}
                        >
                          <div className="flex items-center justify-between gap-2 mb-3">
                            <div className="min-w-0">
                              <div className="text-sm font-semibold text-secondary-900 truncate">
                                {mod.display_name || mod.name}
                              </div>
                              {mod.category && (
                                <div className="text-[10px] font-medium uppercase tracking-wider text-secondary-400 mt-0.5">
                                  {mod.category}
                                </div>
                              )}
                            </div>
                            <button
                              type="button"
                              onClick={() => toggleAll(mod.name)}
                              className="text-xs font-semibold text-primary-600 hover:text-primary-700 shrink-0"
                            >
                              {allOn ? 'Clear' : 'All'}
                            </button>
                          </div>
                          <div className="flex flex-wrap gap-1.5">
                            {actions.map((a) => {
                              const active = selected.includes(a.name as string);
                              return (
                                <button
                                  key={a.name}
                                  type="button"
                                  aria-pressed={active}
                                  onClick={() => toggle(mod.name, a.name as string)}
                                  className={`inline-flex items-center gap-1 px-2.5 py-1 rounded-full text-xs font-medium border transition-colors cursor-pointer ${
                                    active
                                      ? 'bg-primary-600 border-primary-600 text-white'
                                      : 'bg-white border-secondary-300 text-secondary-600 hover:border-primary-400 hover:text-primary-600'
                                  }`}
                                  title={a.description || a.display_name || a.name}
                                >
                                  {active && <Check className="w-3 h-3" />}
                                  {a.display_name || a.name}
                                </button>
                              );
                            })}
                          </div>
                        </div>
                      );
                    })}
                  </div>
                )}
              </>
            )}
          </Card>
        </div>

        {/* Sticky summary rail */}
        <aside className="lg:col-span-4 lg:sticky lg:top-6 space-y-4">
          <Card className="p-5 flex items-start gap-2.5 bg-primary-500/[0.06] border-primary-500/20">
            <ShieldCheck className="w-5 h-5 text-primary-600 shrink-0 mt-0.5" />
            <p className="text-sm text-secondary-600">
              Locked to <strong className="text-secondary-900">{currentNamespace.name}</strong> — this key can
              never reach another tenant, and can never manage keys, members, or roles.
            </p>
          </Card>

          <Card className="p-5 space-y-4">
            <div className="flex items-center justify-between">
              <h3 className="text-sm font-semibold text-secondary-800">Summary</h3>
              <span className="text-xs text-secondary-500">
                {scopeCount === 0 ? 'No permissions yet' : `${scopeCount} module${scopeCount > 1 ? 's' : ''}`}
              </span>
            </div>

            {scopeCount === 0 ? (
              <div className="rounded-lg border border-dashed border-secondary-200 px-3 py-6 text-center">
                <Sparkles className="w-5 h-5 text-secondary-300 mx-auto mb-1.5" />
                <p className="text-xs text-secondary-500">Select actions on the left to build this key’s access.</p>
              </div>
            ) : (
              <div className="space-y-2 max-h-64 overflow-y-auto pr-1">
                {scopeEntries.map(([mod, acts]) => (
                  <div key={mod} className="flex items-start justify-between gap-2">
                    <span className="text-sm font-medium text-secondary-800 truncate">{moduleLabel(mod)}</span>
                    <span className="text-xs text-secondary-500 text-right shrink-0">{acts.join(', ')}</span>
                  </div>
                ))}
              </div>
            )}

            <div className="pt-1 border-t border-secondary-100 space-y-2">
              <label htmlFor="key-expiry" className="block text-xs font-semibold text-secondary-700">
                Expiry (optional)
              </label>
              <input
                id="key-expiry"
                type="date"
                value={expiresAt}
                min={today}
                onChange={(e) => setExpiresAt(e.target.value)}
                className="w-full rounded-lg border border-secondary-300 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-primary-500 transition"
              />
            </div>

            <div className="flex flex-col gap-2 pt-1">
              <Button onClick={submit} isLoading={submitting} leftIcon={<Key className="w-4 h-4" />} className="w-full justify-center">
                Create key
              </Button>
              <Button variant="outline" onClick={() => router.push(KEYS_PATH)} disabled={submitting} className="w-full justify-center">
                Cancel
              </Button>
            </div>
          </Card>
        </aside>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Reveal-once — the raw secret is shown a single time (full width)
// ---------------------------------------------------------------------------

function RevealCreated({ created, onDone }: { created: CreatedApiKey; onDone: () => void }) {
  const [copied, setCopied] = useState(false);

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(created.key);
      setCopied(true);
      toast.success('API key copied to clipboard');
      setTimeout(() => setCopied(false), 2500);
    } catch {
      toast.error('Could not copy — select the key and copy it manually');
    }
  };

  return (
    <div className="space-y-6">
      <div className="flex items-center gap-3">
        <div className="w-11 h-11 rounded-xl bg-success-500/10 flex items-center justify-center">
          <Check className="w-5 h-5 text-success-600" />
        </div>
        <div>
          <h1 className="text-xl font-bold text-secondary-900">Your new API key</h1>
          <p className="text-sm text-secondary-500">
            “{created.name}” is ready. Copy the secret now — it is shown only once.
          </p>
        </div>
      </div>

      <Card className="p-4 flex items-start gap-2.5 bg-warning-500/10 border-warning-500/20">
        <AlertTriangle className="w-5 h-5 text-warning-600 shrink-0 mt-0.5" />
        <p className="text-sm text-warning-600">
          For security this secret is <strong>shown only once</strong> and cannot be retrieved again. Store it in
          your secret manager now. Lost it? Revoke this key and create a new one.
        </p>
      </Card>

      <div className="grid grid-cols-1 lg:grid-cols-12 gap-6 items-start">
        <Card className="lg:col-span-8 p-6 space-y-3">
          <label className="block text-sm font-semibold text-secondary-800">Secret key</label>
          <div className="flex items-stretch gap-2">
            <code className="flex-1 font-mono text-sm bg-secondary-50 text-secondary-900 rounded-lg px-4 py-3.5 break-all border border-secondary-200">
              {created.key}
            </code>
            <Button variant="outline" onClick={copy} leftIcon={copied ? <Check className="w-4 h-4" /> : <Copy className="w-4 h-4" />}>
              {copied ? 'Copied' : 'Copy'}
            </Button>
          </div>
          <div className="text-xs text-secondary-500 flex items-center gap-1.5 pt-1">
            <ShieldAlert className="w-3.5 h-3.5" />
            Use as a bearer token: <code className="font-mono">Authorization: Bearer {created.key_prefix}…</code>
          </div>
        </Card>

        <Card className="lg:col-span-4 p-6 space-y-3">
          <div className="flex items-center gap-2 text-sm font-semibold text-secondary-800">
            <Lock className="w-4 h-4 text-secondary-400" /> This key can do
          </div>
          <div className="flex flex-wrap gap-1.5">
            {Object.entries(created.scopes || {}).map(([mod, acts]) => (
              <Badge key={mod} variant="secondary">
                {mod}: {(acts as string[]).join('/')}
              </Badge>
            ))}
          </div>
          {created.expires_at && (
            <p className="text-xs text-secondary-500">Expires {new Date(created.expires_at).toLocaleDateString()}.</p>
          )}
          <div className="pt-2">
            <Button onClick={onDone} className="w-full justify-center">
              Done
            </Button>
          </div>
        </Card>
      </div>
    </div>
  );
}

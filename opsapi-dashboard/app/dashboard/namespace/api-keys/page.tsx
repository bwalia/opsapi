'use client';

import React, { useState, useEffect, useCallback } from 'react';
import {
  Key,
  Plus,
  Trash2,
  Copy,
  Check,
  Loader2,
  ShieldAlert,
  ShieldCheck,
  AlertTriangle,
  Search,
} from 'lucide-react';
import { Button, Card, Badge, Modal, ConfirmDialog, Table } from '@/components/ui';
import { PageHeader } from '@/components/layout/PageHeader';
import { useNamespace } from '@/contexts/NamespaceContext';
import { apiKeysService, rolesService } from '@/services';
import type {
  ApiKey,
  CreatedApiKey,
  ApiKeyScopes,
  NamespaceModuleMeta,
  NamespaceActionMeta,
  TableColumn,
} from '@/types';
import toast from 'react-hot-toast';

const fmtDate = (s?: string | null) =>
  s ? new Date(s).toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' }) : '—';

export default function ApiKeysPage() {
  const { currentNamespace, isNamespaceOwner, hasPermission } = useNamespace();
  const canManage = isNamespaceOwner || hasPermission('api_keys', 'manage');

  const [keys, setKeys] = useState<ApiKey[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [createOpen, setCreateOpen] = useState(false);
  const [createdKey, setCreatedKey] = useState<CreatedApiKey | null>(null);
  const [keyToRevoke, setKeyToRevoke] = useState<ApiKey | null>(null);
  const [isRevoking, setIsRevoking] = useState(false);

  const fetchKeys = useCallback(async () => {
    if (!currentNamespace) return;
    setIsLoading(true);
    try {
      setKeys(await apiKeysService.list());
    } catch {
      toast.error('Failed to load API keys');
    } finally {
      setIsLoading(false);
    }
  }, [currentNamespace]);

  useEffect(() => {
    fetchKeys();
  }, [fetchKeys]);

  const doRevoke = async () => {
    if (!keyToRevoke) return;
    setIsRevoking(true);
    try {
      await apiKeysService.revoke(keyToRevoke.uuid);
      toast.success('API key revoked');
      setKeyToRevoke(null);
      fetchKeys();
    } catch {
      toast.error('Failed to revoke API key');
    } finally {
      setIsRevoking(false);
    }
  };

  if (!currentNamespace) {
    return (
      <Card className="p-8 text-center text-secondary-500">
        Select a namespace to manage its API keys.
      </Card>
    );
  }

  const columns: TableColumn<ApiKey>[] = [
    {
      key: 'name',
      header: 'Name',
      render: (k) => (
        <div className="flex items-center gap-2">
          <Key className="w-4 h-4 text-secondary-400 shrink-0" />
          <span className="font-medium text-secondary-900">{k.name}</span>
        </div>
      ),
    },
    {
      key: 'key_prefix',
      header: 'Key',
      render: (k) => (
        <code className="font-mono text-xs bg-secondary-50 text-secondary-700 rounded px-2 py-1">
          {k.key_prefix}…
        </code>
      ),
    },
    {
      key: 'scopes',
      header: 'Scopes',
      render: (k) => {
        const entries = Object.entries(k.scopes || {});
        if (entries.length === 0) return <span className="text-secondary-400">—</span>;
        return (
          <div className="flex flex-wrap gap-1">
            {entries.map(([mod, actions]) => (
              <Badge key={mod} variant="secondary" title={actions.join(', ')}>
                {mod}: {actions.join('/')}
              </Badge>
            ))}
          </div>
        );
      },
    },
    { key: 'last_used_at', header: 'Last used', render: (k) => <span className="text-secondary-600">{fmtDate(k.last_used_at)}</span> },
    { key: 'expires_at', header: 'Expires', render: (k) => <span className="text-secondary-600">{fmtDate(k.expires_at)}</span> },
    {
      key: 'status',
      header: 'Status',
      render: (k) =>
        k.revoked ? <Badge variant="error">Revoked</Badge> : <Badge variant="success">Active</Badge>,
    },
    {
      key: 'actions',
      header: '',
      render: (k) =>
        canManage && !k.revoked ? (
          <button
            onClick={() => setKeyToRevoke(k)}
            className="text-secondary-400 hover:text-error-600 transition-colors"
            title="Revoke key"
            aria-label={`Revoke ${k.name}`}
          >
            <Trash2 className="w-4 h-4" />
          </button>
        ) : null,
    },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="API Keys"
        description={`Machine credentials for ${currentNamespace.name}. Keys authenticate as "Authorization: Bearer opsk_…" and only do what their scopes allow.`}
        icon={<Key className="w-6 h-6" />}
        actions={
          canManage ? (
            <Button onClick={() => setCreateOpen(true)} leftIcon={<Plus className="w-4 h-4" />}>
              Create API key
            </Button>
          ) : undefined
        }
      />

      {isLoading ? (
        <div className="flex justify-center py-16">
          <Loader2 className="w-6 h-6 animate-spin text-primary-500" />
        </div>
      ) : keys.length === 0 ? (
        <Card className="p-10 text-center">
          <Key className="w-10 h-10 text-secondary-300 mx-auto mb-3" />
          <h3 className="text-secondary-900 font-medium">No API keys yet</h3>
          <p className="text-secondary-500 text-sm mt-1">
            Create a key to let scripts and services call the API without a user login.
          </p>
          {canManage && (
            <Button className="mt-4" onClick={() => setCreateOpen(true)} leftIcon={<Plus className="w-4 h-4" />}>
              Create API key
            </Button>
          )}
        </Card>
      ) : (
        <Card>
          <Table columns={columns} data={keys} keyExtractor={(k) => k.uuid} />
        </Card>
      )}

      {createOpen && (
        <CreateApiKeyModal
          namespaceName={currentNamespace.name}
          onClose={() => setCreateOpen(false)}
          onCreated={(created) => {
            setCreateOpen(false);
            setCreatedKey(created);
            fetchKeys();
          }}
        />
      )}

      {createdKey && <RevealKeyModal created={createdKey} onClose={() => setCreatedKey(null)} />}

      <ConfirmDialog
        isOpen={!!keyToRevoke}
        onClose={() => setKeyToRevoke(null)}
        onConfirm={doRevoke}
        title="Revoke API key"
        message={`Revoke "${keyToRevoke?.name}"? Any script using it will immediately stop working. This cannot be undone.`}
        confirmText="Revoke"
        variant="danger"
        isLoading={isRevoking}
      />
    </div>
  );
}

// ---------------------------------------------------------------------------
// Create modal — name + scope matrix (module × action) + optional expiry
// ---------------------------------------------------------------------------

function CreateApiKeyModal({
  namespaceName,
  onClose,
  onCreated,
}: {
  namespaceName: string;
  onClose: () => void;
  onCreated: (created: CreatedApiKey) => void;
}) {
  const [name, setName] = useState('');
  const [scopes, setScopes] = useState<ApiKeyScopes>({});
  const [scopeQuery, setScopeQuery] = useState('');
  const [expiresAt, setExpiresAt] = useState('');
  const [modules, setModules] = useState<NamespaceModuleMeta[]>([]);
  const [actions, setActions] = useState<NamespaceActionMeta[]>([]);
  const [metaLoading, setMetaLoading] = useState(true);
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    (async () => {
      try {
        const meta = (await rolesService.getPermissionsMeta()) as unknown as {
          modules: NamespaceModuleMeta[];
          actions: NamespaceActionMeta[];
        };
        // The backend forbids the "namespace" module on API keys (no self-escalation).
        setModules((meta.modules || []).filter((m) => m.name !== 'namespace'));
        setActions(meta.actions || []);
      } catch {
        toast.error('Could not load available scopes');
      } finally {
        setMetaLoading(false);
      }
    })();
  }, []);

  const toggle = (mod: string, action: string) => {
    setScopes((prev) => {
      const current = new Set(prev[mod] || []);
      if (current.has(action)) current.delete(action);
      else current.add(action);
      const next = { ...prev };
      if (current.size === 0) delete next[mod];
      else next[mod] = Array.from(current);
      return next;
    });
  };

  const scopeCount = Object.keys(scopes).length;

  const q = scopeQuery.trim().toLowerCase();
  const filteredModules = q
    ? modules.filter((m) =>
        [m.display_name, m.name, m.category, m.description]
          .filter(Boolean)
          .some((v) => String(v).toLowerCase().includes(q)),
      )
    : modules;

  const submit = async () => {
    if (!name.trim()) return toast.error('Give the key a name');
    if (scopeCount === 0) return toast.error('Select at least one scope');
    setSubmitting(true);
    try {
      const created = await apiKeysService.create({
        name: name.trim(),
        scopes,
        expires_at: expiresAt || undefined,
      });
      toast.success('API key created');
      onCreated(created);
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Failed to create API key');
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal isOpen onClose={onClose} title="Create API key" size="lg">
      <div className="space-y-5">
        <div className="flex items-start gap-2 rounded-lg bg-primary-500/5 border border-primary-500/20 p-3">
          <ShieldCheck className="w-5 h-5 text-primary-600 shrink-0 mt-0.5" />
          <p className="text-sm text-secondary-600">
            This key is locked to the <strong className="text-secondary-900">{namespaceName}</strong> namespace —
            it can never access another. It can do <strong>only</strong> what you grant below, nothing more.
          </p>
        </div>

        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1.5">Name</label>
          <input
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="e.g. blog-importer, ci-deploy"
            className="w-full rounded-lg border border-secondary-300 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-primary-500"
            autoFocus
          />
          <p className="text-xs text-secondary-500 mt-1">A label to recognise this key later — not secret.</p>
        </div>

        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1.5">
            Scopes <span className="text-secondary-400 font-normal">— what this key may do</span>
          </label>
          {metaLoading ? (
            <div className="flex justify-center py-6">
              <Loader2 className="w-5 h-5 animate-spin text-primary-500" />
            </div>
          ) : modules.length === 0 ? (
            <p className="text-sm text-secondary-500">No scopable modules available in this namespace.</p>
          ) : (
            <>
              <div className="relative mb-2">
                <Search className="w-4 h-4 text-secondary-400 absolute left-3 top-1/2 -translate-y-1/2 pointer-events-none" />
                <input
                  value={scopeQuery}
                  onChange={(e) => setScopeQuery(e.target.value)}
                  placeholder={`Search ${modules.length} modules…`}
                  className="w-full rounded-lg border border-secondary-300 pl-9 pr-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-primary-500"
                  aria-label="Search permissions"
                />
              </div>
              <div className="border border-secondary-200 rounded-lg divide-y divide-secondary-100 max-h-64 overflow-y-auto">
                {filteredModules.length === 0 ? (
                  <p className="text-sm text-secondary-500 px-3 py-6 text-center">
                    No modules match “{scopeQuery}”.
                  </p>
                ) : (
                  filteredModules.map((mod) => {
                    const modSelected = (scopes[mod.name] || []).length;
                    return (
                      <div key={mod.name} className="px-3 py-2.5">
                        <div className="flex items-center gap-2">
                          <span className="text-sm font-medium text-secondary-800">
                            {mod.display_name || mod.name}
                          </span>
                          {modSelected > 0 && (
                            <Badge variant="info">{modSelected}</Badge>
                          )}
                        </div>
                        <div className="flex flex-wrap gap-x-4 gap-y-1.5 mt-1.5">
                          {actions.map((a) => {
                            const checked = (scopes[mod.name] || []).includes(a.name);
                            return (
                              <label key={a.name} className="flex items-center gap-1.5 cursor-pointer select-none">
                                <input
                                  type="checkbox"
                                  checked={checked}
                                  onChange={() => toggle(mod.name, a.name)}
                                  className="w-4 h-4 text-primary-600 border-secondary-300 rounded focus:ring-primary-500"
                                />
                                <span className="text-sm text-secondary-600">{a.display_name || a.name}</span>
                              </label>
                            );
                          })}
                        </div>
                      </div>
                    );
                  })
                )}
              </div>
            </>
          )}
          {scopeCount > 0 && (
            <p className="text-xs text-secondary-500 mt-1">{scopeCount} module{scopeCount > 1 ? 's' : ''} scoped.</p>
          )}
        </div>

        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1.5">
            Expiry <span className="text-secondary-400 font-normal">— optional</span>
          </label>
          <input
            type="date"
            value={expiresAt}
            onChange={(e) => setExpiresAt(e.target.value)}
            className="rounded-lg border border-secondary-300 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-primary-500"
          />
          <p className="text-xs text-secondary-500 mt-1">Leave blank for a key that never expires.</p>
        </div>

        <div className="flex justify-end gap-3 pt-2">
          <Button variant="outline" onClick={onClose} disabled={submitting}>
            Cancel
          </Button>
          <Button onClick={submit} isLoading={submitting}>
            Create key
          </Button>
        </div>
      </div>
    </Modal>
  );
}

// ---------------------------------------------------------------------------
// Reveal-once modal — shows the raw secret a single time
// ---------------------------------------------------------------------------

function RevealKeyModal({ created, onClose }: { created: CreatedApiKey; onClose: () => void }) {
  const [copied, setCopied] = useState(false);

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(created.key);
      setCopied(true);
      toast.success('API key copied to clipboard');
      setTimeout(() => setCopied(false), 2500);
    } catch {
      toast.error('Could not copy — select and copy manually');
    }
  };

  return (
    <Modal isOpen onClose={onClose} title="Your new API key" size="lg" showClose={false}>
      <div className="space-y-4">
        <div className="flex items-start gap-2 rounded-lg bg-warning-500/10 border border-warning-500/20 p-3">
          <AlertTriangle className="w-5 h-5 text-warning-600 shrink-0 mt-0.5" />
          <p className="text-sm text-warning-600">
            Copy this key now — for security it is <strong>shown only once</strong> and cannot be retrieved
            again. If you lose it, revoke it and create a new one.
          </p>
        </div>

        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1.5">
            {created.name}
          </label>
          <div className="flex items-stretch gap-2">
            <code className="flex-1 font-mono text-sm bg-secondary-50 text-secondary-900 rounded-lg px-3 py-2.5 break-all border border-secondary-200">
              {created.key}
            </code>
            <Button variant="outline" onClick={copy} leftIcon={copied ? <Check className="w-4 h-4" /> : <Copy className="w-4 h-4" />}>
              {copied ? 'Copied' : 'Copy'}
            </Button>
          </div>
        </div>

        <div className="text-xs text-secondary-500 flex items-center gap-1.5">
          <ShieldAlert className="w-3.5 h-3.5" />
          Use it as a bearer token: <code className="font-mono">Authorization: Bearer {created.key_prefix}…</code>
        </div>

        <div className="flex justify-end pt-1">
          <Button onClick={onClose}>Done</Button>
        </div>
      </div>
    </Modal>
  );
}

'use client';

import React, { useState, useEffect, useCallback } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { Key, Plus, Trash2, Loader2, ShieldCheck } from 'lucide-react';
import { Button, Card, Badge, ConfirmDialog, Table } from '@/components/ui';
import { PageHeader } from '@/components/layout/PageHeader';
import { useNamespace } from '@/contexts/NamespaceContext';
import { usePermissions } from '@/contexts/PermissionsContext';
import { apiKeysService } from '@/services';
import type { ApiKey, TableColumn } from '@/types';
import toast from 'react-hot-toast';

const NEW_PATH = '/dashboard/namespace/api-keys/new';

const fmtDate = (s?: string | null) =>
  s ? new Date(s).toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' }) : '—';

export default function ApiKeysPage() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const { currentNamespace, isNamespaceOwner, hasPermission } = useNamespace();
  const { isAdmin } = usePermissions();

  // Optional target namespace (?ns=<uuid>&nsName=<name>) lets a platform admin
  // manage another tenant's keys without switching their whole context.
  const targetNsId = searchParams.get('ns') || undefined;
  const targetNsName = searchParams.get('nsName') || undefined;
  const isForeign = !!targetNsId && targetNsId !== currentNamespace?.uuid;
  const nsId = targetNsId || currentNamespace?.uuid;
  const nsName = isForeign ? (targetNsName || 'this namespace') : currentNamespace?.name;
  const canManage = isForeign ? isAdmin : isNamespaceOwner || hasPermission('api_keys', 'manage');

  // Carry the target-namespace params onto the create page.
  const newHref = isForeign
    ? `${NEW_PATH}?ns=${encodeURIComponent(targetNsId!)}&nsName=${encodeURIComponent(targetNsName || '')}`
    : NEW_PATH;

  const [keys, setKeys] = useState<ApiKey[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [keyToRevoke, setKeyToRevoke] = useState<ApiKey | null>(null);
  const [isRevoking, setIsRevoking] = useState(false);

  const fetchKeys = useCallback(async () => {
    if (!nsId) return;
    setIsLoading(true);
    try {
      setKeys(await apiKeysService.list(isForeign ? targetNsId : undefined));
    } catch {
      toast.error('Failed to load API keys');
    } finally {
      setIsLoading(false);
    }
  }, [nsId, isForeign, targetNsId]);

  useEffect(() => {
    fetchKeys();
  }, [fetchKeys]);

  const doRevoke = async () => {
    if (!keyToRevoke) return;
    setIsRevoking(true);
    try {
      await apiKeysService.revoke(keyToRevoke.uuid, isForeign ? targetNsId : undefined);
      toast.success('API key revoked');
      setKeyToRevoke(null);
      fetchKeys();
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Failed to revoke API key');
    } finally {
      setIsRevoking(false);
    }
  };

  if (!nsId) {
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
            {entries.map(([mod, acts]) => (
              <Badge key={mod} variant="secondary" title={(acts as string[]).join(', ')}>
                {mod}: {(acts as string[]).join('/')}
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
      render: (k) => (k.revoked ? <Badge variant="error">Revoked</Badge> : <Badge variant="success">Active</Badge>),
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
        description={`Machine credentials for ${nsName}. Keys authenticate as "Authorization: Bearer opsk_…" and only do what their scopes allow — within this namespace.`}
        icon={<Key className="w-6 h-6" />}
        actions={
          canManage ? (
            <Button onClick={() => router.push(newHref)} leftIcon={<Plus className="w-4 h-4" />}>
              Create API key
            </Button>
          ) : undefined
        }
      />

      {isForeign && (
        <Card className="p-4 flex items-start gap-2.5 bg-primary-500/[0.06] border-primary-500/20">
          <ShieldCheck className="w-5 h-5 text-primary-600 shrink-0 mt-0.5" />
          <p className="text-sm text-secondary-600">
            You are managing keys for <strong className="text-secondary-900">{targetNsName || 'another namespace'}</strong> as a
            platform administrator. Keys you create here belong to that namespace, not your own.
          </p>
        </Card>
      )}

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
            <Button className="mt-4" onClick={() => router.push(newHref)} leftIcon={<Plus className="w-4 h-4" />}>
              Create API key
            </Button>
          )}
        </Card>
      ) : (
        <Card>
          <Table columns={columns} data={keys} keyExtractor={(k) => k.uuid} />
        </Card>
      )}

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

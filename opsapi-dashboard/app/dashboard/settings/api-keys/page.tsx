'use client';

import React, { useCallback, useEffect, useState } from 'react';
import { AlertTriangle, Bot, Check, Copy, Key, Loader2, Plus, RotateCw, Trash2 } from 'lucide-react';
import { Badge, Button, Card, ConfirmDialog, Input, Select, Table } from '@/components/ui';
import { PageHeader } from '@/components/layout/PageHeader';
import { useNamespace } from '@/contexts/NamespaceContext';
import { myApiKeysService, type CreatedMyApiKey, type MyApiKey } from '@/services/myApiKeys.service';
import type { ApiKeyScopes, TableColumn } from '@/types';
import toast from 'react-hot-toast';

const API_URL = (process.env.NEXT_PUBLIC_API_URL || 'http://127.0.0.1:4010').replace(/\/+$/, '');
const MCP_URL = (process.env.NEXT_PUBLIC_MCP_URL || '').replace(/\/+$/, '');
const KEY_PLACEHOLDER = 'opsk_YOUR_KEY';
const EXPIRY_OPTIONS = [30, 90, 180, 365];
// What the server grants when no scopes are sent (narrowed to your role there).
const AGENT_PRESET: ApiKeyScopes = { kanban: ['read', 'create', 'update'], projects: ['read'] };
// An agent that may look but never change anything (writes are refused by HTTP method).
const READ_ONLY: ApiKeyScopes = { kanban: ['read'], projects: ['read'] };
const ACCESS = [
  { key: 'agent', title: 'AI agent (MCP)', text: 'Read your tasks, create tasks, update them, log time and comment.',
    scopes: AGENT_PRESET },
  { key: 'readonly', title: 'Read only', text: 'See your tasks and projects; any change is refused.', scopes: READ_ONLY },
] as const;

// Postgres sends "2027-01-10 09:30:00.123456" (UTC, no zone): make it parseable everywhere.
function parseTs(s?: string | null): Date | null {
  if (!s) return null;
  const iso = s.replace(' ', 'T').replace(/(\.\d{3})\d+/, '$1');
  const d = new Date(/[zZ]|[+-]\d\d:?\d\d$/.test(iso) ? iso : iso + 'Z');
  return Number.isNaN(d.getTime()) ? null : d;
}

const fmtDate = (s?: string | null) =>
  parseTs(s)?.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' }) ?? '—';

function statusOf(k: MyApiKey): 'revoked' | 'expired' | 'active' {
  if (k.revoked) return 'revoked';
  const exp = parseTs(k.expires_at);
  return exp && exp.getTime() <= Date.now() ? 'expired' : 'active';
}

function ScopeBadges({ scopes }: { scopes: ApiKeyScopes }) {
  const entries = Object.entries(scopes || {});
  if (entries.length === 0) return <span className="text-secondary-400">—</span>;
  return (
    <div className="flex flex-wrap gap-1">
      {entries.map(([mod, acts]) => (
        <Badge key={mod} variant="secondary">
          {mod}: {acts.join(', ')}
        </Badge>
      ))}
    </div>
  );
}

function CopyButton({ text, label }: { text: string; label: string }) {
  const [copied, setCopied] = useState(false);
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      toast.error('Could not copy. Select the text and copy it manually.');
    }
  };
  return (
    <Button
      variant="outline"
      size="sm"
      onClick={copy}
      aria-label={label}
      leftIcon={copied ? <Check className="w-4 h-4" /> : <Copy className="w-4 h-4" />}
    >
      {copied ? 'Copied' : 'Copy'}
    </Button>
  );
}

function Snippet({ title, hint, code }: { title: string; hint?: string; code: string }) {
  return (
    <div className="space-y-1.5">
      <div className="flex items-center justify-between gap-2">
        <h4 className="text-sm font-semibold text-secondary-800">{title}</h4>
        <CopyButton text={code} label={`Copy: ${title}`} />
      </div>
      {hint && <p className="text-xs text-secondary-500">{hint}</p>}
      <pre className="text-xs font-mono bg-secondary-50 text-secondary-800 border border-secondary-200 rounded-lg p-3 overflow-x-auto whitespace-pre">
        {code}
      </pre>
    </div>
  );
}

function ConnectAgent({ workspaceId, apiKey }: { workspaceId: number; apiKey?: string }) {
  const [tool, setTool] = useState<'claude' | 'cursor'>('claude');
  const key = apiKey || KEY_PLACEHOLDER;
  const ns = String(workspaceId);
  const stdioEnv = { OPSAPI_URL: API_URL, OPSAPI_API_KEY: key, OPSAPI_NAMESPACE: ns };

  const snippets =
    tool === 'claude'
      ? {
          http: `claude mcp add --transport http opsapi ${MCP_URL} \\\n  --header "Authorization: Bearer ${key}"`,
          stdio:
            `claude mcp add opsapi \\\n  -e OPSAPI_URL=${API_URL} \\\n  -e OPSAPI_API_KEY=${key} \\\n` +
            `  -e OPSAPI_NAMESPACE=${ns} \\\n  -- npx -y @opsapi/mcp`,
          where: 'Run in a terminal, then start a new Claude Code session.',
        }
      : {
          http: JSON.stringify(
            { mcpServers: { opsapi: { url: MCP_URL, headers: { Authorization: `Bearer ${key}` } } } },
            null,
            2,
          ),
          stdio: JSON.stringify(
            { mcpServers: { opsapi: { command: 'npx', args: ['-y', '@opsapi/mcp'], env: stdioEnv } } },
            null,
            2,
          ),
          where: 'Add to ~/.cursor/mcp.json (or .cursor/mcp.json in a project), then reload Cursor.',
        };

  const tabs = [
    { id: 'claude' as const, label: 'Claude Code' },
    { id: 'cursor' as const, label: 'Cursor' },
  ];

  return (
    <Card className="space-y-4">
      <div className="flex items-start gap-2.5">
        <Bot className="w-5 h-5 text-primary-600 shrink-0 mt-0.5" aria-hidden="true" />
        <div>
          <h2 className="text-base font-semibold text-secondary-900">Connect an AI agent</h2>
          <p className="text-sm text-secondary-500 mt-0.5">
            Give an agent your tasks through MCP. It acts as you, with this key&apos;s access.
          </p>
        </div>
      </div>

      <dl className="flex items-center justify-between rounded-lg bg-secondary-50 border border-secondary-200 px-3 py-2">
        <dt className="text-xs font-medium text-secondary-600">Workspace ID (OPSAPI_NAMESPACE)</dt>
        <dd className="font-mono text-sm text-secondary-900">{ns}</dd>
      </dl>

      <div role="tablist" aria-label="AI tool" className="inline-flex rounded-lg border border-secondary-200 p-0.5">
        {tabs.map((t) => (
          <button
            key={t.id}
            type="button"
            role="tab"
            id={`tab-${t.id}`}
            aria-selected={tool === t.id}
            aria-controls="agent-snippets"
            onClick={() => setTool(t.id)}
            className={`px-3 py-1.5 text-sm font-medium rounded-md transition-colors ${
              tool === t.id ? 'bg-primary-600 text-white' : 'text-secondary-600 hover:text-secondary-900'
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>

      <div id="agent-snippets" role="tabpanel" aria-labelledby={`tab-${tool}`} className="space-y-4">
        <p className="text-xs text-secondary-500">{snippets.where}</p>
        {MCP_URL && (
          <Snippet title="Remote (HTTP)" hint="Nothing to install." code={snippets.http} />
        )}
        <Snippet title="Local (stdio)" hint="Runs the MCP server on your machine (Node 18+)." code={snippets.stdio} />
        {!apiKey && (
          <p className="text-xs text-secondary-500">
            Replace <code className="font-mono">{KEY_PLACEHOLDER}</code> with your key. Create one on this page to
            fill it in here.
          </p>
        )}
      </div>
    </Card>
  );
}

function RevealKey({ created, onDone }: { created: CreatedMyApiKey; onDone: () => void }) {
  return (
    <Card className="space-y-4 border-success-500/30" aria-live="polite">
      <div className="flex items-start gap-2.5">
        <Check className="w-5 h-5 text-success-600 shrink-0 mt-0.5" aria-hidden="true" />
        <div>
          <h2 className="text-base font-semibold text-secondary-900">“{created.name}” is ready</h2>
          <p className="text-sm text-secondary-500 mt-0.5">Expires {fmtDate(created.expires_at)}.</p>
        </div>
      </div>
      <div className="flex items-start gap-2.5 rounded-lg bg-warning-500/10 border border-warning-500/20 p-3">
        <AlertTriangle className="w-5 h-5 text-warning-600 shrink-0 mt-0.5" aria-hidden="true" />
        <p className="text-sm text-warning-600">
          Copy this key now. <strong>You won&apos;t see it again.</strong> Lost it? Revoke it and create a new one.
        </p>
      </div>
      <div className="flex flex-col sm:flex-row sm:items-stretch gap-2">
        <code
          className="flex-1 font-mono text-sm bg-secondary-50 text-secondary-900 rounded-lg px-4 py-3 break-all border border-secondary-200"
          aria-label="Your new API key"
        >
          {created.key}
        </code>
        <CopyButton text={created.key} label="Copy API key" />
      </div>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <ScopeBadges scopes={created.scopes} />
        <Button onClick={onDone}>I&apos;ve saved it</Button>
      </div>
    </Card>
  );
}

export default function MyApiKeysPage() {
  const { currentNamespace } = useNamespace();
  const nsUuid = currentNamespace?.uuid;

  const [keys, setKeys] = useState<MyApiKey[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);

  const [name, setName] = useState('');
  const [days, setDays] = useState(90);
  const [access, setAccess] = useState<'agent' | 'readonly'>('agent');
  const [isCreating, setIsCreating] = useState(false);
  // The key just made, tied to its workspace so a switch never shows it elsewhere.
  const [made, setMade] = useState<{ ns: string; key: CreatedMyApiKey } | null>(null);
  const created = made && made.ns === nsUuid ? made.key : null;

  const [toRevoke, setToRevoke] = useState<MyApiKey | null>(null);
  const [isRevoking, setIsRevoking] = useState(false);

  const load = useCallback(async () => {
    if (!nsUuid) return;
    setIsLoading(true);
    setLoadError(null);
    try {
      setKeys(await myApiKeysService.list());
    } catch (err) {
      setLoadError(err instanceof Error ? err.message : 'Failed to load your API keys');
    } finally {
      setIsLoading(false);
    }
  }, [nsUuid]);

  useEffect(() => {
    load();
  }, [load]);

  const create = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!name.trim() || !nsUuid) return toast.error('Give the key a name');
    setIsCreating(true);
    try {
      setMade({ ns: nsUuid, key: await myApiKeysService.create({
        name: name.trim(), expires_in_days: days, ...(access === 'readonly' ? { scopes: READ_ONLY } : {}),
      }) });
      setName('');
      load();
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Failed to create API key');
    } finally {
      setIsCreating(false);
    }
  };

  const revoke = async () => {
    if (!toRevoke) return;
    setIsRevoking(true);
    try {
      await myApiKeysService.revoke(toRevoke.uuid);
      toast.success('API key revoked');
      if (created?.uuid === toRevoke.uuid) setMade(null);
      setToRevoke(null);
      load();
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Failed to revoke API key');
    } finally {
      setIsRevoking(false);
    }
  };

  if (!currentNamespace) {
    return <Card className="text-center text-secondary-500">Select a workspace to manage your API keys.</Card>;
  }

  const columns: TableColumn<MyApiKey>[] = [
    {
      key: 'name',
      header: 'Name',
      render: (k) => (
        <div className="min-w-0">
          <div className="font-medium text-secondary-900 truncate">{k.name}</div>
          <code className="font-mono text-xs text-secondary-500">{k.key_prefix}…</code>
        </div>
      ),
    },
    { key: 'scopes', header: 'Access', render: (k) => <ScopeBadges scopes={k.scopes} /> },
    { key: 'created_at', header: 'Created', render: (k) => fmtDate(k.created_at) },
    { key: 'expires_at', header: 'Expires', render: (k) => fmtDate(k.expires_at) },
    { key: 'last_used_at', header: 'Last used', render: (k) => fmtDate(k.last_used_at) },
    {
      key: 'status',
      header: 'Status',
      render: (k) => {
        const st = statusOf(k);
        return st === 'active' ? (
          <Badge variant="success">Active</Badge>
        ) : st === 'expired' ? (
          <Badge variant="warning">Expired</Badge>
        ) : (
          <Badge variant="error">Revoked</Badge>
        );
      },
    },
    {
      key: 'actions',
      header: '',
      render: (k) =>
        statusOf(k) === 'active' ? (
          <button
            type="button"
            onClick={() => setToRevoke(k)}
            className="p-1.5 rounded-md text-secondary-400 hover:text-error-600 hover:bg-error-50 transition-colors"
            aria-label={`Revoke ${k.name}`}
            title="Revoke key"
          >
            <Trash2 className="w-4 h-4" />
          </button>
        ) : null,
    },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="My API keys"
        description={`Personal keys that let an AI agent or script act as you in ${currentNamespace.name}. A key never does more than your role allows, and stops working if your access changes.`}
        icon={<Key className="w-6 h-6" />}
      />

      <div className="grid grid-cols-1 xl:grid-cols-12 gap-6 items-start">
        <div className="xl:col-span-7 space-y-6">
          {created ? (
            <RevealKey created={created} onDone={() => setMade(null)} />
          ) : (
            <Card>
              <form onSubmit={create} className="space-y-4">
                <h2 className="text-base font-semibold text-secondary-900">Create a key</h2>
                <div className="grid gap-4 sm:grid-cols-3">
                  <div className="sm:col-span-2">
                    <Input
                      id="my-key-name"
                      label="Name"
                      value={name}
                      maxLength={100}
                      onChange={(e) => setName(e.target.value)}
                      placeholder="e.g. Claude Code on my laptop"
                      helperText="So you can recognise it later."
                      required
                    />
                  </div>
                  <Select id="my-key-expiry" label="Expires in" value={days} onChange={(e) => setDays(Number(e.target.value))}>
                    {EXPIRY_OPTIONS.map((d) => (
                      <option key={d} value={d}>
                        {d} days
                      </option>
                    ))}
                  </Select>
                </div>

                <fieldset className="space-y-2">
                  <legend className="block text-sm font-medium text-secondary-700 mb-1.5">Access</legend>
                  {ACCESS.map((o) => (
                    <label
                      key={o.key}
                      className={`flex items-start gap-3 rounded-xl border p-4 cursor-pointer ${
                        access === o.key ? 'border-primary-300 bg-primary-500/[0.04]' : 'border-secondary-200'
                      }`}
                    >
                      <input
                        type="radio"
                        name="preset"
                        value={o.key}
                        checked={access === o.key}
                        onChange={() => setAccess(o.key)}
                        className="mt-1 accent-primary-600"
                      />
                      <span className="space-y-1.5">
                        <span className="block text-sm font-semibold text-secondary-900">{o.title}</span>
                        <span className="block text-xs text-secondary-500">
                          {o.text} Limited to what your role allows.
                        </span>
                        <ScopeBadges scopes={o.scopes} />
                      </span>
                    </label>
                  ))}
                </fieldset>

                <div className="flex justify-end">
                  <Button type="submit" isLoading={isCreating} leftIcon={<Plus className="w-4 h-4" />}>
                    Create key
                  </Button>
                </div>
              </form>
            </Card>
          )}

          <Card padding="none">
            <div className="px-6 pt-5 pb-3">
              <h2 className="text-base font-semibold text-secondary-900">Your keys</h2>
            </div>
            {isLoading ? (
              <div className="flex justify-center py-12" role="status" aria-label="Loading your keys">
                <Loader2 className="w-6 h-6 animate-spin text-primary-500" />
              </div>
            ) : loadError ? (
              <div className="text-center px-6 pb-8">
                <p className="text-sm text-error-600">{loadError}</p>
                <Button className="mt-3" variant="outline" size="sm" onClick={load} leftIcon={<RotateCw className="w-4 h-4" />}>
                  Retry
                </Button>
              </div>
            ) : keys.length === 0 ? (
              <p className="text-sm text-secondary-500 text-center px-6 pb-8">
                No keys yet. Create one above to connect an AI agent.
              </p>
            ) : (
              <Table columns={columns} data={keys} keyExtractor={(k) => k.uuid} caption="Your API keys" />
            )}
          </Card>
        </div>

        <div className="xl:col-span-5">
          <ConnectAgent workspaceId={currentNamespace.id} apiKey={created?.key} />
        </div>
      </div>

      <ConfirmDialog
        isOpen={!!toRevoke}
        onClose={() => setToRevoke(null)}
        onConfirm={revoke}
        title="Revoke API key"
        message={`Revoke "${toRevoke?.name}"? Anything using it stops working at once. This cannot be undone.`}
        confirmText="Revoke"
        variant="danger"
        isLoading={isRevoking}
      />
    </div>
  );
}

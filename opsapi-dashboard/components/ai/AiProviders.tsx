'use client';

/**
 * The workspace's AI providers (core): cloud keys, local models and JobShout links. Keys go in,
 * never out ("••••1234" + Replace). Anyone with namespace.read sees the list; namespace.update
 * adds, edits, deletes, tests, and picks the one model that drives the AI assistant
 * (options.assistant — at most one: switching it on for one switches it off for the others).
 * Used by Workspace → AI models and by plugin settings (Property Deals → AI & JobShout).
 */
import React, { useCallback, useEffect, useState } from 'react';
import { Plus, Plug, Trash2, KeyRound, Loader2, Bot } from 'lucide-react';
import toast from 'react-hot-toast';
import { Badge, Button, Card, Input, Modal, Select, Switch } from '@/components/ui';
import { aiProvidersService, providerOptions, type AiProvider } from '@/services/ai-providers.service';
import { pdErrorText } from '@/services/property-deals.service';
import { formatDateTime } from '@/lib/utils';

export const PROVIDER_TYPES: { value: AiProvider['provider_type']; label: string; url?: string; local?: boolean }[] = [
  // The deployment's own self-hosted model (the one the chat assistant uses): no key, data stays on our servers.
  { value: 'platform', label: 'Platform model (self-hosted — same as the chat assistant)', local: true },
  { value: 'anthropic', label: 'Anthropic (Claude)' },
  { value: 'openai', label: 'OpenAI' },
  { value: 'gemini', label: 'Google Gemini' },
  { value: 'azure_openai', label: 'Azure OpenAI' },
  { value: 'mistral', label: 'Mistral' },
  { value: 'openai_compatible', label: 'OpenAI-compatible (LM Studio, vLLM, llama.cpp, LocalAI…)', local: true },
  { value: 'ollama', label: 'Ollama', url: 'http://localhost:11434/v1', local: true },
  { value: 'jobshout', label: 'JobShout link' },
];

const isAssistant = (p: AiProvider) => providerOptions(p).assistant === true;

export default function AiProviders({ canEdit, onLoaded }: { canEdit: boolean; onLoaded?: (list: AiProvider[]) => void }) {
  const [list, setList] = useState<AiProvider[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState<Partial<AiProvider> | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const onLoadedRef = React.useRef(onLoaded);
  onLoadedRef.current = onLoaded;

  const reload = useCallback(async () => {
    try {
      const l = await aiProvidersService.list();
      setList(l);
      setError(null);
      onLoadedRef.current?.(l);
    } catch (e) {
      setError(pdErrorText(e));
    }
  }, []);
  useEffect(() => { void reload(); }, [reload]);

  const test = async (p: AiProvider) => {
    setBusy(p.uuid);
    try {
      const r = await aiProvidersService.test(p.uuid);
      toast.success(p.provider_type === 'jobshout' ? `Connected — ${r.agents} agent(s)` : `Works: ${r.model} answered in ${r.latency_ms} ms`);
    } catch (e) { toast.error(pdErrorText(e)); } finally { setBusy(null); void reload(); }
  };

  // At most one assistant model. This one goes on first: the server refuses a model that can't call tools,
  // and the current assistant must stay in place when it does.
  const setAssistant = async (p: AiProvider, on: boolean) => {
    setBusy(p.uuid);
    try {
      await aiProvidersService.save({ options: { ...providerOptions(p), assistant: on } }, p.uuid);
      if (on) {
        for (const o of (list || []).filter((x) => x.uuid !== p.uuid && isAssistant(x))) {
          await aiProvidersService.save({ options: { ...providerOptions(o), assistant: false } }, o.uuid);
        }
      }
      toast.success(on ? `${p.name} now runs the AI assistant` : 'The AI assistant uses the server’s default model');
    } catch (e) { toast.error(pdErrorText(e)); } finally { setBusy(null); void reload(); }
  };

  return (
    <Card>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h3 className="font-semibold text-secondary-900">AI providers</h3>
          <p className="text-sm text-secondary-500">Your own keys, local models and the JobShout link. Keys are stored encrypted and never shown again.</p>
        </div>
        {canEdit && <Button leftIcon={<Plus className="h-4 w-4" />} onClick={() => setEditing({ provider_type: 'anthropic', enabled: true })}>Add provider</Button>}
      </div>
      {error && <p className="mt-3 rounded-lg bg-error-500/10 p-3 text-sm text-error-700" role="alert">{error}</p>}
      {!list && !error ? (
        <p className="flex items-center gap-2 py-6 text-sm text-secondary-500" role="status"><Loader2 className="h-4 w-4 animate-spin" aria-hidden /> Loading…</p>
      ) : list && (
        <ul className="mt-4 divide-y divide-secondary-100 rounded-lg border border-secondary-200">
          {list.length === 0 && <li className="p-4 text-sm text-secondary-500">No providers yet.{canEdit ? ' Add one to choose the models this workspace uses.' : ''}</li>}
          {list.map((p) => (
            <li key={p.uuid} className="flex flex-wrap items-center justify-between gap-3 p-4 text-sm">
              <div>
                <div className="flex flex-wrap items-center gap-2">
                  <span className="font-medium text-secondary-900">{p.name}</span>
                  <Badge size="sm">{PROVIDER_TYPES.find((t) => t.value === p.provider_type)?.label || p.provider_type}</Badge>
                  {p.is_local && <Badge size="sm" variant="success">local</Badge>}
                  {!p.enabled && <Badge size="sm" variant="secondary">off</Badge>}
                  {isAssistant(p) && <Badge size="sm" variant="info">AI assistant{p.enabled ? '' : ' (enable it to take effect)'}</Badge>}
                </div>
                <div className="mt-0.5 text-secondary-500">
                  {p.default_model || p.username || ''}{p.base_url ? ` · ${p.base_url}` : ''}
                  {p.has_secret ? ` · key ${p.secret_hint ? p.secret_hint.replace('…', '••••') : '••••'}` : ' · no key'}
                </div>
                {p.last_tested_at && <div className={p.last_error ? 'text-xs text-error-600' : 'text-xs text-success-600'}>{p.last_error ? `Last test failed: ${p.last_error}` : `Tested OK ${formatDateTime(p.last_tested_at)}`}</div>}
              </div>
              {canEdit && (
                <div className="flex flex-wrap items-center gap-1">
                  {p.provider_type !== 'jobshout' && (
                    <label className="mr-2 flex items-center gap-2 text-xs text-secondary-600" title="Use this model for the AI assistant (at most one)">
                      <Switch checked={isAssistant(p)} disabled={busy === p.uuid} onChange={(on) => setAssistant(p, on)} aria-label={`Use ${p.name} for the AI assistant`} />
                      <Bot className="h-4 w-4" aria-hidden /> Assistant
                    </label>
                  )}
                  <Button size="sm" variant="outline" leftIcon={<Plug className="h-4 w-4" />} isLoading={busy === p.uuid} onClick={() => test(p)}>Test connection</Button>
                  <Button size="sm" variant="ghost" onClick={() => setEditing(p)}>Edit</Button>
                  <Button size="sm" variant="ghost" aria-label={`Delete ${p.name}`} onClick={async () => {
                    if (!window.confirm(`Delete ${p.name}?`)) return;
                    try { await aiProvidersService.remove(p.uuid); void reload(); } catch (e) { toast.error(pdErrorText(e)); }
                  }}><Trash2 className="h-4 w-4" /></Button>
                </div>
              )}
            </li>
          ))}
        </ul>
      )}
      {editing && <ProviderModal p={editing} onClose={() => setEditing(null)} onSaved={() => { setEditing(null); void reload(); }} />}
    </Card>
  );
}

function ProviderModal({ p, onClose, onSaved }: { p: Partial<AiProvider>; onClose: () => void; onSaved: () => void }) {
  const [f, setF] = useState<Record<string, unknown>>({
    name: p.name || '', provider_type: p.provider_type, base_url: p.base_url || '', default_model: p.default_model || '',
    username: p.username || '', is_local: p.is_local ?? false, enabled: p.enabled ?? true,
    input_cost_per_mtok: p.input_cost_per_mtok ?? '', output_cost_per_mtok: p.output_cost_per_mtok ?? '',
    deployment: (p.options as { deployment?: string } | undefined)?.deployment || '',
  });
  const [replacing, setReplacing] = useState(!p.has_secret);
  const [secret, setSecret] = useState('');
  const [busy, setBusy] = useState(false);
  const type = f.provider_type as AiProvider['provider_type'];
  const s = (k: string) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setF({ ...f, [k]: e.target.value });
  return (
    <Modal isOpen onClose={onClose} title={p.uuid ? `Edit ${p.name}` : 'Add an AI provider'} size="lg">
      <div className="grid gap-3 sm:grid-cols-2">
        <Input label="Name" value={String(f.name)} onChange={s('name')} />
        <Select label="Type" value={type} onChange={(e) => { const t = PROVIDER_TYPES.find((x) => x.value === e.target.value); setF({ ...f, provider_type: e.target.value, is_local: t?.local ?? false, base_url: f.base_url || t?.url || '' }); }} disabled={!!p.uuid}>
          {PROVIDER_TYPES.map((t) => <option key={t.value} value={t.value}>{t.label}</option>)}
        </Select>
        {['azure_openai', 'openai_compatible', 'ollama', 'jobshout'].includes(type) || f.base_url ? (
          <Input label={type === 'jobshout' ? 'JobShout API URL (…/api/v1)' : type === 'azure_openai' ? 'Azure endpoint (https://<resource>.openai.azure.com)' : 'Base URL'} value={String(f.base_url)} onChange={s('base_url')} />
        ) : null}
        {type === 'jobshout' ? (
          <Input label="JobShout service user (email)" value={String(f.username)} onChange={s('username')} />
        ) : (
          <Input label={type === 'azure_openai' ? 'Model / deployment name' : 'Default model'} value={String(f.default_model)} onChange={s('default_model')} placeholder={type === 'anthropic' ? 'claude-sonnet-5-5' : type === 'ollama' ? 'qwen3:8b' : ''} />
        )}
        {type === 'azure_openai' && <Input label="Deployment" value={String(f.deployment)} onChange={s('deployment')} />}
        {type !== 'jobshout' && (
          <>
            <Input label="Input cost (USD per million tokens)" type="number" step="any" min={0} value={String(f.input_cost_per_mtok)} onChange={s('input_cost_per_mtok')} />
            <Input label="Output cost (USD per million tokens)" type="number" step="any" min={0} value={String(f.output_cost_per_mtok)} onChange={s('output_cost_per_mtok')} />
          </>
        )}
        {type !== 'platform' && <div className="sm:col-span-2">
          {replacing ? (
            <Input label={type === 'jobshout' ? 'Password' : 'API key'} type="password" autoComplete="new-password" value={secret} onChange={(e) => setSecret(e.target.value)} helperText={p.has_secret ? 'Leave empty to keep the saved one.' : type === 'ollama' || type === 'openai_compatible' ? 'Optional for local servers.' : undefined} />
          ) : (
            <div className="flex items-center justify-between rounded-lg border border-secondary-200 p-3 text-sm">
              <span className="inline-flex items-center gap-2"><KeyRound className="h-4 w-4 text-secondary-400" aria-hidden /> Saved key {p.secret_hint ? p.secret_hint.replace('…', '••••') : '••••'}</span>
              <Button size="sm" variant="outline" onClick={() => setReplacing(true)}>Replace</Button>
            </div>
          )}
        </div>}
        <label className="flex items-center gap-2 text-sm"><Switch checked={Boolean(f.is_local)} onChange={(v) => setF({ ...f, is_local: v })} /> Local (on your own servers: allowed for local-only jobs)</label>
        <label className="flex items-center gap-2 text-sm"><Switch checked={Boolean(f.enabled)} onChange={(v) => setF({ ...f, enabled: v })} /> Enabled</label>
      </div>
      <div className="mt-5 flex justify-end gap-2">
        <Button variant="ghost" onClick={onClose}>Cancel</Button>
        <Button isLoading={busy} disabled={!f.name} onClick={async () => {
          setBusy(true);
          try {
            const body: Record<string, unknown> = {
              name: f.name, base_url: f.base_url || undefined, default_model: f.default_model || undefined,
              username: f.username || undefined, is_local: f.is_local, enabled: f.enabled,
              input_cost_per_mtok: f.input_cost_per_mtok === '' ? undefined : Number(f.input_cost_per_mtok),
              output_cost_per_mtok: f.output_cost_per_mtok === '' ? undefined : Number(f.output_cost_per_mtok),
            };
            if (!p.uuid) body.provider_type = f.provider_type;
            // options is replaced whole on save: keep the rest (e.g. the assistant flag).
            if (type === 'azure_openai') body.options = { ...providerOptions(p), deployment: f.deployment || f.default_model };
            if (secret) body.secret = secret;
            await aiProvidersService.save(body, p.uuid);
            toast.success('Saved');
            onSaved();
          } catch (e) { toast.error(pdErrorText(e)); } finally { setBusy(false); }
        }}>Save</Button>
      </div>
    </Modal>
  );
}

'use client';

/**
 * AI settings: the workspace's providers (cloud, local, JobShout link — keys go in, never out:
 * "••••1234" + Replace), test connection, the model chain per job type (fallback order,
 * local-only), and each agent (on/off, built-in or a JobShout agent, approval rule, auto pickup).
 */
import React, { useState } from 'react';
import { Plus, Plug, Trash2, ArrowUp, ArrowDown, KeyRound } from 'lucide-react';
import toast from 'react-hot-toast';
import { Badge, Button, Card, Input, Modal, Select, Switch } from '@/components/ui';
import { pdService, pdErrorText, type AiProvider, type Agent, type AiRoute } from '@/services/property-deals.service';
import { ErrorNote, Spinner, label, dateText } from '../ui';
import { usePdData } from '../usePd';

const TYPES: { value: AiProvider['provider_type']; label: string; url?: string; local?: boolean }[] = [
  { value: 'anthropic', label: 'Anthropic (Claude)' },
  { value: 'openai', label: 'OpenAI' },
  { value: 'gemini', label: 'Google Gemini' },
  { value: 'azure_openai', label: 'Azure OpenAI' },
  { value: 'mistral', label: 'Mistral' },
  { value: 'openai_compatible', label: 'OpenAI-compatible (LM Studio, vLLM, llama.cpp, LocalAI…)', local: true },
  { value: 'ollama', label: 'Ollama', url: 'http://localhost:11434/v1', local: true },
  { value: 'jobshout', label: 'JobShout link' },
];
const JOB_TYPES = ['draft', 'plan', 'classify', 'extract', 'summarise', 'chat'];

export default function AiSettings({ canEditProviders, canEditPlugin }: { canEditProviders: boolean; canEditPlugin: boolean }) {
  const providers = usePdData(async () => (await pdService.aiProviders()).data, []);
  const [editing, setEditing] = useState<Partial<AiProvider> | null>(null);
  const [testing, setTesting] = useState<string | null>(null);

  return (
    <div className="space-y-6">
      <Card>
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h3 className="font-semibold text-secondary-900">AI providers</h3>
            <p className="text-sm text-secondary-500">Your own keys, local models and the JobShout link. Keys are stored encrypted and never shown again.</p>
          </div>
          {canEditProviders && <Button leftIcon={<Plus className="h-4 w-4" />} onClick={() => setEditing({ provider_type: 'anthropic', enabled: true })}>Add provider</Button>}
        </div>
        <ErrorNote error={providers.error} />
        {providers.loading && !providers.data ? <Spinner /> : (
          <ul className="mt-4 divide-y divide-secondary-100 rounded-lg border border-secondary-200">
            {(providers.data || []).length === 0 && <li className="p-4 text-sm text-secondary-500">No providers yet. Add one so agents can draft.</li>}
            {(providers.data || []).map((p) => (
              <li key={p.uuid} className="flex flex-wrap items-center justify-between gap-3 p-4 text-sm">
                <div>
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="font-medium text-secondary-900">{p.name}</span>
                    <Badge size="sm">{TYPES.find((t) => t.value === p.provider_type)?.label || p.provider_type}</Badge>
                    {p.is_local && <Badge size="sm" variant="success">local</Badge>}
                    {!p.enabled && <Badge size="sm" variant="secondary">off</Badge>}
                  </div>
                  <div className="mt-0.5 text-secondary-500">
                    {p.default_model || p.username || ''}{p.base_url ? ` · ${p.base_url}` : ''}
                    {p.has_secret ? ` · key ${p.secret_hint ? p.secret_hint.replace('…', '••••') : '••••'}` : ' · no key'}
                  </div>
                  {p.last_tested_at && <div className={p.last_error ? 'text-xs text-error-600' : 'text-xs text-success-600'}>{p.last_error ? `Last test failed: ${p.last_error}` : `Tested OK ${dateText(p.last_tested_at, true)}`}</div>}
                </div>
                <div className="flex gap-1">
                  <Button size="sm" variant="outline" leftIcon={<Plug className="h-4 w-4" />} isLoading={testing === p.uuid} onClick={async () => {
                    setTesting(p.uuid);
                    try {
                      const r = (await pdService.testAiProvider(p.uuid)).data;
                      toast.success(p.provider_type === 'jobshout' ? `Connected — ${r.agents} agent(s)` : `Works: ${r.model} answered in ${r.latency_ms} ms`);
                    } catch (e) { toast.error(pdErrorText(e)); } finally { setTesting(null); providers.refresh(); }
                  }}>Test connection</Button>
                  {canEditProviders && <Button size="sm" variant="ghost" onClick={() => setEditing(p)}>Edit</Button>}
                  {canEditProviders && <Button size="sm" variant="ghost" aria-label={`Delete ${p.name}`} onClick={async () => {
                    if (!window.confirm(`Delete ${p.name}?`)) return;
                    try { await pdService.deleteAiProvider(p.uuid); providers.refresh(); } catch (e) { toast.error(pdErrorText(e)); }
                  }}><Trash2 className="h-4 w-4" /></Button>}
                </div>
              </li>
            ))}
          </ul>
        )}
      </Card>
      <Routes providers={providers.data || []} canEdit={canEditPlugin} />
      <Agents providers={providers.data || []} canEdit={canEditPlugin} />
      {editing && <ProviderModal p={editing} onClose={() => setEditing(null)} onSaved={() => { setEditing(null); providers.refresh(); }} />}
    </div>
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
        <Select label="Type" value={type} onChange={(e) => { const t = TYPES.find((x) => x.value === e.target.value); setF({ ...f, provider_type: e.target.value, is_local: t?.local ?? false, base_url: f.base_url || t?.url || '' }); }} disabled={!!p.uuid}>
          {TYPES.map((t) => <option key={t.value} value={t.value}>{t.label}</option>)}
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
        <div className="sm:col-span-2">
          {replacing ? (
            <Input label={type === 'jobshout' ? 'Password' : 'API key'} type="password" autoComplete="new-password" value={secret} onChange={(e) => setSecret(e.target.value)} helperText={p.has_secret ? 'Leave empty to keep the saved one.' : type === 'ollama' || type === 'openai_compatible' ? 'Optional for local servers.' : undefined} />
          ) : (
            <div className="flex items-center justify-between rounded-lg border border-secondary-200 p-3 text-sm">
              <span className="inline-flex items-center gap-2"><KeyRound className="h-4 w-4 text-secondary-400" aria-hidden /> Saved key {p.secret_hint ? p.secret_hint.replace('…', '••••') : '••••'}</span>
              <Button size="sm" variant="outline" onClick={() => setReplacing(true)}>Replace</Button>
            </div>
          )}
        </div>
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
            if (type === 'azure_openai') body.options = { deployment: f.deployment || f.default_model };
            if (secret) body.secret = secret;
            await pdService.saveAiProvider(body, p.uuid);
            toast.success('Saved');
            onSaved();
          } catch (e) { toast.error(pdErrorText(e)); } finally { setBusy(false); }
        }}>Save</Button>
      </div>
    </Modal>
  );
}

function Routes({ providers, canEdit }: { providers: AiProvider[]; canEdit: boolean }) {
  const routes = usePdData(async () => (await pdService.routes()).data, []);
  const models = providers.filter((p) => p.provider_type !== 'jobshout');
  const [edit, setEdit] = useState<{ job: string; chain: { provider_uuid: string; model?: string }[]; local_only: boolean } | null>(null);
  const byJob = Object.fromEntries((routes.data || []).map((r) => [r.job_type, r])) as Record<string, AiRoute>;
  const name = (u: string) => providers.find((p) => p.uuid === u)?.name || 'removed provider';
  return (
    <Card>
      <h3 className="font-semibold text-secondary-900">Model per job type</h3>
      <p className="text-sm text-secondary-500">Each job tries these in order (the fallback order). Without a route a job uses “draft”, then any provider.</p>
      <ul className="mt-4 divide-y divide-secondary-100 rounded-lg border border-secondary-200">
        {JOB_TYPES.map((j) => {
          const r = byJob[j];
          return (
            <li key={j} className="flex flex-wrap items-center justify-between gap-3 p-3 text-sm">
              <div>
                <span className="font-medium text-secondary-900">{label(j)}</span>
                {r?.local_only && <Badge size="sm" variant="success" className="ml-2">local only</Badge>}
                <div className="text-secondary-500">{r ? r.chain.map((c, i) => `${i + 1}. ${name(c.provider_uuid)}${c.model ? ` (${c.model})` : ''}`).join('  →  ') : 'Not set'}</div>
              </div>
              {canEdit && <Button size="sm" variant="ghost" onClick={() => setEdit({ job: j, chain: r?.chain?.map((c) => ({ provider_uuid: c.provider_uuid, model: c.model || undefined })) || [], local_only: Boolean(r?.local_only) })}>Edit</Button>}
            </li>
          );
        })}
      </ul>
      {edit && (
        <Modal isOpen onClose={() => setEdit(null)} title={`Models for “${label(edit.job)}”`} size="lg">
          <ol className="space-y-2">
            {edit.chain.map((c, i) => (
              <li key={i} className="flex flex-wrap items-end gap-2">
                <span className="w-6 pb-2 text-sm text-secondary-500">{i + 1}.</span>
                <Select value={c.provider_uuid} onChange={(e) => { const chain = [...edit.chain]; chain[i] = { ...c, provider_uuid: e.target.value }; setEdit({ ...edit, chain }); }}>
                  {models.map((p) => <option key={p.uuid} value={p.uuid}>{p.name}</option>)}
                </Select>
                <Input placeholder="model (default)" value={c.model || ''} onChange={(e) => { const chain = [...edit.chain]; chain[i] = { ...c, model: e.target.value || undefined }; setEdit({ ...edit, chain }); }} aria-label="Model" />
                <Button size="sm" variant="ghost" aria-label="Move up" disabled={i === 0} onClick={() => { const chain = [...edit.chain]; [chain[i - 1], chain[i]] = [chain[i], chain[i - 1]]; setEdit({ ...edit, chain }); }}><ArrowUp className="h-4 w-4" /></Button>
                <Button size="sm" variant="ghost" aria-label="Move down" disabled={i === edit.chain.length - 1} onClick={() => { const chain = [...edit.chain]; [chain[i + 1], chain[i]] = [chain[i], chain[i + 1]]; setEdit({ ...edit, chain }); }}><ArrowDown className="h-4 w-4" /></Button>
                <Button size="sm" variant="ghost" aria-label="Remove" onClick={() => setEdit({ ...edit, chain: edit.chain.filter((_, k) => k !== i) })}><Trash2 className="h-4 w-4" /></Button>
              </li>
            ))}
          </ol>
          <Button className="mt-3" size="sm" variant="outline" leftIcon={<Plus className="h-4 w-4" />} disabled={!models.length} onClick={() => setEdit({ ...edit, chain: [...edit.chain, { provider_uuid: models[0].uuid }] })}>Add a provider</Button>
          <label className="mt-4 flex items-center gap-2 text-sm"><Switch checked={edit.local_only} onChange={(v) => setEdit({ ...edit, local_only: v })} /> Local only (sensitive data never leaves your servers)</label>
          <div className="mt-5 flex justify-end gap-2">
            <Button variant="ghost" onClick={() => setEdit(null)}>Cancel</Button>
            <Button disabled={!edit.chain.length} onClick={async () => {
              try { await pdService.saveRoute(edit.job, { chain: edit.chain, local_only: edit.local_only }); toast.success('Saved'); setEdit(null); routes.refresh(); } catch (e) { toast.error(pdErrorText(e)); }
            }}>Save</Button>
          </div>
        </Modal>
      )}
    </Card>
  );
}

function Agents({ providers, canEdit }: { providers: AiProvider[]; canEdit: boolean }) {
  const agents = usePdData(async () => (await pdService.agents()).data, []);
  const [edit, setEdit] = useState<Agent | null>(null);
  return (
    <Card>
      <h3 className="font-semibold text-secondary-900">Agents</h3>
      <p className="text-sm text-secondary-500">Each agent drafts work for approval. Route any agent to a JobShout agent instead of a model.</p>
      <ul className="mt-4 divide-y divide-secondary-100 rounded-lg border border-secondary-200">
        {(agents.data || []).map((a) => {
          const c = a.config;
          return (
            <li key={a.key} className="flex flex-wrap items-center justify-between gap-3 p-3 text-sm">
              <div>
                <div className="flex flex-wrap items-center gap-2">
                  <span className="font-medium text-secondary-900">{a.name}</span>
                  {!c.enabled && <Badge size="sm" variant="secondary">off</Badge>}
                  {c.route === 'jobshout' && <Badge size="sm" variant="info">JobShout</Badge>}
                  {c.local_only && <Badge size="sm" variant="success">local only</Badge>}
                  {c.auto_pickup && <Badge size="sm">auto {c.auto_pickup_at}</Badge>}
                </div>
                <div className="text-secondary-500">Job: {label(a.job_type)} · tools: {a.tools.join(', ') || 'none'} · approval: {label(c.approval_rule || a.default_approval)}</div>
              </div>
              {canEdit && <Button size="sm" variant="ghost" onClick={() => setEdit(a)}>Configure</Button>}
            </li>
          );
        })}
      </ul>
      {edit && <AgentModal agent={edit} providers={providers} onClose={() => setEdit(null)} onSaved={() => { setEdit(null); agents.refresh(); }} />}
    </Card>
  );
}

function AgentModal({ agent, providers, onClose, onSaved }: { agent: Agent; providers: AiProvider[]; onClose: () => void; onSaved: () => void }) {
  const c = agent.config;
  const links = providers.filter((p) => p.provider_type === 'jobshout');
  const [f, setF] = useState({
    enabled: c.enabled, route: c.route, jobshout_provider_uuid: c.jobshout_provider_uuid || links[0]?.uuid || '',
    jobshout_agent_id: c.jobshout_agent_id || '', fallback_to_builtin: c.fallback_to_builtin ?? true, local_only: c.local_only ?? false,
    approval_rule: c.approval_rule || '', auto_pickup: c.auto_pickup ?? false, auto_pickup_at: c.auto_pickup_at || '08:00',
  });
  const jsAgents = usePdData(async () => (f.route === 'jobshout' && f.jobshout_provider_uuid ? (await pdService.jobshoutAgents(f.jobshout_provider_uuid)).data : []), [f.route, f.jobshout_provider_uuid]);
  return (
    <Modal isOpen onClose={onClose} title={agent.name} description={`Prompt ${agent.version}`} size="lg">
      <div className="space-y-3">
        <label className="flex items-center gap-2 text-sm"><Switch checked={f.enabled} onChange={(v) => setF({ ...f, enabled: v })} /> Enabled</label>
        <Select label="Runs on" value={f.route} onChange={(e) => setF({ ...f, route: e.target.value as 'builtin' | 'jobshout' })}>
          <option value="builtin">Our models (Model per job type)</option>
          <option value="jobshout" disabled={!links.length}>A JobShout agent{links.length ? '' : ' (add a JobShout link first)'}</option>
        </Select>
        {f.route === 'jobshout' && (
          <div className="grid gap-3 sm:grid-cols-2">
            <Select label="JobShout link" value={f.jobshout_provider_uuid} onChange={(e) => setF({ ...f, jobshout_provider_uuid: e.target.value })}>
              {links.map((l) => <option key={l.uuid} value={l.uuid}>{l.name}</option>)}
            </Select>
            <Select label="JobShout agent" value={f.jobshout_agent_id} onChange={(e) => setF({ ...f, jobshout_agent_id: e.target.value })}>
              <option value="">Choose…</option>
              {(jsAgents.data || []).map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}
            </Select>
            <label className="flex items-center gap-2 text-sm sm:col-span-2"><Switch checked={f.fallback_to_builtin} onChange={(v) => setF({ ...f, fallback_to_builtin: v })} /> If JobShout is down, use our models</label>
            {jsAgents.error && <div className="sm:col-span-2"><ErrorNote error={jsAgents.error} /></div>}
          </div>
        )}
        <label className="flex items-center gap-2 text-sm"><Switch checked={f.local_only} onChange={(v) => setF({ ...f, local_only: v })} /> Local models only</label>
        <Select label="Approval rule" value={f.approval_rule} onChange={(e) => setF({ ...f, approval_rule: e.target.value })}>
          <option value="">Default ({label(agent.default_approval)})</option>
          <option value="any_operator">Any operator</option>
          <option value="manager">A manager</option>
          <option value="two_person">Two people</option>
        </Select>
        <div className="flex flex-wrap items-end gap-3">
          <label className="flex items-center gap-2 text-sm"><Switch checked={f.auto_pickup} onChange={(v) => setF({ ...f, auto_pickup: v })} /> Start by itself every day at</label>
          <Input type="time" value={f.auto_pickup_at} onChange={(e) => setF({ ...f, auto_pickup_at: e.target.value })} aria-label="Auto pickup time" disabled={!f.auto_pickup} />
        </div>
      </div>
      <div className="mt-5 flex justify-end gap-2">
        <Button variant="ghost" onClick={onClose}>Cancel</Button>
        <Button onClick={async () => {
          try {
            await pdService.saveAgent(agent.key, {
              enabled: f.enabled, route: f.route, local_only: f.local_only, auto_pickup: f.auto_pickup,
              auto_pickup_at: f.auto_pickup ? f.auto_pickup_at : undefined, fallback_to_builtin: f.fallback_to_builtin,
              approval_rule: (f.approval_rule || null) as never,
              ...(f.route === 'jobshout' ? { jobshout_provider_uuid: f.jobshout_provider_uuid, jobshout_agent_id: f.jobshout_agent_id } : {}),
            });
            toast.success('Saved');
            onSaved();
          } catch (e) { toast.error(pdErrorText(e)); }
        }}>Save</Button>
      </div>
    </Modal>
  );
}

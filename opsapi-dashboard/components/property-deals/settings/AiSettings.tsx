'use client';

/**
 * AI settings for Property Deals: the workspace's AI providers (the core component, also under
 * Workspace → AI models), the model chain per job type (fallback order, local-only), and each agent
 * (on/off, built-in or a JobShout agent, approval rule, auto pickup).
 */
import React, { useState } from 'react';
import { Plus, Trash2, ArrowUp, ArrowDown } from 'lucide-react';
import toast from 'react-hot-toast';
import { Badge, Button, Card, Input, Modal, Select, Switch } from '@/components/ui';
import { pdService, pdErrorText, type Agent, type AiRoute } from '@/services/property-deals.service';
import { aiProvidersService, type AiProvider } from '@/services/ai-providers.service';
import AiProviders from '@/components/ai/AiProviders';
import { ErrorNote, label } from '../ui';
import { usePdData } from '../usePd';

const JOB_TYPES = ['draft', 'plan', 'classify', 'extract', 'summarise', 'chat'];

/** canEditProviders = core namespace.update (what the providers API checks); canEditPlugin = this plugin's settings.update. */
export default function AiSettings({ canEditProviders, canEditPlugin }: { canEditProviders: boolean; canEditPlugin: boolean }) {
  const [providers, setProviders] = useState<AiProvider[]>([]);
  return (
    <div className="space-y-6">
      <AiProviders canEdit={canEditProviders} onLoaded={setProviders} />
      <Routes providers={providers} canEdit={canEditPlugin} />
      <Agents providers={providers} canEdit={canEditPlugin} />
    </div>
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
  const jsAgents = usePdData(async () => (f.route === 'jobshout' && f.jobshout_provider_uuid ? await aiProvidersService.jobshoutAgents(f.jobshout_provider_uuid) : []), [f.route, f.jobshout_provider_uuid]);
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

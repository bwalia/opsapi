'use client';

/**
 * Platform AI fallback chain (platform admins only): per AI feature, which of the platform's models are
 * tried and in what order. The first enabled, working model answers; if it fails (timeout, error, rate
 * limit, bad key) the next one gets the same request, and a model that keeps failing is skipped for a
 * minute. Keys and endpoints stay in the environment / Vault: this card only orders the models the
 * environment already has, picks their model id, and switches them on or off.
 * Backend: lapis/routes/ai-chain-admin.lua, applied in lapis/lib/agent/llm.lua ("Saved chains").
 */
import React, { useCallback, useEffect, useMemo, useState } from 'react';
import {
  ChevronDown, ChevronUp, FlaskConical, GitBranch, Info, Loader2, Plus, RotateCcw, Save, Trash2,
} from 'lucide-react';
import toast from 'react-hot-toast';
import { Badge, Button, Card, Input, Select, Switch, confirmDialog } from '@/components/ui';
import {
  aiChainService, type ChainHop, type ChainModel, type ChainOverview, type ChainScope, type ChainTestResult,
} from '@/services/ai-chain.service';
import { extractApiError, formatDateTime } from '@/lib/utils';

const clean = (hops: ChainHop[]): ChainHop[] =>
  hops.map((h) => ({ name: h.name, model: h.model ? h.model : null, enabled: h.enabled !== false }));
const same = (a: ChainHop[], b: ChainHop[]) => JSON.stringify(clean(a)) === JSON.stringify(clean(b));

function statusOf(m: ChainModel | undefined): { label: string; variant: 'success' | 'warning' | 'secondary' } {
  if (!m) return { label: 'Unknown', variant: 'secondary' };
  if (!m.configured) return { label: 'Not configured', variant: 'secondary' };
  if (m.circuit_open) return { label: 'Down (skipped for now)', variant: 'warning' };
  return { label: 'Ready', variant: 'success' };
}

export default function AiFallbackChain() {
  const [data, setData] = useState<ChainOverview | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState('default');
  const [drafts, setDrafts] = useState<Record<string, ChainHop[]>>({});
  const [busy, setBusy] = useState<'save' | 'reset' | 'test' | null>(null);
  const [tests, setTests] = useState<Record<string, ChainTestResult | undefined>>({});
  const [adding, setAdding] = useState('');

  const apply = useCallback((d: ChainOverview, only?: string) => {
    setData(d);
    setDrafts((prev) => {
      const next = { ...prev };
      for (const s of d.scopes) if (!only || s.key === only || !next[s.key]) next[s.key] = clean(s.hops);
      return next;
    });
  }, []);

  const load = useCallback(async () => {
    try {
      apply(await aiChainService.overview());
      setError(null);
    } catch (e) {
      setError(extractApiError(e, 'Could not load the fallback chain'));
    }
  }, [apply]);
  useEffect(() => { void load(); }, [load]);

  const models = useMemo(() => {
    const m = new Map<string, ChainModel>();
    for (const c of data?.catalogue ?? []) m.set(c.name, c);
    return m;
  }, [data]);

  const scope: ChainScope | undefined = data?.scopes.find((s) => s.key === tab);
  const draft = drafts[tab] ?? [];
  const dirty = scope ? !same(draft, scope.hops) : false;
  const test = tests[tab];

  const setDraft = (fn: (prev: ChainHop[]) => ChainHop[]) => {
    setDrafts((p) => ({ ...p, [tab]: fn(p[tab] ?? []) }));
    setTests((p) => ({ ...p, [tab]: undefined }));
  };
  const move = (i: number, d: -1 | 1) => setDraft((prev) => {
    const j = i + d;
    if (j < 0 || j >= prev.length) return prev;
    const c = [...prev];
    [c[i], c[j]] = [c[j], c[i]];
    return c;
  });
  const update = (i: number, patch: Partial<ChainHop>) =>
    setDraft((prev) => prev.map((h, k) => (k === i ? { ...h, ...patch } : h)));
  const remove = (i: number) => setDraft((prev) => prev.filter((_, k) => k !== i));

  const save = async () => {
    if (!scope) return;
    const enabled = draft.filter((h) => h.enabled);
    if (enabled.length === 0) { toast.error('Keep at least one model switched on.'); return; }
    if (!enabled.some((h) => models.get(h.name)?.configured)) {
      const ok = await confirmDialog({
        title: 'None of these models is configured',
        message: 'Every call for this feature would fall back to the environment order until a key is added. Save anyway?',
        confirmText: 'Save anyway',
      });
      if (!ok) return;
    }
    setBusy('save');
    try {
      apply(await aiChainService.save(scope.key, draft), scope.key);
      toast.success(`${scope.label}: order saved — it applies from the next AI call`);
    } catch (e) { toast.error(extractApiError(e, 'Could not save')); } finally { setBusy(null); }
  };

  const reset = async () => {
    if (!scope) return;
    if (scope.saved && !(await confirmDialog({
      title: `Use the environment's order for ${scope.label}?`,
      message: 'The saved order is deleted; the order from AI_PROVIDER / AI_FALLBACK_CHAIN applies again.',
      confirmText: 'Use environment order', danger: true,
    }))) return;
    setBusy('reset');
    try {
      if (scope.saved) apply(await aiChainService.reset(scope.key), scope.key);
      else setDrafts((p) => ({ ...p, [scope.key]: clean(scope.env_hops) }));
      setTests((p) => ({ ...p, [tab]: undefined }));
    } catch (e) { toast.error(extractApiError(e, 'Could not reset')); } finally { setBusy(null); }
  };

  const runTest = async () => {
    if (!scope) return;
    setBusy('test');
    try {
      const r = await aiChainService.test(scope.key, draft);
      setTests((p) => ({ ...p, [tab]: r }));
      if (r.serving) toast.success(`${r.serving} answered`);
      else toast.error('No model in this order answered');
      void aiChainService.overview().then((d) => setData(d)).catch(() => undefined);
    } catch (e) { toast.error(extractApiError(e, 'Could not test')); } finally { setBusy(null); }
  };

  const addable = data?.catalogue ?? [];

  return (
    <Card>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h3 className="flex items-center gap-2 font-semibold text-secondary-900">
            <GitBranch className="h-4 w-4" aria-hidden /> Platform fallback chain
            <Badge size="sm" variant="info">platform admins</Badge>
          </h3>
          <p className="mt-1 max-w-3xl text-sm text-secondary-500">
            The order in which the platform&apos;s models are tried, for every workspace that doesn&apos;t use its own
            provider. The first working model answers; if it fails, the next one gets the same request, and a
            failing model is skipped for {data ? Math.round(data.breaker_seconds) : 60}s. API keys stay in the
            environment / Vault — add a model there (e.g. <code>BEDROCK_*</code>, <code>ANTHROPIC_API_KEY</code>, or
            any OpenAI-compatible server in <code>AI_HOPS</code>) and it appears here to place in the order.
          </p>
        </div>
      </div>

      {error && (
        <p className="mt-3 rounded-lg bg-error-500/10 p-3 text-sm text-error-700" role="alert">
          {error} <button type="button" className="underline" onClick={() => void load()}>Retry</button>
        </p>
      )}
      {!data && !error && (
        <p className="flex items-center gap-2 py-6 text-sm text-secondary-500" role="status">
          <Loader2 className="h-4 w-4 animate-spin" aria-hidden /> Loading…
        </p>
      )}

      {data && scope && (
        <>
          <div className="mt-4 flex flex-wrap gap-1 rounded-xl border border-secondary-200 bg-secondary-50 p-1" role="tablist">
            {data.scopes.map((s) => {
              const tabDirty = drafts[s.key] && !same(drafts[s.key], s.hops);
              return (
                <button
                  key={s.key}
                  type="button"
                  role="tab"
                  aria-selected={tab === s.key}
                  onClick={() => setTab(s.key)}
                  className={`flex-1 whitespace-nowrap rounded-lg px-3 py-2 text-sm font-medium transition ${
                    tab === s.key ? 'bg-white text-secondary-900 shadow-sm' : 'text-secondary-600 hover:text-secondary-900'
                  }`}
                >
                  {s.label}
                  {s.saved && <span className="ml-1.5 text-xs text-primary-600">•&nbsp;saved</span>}
                  {tabDirty && <span className="ml-1.5 inline-block h-1.5 w-1.5 rounded-full bg-warning-500 align-middle" aria-label="unsaved changes" />}
                </button>
              );
            })}
          </div>

          <p className="mt-3 flex items-start gap-2 text-sm text-secondary-600">
            <Info className="mt-0.5 h-4 w-4 flex-shrink-0 text-secondary-400" aria-hidden />
            <span>
              {scope.description}{' '}
              {scope.saved
                ? <>Saved{scope.updated_by ? ` by ${scope.updated_by}` : ''}{scope.updated_at ? ` on ${formatDateTime(scope.updated_at)}` : ''}.</>
                : 'Not saved: this is the order from the environment.'}
              {scope.key === 'default' ? '' : scope.env_feature_chain && !scope.saved
                ? ' The environment sets a chain for this feature (AI_FALLBACK_CHAIN_BY_FEATURE), so the "All AI features" order doesn’t apply here.'
                : ''}
            </span>
          </p>

          <ol className="mt-3 divide-y divide-secondary-100 rounded-lg border border-secondary-200">
            {draft.length === 0 && <li className="p-4 text-sm text-secondary-500">No models. Add one below.</li>}
            {draft.map((h, i) => {
              const m = models.get(h.name);
              const st = statusOf(m);
              const r = test?.results.find((x) => x.position === i + 1);
              const first = draft.findIndex((x) => x.enabled) === i;
              const warn = scope.tools && m && !m.tools ? 'can’t call tools: skipped here' : null;
              return (
                <li key={`${h.name}-${i}`} className={`flex flex-wrap items-center gap-3 p-3 text-sm ${h.enabled ? '' : 'opacity-60'} ${r?.ok ? 'bg-success-500/5' : ''}`}>
                  <div className="flex flex-col">
                    <button type="button" aria-label={`Move ${h.name} up`} disabled={i === 0} onClick={() => move(i, -1)}
                      className="rounded p-0.5 text-secondary-500 hover:bg-secondary-100 disabled:opacity-30">
                      <ChevronUp className="h-4 w-4" />
                    </button>
                    <button type="button" aria-label={`Move ${h.name} down`} disabled={i === draft.length - 1} onClick={() => move(i, 1)}
                      className="rounded p-0.5 text-secondary-500 hover:bg-secondary-100 disabled:opacity-30">
                      <ChevronDown className="h-4 w-4" />
                    </button>
                  </div>
                  <span className="flex h-7 w-7 flex-shrink-0 items-center justify-center rounded-full bg-secondary-100 text-xs font-semibold text-secondary-700">
                    {i + 1}
                  </span>
                  <div className="min-w-[12rem] flex-1">
                    <div className="flex flex-wrap items-center gap-2">
                      <span className="font-medium text-secondary-900">{m?.label || h.name}</span>
                      <code className="text-xs text-secondary-500">{h.name}</code>
                      {first && h.enabled && <Badge size="sm" variant="info">answers first</Badge>}
                      <Badge size="sm" variant={st.variant}>{st.label}</Badge>
                      {warn && <Badge size="sm" variant="warning">{warn}</Badge>}
                    </div>
                    {m && !m.configured && m.reason && <p className="text-xs text-secondary-500">Missing in the environment: {m.reason}</p>}
                    {r && (
                      <p className={`text-xs ${r.ok ? 'text-success-700' : r.skipped ? 'text-secondary-500' : 'text-error-600'}`}>
                        {r.ok ? `Answered in ${r.latency_ms} ms` : r.skipped ? r.skipped : `Failed: ${r.error}`}
                      </p>
                    )}
                  </div>
                  <div className="w-64">
                    <Input
                      aria-label={`Model for ${h.name}`}
                      value={h.model ?? ''}
                      placeholder={m?.model ? `${m.model} (default)` : 'model id'}
                      onChange={(e) => update(i, { model: e.target.value.trim() || null })}
                    />
                  </div>
                  <label className="flex items-center gap-2 text-xs text-secondary-600">
                    <Switch checked={h.enabled} onChange={(v) => update(i, { enabled: v })} aria-label={`Use ${h.name}`} /> On
                  </label>
                  <Button size="sm" variant="ghost" aria-label={`Remove ${h.name}`} onClick={() => remove(i)}>
                    <Trash2 className="h-4 w-4" />
                  </Button>
                </li>
              );
            })}
          </ol>

          <div className="mt-3 flex flex-wrap items-end gap-2">
            <div className="w-72">
              <Select label="Add a model" value={adding} onChange={(e) => setAdding(e.target.value)}>
                <option value="">Choose…</option>
                {addable.map((c) => (
                  <option key={c.name} value={c.name}>
                    {(c.label || c.name) + (c.model ? ` — ${c.model}` : '') + (c.configured ? '' : ' (not configured)')}
                  </option>
                ))}
              </Select>
            </div>
            <Button variant="outline" leftIcon={<Plus className="h-4 w-4" />} disabled={!adding} onClick={() => {
              setDraft((prev) => [...prev, { name: adding, model: null, enabled: true }]);
              setAdding('');
            }}>Add</Button>
            <p className="pb-2 text-xs text-secondary-500">
              The same provider can be added twice with different models (e.g. Bedrock Sonnet, then Bedrock Haiku).
            </p>
          </div>

          {test && (
            <p className={`mt-3 rounded-lg p-3 text-sm ${test.serving ? 'bg-success-500/10 text-success-800' : 'bg-warning-500/10 text-warning-800'}`}>
              {test.serving ? `Right now, ${test.serving} would answer.` : 'No model in this order answered.'}
            </p>
          )}

          <div className="mt-4 flex flex-wrap items-center gap-2">
            <Button leftIcon={<Save className="h-4 w-4" />} isLoading={busy === 'save'} disabled={!dirty || !!busy} onClick={() => void save()}>
              Save {scope.label}
            </Button>
            <Button variant="outline" leftIcon={<FlaskConical className="h-4 w-4" />} isLoading={busy === 'test'} disabled={!!busy || draft.length === 0} onClick={() => void runTest()}>
              Test this order
            </Button>
            <Button variant="ghost" disabled={!dirty || !!busy} onClick={() => setDrafts((p) => ({ ...p, [tab]: clean(scope.hops) }))}>
              Discard changes
            </Button>
            <Button variant="ghost" leftIcon={<RotateCcw className="h-4 w-4" />} isLoading={busy === 'reset'} disabled={!!busy || (!scope.saved && same(draft, scope.env_hops))} onClick={() => void reset()}>
              Use environment order
            </Button>
          </div>

          <p className="mt-4 text-xs text-secondary-500">
            Now, a call here tries:{' '}
            {scope.effective.length ? scope.effective.map((e) => `${e.label || e.name} (${e.model || 'default'})`).join(' → ') : 'nothing configured'}.
            {scope.vision && ' Every model in this order must read images.'}
          </p>
        </>
      )}
    </Card>
  );
}

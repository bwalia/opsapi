'use client';

/**
 * AI Runs platform settings (docs/AI_RUNNER.md §27.5): timings and limits for every workspace, platform admins only.
 * The server decides who may see them (403 for everyone else), so the page shows nothing to others even when their
 * cached roles are stale; AI run settings links here only for platform admins (no sidebar entry: plugin menu items
 * can't be admin-only). Only the fields shown are saved. §28: the built-in runner's limits, and the GitHub App it works
 * through (its own form: the client secret and private key are write-only).
 */
import React, { useEffect, useState } from 'react';
import { GitBranch, Lock, SlidersHorizontal } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, Card, Input, Textarea } from '@/components/ui';
import { ErrorNote, Spinner } from '@/components/property-deals/ui';
import { AiRunnerPage, PRODUCT, useAiData } from '@/components/ai-runner/ui';
import { shown, typed } from '@/components/ai-runner/fields';
import {
  aiRunner, aiErrorText, type Bounds, type GithubApp, type GithubAppInput, type PlatformValues,
} from '@/services/ai-runner.service';

export default function AiRunsPlatformPage() {
  return (
    <AiRunnerPage>
      <div className="space-y-6">
        <PageHeader title="AI Runs platform settings" description="Timings and limits for every workspace. Only platform admins see this page."
          icon={<SlidersHorizontal className="h-6 w-6" />} />
        <Platform />
        <GithubAppForm />
      </div>
    </AiRunnerPage>
  );
}

type Field = { key: string; label: string; min: number; max: number; def: number; help: string };
type Group = { title: string; intro?: string; group?: 'guard_max'; fields: Field[] };

// Fallback bounds and defaults, as the server checks them (projects/ai-runner R.PLATFORM_BOUNDS / R.PLATFORM_DEFAULTS);
// GET /platform/settings sends its own `bounds` and `defaults`, which win.
const GROUPS: Group[] = [
  {
    title: 'Runner protocol',
    intro: 'Runners follow the heartbeat and claim timings the server sends them. Keep the lease and the online window well above the heartbeat.',
    fields: [
      { key: 'heartbeat_s', label: 'Heartbeat every (seconds)', min: 5, max: 300, def: 15, help: 'How often runners report in.' },
      { key: 'claim_wait_s', label: 'Claim wait (seconds)', min: 1, max: 25, def: 25, help: 'How long a runner asking for work waits for a queued run.' },
      { key: 'lease_s', label: 'Run lease (seconds)', min: 30, max: 3600, def: 60, help: "A run whose runner stops reporting for this long is lost." },
      { key: 'online_s', label: 'Online within (seconds)', min: 10, max: 3600, def: 45, help: 'A runner that reported within this counts as online.' },
    ],
  },
  {
    title: 'Timeouts',
    fields: [
      { key: 'queue_timeout_hours', label: 'Queued run timeout (hours)', min: 1, max: 720, def: 24, help: 'A run no runner claims in this time fails.' },
      { key: 'approval_timeout_hours', label: 'Approval timeout (hours)', min: 1, max: 720, def: 72, help: 'A run nobody approves in this time is cancelled.' },
    ],
  },
  {
    title: 'Per-run limits',
    fields: [
      { key: 'max_events_per_run', label: 'Log events per run', min: 100, max: 1_000_000, def: 20_000, help: 'After this, the run log is truncated.' },
      { key: 'max_queued_followups', label: 'Waiting follow-ups per run', min: 1, max: 1000, def: 50, help: 'Messages waiting for the agent; more are refused.' },
      { key: 'max_requests_per_run', label: 'Permission requests per run', min: 10, max: 10_000, def: 500, help: 'After this, requests are denied automatically.' },
      {
        key: 'max_tracked_per_heartbeat_cap', label: 'New tracked tasks per heartbeat, at most', min: 1, max: 1000, def: 100,
        help: "The highest a workspace may set for New tasks per heartbeat.",
      },
    ],
  },
  {
    title: 'Built-in runner',
    intro: 'Runs inside OpsAPI on the AI models (no machine). Keep these within what the model server can take at once.',
    fields: [
      { key: 'builtin_max_runs', label: 'Built-in runs at once (all workspaces)', min: 1, max: 100, def: 2, help: 'More wait in the queue.' },
      { key: 'builtin_max_runs_per_workspace', label: 'Built-in runs at once per workspace', min: 1, max: 20, def: 1, help: '' },
      { key: 'builtin_max_steps', label: 'Agent steps per run', min: 5, max: 200, def: 40, help: 'Model calls in one run; a run that needs more fails.' },
    ],
  },
  {
    title: 'Highest values a workspace may set',
    intro: 'Upper bounds for AI run settings. A workspace with a higher value is held to this.',
    group: 'guard_max',
    fields: [
      { key: 'max_open_runs_per_user', label: 'Max open runs per person', min: 1, max: 10_000, def: 100, help: '' },
      { key: 'max_open_runs_per_workspace', label: 'Max open runs in a workspace', min: 1, max: 100_000, def: 1000, help: '' },
      { key: 'daily_token_limit', label: 'Daily token limit', min: 1, max: 2_000_000_000, def: 1_000_000_000, help: '' },
      { key: 'retention_days', label: 'Keep run logs (days)', min: 30, max: 36_500, def: 3650, help: '' },
      { key: 'max_run_minutes', label: 'Max run minutes', min: 1, max: 10_080, def: 1440, help: '' },
    ],
  },
];

const n = (v: number) => v.toLocaleString('en-GB');
/** obj[key], or obj[group][key] for a grouped field. */
function at<T>(obj: Record<string, unknown> | undefined, g: Group, key: string): T | undefined {
  const o = g.group ? obj?.[g.group] : obj;
  return o && typeof o === 'object' ? ((o as Record<string, unknown>)[key] as T) : undefined;
}

function Platform() {
  const loaded = useAiData(() => aiRunner.getPlatformSettings(), []);
  const [v, setV] = useState<PlatformValues | null>(null);
  const [url, setUrl] = useState('');
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    if (loaded.data) { setV(loaded.data.values); setUrl(loaded.data.dashboardUrl); }
  }, [loaded.data]);

  if (loaded.error?.status === 403) {
    return (
      <div className="flex items-center gap-2 rounded-lg bg-warning-500/10 p-3 text-sm text-warning-700">
        <Lock className="h-4 w-4" aria-hidden /> Only platform admins can see and change these settings.
      </div>
    );
  }
  if (!v || !loaded.data) return loaded.error ? <ErrorNote error={loaded.error} product={PRODUCT} /> : <Spinner />;
  const meta = loaded.data;
  // The server's bounds and defaults when it sends them; this page's copy otherwise.
  const limits = (g: Group, f: Field) => {
    const b = at<Bounds>(meta.bounds, g, f.key);
    const def = at<number>(meta.defaults, g, f.key);
    return { min: b?.min ?? f.min, max: b?.max ?? f.max, def: typeof def === 'number' ? def : f.def };
  };
  const value = (g: Group, f: Field) => {
    const x = at<number>(v, g, f.key);
    return typeof x === 'number' ? x : undefined;
  };
  const set = (g: Group, f: Field, x: number) => setV(g.group
    ? { ...v, [g.group]: { ...(typeof v[g.group] === 'object' ? v[g.group] as Record<string, number> : {}), [f.key]: x } }
    : { ...v, [f.key]: x });

  async function save(e: React.FormEvent) {
    e.preventDefault();
    if (!v) return;
    // Only the fields on this page (the server keeps the rest).
    const body: PlatformValues = {};
    for (const g of GROUPS) {
      for (const f of g.fields) {
        const x = value(g, f);
        if (x === undefined) continue;
        if (g.group) body[g.group] = { ...(body[g.group] as Record<string, number> | undefined), [f.key]: x };
        else body[f.key] = x;
      }
    }
    setBusy(true);
    try {
      const saved = await aiRunner.savePlatformSettings(body, url.trim());
      setV(saved.values);
      setUrl(saved.dashboardUrl);
      toast.success('Platform settings saved. Every server uses them within a minute.');
    } catch (err) {
      toast.error(aiErrorText(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Card>
      <form onSubmit={save} className="space-y-6">
        <p className="text-sm text-secondary-600">
          These apply to every workspace on this platform. Workspaces set their own AI run settings within the bounds below.
        </p>
        <Input id="air-p-dashboard-url" label="Dashboard address" type="url" value={url} onChange={(e) => setUrl(e.target.value)}
          placeholder={meta.dashboardUrlFallback || 'https://ops.example.com'}
          helperText={`Task links in AI run prompts and run details point here. Just the address, no path. Empty = this server's FRONTEND_URL${meta.dashboardUrlFallback ? ` (${meta.dashboardUrlFallback})` : ''}.`} />
        {GROUPS.map((g) => (
          <fieldset key={g.title} className="min-w-0 space-y-3 border-t border-secondary-200 pt-4 first-of-type:border-t-0 first-of-type:pt-0">
            <legend className="sr-only">{g.title}</legend>
            <h2 className="text-sm font-semibold text-secondary-800" aria-hidden>{g.title}</h2>
            {g.intro && <p className="text-xs text-secondary-500">{g.intro}</p>}
            <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
              {g.fields.map((f) => {
                const l = limits(g, f);
                return (
                  <Input key={f.key} id={`air-p-${g.group ? `${g.group}-` : ''}${f.key}`} label={f.label} type="number" required
                    min={l.min} max={l.max} step={1} value={shown(value(g, f))} placeholder={String(l.def)}
                    onChange={(e) => set(g, f, typed(e.target.value))}
                    helperText={`${f.help ? `${f.help} ` : ''}${n(l.min)}–${n(l.max)}, default ${n(l.def)}.`} />
                );
              })}
            </div>
          </fieldset>
        ))}
        <div className="flex justify-end">
          <Button type="submit" isLoading={busy}>Save platform settings</Button>
        </div>
      </form>
    </Card>
  );
}

const GITHUB_FIELDS: { key: keyof GithubAppInput & keyof GithubApp; label: string; help: string; placeholder?: string }[] = [
  { key: 'app_id', label: 'App ID', help: 'On the App’s General page.' },
  { key: 'app_slug', label: 'App slug', help: 'As in github.com/apps/<slug>.' },
  { key: 'client_id', label: 'Client ID', help: 'On the App’s General page.' },
  { key: 'api_url', label: 'API address', help: 'Empty = GitHub.com. GitHub Enterprise Server: https://<host>/api/v3.', placeholder: 'https://api.github.com' },
  { key: 'web_url', label: 'Web address', help: 'Empty = GitHub.com. GitHub Enterprise Server: https://<host>.', placeholder: 'https://github.com' },
];

/**
 * §28.3: the GitHub App the built-in runner works through, for every workspace. Each workspace installs it on the
 * repositories it chooses (Runners & sources → Connect GitHub).
 */
function GithubAppForm() {
  const loaded = useAiData(() => aiRunner.getPlatformSettings(), []);
  const [form, setForm] = useState<Record<string, string>>({});
  const [secret, setSecret] = useState('');
  const [key, setKey] = useState('');
  const [busy, setBusy] = useState<'save' | 'remove' | null>(null);
  const [g, setG] = useState<GithubApp | null>(null);
  useEffect(() => {
    const x = loaded.data?.github;
    if (x) { setG(x); setForm(Object.fromEntries(GITHUB_FIELDS.map((f) => [f.key, String(x[f.key] ?? '')]))); }
  }, [loaded.data]);
  if (loaded.error || !g) return null; // the settings card above says why

  async function save(input: GithubAppInput | null, which: 'save' | 'remove') {
    setBusy(which);
    try {
      const saved = await aiRunner.saveGithubApp(input);
      setG(saved.github);
      setForm(Object.fromEntries(GITHUB_FIELDS.map((f) => [f.key, String(saved.github[f.key] ?? '')])));
      setSecret('');
      setKey('');
      toast.success(which === 'remove' ? 'GitHub App removed' : 'GitHub App saved');
    } catch (err) {
      toast.error(aiErrorText(err));
    } finally {
      setBusy(null);
    }
  }

  function submit(e: React.FormEvent) {
    e.preventDefault();
    const input: GithubAppInput = { ...form };
    if (secret.trim()) input.client_secret = secret.trim();
    if (key.trim()) input.private_key = key.trim();
    save(input, 'save');
  }

  return (
    <Card>
      <form onSubmit={submit} className="space-y-5" aria-labelledby="air-gh-title">
        <div>
          <h2 id="air-gh-title" className="flex items-center gap-2 text-base font-semibold text-secondary-900">
            <GitBranch className="h-5 w-5" aria-hidden /> GitHub App {g.configured ? '(set up)' : '(not set up)'}
          </h2>
          <p className="mt-1 text-sm text-secondary-600">
            The built-in runner reads code and opens pull requests through one GitHub App. Workspaces install it on the repositories
            they choose; OpsAPI never sees a personal token.
          </p>
        </div>
        <ol className="list-decimal space-y-1 pl-5 text-sm text-secondary-700">
          <li>On GitHub: Settings → Developer settings → GitHub Apps → New GitHub App.</li>
          <li>
            Callback URL and Setup URL: <code className="break-all font-mono text-xs" data-testid="air-gh-callback">{g.callback_url}</code>.
            Tick <em>Redirect on update</em>. Leave <em>Request user authorization during installation</em> off, and the webhook inactive.
          </li>
          <li>Repository permissions: Contents read and write, Pull requests read and write (Metadata read comes with them).</li>
          <li>Create it, generate a private key and a client secret, and enter them here.</li>
        </ol>
        <div className="grid gap-4 sm:grid-cols-2">
          {GITHUB_FIELDS.map((f) => (
            <Input key={f.key} id={`air-gh-${f.key}`} label={f.label} value={form[f.key] ?? ''} placeholder={f.placeholder}
              onChange={(e) => setForm({ ...form, [f.key]: e.target.value })} helperText={f.help} spellCheck={false} autoComplete="off" />
          ))}
          <Input id="air-gh-client_secret" label="Client secret" type="password" value={secret} onChange={(e) => setSecret(e.target.value)}
            autoComplete="new-password" placeholder={g.has_client_secret ? 'Saved; type to replace' : ''}
            helperText={g.has_client_secret ? 'Saved (never shown). Leave empty to keep it.' : 'Generate one on the App’s General page.'} />
        </div>
        <Textarea id="air-gh-private_key" label="Private key (PEM)" rows={4} value={key} onChange={(e) => setKey(e.target.value)}
          className="font-mono text-xs" spellCheck={false} placeholder={g.has_private_key ? 'Saved; paste a new key to replace it' : '-----BEGIN RSA PRIVATE KEY-----'}
          helperText={g.has_private_key ? 'Saved (never shown). Leave empty to keep it.' : 'The .pem file GitHub downloads when you generate a private key.'} />
        <div className="flex flex-wrap justify-end gap-2">
          {(g.configured || g.app_id) && (
            <Button type="button" variant="ghost" className="text-error-600" isLoading={busy === 'remove'} disabled={busy !== null}
              onClick={() => save(null, 'remove')}>Remove the GitHub App</Button>
          )}
          <Button type="submit" isLoading={busy === 'save'} disabled={busy !== null}>Save GitHub App</Button>
        </div>
      </form>
    </Card>
  );
}

'use client';

/** AI run settings (ai_runs_settings.manage): workspace defaults for runs, and the prompt template. */
import React, { useEffect, useState } from 'react';
import { Settings as SettingsIcon } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, Card, Input, Select, Switch, Textarea } from '@/components/ui';
import { ErrorNote, Spinner } from '@/components/property-deals/ui';
import { AiRunnerPage, OUTPUT_MODES, PRODUCT, useAiData } from '@/components/ai-runner/ui';
import { aiRunner, aiErrorText, type Settings } from '@/services/ai-runner.service';

export default function AiRunSettingsPage() {
  return (
    <AiRunnerPage module="ai_runs_settings" action="manage">
      <div className="space-y-6">
        <PageHeader title="AI run settings" description="Workspace defaults for AI runs and the prompt every run starts from."
          icon={<SettingsIcon className="h-6 w-6" />} />
        <RunSettings />
        <TemplateEditor />
      </div>
    </AiRunnerPage>
  );
}

const DEFAULTS: Settings = {
  output_mode: 'pull_request',
  pr_draft: false,
  pr_base: 'main',
  max_run_minutes: 60,
  task_automation: { in_progress_on_start: false, review_on_success: false },
  approval_policy: { deciders: 'managers', require_start_approval: false, permission_timeout_minutes: 30, input_timeout_minutes: 60 },
  guards: {
    similar_threshold: 0.45, max_open_runs_per_user: 3, max_open_runs_per_workspace: 10, daily_token_limit: 0, retention_days: 365,
  },
};

function Toggle({ label, hint, checked, onChange }: { label: string; hint?: string; checked: boolean; onChange: (v: boolean) => void }) {
  return (
    <div className="flex items-start justify-between gap-4">
      <div>
        <div className="text-sm font-medium text-secondary-800">{label}</div>
        {hint && <div className="text-xs text-secondary-500">{hint}</div>}
      </div>
      <Switch checked={checked} onChange={onChange} aria-label={label} />
    </div>
  );
}

function RunSettings() {
  const loaded = useAiData(() => aiRunner.getSettings(), []);
  const [s, setS] = useState<Settings | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    const d = loaded.data;
    if (d) {
      setS({
        ...DEFAULTS, ...d,
        task_automation: { ...DEFAULTS.task_automation, ...d.task_automation },
        approval_policy: { ...DEFAULTS.approval_policy, ...d.approval_policy },
        guards: { ...DEFAULTS.guards, ...d.guards },
      });
    }
  }, [loaded.data]);

  if (!s) return loaded.error ? <ErrorNote error={loaded.error} product={PRODUCT} /> : <Spinner />;
  const set = (patch: Partial<Settings>) => setS({ ...s, ...patch });
  const g = s.guards;
  const guard = (patch: Partial<Settings['guards']>) => set({ guards: { ...g, ...patch } });
  // 0 is a valid limit, so an emptied field stays empty (NaN) rather than snapping to 0; `required` stops the save.
  const typed = (v: string) => (v === '' ? NaN : Number(v));
  const shown = (n: number) => (Number.isNaN(n) ? '' : n);

  async function save(e: React.FormEvent) {
    e.preventDefault();
    if (!s) return;
    setBusy(true);
    try {
      const saved = await aiRunner.saveSettings(s);
      if (saved) setS({ ...s, ...saved, guards: { ...s.guards, ...saved.guards } });
      toast.success('Settings saved');
    } catch (err) {
      toast.error(aiErrorText(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Card>
      <form onSubmit={save} className="space-y-6">
        <h2 className="text-lg font-semibold text-secondary-900">Runs</h2>
        <div className="grid gap-4 sm:grid-cols-3">
          <Select id="air-s-output" label="Default output" value={s.output_mode} onChange={(e) => set({ output_mode: e.target.value as Settings['output_mode'] })}>
            {OUTPUT_MODES.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
          </Select>
          <Input id="air-s-base" label="Pull request base branch" value={s.pr_base} onChange={(e) => set({ pr_base: e.target.value })}
            disabled={s.output_mode !== 'pull_request'} className="font-mono" />
          <Input id="air-s-minutes" label="Max run minutes" type="number" min={1} max={1440} required value={s.max_run_minutes || ''}
            onChange={(e) => set({ max_run_minutes: Number(e.target.value) || 0 })} helperText="A run still going after this is stopped." />
        </div>
        <Toggle label="Open pull requests as drafts" checked={s.pr_draft} onChange={(v) => set({ pr_draft: v })} />

        <div className="space-y-3 border-t border-secondary-200 pt-4">
          <h3 className="text-sm font-semibold text-secondary-800">Task automation</h3>
          <Toggle label="Move the task to In progress when a run starts" checked={s.task_automation.in_progress_on_start}
            onChange={(v) => set({ task_automation: { ...s.task_automation, in_progress_on_start: v } })} />
          <Toggle label="Move the task to Review when a run succeeds" checked={s.task_automation.review_on_success}
            onChange={(v) => set({ task_automation: { ...s.task_automation, review_on_success: v } })} />
        </div>

        <div className="space-y-3 border-t border-secondary-200 pt-4">
          <h3 className="text-sm font-semibold text-secondary-800">Approval policy</h3>
          <p className="text-xs text-secondary-500">
            An agent asks before risky steps, such as running a command. Profiles that can&apos;t ask (Cursor) always need a manager&apos;s approval to start.
          </p>
          <div className="max-w-sm">
            <Select id="air-s-deciders" label="Who decides permission requests" value={s.approval_policy.deciders}
              onChange={(e) => set({ approval_policy: { ...s.approval_policy, deciders: e.target.value as Settings['approval_policy']['deciders'] } })}>
              <option value="managers">Managers</option>
              <option value="requester">The person who started the run</option>
              <option value="requester_or_managers">The requester or a manager</option>
            </Select>
          </div>
          <Toggle label="Runs started by an assignee need a manager's approval first" checked={s.approval_policy.require_start_approval}
            onChange={(v) => set({ approval_policy: { ...s.approval_policy, require_start_approval: v } })} />
          <div className="grid gap-4 sm:grid-cols-2">
            <Input id="air-s-perm-timeout" label="Permission timeout (minutes)" type="number" min={1} max={1440} required
              value={s.approval_policy.permission_timeout_minutes || ''}
              onChange={(e) => set({ approval_policy: { ...s.approval_policy, permission_timeout_minutes: Number(e.target.value) || 0 } })}
              helperText="A request nobody answers in time is denied; the agent carries on without it." />
            <Input id="air-s-input-timeout" label="Input timeout (minutes)" type="number" min={1} max={1440} required
              value={s.approval_policy.input_timeout_minutes || ''}
              onChange={(e) => set({ approval_policy: { ...s.approval_policy, input_timeout_minutes: Number(e.target.value) || 0 } })}
              helperText="A run waiting for an answer longer than this fails." />
          </div>
        </div>

        {/* Ranges as the server checks them (docs/AI_RUNNER.md §24.1); the browser enforces them before saving. */}
        <div className="space-y-3 border-t border-secondary-200 pt-4">
          <h3 className="text-sm font-semibold text-secondary-800">Limits and safeguards</h3>
          <p className="text-xs text-secondary-500">Stop AI work from piling up or clashing. For the limits, 0 means no limit.</p>
          <div className="grid gap-4 sm:grid-cols-2">
            <Input id="air-s-similar" label="Similar work threshold (%)" type="number" min={10} max={100} required
              value={shown(Math.round(g.similar_threshold * 100))} onChange={(e) => guard({ similar_threshold: typed(e.target.value) / 100 })}
              helperText="How alike two task titles must be (10–100) for an open run to count as similar work. Starting then needs Start anyway. Lower warns more often." />
            <Input id="air-s-user-cap" label="Max open runs per person" type="number" min={0} max={100} required
              value={shown(g.max_open_runs_per_user)} onChange={(e) => guard({ max_open_runs_per_user: typed(e.target.value) })}
              helperText="Runs one person may have open at once (0–100)." />
            <Input id="air-s-ws-cap" label="Max open runs in the workspace" type="number" min={0} max={1000} required
              value={shown(g.max_open_runs_per_workspace)} onChange={(e) => guard({ max_open_runs_per_workspace: typed(e.target.value) })}
              helperText="Runs open at once across the workspace (0–1000). Approving a waiting run is never blocked." />
            <Input id="air-s-tokens" label="Daily token limit" type="number" min={0} max={1_000_000_000} required
              value={shown(g.daily_token_limit)} onChange={(e) => guard({ daily_token_limit: typed(e.target.value) })}
              helperText="Agent tokens (in + out) per day, UTC. At the limit no new run starts; running ones finish." />
            <Input id="air-s-retention" label="Keep run logs (days)" type="number" min={30} max={3650} required
              value={shown(g.retention_days)} onChange={(e) => guard({ retention_days: typed(e.target.value) })}
              helperText="30–3650. After this, a finished run's log, conversation text and request details are deleted; the run, its summary and usage stay." />
          </div>
        </div>

        <div className="flex justify-end">
          <Button type="submit" isLoading={busy}>Save settings</Button>
        </div>
      </form>
    </Card>
  );
}

const VARIABLES: [string, string][] = [
  ['{{task.number}}', 'the task number'],
  ['{{task.title}}', 'the task title'],
  ['{{task.url}}', 'a link to the task'],
  ['{{project.name}}', 'the kanban project'],
  ['{{repo_path}}', 'the folder on the machine'],
  ['{{work_branch}}', 'the branch the run works on'],
];

function TemplateEditor() {
  const loaded = useAiData(() => aiRunner.getTemplate(), []);
  const [body, setBody] = useState('');
  const [saved, setSaved] = useState('');
  const [version, setVersion] = useState<number>();
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    if (loaded.data) { setBody(loaded.data.body || ''); setSaved(loaded.data.body || ''); setVersion(loaded.data.version); }
  }, [loaded.data]);

  async function save() {
    setBusy(true);
    try {
      const t = await aiRunner.saveTemplate(body);
      setSaved(body);
      if (t?.version) setVersion(t.version);
      toast.success(t?.version ? `Template saved as version ${t.version}` : 'Template saved');
    } catch (e) {
      toast.error(aiErrorText(e));
    } finally {
      setBusy(false);
    }
  }

  if (!loaded.data) return loaded.error ? <ErrorNote error={loaded.error} product={PRODUCT} /> : <Spinner />;
  return (
    <Card>
      <div className="space-y-4">
        <div className="flex items-baseline justify-between gap-4">
          <h2 className="text-lg font-semibold text-secondary-900">Prompt template</h2>
          {version !== undefined && <span className="text-sm text-secondary-500">Version {version}</span>}
        </div>
        <p className="text-sm text-secondary-600">
          Every run&apos;s prompt starts from this. Keep the guardrails in it: work only in the folder and on the run&apos;s branch,
          never on main; never print, commit or log secrets; don&apos;t merge. Saving creates a new version; runs keep the one they started with.
        </p>
        <Textarea id="air-template" label="Template" rows={16} value={body} onChange={(e) => setBody(e.target.value)} className="font-mono text-xs" spellCheck={false} />
        <div>
          <p className="mb-1 text-sm font-medium text-secondary-700">Variables</p>
          <ul className="grid gap-x-6 gap-y-1 text-xs text-secondary-600 sm:grid-cols-2">
            {VARIABLES.map(([v, what]) => <li key={v}><code className="font-mono text-secondary-800">{v}</code> — {what}</li>)}
          </ul>
        </div>
        <div className="flex justify-end">
          <Button onClick={save} isLoading={busy} disabled={!body.trim() || body === saved}>Save template</Button>
        </div>
      </div>
    </Card>
  );
}

'use client';

/**
 * AI run settings (ai_runs_settings.manage): workspace defaults for runs, task automation, safety additions,
 * tracking sessions started by hand (default target, tunables and routing rules, §26–§27), and the prompt template.
 */
import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import { Plus, SlidersHorizontal, Settings as SettingsIcon, Trash2 } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, Card, Input, Select, Textarea, buttonClass } from '@/components/ui';
import { ErrorNote, Spinner } from '@/components/property-deals/ui';
import { AiRunnerPage, BASE, OUTPUT_MODES, PRODUCT, useAiData } from '@/components/ai-runner/ui';
import { ColumnField, ProjectSelect, TagsInput, Toggle, shown, strings, typed, useProjects } from '@/components/ai-runner/fields';
import { TrackRules } from '@/components/ai-runner/TrackRules';
import { usePermissions } from '@/contexts/PermissionsContext';
import { useMenuStore } from '@/store/menu.store';
import {
  aiRunner, aiErrorText, type KanbanStatus, type SessionTracking, type Settings, type TaskMove,
} from '@/services/ai-runner.service';

export default function AiRunSettingsPage() {
  // Platform admin: the user's "administrative" role, or the server's word in the menu response.
  const { isAdmin: hasAdminRole } = usePermissions();
  const menuSaysAdmin = useMenuStore((st) => st.isAdmin);
  const isAdmin = hasAdminRole || menuSaysAdmin;
  return (
    <AiRunnerPage module="ai_runs_settings" action="manage">
      <div className="space-y-6">
        <PageHeader title="AI run settings" description="Workspace defaults for AI runs and the prompt every run starts from."
          icon={<SettingsIcon className="h-6 w-6" />}
          actions={isAdmin ? (
            <Link href={`${BASE}/platform`} className={buttonClass('outline')}>
              <SlidersHorizontal className="h-4 w-4" aria-hidden /> Platform settings
            </Link>
          ) : undefined} />
        <RunSettings />
        <TrackRules />
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
  task_automation: {
    on_start: { enabled: false, status: 'in_progress', column: 'In Progress' },
    on_success: { enabled: false, status: 'review', column: 'Review' },
  },
  approval_policy: {
    deciders: 'managers', project_admins_decide: false, require_start_approval: false, permission_timeout_minutes: 30, input_timeout_minutes: 60,
  },
  guards: {
    similar_threshold: 0.45, max_open_runs_per_user: 3, max_open_runs_per_workspace: 10, daily_token_limit: 0, retention_days: 365,
  },
  session_tracking: {
    enabled: false, project_uuid: null, column: null, status: 'in_progress', notify: true, gone_after_minutes: 10, max_new_per_heartbeat: 20,
    idle_statuses: ['idle', 'done', 'finished', 'stopped', 'exited', 'ended', 'completed', 'closed', 'inactive'],
    tool_labels: { claude: 'Claude', cursor: 'Cursor' },
  },
  safety: { extra_denied_commands: [], extra_redactions: [] },
};

const KANBAN_STATUSES: { value: KanbanStatus; label: string }[] = [
  { value: 'open', label: 'Open' },
  { value: 'in_progress', label: 'In progress' },
  { value: 'blocked', label: 'Blocked' },
  { value: 'review', label: 'Review' },
  { value: 'completed', label: 'Completed' },
  { value: 'cancelled', label: 'Cancelled' },
];

const isObject = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);

/** The server's settings over the defaults; task automation from on_start / on_success, else the old booleans (§27.4). */
function normalize(d: Partial<Settings>, base: Settings = DEFAULTS): Settings {
  const ta = (isObject(d.task_automation) ? d.task_automation : {}) as Partial<Settings['task_automation']>;
  const st = { ...base.session_tracking, ...d.session_tracking };
  const sf = { ...base.safety, ...d.safety };
  return {
    ...base, ...d,
    task_automation: {
      on_start: { ...base.task_automation.on_start, ...(ta.on_start ?? (ta.in_progress_on_start != null && { enabled: ta.in_progress_on_start })) },
      on_success: { ...base.task_automation.on_success, ...(ta.on_success ?? (ta.review_on_success != null && { enabled: ta.review_on_success })) },
    },
    approval_policy: { ...base.approval_policy, ...d.approval_policy },
    guards: { ...base.guards, ...d.guards },
    // An empty Lua table arrives as {} or [] whatever it was.
    session_tracking: { ...st, idle_statuses: strings(st.idle_statuses), tool_labels: isObject(st.tool_labels) ? st.tool_labels as Record<string, string> : {} },
    safety: { extra_denied_commands: strings(sf.extra_denied_commands), extra_redactions: strings(sf.extra_redactions) },
  };
}

/** Why a redaction pattern can't be used (the server checks it again as PCRE), or null. */
function regexError(p: string): string | null {
  if (new TextEncoder().encode(p).length > 200) return 'At most 200 characters.';
  try {
    if (new RegExp(p).test('')) return 'It must not match empty text: make it match at least one character.';
    return null;
  } catch (e) {
    return `Not a valid regular expression: ${(e as Error).message}`;
  }
}

function RunSettings() {
  const loaded = useAiData(() => aiRunner.getSettings(), []);
  const [s, setS] = useState<Settings | null>(null);
  const lim = s?.limits;
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    if (loaded.data) setS(normalize(loaded.data));
  }, [loaded.data]);

  if (!s) return loaded.error ? <ErrorNote error={loaded.error} product={PRODUCT} /> : <Spinner />;
  const set = (patch: Partial<Settings>) => setS({ ...s, ...patch });
  const g = s.guards;
  const guard = (patch: Partial<Settings['guards']>) => set({ guards: { ...g, ...patch } });
  const move = (k: 'on_start' | 'on_success', patch: Partial<TaskMove>) =>
    set({ task_automation: { ...s.task_automation, [k]: { ...s.task_automation[k], ...patch } } });
  const safety = (patch: Partial<Settings['safety']>) => set({ safety: { ...s.safety, ...patch } });

  async function save(e: React.FormEvent) {
    e.preventDefault();
    if (!s) return;
    const bad = s.safety.extra_redactions.map(regexError).find(Boolean)
      || (!s.session_tracking.idle_statuses.length && 'Name at least one idle status.');
    if (bad) { toast.error(bad); return; }
    setBusy(true);
    try {
      // Only the new task automation shape: the old booleans would say something else.
      const saved = await aiRunner.saveSettings({ ...s, task_automation: { on_start: s.task_automation.on_start, on_success: s.task_automation.on_success } });
      if (saved) setS(normalize(saved, s));
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
          <Input id="air-s-minutes" label="Max run minutes" type="number" min={1} max={lim?.max_run_minutes ?? 1440} required value={s.max_run_minutes || ''}
            onChange={(e) => set({ max_run_minutes: Number(e.target.value) || 0 })} helperText="A run still going after this is stopped." />
        </div>
        <Toggle label="Open pull requests as drafts" checked={s.pr_draft} onChange={(v) => set({ pr_draft: v })} />

        <div className="space-y-3 border-t border-secondary-200 pt-4">
          <h3 className="text-sm font-semibold text-secondary-800">Task automation</h3>
          <TaskMoveFields id="air-s-on-start" label="When a run starts, move its task" move={s.task_automation.on_start} onChange={(p) => move('on_start', p)} />
          <TaskMoveFields id="air-s-on-success" label="When a run succeeds, move its task" move={s.task_automation.on_success} onChange={(p) => move('on_success', p)} />
        </div>

        <div className="space-y-3 border-t border-secondary-200 pt-4">
          <h3 className="text-sm font-semibold text-secondary-800">Approval policy</h3>
          <p className="text-xs text-secondary-500">
            An agent asks before risky steps, such as running a command. Profiles that can&apos;t ask (Cursor) always need a manager&apos;s approval to start.
            Managers are people with manage on AI runs or AI run approvals. Nobody approves the start of a run they asked for themselves.
          </p>
          <div className="max-w-sm">
            <Select id="air-s-deciders" label="Who decides permission requests" value={s.approval_policy.deciders}
              helperText={s.approval_policy.deciders === 'managers' ? "A manager who started a run doesn't decide its requests: another manager does." : undefined}
              onChange={(e) => set({ approval_policy: { ...s.approval_policy, deciders: e.target.value as Settings['approval_policy']['deciders'] } })}>
              <option value="managers">Managers</option>
              <option value="requester">The person who started the run</option>
              <option value="requester_or_managers">The requester or a manager</option>
            </Select>
          </div>
          <Toggle label="Project owners and admins can also decide" checked={s.approval_policy.project_admins_decide}
            hint="Owners and admins of a task's project count as managers for runs on that project's tasks: they approve starts and, when managers decide, answer permission requests. Off: only AI-run managers do."
            onChange={(v) => set({ approval_policy: { ...s.approval_policy, project_admins_decide: v } })} />
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
            <Input id="air-s-user-cap" label="Max open runs per person" type="number" min={0} max={lim?.guards.max_open_runs_per_user ?? 100} required
              value={shown(g.max_open_runs_per_user)} onChange={(e) => guard({ max_open_runs_per_user: typed(e.target.value) })}
              helperText="Runs one person may have open at once (0–100)." />
            <Input id="air-s-ws-cap" label="Max open runs in the workspace" type="number" min={0} max={lim?.guards.max_open_runs_per_workspace ?? 1000} required
              value={shown(g.max_open_runs_per_workspace)} onChange={(e) => guard({ max_open_runs_per_workspace: typed(e.target.value) })}
              helperText="Runs open at once across the workspace (0–1000). Approving a waiting run is never blocked." />
            <Input id="air-s-tokens" label="Daily token limit" type="number" min={0} max={lim?.guards.daily_token_limit ?? 1_000_000_000} required
              value={shown(g.daily_token_limit)} onChange={(e) => guard({ daily_token_limit: typed(e.target.value) })}
              helperText="Agent tokens (in + out) per day, UTC. At the limit no new run starts; running ones finish." />
            <Input id="air-s-retention" label="Keep run logs (days)" type="number" min={30} max={lim?.guards.retention_days ?? 3650} required
              value={shown(g.retention_days)} onChange={(e) => guard({ retention_days: typed(e.target.value) })}
              helperText="30–3650. After this, a finished run's log, conversation text and request details are deleted; the run, its summary and usage stay." />
          </div>
        </div>

        <div className="space-y-3 border-t border-secondary-200 pt-4">
          <h3 className="text-sm font-semibold text-secondary-800">Safety</h3>
          <p className="text-xs text-secondary-500">
            Add to the built-in rules: runners always block risky commands (git push, sudo, reading secrets, anything outside the run&apos;s
            folder), and the server always masks tokens, keys and passwords. The built-in rules can&apos;t be removed or loosened here.
          </p>
          <div className="grid gap-4 sm:grid-cols-2">
            <TagsInput id="air-s-denied" label="Extra denied commands" values={s.safety.extra_denied_commands}
              onChange={(v) => safety({ extra_denied_commands: v })} placeholder="terraform apply"
              hint="A command prefix or glob, such as kubectl delete or rm -rf *. Runners deny it like their built-in list." />
            <TagsInput id="air-s-redact" label="Extra redactions" values={s.safety.extra_redactions} check={regexError}
              onChange={(v) => safety({ extra_redactions: v })} placeholder="ACME-[0-9]{6}"
              hint="Regular expressions. Matching text is masked in logs, prompts and conversations the server stores." />
          </div>
        </div>

        <SessionTrackingFields t={s.session_tracking} maxPerHeartbeat={lim?.max_new_per_heartbeat ?? 100} onChange={(patch) => set({ session_tracking: { ...s.session_tracking, ...patch } })} />

        <div className="flex justify-end">
          <Button type="submit" isLoading={busy}>Save settings</Button>
        </div>
      </form>
    </Card>
  );
}

/** Move the run's task to a status (and optionally a column) when a run starts or succeeds (§27.4). */
function TaskMoveFields({ id, label, move, onChange }: { id: string; label: string; move: TaskMove; onChange: (p: Partial<TaskMove>) => void }) {
  return (
    <div className="space-y-2">
      <Toggle label={label} checked={move.enabled} onChange={(v) => onChange({ enabled: v })} />
      {move.enabled && (
        <div className="grid gap-4 sm:grid-cols-2">
          <Select id={`${id}-status`} label="Status" value={move.status} onChange={(e) => onChange({ status: e.target.value as KanbanStatus })}>
            {KANBAN_STATUSES.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
          </Select>
          <Input id={`${id}-column`} label="Column (optional)" value={move.column || ''} placeholder="Leave the column as it is"
            onChange={(e) => onChange({ column: e.target.value.trim() ? e.target.value : null })}
            helperText="A column name on the task's board. Tasks on boards without it keep their column." />
        </div>
      )}
    </div>
  );
}

/** tool → label rows (§27.4); rows with no tool name are left out. */
function ToolLabels({ labels, onChange }: { labels: Record<string, string>; onChange: (v: Record<string, string>) => void }) {
  const [rows, setRows] = useState<[string, string][]>(() => Object.entries(labels));
  const update = (next: [string, string][]) => {
    setRows(next);
    onChange(Object.fromEntries(next.filter(([k]) => k.trim()).map(([k, v]) => [k.trim(), v])));
  };
  return (
    <fieldset className="min-w-0 space-y-2">
      <legend className="text-sm font-medium text-secondary-700">Tool names</legend>
      <p className="text-xs text-secondary-500">How each tool is named in task titles and {'{{tool_label}}'}; others use the tool as reported.</p>
      {rows.map(([k, v], i) => (
        <div key={i} className="flex items-center gap-2">
          <Input aria-label={`Tool ${i + 1}`} placeholder="claude" value={k} className="font-mono"
            onChange={(e) => update(rows.map((r, j) => (j === i ? [e.target.value, r[1]] : r)))} />
          <Input aria-label={`Label of tool ${i + 1}`} placeholder="Claude" value={v}
            onChange={(e) => update(rows.map((r, j) => (j === i ? [r[0], e.target.value] : r)))} />
          <Button type="button" size="sm" variant="ghost" aria-label={`Remove tool ${k || i + 1}`} onClick={() => update(rows.filter((_, j) => j !== i))}>
            <Trash2 className="h-4 w-4" aria-hidden />
          </Button>
        </div>
      ))}
      <Button type="button" size="sm" variant="outline" leftIcon={<Plus className="h-4 w-4" aria-hidden />} onClick={() => setRows([...rows, ['', '']])}>
        Add a tool
      </Button>
    </fieldset>
  );
}

/**
 * §26: a session someone starts by hand on a runner's machine becomes a kanban task — where it goes when no routing
 * rule matches (§27.3), and the §27.4 tunables. Saved with the form above.
 */
function SessionTrackingFields({ t, maxPerHeartbeat, onChange }: { t: SessionTracking; maxPerHeartbeat: number; onChange: (patch: Partial<SessionTracking>) => void }) {
  const projects = useProjects();
  return (
    <div className="space-y-3 border-t border-secondary-200 pt-4">
      <h3 className="text-sm font-semibold text-secondary-800">Track sessions started by hand</h3>
      <p className="text-xs text-secondary-500">
        When someone starts Claude Code or Cursor by hand on a runner&apos;s machine, OpsAPI creates a task for the session.
        Routing rules (below) decide first; a session no rule matches goes to this project.
        The task has no assignee, so a manager can assign it like any other. Runs started from OpsAPI already have a task.
        The task takes its title from the session&apos;s first prompt only when the runner&apos;s config has{' '}
        <code className="font-mono">share_manual_prompts: true</code>; otherwise it is named after the tool, folder and machine.
        The runner reports sessions in its allowed folders; add <code className="font-mono">inventory_roots</code> to its config to see
        more (<code className="font-mono">[&quot;~&quot;]</code> for every session on the machine).
      </p>
      <Toggle label="Create a task for each session started by hand" checked={t.enabled} onChange={(v) => onChange({ enabled: v })} />
      <div className="grid gap-4 sm:grid-cols-3">
        <ProjectSelect id="air-s-track-project" required={t.enabled} value={t.project_uuid} projects={projects}
          onChange={(uuid) => onChange({ project_uuid: uuid, column: null })} />
        <ColumnField id="air-s-track-column" projectUuid={t.project_uuid} value={t.column} onChange={(column) => onChange({ column })} />
        <Select id="air-s-track-status" label="Task status" value={t.status}
          onChange={(e) => onChange({ status: e.target.value as SessionTracking['status'] })}>
          <option value="in_progress">In progress</option>
          <option value="todo">To do</option>
        </Select>
      </div>
      <Toggle label="Tell managers about each new task" hint="A notification with a link to the task." checked={t.notify}
        onChange={(v) => onChange({ notify: v })} />
      <div className="grid gap-4 sm:grid-cols-2">
        <Input id="air-s-gone" label="Ended after (minutes)" type="number" min={1} max={1440} required value={shown(t.gone_after_minutes)}
          onChange={(e) => onChange({ gone_after_minutes: typed(e.target.value) })}
          helperText="1–1440. A tracked session nobody reports for this long has ended; its task gets a comment." />
        <Input id="air-s-per-heartbeat" label="New tasks per heartbeat" type="number" min={1} max={maxPerHeartbeat} required value={shown(t.max_new_per_heartbeat)}
          onChange={(e) => onChange({ max_new_per_heartbeat: typed(e.target.value) })}
          helperText="1–100 (the platform may cap it lower). More new sessions than this wait for the machine's next report." />
        <TagsInput id="air-s-idle" label="Idle statuses" values={t.idle_statuses} onChange={(v) => onChange({ idle_statuses: v })} placeholder="idle"
          hint="Sessions reporting one of these don't count as busy, so they never become tasks." />
        <ToolLabels labels={t.tool_labels} onChange={(v) => onChange({ tool_labels: v })} />
      </div>
    </div>
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

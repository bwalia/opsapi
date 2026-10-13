'use client';

/**
 * Routing rules for sessions started by hand (docs/AI_RUNNER.md §27.3, ai_runs_settings.manage): an ordered list,
 * the first enabled rule that matches a session decides — a task (project, column, status, priority, assignees,
 * title / description templates, who hears) or nothing. Sessions no rule matches use the workspace default (Track
 * sessions started by hand). "Test a session" asks the server which rule a sample session meets; nothing is created.
 */
import React, { useState } from 'react';
import { ArrowDown, ArrowUp, FlaskConical, Pencil, Plus, Route, Trash2 } from 'lucide-react';
import toast from 'react-hot-toast';
import { Badge, Button, Card, ConfirmDialog, Input, Modal, Select, Switch, Textarea } from '@/components/ui';
import { ErrorNote } from '@/components/property-deals/ui';
import { PRODUCT, useAiData } from '@/components/ai-runner/ui';
import {
  CheckList, ColumnField, ProjectSelect, TagsInput, Toggle, strings, useMembers, useProjects, type Choice,
} from '@/components/ai-runner/fields';
import {
  aiRunner, aiErrorText, type SampleSession, type TaskPriority, type TrackNotify, type TrackRule, type TrackRuleAction,
  type TrackRuleInput, type TrackRuleTest,
} from '@/services/ai-runner.service';

const EMPTY: TrackRuleInput = {
  name: '',
  enabled: true,
  match: { runner_uuids: [], tools: [], folder_globs: [], branch_globs: [], prompt_keywords: [] },
  action: {
    type: 'create_task', project_uuid: null, column: null, status: 'in_progress', priority: null, assignee_uuids: [],
    title_template: '', description_template: '', notify: 'managers', notify_user_uuids: [],
  },
};

/** A rule as the server sent it, with every field present (an empty Lua table arrives as {} rather than []). */
function normalize(r: Partial<TrackRule>): TrackRuleInput {
  const m = r.match || ({} as Partial<TrackRule['match']>);
  const a = r.action || ({} as Partial<TrackRuleAction>);
  return {
    name: r.name || '',
    enabled: r.enabled !== false,
    match: {
      runner_uuids: strings(m.runner_uuids), tools: strings(m.tools), folder_globs: strings(m.folder_globs),
      branch_globs: strings(m.branch_globs), prompt_keywords: strings(m.prompt_keywords),
    },
    action: {
      ...EMPTY.action, ...a,
      assignee_uuids: strings(a.assignee_uuids), notify_user_uuids: strings(a.notify_user_uuids),
      title_template: a.title_template || '', description_template: a.description_template || '',
    },
  };
}

const PRIORITIES: { value: TaskPriority; label: string }[] = [
  { value: 'critical', label: 'Critical' }, { value: 'high', label: 'High' }, { value: 'medium', label: 'Medium' },
  { value: 'low', label: 'Low' }, { value: 'none', label: 'None' },
];
const NOTIFY: { value: TrackNotify; label: string }[] = [
  { value: 'managers', label: 'AI-run managers' },
  { value: 'assignees', label: 'The assignees' },
  { value: 'users', label: 'These people' },
  { value: 'none', label: 'Nobody' },
];
export const TEMPLATE_VARIABLES: [string, string][] = [
  ['{{first_prompt}}', "the session's first prompt (when the runner shares prompts)"],
  ['{{prompt_preview}}', 'its latest prompt, short'],
  ['{{tool}}', 'the tool as reported (claude)'],
  ['{{tool_label}}', 'its name (Claude)'],
  ['{{folder}}', "the session's folder"],
  ['{{repo}}', "the folder's name (its last part)"],
  ['{{branch}}', 'the branch'],
  ['{{runner}}', 'the machine (runner or source)'],
  ['{{started}}', 'when it started'],
  ['{{session_id}}', 'the session id'],
];

const quote = (v: string[]) => v.map((x) => `"${x}"`).join(' or ');
const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

/** "Tool "claude" · folder "~/work/**"" — what a rule matches. */
function matchText(m: TrackRuleInput['match'], runnerName: (uuid: string) => string): string {
  const parts = [
    m.runner_uuids.length ? `on ${m.runner_uuids.map(runnerName).join(' or ')}` : '',
    m.tools.length ? `tool ${quote(m.tools)}` : '',
    m.folder_globs.length ? `folder ${quote(m.folder_globs)}` : '',
    m.branch_globs.length ? `branch ${quote(m.branch_globs)}` : '',
    m.prompt_keywords.length ? `prompt mentions ${quote(m.prompt_keywords)}` : '',
  ].filter(Boolean);
  return parts.length ? `Sessions ${parts.join(' · ')}` : 'Every session';
}

/** "Task in Website · In progress · 2 assignees · notifies managers" — what a rule does. */
function actionText(a: TrackRuleAction, projectName: (uuid: string) => string): string {
  if (a.type === 'ignore') return 'Ignore: no task';
  return [
    `Task in ${a.project_uuid ? projectName(a.project_uuid) : 'no project'}`,
    a.column || 'first column',
    a.status === 'todo' ? 'To do' : 'In progress',
    a.priority && `${PRIORITIES.find((p) => p.value === a.priority)?.label || a.priority} priority`,
    a.assignee_uuids.length ? plural(a.assignee_uuids.length, 'assignee', 'assignees') : 'unassigned',
    a.notify === 'none' ? 'no notification'
      : `notifies ${a.notify === 'users' ? plural(a.notify_user_uuids.length, 'person', 'people') : NOTIFY.find((n) => n.value === a.notify)?.label.toLowerCase()}`,
  ].filter(Boolean).join(' · ');
}

const nameFrom = (choices: Choice[], fallback: string) => (uuid: string) => choices.find((c) => c.value === uuid)?.label || fallback;

export function TrackRules() {
  const rules = useAiData(() => aiRunner.listTrackRules(), []);
  const runners = useAiData(() => aiRunner.listRunners(), []);
  const projects = useProjects();
  const members = useMembers();
  const [editing, setEditing] = useState<TrackRule | 'new' | null>(null);
  const [deleting, setDeleting] = useState<TrackRule | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

  const list = [...(rules.data || [])].sort((a, b) => (a.position ?? 0) - (b.position ?? 0));
  const runnerChoices: Choice[] = (runners.data || []).map((r) => ({ value: r.uuid, label: r.name, hint: r.kind === 'source' ? 'Source' : undefined }));
  const runnerName = nameFrom(runnerChoices, 'a removed runner');
  const projectName = nameFrom(projects.choices, 'a project you can’t see');

  async function act(key: string, fn: () => Promise<unknown>, ok?: string) {
    setBusy(key);
    try {
      await fn();
      if (ok) toast.success(ok);
    } catch (e) {
      toast.error(aiErrorText(e));
    } finally {
      setBusy(null);
      rules.refresh();
    }
  }
  const moveRule = (i: number, by: -1 | 1) => {
    const uuids = list.map((r) => r.uuid);
    [uuids[i], uuids[i + by]] = [uuids[i + by], uuids[i]];
    return act(`move:${list[i].uuid}`, () => aiRunner.orderTrackRules(uuids));
  };

  return (
    <Card>
      <section aria-labelledby="air-rules-title" className="space-y-4">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="min-w-0">
            <h2 id="air-rules-title" className="flex items-center gap-2 text-lg font-semibold text-secondary-900">
              <Route className="h-5 w-5" aria-hidden /> Routing rules
            </h2>
            <p className="mt-1 max-w-3xl text-sm text-secondary-600">
              Where the task for each session started by hand goes. Rules are checked from the top; the first enabled rule that matches
              decides, and a session no rule matches uses <span className="font-medium">Track sessions started by hand</span> above.
            </p>
          </div>
          <Button leftIcon={<Plus className="h-4 w-4" aria-hidden />} onClick={() => setEditing('new')}>Add rule</Button>
        </div>
        <ErrorNote error={rules.error} product={PRODUCT} />
        {rules.loading && !rules.data && <p className="text-sm text-secondary-500">Loading rules…</p>}
        {rules.data && !list.length && (
          <p className="rounded-lg border border-dashed border-secondary-300 p-4 text-center text-sm text-secondary-500">
            No rules yet: every session goes to the default above.
          </p>
        )}
        {list.length > 0 && (
          <ol className="space-y-2" data-testid="air-rules">
            {list.map((rule, i) => {
              const r = normalize(rule);
              const n = i + 1;
              return (
                <li key={rule.uuid} data-testid="air-rule" className="flex flex-col gap-3 rounded-lg border border-secondary-200 p-3 sm:flex-row sm:items-center">
                  <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-secondary-100 text-sm font-semibold text-secondary-700" aria-hidden>{n}</span>
                  <div className={`min-w-0 flex-1 text-sm ${r.enabled ? '' : 'opacity-60'}`}>
                    {r.name && <p className="break-words font-semibold text-secondary-900">{r.name}</p>}
                    <p className={`break-words ${r.name ? 'text-secondary-700' : 'font-medium text-secondary-900'}`}>{matchText(r.match, runnerName)}</p>
                    <p className="mt-0.5 break-words text-secondary-600">
                      <Badge size="sm" variant={r.action.type === 'ignore' ? 'secondary' : 'info'}>{r.action.type === 'ignore' ? 'Ignore' : 'Create task'}</Badge>{' '}
                      {r.action.type === 'ignore' ? 'No task is created' : actionText(r.action, projectName)}
                      {!r.enabled && <> <Badge size="sm" variant="warning">Off</Badge></>}
                    </p>
                  </div>
                  <div className="flex shrink-0 flex-wrap items-center gap-1">
                    <Switch checked={r.enabled} aria-label={`Rule ${n} enabled`} disabled={!!busy}
                      onChange={(v) => act(`enable:${rule.uuid}`, () => aiRunner.updateTrackRule(rule.uuid, { enabled: v }), v ? `Rule ${n} on` : `Rule ${n} off`)} />
                    <Button size="sm" variant="ghost" aria-label={`Move rule ${n} up`} disabled={i === 0 || !!busy} onClick={() => moveRule(i, -1)}>
                      <ArrowUp className="h-4 w-4" aria-hidden />
                    </Button>
                    <Button size="sm" variant="ghost" aria-label={`Move rule ${n} down`} disabled={i === list.length - 1 || !!busy} onClick={() => moveRule(i, 1)}>
                      <ArrowDown className="h-4 w-4" aria-hidden />
                    </Button>
                    <Button size="sm" variant="ghost" aria-label={`Edit rule ${n}`} leftIcon={<Pencil className="h-4 w-4" aria-hidden />} onClick={() => setEditing(rule)}>Edit</Button>
                    <Button size="sm" variant="ghost" className="text-error-600" aria-label={`Delete rule ${n}`} onClick={() => setDeleting(rule)}>
                      <Trash2 className="h-4 w-4" aria-hidden />
                    </Button>
                  </div>
                </li>
              );
            })}
          </ol>
        )}

        <RuleTester rules={list} runners={runnerChoices} describe={(rule) => actionText(normalize(rule).action, projectName)} />
      </section>

      {editing && (
        <RuleModal rule={editing === 'new' ? null : editing} runners={runnerChoices} runnersLoading={runners.loading}
          projects={projects} members={members} onClose={() => setEditing(null)} onSaved={rules.refresh} />
      )}
      <ConfirmDialog
        isOpen={!!deleting}
        onClose={() => setDeleting(null)}
        onConfirm={async () => {
          if (deleting) await act(`delete:${deleting.uuid}`, () => aiRunner.deleteTrackRule(deleting.uuid), 'Rule deleted');
          setDeleting(null);
        }}
        title="Delete this rule?"
        message={deleting ? `${matchText(normalize(deleting).match, runnerName)}: ${actionText(normalize(deleting).action, projectName)}. Tasks it already created stay.` : ''}
        confirmText="Delete rule"
        variant="danger"
        isLoading={!!busy && busy.startsWith('delete:')}
      />
    </Card>
  );
}

function Variables() {
  return (
    <details className="text-xs text-secondary-600">
      <summary className="cursor-pointer font-medium text-secondary-700">Variables</summary>
      <ul className="mt-1 grid gap-x-6 gap-y-1 sm:grid-cols-2">
        {TEMPLATE_VARIABLES.map(([v, what]) => <li key={v}><code className="font-mono text-secondary-800">{v}</code> — {what}</li>)}
      </ul>
      <p className="mt-1">Unknown variables render empty, and a line whose variables are all empty is left out.</p>
    </details>
  );
}

/** Create or edit a rule: when it applies, then what it does. */
function RuleModal({ rule, runners, runnersLoading, projects, members, onClose, onSaved }: {
  rule: TrackRule | null; runners: Choice[]; runnersLoading: boolean; projects: ReturnType<typeof useProjects>;
  members: ReturnType<typeof useMembers>; onClose: () => void; onSaved: () => void;
}) {
  const [r, setR] = useState<TrackRuleInput>(() => (rule ? normalize(rule) : EMPTY));
  const [busy, setBusy] = useState(false);
  const m = r.match;
  const a = r.action;
  const match = (patch: Partial<TrackRuleInput['match']>) => setR({ ...r, match: { ...m, ...patch } });
  const action = (patch: Partial<TrackRuleAction>) => setR({ ...r, action: { ...a, ...patch } });
  const peopleError = members.error && "Can't load the workspace's members.";

  async function save(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    try {
      if (rule) await aiRunner.updateTrackRule(rule.uuid, r);
      else await aiRunner.createTrackRule(r);
      toast.success(rule ? 'Rule saved' : 'Rule added');
      onSaved();
      onClose();
    } catch (err) {
      toast.error(aiErrorText(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal isOpen onClose={onClose} size="3xl" title={rule ? 'Edit rule' : 'Add a rule'}
      description="Empty fields match any session. A session must fit every field you fill in (any one value per field).">
      <form onSubmit={save} className="space-y-5">
        <div className="max-w-md">
          <Input id="air-rule-name" label="Name (optional)" value={r.name || ''} maxLength={100} placeholder="Shop repo to the Shop board"
            onChange={(e) => setR({ ...r, name: e.target.value })} />
        </div>
        <fieldset className="min-w-0 space-y-3">
          <legend className="text-sm font-semibold text-secondary-900">When a session</legend>
          <div className="grid gap-4 sm:grid-cols-2">
            <TagsInput id="air-rule-tools" label="Tool is" values={m.tools} onChange={(tools) => match({ tools })} placeholder="claude"
              hint="Tool names as reported (claude, cursor, codex…)." />
            <TagsInput id="air-rule-folders" label="Folder matches" values={m.folder_globs} onChange={(folder_globs) => match({ folder_globs })}
              placeholder="~/work/shop/**" hint="Globs on the session's folder." />
            <TagsInput id="air-rule-branches" label="Branch matches" values={m.branch_globs} onChange={(branch_globs) => match({ branch_globs })}
              placeholder="feature/*" hint="Globs on the git branch." />
            <TagsInput id="air-rule-keywords" label="First prompt mentions" values={m.prompt_keywords} mono={false}
              onChange={(prompt_keywords) => match({ prompt_keywords })} placeholder="invoice"
              hint="Words in the first prompt (only when the runner shares prompts)." />
          </div>
          <CheckList legend="Runs on" items={runners} picked={m.runner_uuids} onChange={(runner_uuids) => match({ runner_uuids })}
            loading={runnersLoading} hint="Runners and sources. None picked: any." />
        </fieldset>

        <fieldset className="min-w-0 space-y-3 border-t border-secondary-200 pt-4">
          <legend className="sr-only">Then</legend>
          <p className="text-sm font-semibold text-secondary-900" aria-hidden>Then</p>
          <div className="flex flex-wrap gap-x-6 gap-y-2">
            {([['create_task', 'Create a task'], ['ignore', "Ignore it (no task)"]] as const).map(([v, label]) => (
              <label key={v} className="flex items-center gap-2 text-sm">
                <input type="radio" name="air-rule-type" value={v} checked={a.type === v} onChange={() => action({ type: v })} /> {label}
              </label>
            ))}
          </div>
          {a.type === 'create_task' && (
            <>
              <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
                <ProjectSelect id="air-rule-project" required value={a.project_uuid} projects={projects}
                  onChange={(project_uuid) => action({ project_uuid, column: null })} />
                <ColumnField id="air-rule-column" projectUuid={a.project_uuid} value={a.column} onChange={(column) => action({ column })} />
                <Select id="air-rule-status" label="Status" value={a.status} onChange={(e) => action({ status: e.target.value as TrackRuleAction['status'] })}>
                  <option value="in_progress">In progress</option>
                  <option value="todo">To do</option>
                </Select>
                <Select id="air-rule-priority" label="Priority" value={a.priority || ''} onChange={(e) => action({ priority: (e.target.value || null) as TaskPriority | null })}>
                  <option value="">Project default</option>
                  {PRIORITIES.map((p) => <option key={p.value} value={p.value}>{p.label}</option>)}
                </Select>
              </div>
              <CheckList legend="Assign to" items={members.choices} picked={a.assignee_uuids} onChange={(assignee_uuids) => action({ assignee_uuids })}
                loading={members.loading} error={peopleError || undefined} hint="Active members. None picked: unassigned, for a manager to assign." />
              <Input id="air-rule-title" label="Title" value={a.title_template} onChange={(e) => action({ title_template: e.target.value })}
                placeholder="{{tool_label}}: {{first_prompt}}" maxLength={500}
                helperText="Empty: the first line of the first prompt, else “<Tool> session in <folder> on <machine>”." />
              <Textarea id="air-rule-description" label="Description" rows={4} value={a.description_template} maxLength={5000}
                onChange={(e) => action({ description_template: e.target.value })} placeholder="Started by hand on {{runner}} in {{folder}} ({{branch}})."
                helperText="Empty: who started it where, with the tool, folder, branch, start time, session id and first prompt." />
              <Variables />
              <div className="grid gap-4 sm:grid-cols-2">
                <Select id="air-rule-notify" label="Tell" value={a.notify} onChange={(e) => action({ notify: e.target.value as TrackNotify })}>
                  {NOTIFY.map((n) => <option key={n.value} value={n.value}>{n.label}</option>)}
                </Select>
              </div>
              {a.notify === 'users' && (
                <CheckList legend="People to tell" items={members.choices} picked={a.notify_user_uuids}
                  onChange={(notify_user_uuids) => action({ notify_user_uuids })} loading={members.loading} error={peopleError || undefined} />
              )}
            </>
          )}
        </fieldset>

        <div className="border-t border-secondary-200 pt-4">
          <Toggle label="Rule on" hint="An off rule is skipped." checked={r.enabled} onChange={(enabled) => setR({ ...r, enabled })} />
        </div>
        <div className="flex justify-end gap-2">
          <Button type="button" variant="ghost" onClick={onClose}>Cancel</Button>
          <Button type="submit" isLoading={busy}>{rule ? 'Save rule' : 'Add rule'}</Button>
        </div>
      </form>
    </Modal>
  );
}

/** A sample session → the rule it meets and the task it would make (POST /track-rules/test; nothing is created). */
function RuleTester({ rules, runners, describe }: { rules: TrackRule[]; runners: Choice[]; describe: (r: TrackRule) => string }) {
  const [sample, setSample] = useState<Required<SampleSession>>({ tool: 'claude', cwd: '', branch: '', first_prompt: '', runner_uuid: '' });
  const [result, setResult] = useState<TrackRuleTest | null>(null);
  const [busy, setBusy] = useState(false);
  const set = (patch: Partial<SampleSession>) => setSample({ ...sample, ...patch });

  async function test(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    try {
      // Only what was filled in.
      const session = Object.fromEntries(Object.entries(sample).filter(([, v]) => v.trim())) as SampleSession;
      setResult(await aiRunner.testTrackRules(session));
    } catch (err) {
      setResult(null);
      toast.error(aiErrorText(err));
    } finally {
      setBusy(false);
    }
  }

  const matched = result?.rule ? rules.findIndex((r) => r.uuid === result.rule?.uuid) : -1;
  const action = result?.action;
  return (
    <form onSubmit={test} className="space-y-3 rounded-lg bg-secondary-50 p-4" aria-labelledby="air-test-title">
      <h3 id="air-test-title" className="flex items-center gap-2 text-sm font-semibold text-secondary-800">
        <FlaskConical className="h-4 w-4" aria-hidden /> Test a session
      </h3>
      <p className="text-xs text-secondary-500">
        See which rule a session would meet and the task it would create, as if tracking were on. Nothing is created.
      </p>
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Input id="air-t-tool" label="Tool" value={sample.tool} onChange={(e) => set({ tool: e.target.value })} className="font-mono" />
        <Input id="air-t-cwd" label="Folder" value={sample.cwd} onChange={(e) => set({ cwd: e.target.value })} placeholder="/Users/me/work/shop" className="font-mono" />
        <Input id="air-t-branch" label="Branch" value={sample.branch} onChange={(e) => set({ branch: e.target.value })} placeholder="main" className="font-mono" />
        <Select id="air-t-runner" label="Runner or source" value={sample.runner_uuid} onChange={(e) => set({ runner_uuid: e.target.value })}>
          <option value="">Any</option>
          {runners.map((r) => <option key={r.value} value={r.value}>{r.label}</option>)}
        </Select>
      </div>
      <Textarea id="air-t-prompt" label="First prompt" rows={2} value={sample.first_prompt} onChange={(e) => set({ first_prompt: e.target.value })}
        placeholder="Fix the invoice rounding bug" />
      <div className="flex justify-end">
        <Button type="submit" variant="outline" isLoading={busy}>Test</Button>
      </div>
      <div aria-live="polite">
        {result && (
          <div data-testid="air-rule-test-result" className="space-y-2 rounded-lg border border-secondary-200 bg-surface p-3 text-sm">
            <p className="font-medium text-secondary-900">
              {result.rule
                ? `${matched >= 0 ? `Rule ${matched + 1}` : 'A rule'}${result.rule.name ? ` (${result.rule.name})` : ''} matches`
                : 'No rule matches: the default (Track sessions started by hand) applies'}
            </p>
            {result.rule && <p className="text-secondary-600">{describe(result.rule)}</p>}
            {!action || action.type === 'ignore' ? (
              <p className="text-secondary-600">Ignored: no task is created.</p>
            ) : (
              <dl className="grid gap-x-4 gap-y-1 sm:grid-cols-[7rem_minmax(0,1fr)]">
                <dt className="text-xs font-medium uppercase tracking-wide text-secondary-500 sm:pt-0.5">Title</dt>
                <dd className="min-w-0 break-words text-secondary-900" data-testid="air-rule-test-title">{result.title || '—'}</dd>
                <dt className="text-xs font-medium uppercase tracking-wide text-secondary-500 sm:pt-0.5">Description</dt>
                <dd className="min-w-0">
                  <pre className="max-h-48 overflow-auto whitespace-pre-wrap break-words font-sans text-secondary-700">{result.description || '—'}</pre>
                </dd>
              </dl>
            )}
          </div>
        )}
      </div>
    </form>
  );
}

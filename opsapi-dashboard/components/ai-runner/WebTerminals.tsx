'use client';

/**
 * Web terminals (docs/AI_RUNNER_WEB_TERMINAL.md, ai_runners.manage): connect a workstation-terminal so people can
 * open a task's folder there from Start with AI. Add (the shared secret and the terminal's config block are shown
 * once), edit the name, address and agents, switch off, rotate the secret, remove, and People: the keys managers
 * issue (§10). Each card says whether the terminal is in touch, and what to do when it isn't (§12).
 */
import React, { useState } from 'react';
import toast from 'react-hot-toast';
import {
  CheckCircle2, ChevronDown, Clock, KeyRound, Pencil, Plus, ShieldAlert, Terminal, Trash2, Users, WifiOff, X,
} from 'lucide-react';
import { Badge, Button, Card, Input, Modal, confirmDialog } from '@/components/ui';
import { ErrorNote } from '@/components/property-deals/ui';
import {
  aiRunner, aiErrorText, type TerminalAgent, type TerminalConnection, type WebTerminal,
} from '@/services/ai-runner.service';
import { TerminalPeople } from './TerminalPeople';
import { CopyBlock, PRODUCT, opsapiUrl, useAiData } from './ui';

// What the terminal runs for the default agents; the terminal's own config decides (shown in the config block).
const RUN_LINES: Record<string, string> = {
  claude: 'claude "$OPSAPI_TASK_PROMPT"',
  // Never stops to ask: only acceptable because the terminal runs under its own macOS account.
  claude_auto: 'claude --dangerously-skip-permissions "$OPSAPI_TASK_PROMPT"',
  codex: 'codex "$OPSAPI_TASK_PROMPT"',
  cursor: 'cursor-agent "$OPSAPI_TASK_PROMPT"',
};

/** The block to paste into the terminal's config.yaml. */
function configBlock(terminal: WebTerminal, secret: string): string {
  const { agents, autologin } = terminal;
  const lines = [
    "# Paste into the terminal's config.yaml (sshweb), then restart it.",
    'opsapi:',
    `  webhook_url: ${opsapiUrl()}/api/v2/ai-runner/public/terminal/webhook`,
    `  webhook_secret: "${secret}"`,
    '  # People\'s keys issued in OpsAPI (Web terminals → People), fetched every 30 seconds.',
    '  keys:',
    `    url: ${opsapiUrl()}/api/v2/ai-runner/public/terminal/keys`,
    `    terminal_id: ${terminal.uuid}`,
    '  agents:',
  ];
  for (const a of agents.filter((x) => x.id !== 'shell')) {
    lines.push(
      `    - id: ${a.id}`,
      `      name: ${JSON.stringify(a.label)}`,
      `      run: ${JSON.stringify(RUN_LINES[a.id] || `${a.id} "$OPSAPI_TASK_PROMPT"`)}`,
    );
  }
  if (autologin) {
    lines.push(
      '  # Auto sign-in from Start with AI (docs §8). People with a key issued in OpsAPI are matched by their',
      '  # email. Only keys added on the terminal itself (sshweb keys add) need a line in users:',
      '  #   "their@email.com": their_terminal_user',
      '  autologin:',
      '    enabled: true',
      '    max_stepup_age_secs: 43200',
      '    users: {}',
    );
  }
  lines.push(
    'local:',
    '  # The folders a task may open (and everything inside them).',
    '  allowed_roots: [~/projects]',
  );
  return lines.join('\n');
}

type Shown = { terminal: WebTerminal; secret: string; rotated: boolean };

function SecretModal({ shown, onClose }: { shown: Shown | null; onClose: () => void }) {
  if (!shown) return null;
  return (
    <Modal
      isOpen
      onClose={onClose}
      size="2xl"
      title={shown.rotated ? `New secret for ${shown.terminal.name}` : `${shown.terminal.name} connected`}
      footer={<Button onClick={onClose}>I saved it</Button>}
    >
      <div className="space-y-4 text-sm text-secondary-700">
        <p className="rounded-lg bg-warning-500/10 p-3 font-medium text-warning-700" role="alert">
          Copy this now. You won&apos;t see the secret again
          {shown.rotated ? ', and links and updates signed with the old one stop working' : ''}.
        </p>
        <p>
          On the machine that runs the terminal, add this to its <code className="font-mono">config.yaml</code> and
          restart it:
        </p>
        <CopyBlock what="Config" text={configBlock(shown.terminal, shown.secret)} testId="air-terminal-config" />
        <p className="text-xs text-secondary-500">
          Change <code className="font-mono">allowed_roots</code> to the folders people may open, and the
          <code className="font-mono"> run</code> lines to how each agent starts on that machine. The task text reaches
          the agent only through <code className="font-mono">$OPSAPI_TASK_PROMPT</code>.
        </p>
      </div>
    </Modal>
  );
}

function EditModal({
  terminal,
  onClose,
  onSaved,
}: {
  terminal: WebTerminal | 'new';
  onClose: () => void;
  onSaved: (t: WebTerminal, secret?: string) => void;
}) {
  const isNew = terminal === 'new';
  const [name, setName] = useState(isNew ? '' : terminal.name);
  const [url, setUrl] = useState(isNew ? 'https://' : terminal.url);
  const [agents, setAgents] = useState<TerminalAgent[]>(isNew ? [] : terminal.agents);
  const [autologin, setAutologin] = useState(isNew ? false : terminal.autologin);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function save() {
    setBusy(true);
    setError(null);
    try {
      const body = { name: name.trim(), url: url.trim(), autologin, ...(isNew ? {} : { agents }) };
      if (isNew) {
        const res = await aiRunner.addTerminal(body);
        onSaved(res.terminal, res.secret);
      } else {
        onSaved(await aiRunner.updateTerminal(terminal.uuid, body));
      }
    } catch (e) {
      setError(aiErrorText(e));
    } finally {
      setBusy(false);
    }
  }

  const setAgent = (i: number, patch: Partial<TerminalAgent>) =>
    setAgents((list) => list.map((a, j) => (j === i ? { ...a, ...patch } : a)));

  return (
    <Modal
      isOpen
      onClose={onClose}
      size="lg"
      title={isNew ? 'Connect a web terminal' : `Edit ${terminal.name}`}
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button onClick={save} isLoading={busy} disabled={!name.trim() || !url.trim()}>
            {isNew ? 'Connect' : 'Save'}
          </Button>
        </>
      }
    >
      <div className="space-y-4">
        <Input
          id="air-term-name"
          label="Name"
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="Mac Studio"
          helperText="What people see when they pick where to work."
        />
        <Input
          id="air-term-url"
          label="Address"
          value={url}
          onChange={(e) => setUrl(e.target.value)}
          spellCheck={false}
          placeholder="https://dev.example.com"
          className="font-mono"
          helperText="Where people open the terminal in their browser."
        />
        <label className="flex items-start gap-2 text-sm text-secondary-800">
          <input type="checkbox" className="mt-0.5" checked={autologin} onChange={(e) => setAutologin(e.target.checked)} />
          <span>
            Let power users be signed in automatically
            <span className="block text-xs text-secondary-500">
              People with a key from People (or &quot;Web terminal auto sign-in&quot;) are signed in by Start with AI
              after confirming an emailed code (every 12 hours), without using their key file.
            </span>
          </span>
        </label>
        {!isNew && (
          <fieldset className="space-y-2">
            <legend className="text-sm font-medium text-secondary-700">Agents people can start</legend>
            <p className="text-xs text-secondary-500">
              The ids must match the agents in the terminal&apos;s config. &quot;shell&quot; is just a terminal.
            </p>
            {agents.map((a, i) => (
              <div key={i} className="flex items-end gap-2">
                <Input
                  id={`air-term-agent-id-${i}`}
                  label={i === 0 ? 'Id' : undefined}
                  value={a.id}
                  className="font-mono"
                  onChange={(e) => setAgent(i, { id: e.target.value.toLowerCase() })}
                  aria-label="Agent id"
                />
                <Input
                  id={`air-term-agent-label-${i}`}
                  label={i === 0 ? 'Shown as' : undefined}
                  value={a.label}
                  onChange={(e) => setAgent(i, { label: e.target.value })}
                  aria-label="Agent name"
                />
                <Button
                  variant="ghost"
                  size="sm"
                  aria-label={`Remove ${a.label || a.id}`}
                  onClick={() => setAgents((list) => list.filter((_, j) => j !== i))}
                  disabled={agents.length <= 1}
                >
                  <X className="h-4 w-4" aria-hidden />
                </Button>
              </div>
            ))}
            <Button
              variant="outline"
              size="sm"
              leftIcon={<Plus className="h-4 w-4" aria-hidden />}
              onClick={() => setAgents((list) => [...list, { id: '', label: '' }])}
              disabled={agents.length >= 20}
            >
              Add an agent
            </Button>
          </fieldset>
        )}
        {error && (
          <p className="rounded-lg bg-error-500/10 p-3 text-sm text-error-700" role="alert">
            {error}
          </p>
        )}
      </div>
    </Modal>
  );
}

/** 7 → "just now", 75 → "1 minute ago", 7200 → "2 hours ago". */
function agoWords(secs?: number | null): string {
  const s = Math.max(0, Math.round(secs ?? 0));
  const n = (v: number, unit: string) => `${v} ${unit}${v === 1 ? '' : 's'} ago`;
  if (s < 10) return 'just now';
  if (s < 60) return n(s, 'second');
  if (s < 3600) return n(Math.round(s / 60), 'minute');
  if (s < 86400) return n(Math.round(s / 3600), 'hour');
  return n(Math.round(s / 86400), 'day');
}

/** One line on the card: is the terminal in touch (§12)? When not, "What to do" opens the steps. */
function ConnectionStatus({ terminal }: { terminal: WebTerminal }) {
  const [open, setOpen] = useState(false);
  const c: TerminalConnection = terminal.connection ?? { state: 'waiting' };
  const address = <span className="font-mono">{terminal.url}</span>;
  const info = {
    connected: {
      icon: <CheckCircle2 className="h-4 w-4 text-success-600" aria-hidden />,
      tone: 'text-success-600',
      text: terminal.is_active
        ? `Connected · checked in ${agoWords(c.seen_secs_ago)}`
        : `Connected · checked in ${agoWords(c.seen_secs_ago)}, but switched off: nobody can sign in`,
      steps: null,
    },
    waiting: {
      icon: <Clock className="h-4 w-4 text-secondary-500" aria-hidden />,
      tone: 'text-secondary-700',
      text: 'Not connected yet: this terminal hasn’t checked in',
      steps: (
        <>
          <li>Open {address}. Its sign-in page should load; if it doesn’t, the machine or the terminal isn’t running.</li>
          <li>
            The terminal’s settings need this card’s terminal id and secret (the <em>keys</em> lines of its config). Not
            sure they’re there? Click <strong>New secret</strong> and put the lines it shows into its settings.
          </li>
          <li>Once it runs with the right settings it checks in every 30 seconds, and this line turns green by itself.</li>
        </>
      ),
    },
    lost: {
      icon: <WifiOff className="h-4 w-4 text-warning-600" aria-hidden />,
      tone: 'text-warning-600',
      text: `Lost contact · last checked in ${agoWords(c.seen_secs_ago)}`,
      steps: (
        <>
          <li>Open {address}. If the sign-in page doesn’t load, the machine is off or offline, or the terminal stopped: start it again.</li>
          <li>
            Until it’s back, keys you add or block in <strong>People</strong> don’t reach it. After 15 minutes it stops
            accepting keys from here altogether, so a blocked key can’t keep working.
          </li>
          <li>When it checks in again, this line turns green by itself.</li>
        </>
      ),
    },
    secret: {
      icon: <ShieldAlert className="h-4 w-4 text-error-600" aria-hidden />,
      tone: 'text-error-600',
      text: 'Not connected: the secret on the machine doesn’t match',
      steps: (
        <>
          <li>
            The terminal calls in with a different secret than OpsAPI has (for example after <strong>New secret</strong>
            {' '}was clicked and the machine wasn’t updated). Until they match, nobody can sign in with a key from People.
          </li>
          <li>Click <strong>New secret</strong> on this card and keep the window that opens.</li>
          <li>On the terminal’s machine, put the new terminal id and secret into its settings and restart it.</li>
          <li>Within a minute this line turns green.</li>
        </>
      ),
    },
    clock: {
      icon: <Clock className="h-4 w-4 text-error-600" aria-hidden />,
      tone: 'text-error-600',
      text: 'Not connected: the machine’s clock is wrong',
      steps: (
        <>
          <li>Its secret is right, but its clock is more than 5 minutes off, so OpsAPI can’t trust its requests.</li>
          <li>
            On the terminal’s machine, switch on automatic date and time (on a Mac: System Settings → General → Date &amp;
            Time → <em>Set time and date automatically</em>).
          </li>
          <li>Within a minute this line turns green.</li>
        </>
      ),
    },
  }[c.state];
  if (!info) return null;
  return (
    <div className="space-y-1" data-testid="air-terminal-connection" data-state={c.state}>
      <p className={`flex flex-wrap items-center gap-1.5 text-sm ${info.tone}`}>
        {info.icon}
        <span>{info.text}</span>
        {info.steps && (
          <button
            type="button"
            onClick={() => setOpen((v) => !v)}
            aria-expanded={open}
            className="inline-flex items-center gap-0.5 font-medium text-primary-600 hover:underline"
          >
            What to do <ChevronDown className={`h-3.5 w-3.5 transition-transform ${open ? 'rotate-180' : ''}`} aria-hidden />
          </button>
        )}
      </p>
      {open && info.steps && (
        <ol className="ml-6 list-decimal space-y-1 rounded-lg bg-secondary-50 p-3 pl-7 text-sm text-secondary-700">
          {info.steps}
        </ol>
      )}
    </div>
  );
}

export function WebTerminals() {
  // Every 15 seconds, like the rest of the page, so the connection line stays current.
  const terminals = useAiData(() => aiRunner.listTerminals(), [], 15_000);
  const [editing, setEditing] = useState<WebTerminal | 'new' | null>(null);
  const [shown, setShown] = useState<Shown | null>(null);
  const [people, setPeople] = useState<WebTerminal | null>(null);
  const list = terminals.data || [];

  async function act(what: string, fn: () => Promise<unknown>) {
    try {
      await fn();
      toast.success(what);
      terminals.refresh();
    } catch (e) {
      toast.error(aiErrorText(e));
    }
  }

  async function rotate(t: WebTerminal) {
    const ok = await confirmDialog({
      title: `New secret for ${t.name}?`,
      message: 'Open links and the terminal’s updates stop working until you paste the new secret into its config.',
      confirmText: 'Make a new secret',
      danger: true,
    });
    if (!ok) return;
    try {
      const res = await aiRunner.rotateTerminalSecret(t.uuid);
      setShown({ terminal: res.terminal, secret: res.secret, rotated: true });
      terminals.refresh();
    } catch (e) {
      toast.error(aiErrorText(e));
    }
  }

  async function remove(t: WebTerminal) {
    const ok = await confirmDialog({
      title: `Remove ${t.name}?`,
      message: 'People can no longer open tasks in it. Sessions already on tasks stay there.',
      confirmText: 'Remove',
      danger: true,
    });
    if (ok) await act(`${t.name} removed`, () => aiRunner.deleteTerminal(t.uuid));
  }

  return (
    <section aria-labelledby="air-web-terminals" className="space-y-3" data-testid="air-web-terminals">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h2 id="air-web-terminals" className="flex items-center gap-2 font-semibold text-secondary-900">
            <Terminal className="h-5 w-5" aria-hidden /> Web terminals
          </h2>
          <p className="text-sm text-secondary-500">
            Where people work on a task themselves: Start with AI opens the task&apos;s folder there and starts their
            agent.
          </p>
        </div>
        <Button variant="outline" leftIcon={<Plus className="h-4 w-4" aria-hidden />} onClick={() => setEditing('new')}>
          Connect a terminal
        </Button>
      </div>
      <ErrorNote error={terminals.error} product={PRODUCT} />
      {!terminals.loading && !terminals.error && list.length === 0 && (
        <Card className="text-sm text-secondary-600">No web terminal connected yet.</Card>
      )}
      <ul className="space-y-2">
        {list.map((t) => (
          <li
            key={t.uuid}
            className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-secondary-200 bg-surface p-4"
          >
            <div className="min-w-0">
              <p className="flex flex-wrap items-center gap-2 font-medium text-secondary-900">
                <span className="break-all">{t.name}</span>
                <Badge size="sm" variant={t.is_active ? 'success' : 'secondary'}>
                  {t.is_active ? 'On' : 'Off'}
                </Badge>
                {t.autologin && (
                  <Badge size="sm" variant="info">
                    Auto sign-in
                  </Badge>
                )}
              </p>
              <p className="truncate font-mono text-xs text-secondary-500">{t.url}</p>
              <p className="text-xs text-secondary-500">
                Agents: {t.agents.map((a) => a.label).join(', ')}
                {t.secret_hint ? ` · secret ${t.secret_hint}` : ''}
              </p>
            </div>
            <div className="flex flex-wrap gap-1">
              <Button
                size="sm"
                variant="ghost"
                leftIcon={<Users className="h-4 w-4" aria-hidden />}
                onClick={() => setPeople(t)}
              >
                People
              </Button>
              <Button
                size="sm"
                variant="ghost"
                leftIcon={<Pencil className="h-4 w-4" aria-hidden />}
                onClick={() => setEditing(t)}
              >
                Edit
              </Button>
              <Button
                size="sm"
                variant="ghost"
                onClick={() =>
                  act(t.is_active ? `${t.name} switched off` : `${t.name} switched on`, () =>
                    aiRunner.updateTerminal(t.uuid, { is_active: !t.is_active }),
                  )
                }
              >
                {t.is_active ? 'Switch off' : 'Switch on'}
              </Button>
              <Button
                size="sm"
                variant="ghost"
                leftIcon={<KeyRound className="h-4 w-4" aria-hidden />}
                onClick={() => rotate(t)}
              >
                New secret
              </Button>
              <Button
                size="sm"
                variant="ghost"
                leftIcon={<Trash2 className="h-4 w-4" aria-hidden />}
                onClick={() => remove(t)}
              >
                Remove
              </Button>
            </div>
            <div className="w-full border-t border-secondary-100 pt-2">
              <ConnectionStatus terminal={t} />
            </div>
          </li>
        ))}
      </ul>
      {editing && (
        <EditModal
          terminal={editing}
          onClose={() => setEditing(null)}
          onSaved={(t, secret) => {
            setEditing(null);
            terminals.refresh();
            if (secret) setShown({ terminal: t, secret, rotated: false });
            else toast.success(`${t.name} saved`);
          }}
        />
      )}
      <SecretModal shown={shown} onClose={() => setShown(null)} />
      {people && <TerminalPeople terminal={people} onClose={() => setPeople(null)} />}
    </section>
  );
}

export default WebTerminals;

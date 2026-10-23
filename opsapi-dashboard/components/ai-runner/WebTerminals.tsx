'use client';

/**
 * Web terminals (docs/AI_RUNNER_WEB_TERMINAL.md, ai_runners.manage): connect a workstation-terminal so people can
 * open a task's folder there from Start with AI. Add (the shared secret and the terminal's config block are shown
 * once), edit the name, address and agents, switch off, rotate the secret, remove.
 */
import React, { useState } from 'react';
import toast from 'react-hot-toast';
import { KeyRound, Pencil, Plus, Terminal, Trash2, X } from 'lucide-react';
import { Badge, Button, Card, Input, Modal, confirmDialog } from '@/components/ui';
import { ErrorNote } from '@/components/property-deals/ui';
import { aiRunner, aiErrorText, type TerminalAgent, type WebTerminal } from '@/services/ai-runner.service';
import { CopyBlock, PRODUCT, opsapiUrl, useAiData } from './ui';

// What the terminal runs for the default agents; the terminal's own config decides (shown in the config block).
const RUN_LINES: Record<string, string> = {
  claude: 'claude "$OPSAPI_TASK_PROMPT"',
  codex: 'codex "$OPSAPI_TASK_PROMPT"',
  cursor: 'cursor-agent "$OPSAPI_TASK_PROMPT"',
};

/** The block to paste into the terminal's config.yaml. */
function configBlock(secret: string, agents: TerminalAgent[]): string {
  const lines = [
    "# Paste into the terminal's config.yaml (sshweb), then restart it.",
    'opsapi:',
    `  webhook_url: ${opsapiUrl()}/api/v2/ai-runner/public/terminal/webhook`,
    `  webhook_secret: "${secret}"`,
    '  agents:',
  ];
  for (const a of agents.filter((x) => x.id !== 'shell')) {
    lines.push(
      `    - id: ${a.id}`,
      `      name: ${JSON.stringify(a.label)}`,
      `      run: ${JSON.stringify(RUN_LINES[a.id] || `${a.id} "$OPSAPI_TASK_PROMPT"`)}`,
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
        <CopyBlock what="Config" text={configBlock(shown.secret, shown.terminal.agents)} testId="air-terminal-config" />
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
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function save() {
    setBusy(true);
    setError(null);
    try {
      const body = { name: name.trim(), url: url.trim(), ...(isNew ? {} : { agents }) };
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

export function WebTerminals() {
  const terminals = useAiData(() => aiRunner.listTerminals(), []);
  const [editing, setEditing] = useState<WebTerminal | 'new' | null>(null);
  const [shown, setShown] = useState<Shown | null>(null);
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
    </section>
  );
}

export default WebTerminals;

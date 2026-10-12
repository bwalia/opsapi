'use client';

/**
 * Runners (ai_runners.manage): the machines that run AI tasks for this workspace through PromptPilot.
 * Register (token shown once + setup), rotate the token, pause / resume, revoke, and each machine's sessions.
 */
import React, { useState } from 'react';
import Link from 'next/link';
import { Copy, KeyRound, ListTree, Pause, Play, Plus, Server, Trash2 } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, ConfirmDialog, Input, Modal, Table } from '@/components/ui';
import { ErrorNote } from '@/components/property-deals/ui';
import { AiRunnerPage, BASE, PRODUCT, RunnerStatusBadge, ago, rateLimitText, useAiData } from '@/components/ai-runner/ui';
import apiClient from '@/lib/api-client';
import { aiRunner, aiErrorText, type Runner } from '@/services/ai-runner.service';

export default function RunnersPage() {
  return (
    <AiRunnerPage module="ai_runners" action="manage">
      <Runners />
    </AiRunnerPage>
  );
}

const slug = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'runner';

function opsapiUrl(): string {
  const base = apiClient.defaults.baseURL || '';
  return /^https?:\/\//.test(base) ? base.replace(/\/$/, '') : `${window.location.origin}${base}`.replace(/\/$/, '');
}

function copy(text: string, what: string) {
  navigator.clipboard.writeText(text).then(() => toast.success(`${what} copied`), () => toast.error('Could not copy'));
}

function CopyBlock({ text, what, testId }: { text: string; what: string; testId?: string }) {
  return (
    <div className="relative">
      <pre data-testid={testId} className="overflow-x-auto whitespace-pre rounded-lg bg-secondary-900 p-3 pr-24 font-mono text-xs text-secondary-100">{text}</pre>
      <Button size="sm" variant="ghost" className="absolute right-1.5 top-1.5 bg-surface/90" onClick={() => copy(text, what)}
        leftIcon={<Copy className="h-3.5 w-3.5" aria-hidden />} aria-label={`Copy ${what.toLowerCase()}`}>
        Copy
      </Button>
    </div>
  );
}

function runnerJson(name: string): string {
  const s = slug(name);
  return JSON.stringify({
    registrations: [{
      name,
      opsapi_url: opsapiUrl(),
      token_file: `/Users/you/.promptpilot/${s}.token`,
      allowed_roots: ['/Users/you/projects'],
      max_concurrency: 1,
    }],
    profiles: [{
      key: 'claude',
      label: 'Claude Code',
      approval: 'none',
      models: [],
      command: ['claude', '-p', '{{prompt}}', '--output-format', 'stream-json', '--verbose', '--session-id', '{{run_uuid}}',
        '--restricted', '--permission-mode', 'acceptEdits', '--permission-prompts', 'none',
        '--allowedTools', 'Read,Grep,Glob,Edit,MultiEdit,Write'],
      env: {},
    }],
    claude_oauth_token_file: '/Users/you/.promptpilot/claude-oauth.token',
    restore_branch: true,
  }, null, 2);
}

/** The token, once, with how to set the machine up. */
function TokenModal({ shown, onClose }: { shown: { name: string; token: string; rotated: boolean } | null; onClose: () => void }) {
  if (!shown) return null;
  const s = slug(shown.name);
  return (
    <Modal isOpen onClose={onClose} size="2xl" title={shown.rotated ? `New token for ${shown.name}` : `Runner ${shown.name} registered`}
      footer={<Button onClick={onClose}>I saved the token</Button>}>
      <div className="space-y-4 text-sm text-secondary-700">
        <p className="rounded-lg bg-warning-500/10 p-3 font-medium text-warning-700" role="alert">
          Copy this token now. You won&apos;t see it again{shown.rotated ? ', and the old token no longer works' : ''}.
        </p>
        <CopyBlock text={shown.token} what="Token" testId="runner-token" />
        <ol className="list-decimal space-y-3 pl-5">
          <li>
            Save the token on the machine (macOS, after Copy; on Linux paste it into the file with an editor):
            <CopyBlock what="Command" text={`mkdir -p ~/.promptpilot && pbpaste > ~/.promptpilot/${s}.token && chmod 600 ~/.promptpilot/${s}.token`} />
          </li>
          {!shown.rotated && (
            <li>
              Save this as <code className="font-mono">runner.json</code>, changing <code className="font-mono">/Users/you</code> and{' '}
              <code className="font-mono">allowed_roots</code> to the folders the agent may work in:
              <CopyBlock what="runner.json" text={runnerJson(shown.name)} />
            </li>
          )}
          <li>
            {shown.rotated ? 'Restart the runner' : 'Start the runner'}:
            <CopyBlock what="Command" text="promptpilot runner -config runner.json" />
          </li>
          <li>Within about 15 seconds the runner shows as Online here.</li>
        </ol>
      </div>
    </Modal>
  );
}

function SessionsModal({ runner, onClose }: { runner: Runner | null; onClose: () => void }) {
  const sessions = useAiData(() => (runner ? aiRunner.runnerSessions(runner.uuid) : Promise.resolve([])), [runner?.uuid]);
  if (!runner) return null;
  return (
    <Modal isOpen onClose={onClose} size="3xl" title={`Sessions on ${runner.name}`} description="What the runner last reported: runs it manages and sessions started by hand.">
      <ErrorNote error={sessions.error} product={PRODUCT} />
      <Table
        caption={`Sessions on ${runner.name}`}
        data={sessions.data || []}
        isLoading={sessions.loading && !sessions.data}
        keyExtractor={(s) => s.key}
        emptyMessage="No sessions reported."
        columns={[
          { key: 'tool', header: 'Tool', render: (s) => s.tool || '—' },
          { key: 'status', header: 'Status', render: (s) => s.status || '—' },
          { key: 'cwd', header: 'Folder', render: (s) => <span className="break-all font-mono text-xs">{s.cwd || '—'}</span> },
          { key: 'branch', header: 'Branch', render: (s) => <span className="font-mono text-xs">{s.branch || '—'}</span> },
          {
            key: 'run', header: 'Run', render: (s) => s.run_uuid
              ? <Link href={`${BASE}/runs/${s.run_uuid}`} className="text-primary-600 hover:underline" onClick={onClose}>Open run</Link>
              : <span className="text-secondary-400">by hand</span>,
          },
        ]}
      />
    </Modal>
  );
}

function Runners() {
  const runners = useAiData(() => aiRunner.listRunners(), [], 15_000);
  const [registerOpen, setRegisterOpen] = useState(false);
  const [name, setName] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [token, setToken] = useState<{ name: string; token: string; rotated: boolean } | null>(null);
  const [confirm, setConfirm] = useState<{ kind: 'rotate' | 'revoke'; runner: Runner } | null>(null);
  const [sessionsOf, setSessionsOf] = useState<Runner | null>(null);

  async function act(key: string, fn: () => Promise<unknown>, ok: string) {
    setBusy(key);
    try {
      await fn();
      toast.success(ok);
      runners.refresh();
      return true;
    } catch (e) {
      toast.error(aiErrorText(e));
      return false;
    } finally {
      setBusy(null);
    }
  }

  async function register(e: React.FormEvent) {
    e.preventDefault();
    if (!name.trim()) return;
    await act('register', async () => {
      const res = await aiRunner.registerRunner(name.trim());
      setRegisterOpen(false);
      setToken({ name: res.runner?.name || name.trim(), token: res.token, rotated: false });
      setName('');
    }, 'Runner registered');
  }

  async function confirmed() {
    if (!confirm) return;
    const r = confirm.runner;
    if (confirm.kind === 'rotate') {
      await act(`rotate:${r.uuid}`, async () => {
        const res = await aiRunner.rotateToken(r.uuid);
        setToken({ name: r.name, token: res.token, rotated: true });
      }, 'New token issued');
    } else {
      await act(`revoke:${r.uuid}`, () => aiRunner.revokeRunner(r.uuid), 'Runner revoked');
    }
    setConfirm(null);
  }

  const columns = [
    { key: 'name', header: 'Name', render: (r: Runner) => <span className="font-medium">{r.name}</span> },
    { key: 'status', header: 'Status', render: (r: Runner) => <RunnerStatusBadge status={r.status} /> },
    {
      key: 'machine', header: 'Machine', render: (r: Runner) => (
        <div>
          <div>{r.host || '—'}</div>
          {(r.os || r.version) && <div className="text-xs text-secondary-500">{[r.os, r.version && `v${r.version}`].filter(Boolean).join(' · ')}</div>}
        </div>
      ),
    },
    { key: 'heartbeat', header: 'Last heartbeat', render: (r: Runner) => ago(r.last_heartbeat_at) },
    {
      key: 'profiles', header: 'Profiles',
      render: (r: Runner) => {
        const profiles = r.capabilities?.profiles || [];
        if (!profiles.length) return '—';
        return (
          <ul className="space-y-0.5">
            {profiles.map((p) => {
              const limit = rateLimitText(p.rate_limit);
              return (
                <li key={p.key}>
                  {p.label || p.key}
                  {limit && <span className="block text-xs text-secondary-500">{limit}</span>}
                </li>
              );
            })}
          </ul>
        );
      },
    },
    { key: 'repos', header: 'Repos', render: (r: Runner) => (r.repos || []).length },
    {
      key: 'actions', header: 'Actions', render: (r: Runner) => r.status === 'revoked' ? null : (
        <div className="flex flex-wrap gap-1">
          <Button size="sm" variant="ghost" onClick={() => setSessionsOf(r)} leftIcon={<ListTree className="h-4 w-4" aria-hidden />} aria-label={`Sessions on ${r.name}`}>Sessions</Button>
          {r.status === 'paused' ? (
            <Button size="sm" variant="ghost" isLoading={busy === `resume:${r.uuid}`} onClick={() => act(`resume:${r.uuid}`, () => aiRunner.resumeRunner(r.uuid), 'Runner resumed')}
              leftIcon={<Play className="h-4 w-4" aria-hidden />} aria-label={`Resume ${r.name}`}>Resume</Button>
          ) : (
            <Button size="sm" variant="ghost" isLoading={busy === `pause:${r.uuid}`} onClick={() => act(`pause:${r.uuid}`, () => aiRunner.pauseRunner(r.uuid), 'Runner paused')}
              leftIcon={<Pause className="h-4 w-4" aria-hidden />} aria-label={`Pause ${r.name}`}>Pause</Button>
          )}
          <Button size="sm" variant="ghost" onClick={() => setConfirm({ kind: 'rotate', runner: r })} leftIcon={<KeyRound className="h-4 w-4" aria-hidden />} aria-label={`Rotate the token of ${r.name}`}>Rotate token</Button>
          <Button size="sm" variant="ghost" className="text-error-600" onClick={() => setConfirm({ kind: 'revoke', runner: r })} leftIcon={<Trash2 className="h-4 w-4" aria-hidden />} aria-label={`Revoke ${r.name}`}>Revoke</Button>
        </div>
      ),
    },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="Runners"
        description="Machines that run AI tasks for this workspace through PromptPilot."
        icon={<Server className="h-6 w-6" />}
        actions={<Button leftIcon={<Plus className="h-4 w-4" aria-hidden />} onClick={() => setRegisterOpen(true)}>Register runner</Button>}
      />
      <ErrorNote error={runners.error} product={PRODUCT} />
      <Table<Runner>
        caption="Runners"
        columns={columns}
        data={runners.data || []}
        keyExtractor={(r) => r.uuid}
        isLoading={runners.loading && !runners.data}
        emptyMessage="No runners yet. Register one, then start PromptPilot on that machine."
      />

      <Modal isOpen={registerOpen} onClose={() => setRegisterOpen(false)} title="Register a runner" size="md"
        description="One runner per machine (or per set of folders). You get its token once.">
        <form onSubmit={register} className="space-y-4">
          <Input id="air-runner-name" label="Name" value={name} onChange={(e) => setName(e.target.value)} placeholder="mac-studio" required maxLength={100} />
          <div className="flex justify-end gap-2">
            <Button type="button" variant="ghost" onClick={() => setRegisterOpen(false)}>Cancel</Button>
            <Button type="submit" isLoading={busy === 'register'} disabled={!name.trim()}>Register</Button>
          </div>
        </form>
      </Modal>

      <TokenModal shown={token} onClose={() => setToken(null)} />
      <SessionsModal runner={sessionsOf} onClose={() => setSessionsOf(null)} />

      <ConfirmDialog
        isOpen={!!confirm}
        onClose={() => setConfirm(null)}
        onConfirm={confirmed}
        title={confirm?.kind === 'rotate' ? `Rotate the token of ${confirm.runner.name}?` : `Revoke ${confirm?.runner.name}?`}
        message={confirm?.kind === 'rotate'
          ? 'The current token stops working at once. Put the new one on the machine and restart the runner.'
          : 'The runner can no longer claim or report runs. This cannot be undone; register it again to bring it back.'}
        confirmText={confirm?.kind === 'rotate' ? 'Rotate token' : 'Revoke'}
        variant={confirm?.kind === 'rotate' ? 'warning' : 'danger'}
        isLoading={!!busy && busy !== 'register'}
      />
    </div>
  );
}

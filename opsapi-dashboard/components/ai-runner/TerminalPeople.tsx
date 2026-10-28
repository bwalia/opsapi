'use client';

/**
 * People who may sign in to a web terminal with a key a manager issued them (docs/AI_RUNNER_WEB_TERMINAL.md §10).
 * The key pair is made in this browser (lib/ssh-key.ts); OpsAPI keeps only the public half, so the key file and its
 * passphrase are shown once, to hand over. Keys work 90 days; blocking one closes the person's terminals within a
 * minute; people who leave the workspace lose their keys by themselves.
 */
import React, { useState } from 'react';
import toast from 'react-hot-toast';
import { Ban, Copy, Download, KeyRound, ShieldCheck } from 'lucide-react';
import { Badge, Button, Modal, SearchableSelect, confirmDialog } from '@/components/ui';
import { ErrorNote } from '@/components/property-deals/ui';
import { aiRunner, aiErrorText, type TerminalAccessKey, type WebTerminal } from '@/services/ai-runner.service';
import { makeTerminalKey, type TerminalKey } from '@/lib/ssh-key';
import { copy, CopyBlock, PRODUCT, toDate, useAiData } from './ui';
import { signInLink, terminalLabel } from './MyTerminalAccess';

const SOON_DAYS = 14;

const day = (v?: string | null) =>
  toDate(v)?.toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }) || '—';

function daysLeft(k: TerminalAccessKey): number {
  return Math.ceil(((toDate(k.expires_at)?.getTime() ?? 0) - Date.now()) / 86400000);
}

function StatusBadge({ k }: { k: TerminalAccessKey }) {
  if (k.status === 'active') {
    const left = daysLeft(k);
    return left <= SOON_DAYS ? (
      <Badge size="sm" variant="warning">Expires in {left} {left === 1 ? 'day' : 'days'}</Badge>
    ) : (
      <Badge size="sm" variant="success">Active</Badge>
    );
  }
  const label = { expired: 'Expired', blocked: 'Blocked', replaced: 'Replaced', left: 'Left the workspace' }[k.status];
  return <Badge size="sm" variant="secondary">{label}</Badge>;
}

type Handover = { person: string; terminalUser: string; key: TerminalKey; downloaded: boolean };

export function TerminalPeople({ terminal, onClose }: { terminal: WebTerminal; onClose: () => void }) {
  const data = useAiData(() => aiRunner.terminalKeys(terminal.uuid), [terminal.uuid]);
  const [person, setPerson] = useState('');
  const [busy, setBusy] = useState(false);
  const [handover, setHandover] = useState<Handover | null>(null);
  const keys = data.data?.keys || [];
  const live = new Set(keys.filter((k) => k.status === 'active').map((k) => k.user_uuid));
  const options = (data.data?.people || []).map((p) => ({
    value: p.uuid,
    label: p.name || p.email || p.uuid,
    hint: [p.email, live.has(p.uuid) ? 'has a key: a new one replaces it' : ''].filter(Boolean).join(' · '),
  }));

  async function issue(userUuid: string) {
    const p = data.data?.people.find((x) => x.uuid === userUuid);
    if (!p) return;
    if (live.has(userUuid)) {
      const ok = await confirmDialog({
        title: `Replace ${p.name || p.email}'s key?`,
        message: 'Their current key stops working straight away, and their open terminals close within a minute.',
        confirmText: 'Make a new key',
        danger: true,
      });
      if (!ok) return;
    }
    setBusy(true);
    try {
      const key = await makeTerminalKey(p.email || p.uuid);
      const issued = await aiRunner.issueTerminalKey(terminal.uuid, { user_uuid: userUuid, public_key: key.publicKey });
      setHandover({ person: p.name || p.email || 'them', terminalUser: issued.terminal_user, key, downloaded: false });
      setPerson('');
      data.refresh();
    } catch (e) {
      toast.error(aiErrorText(e));
    } finally {
      setBusy(false);
    }
  }

  async function block(k: TerminalAccessKey) {
    const who = k.person_name || k.person_email || k.terminal_user;
    const ok = await confirmDialog({
      title: `Block ${who}'s key?`,
      message: `They can't sign in to ${terminal.name} with it any more, and their open terminals close within a minute.`,
      confirmText: 'Block',
      danger: true,
    });
    if (!ok) return;
    try {
      await aiRunner.blockTerminalKey(terminal.uuid, k.uuid);
      toast.success(`${who}'s key is blocked`);
      data.refresh();
    } catch (e) {
      toast.error(aiErrorText(e));
    }
  }

  const fileName = handover ? `${handover.terminalUser}-${terminal.name.toLowerCase().replace(/[^a-z0-9]+/g, '-')}.key` : '';

  function download() {
    if (!handover) return;
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([handover.key.privateKey], { type: 'application/octet-stream' }));
    a.download = fileName;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
    setHandover({ ...handover, downloaded: true });
  }

  async function finishHandover() {
    // With auto sign-in the file is only for opening the terminal without a task, so skipping it is fine.
    if (handover && !handover.downloaded && !terminal.autologin) {
      const ok = await confirmDialog({
        title: 'Close without the key file?',
        message: 'It can’t be shown again. If you close now, you’ll need to make a new key for them.',
        confirmText: 'Close anyway',
        danger: true,
      });
      if (!ok) return;
    }
    setHandover(null);
  }

  // What the person does with the file and passphrase, ready to paste into the email that carries the file.
  const message = handover
    ? [
        `Hi ${handover.person}, you can now work in our ${terminalLabel(terminal.name)}.`,
        '',
        'To work on a task: open the task in OpsAPI, click Start with AI, choose to work on it in the terminal and '
          + 'click Open the terminal.'
          + (terminal.autologin ? ' The first time, type the code we email you.' : ' If it asks you to sign in, do the steps below.'),
        '',
        'To open the terminal on its own:',
        `1. Save the attached file (${fileName}) where you can find it.`,
        `2. Go to ${signInLink({ url: terminal.url, terminal_user: handover.terminalUser })} `
          + `(your user name, ${handover.terminalUser}, is filled in for you).`,
        '3. Click Choose file and pick that file, type the passphrase I give you separately, then click Sign in.',
        '',
        'Keep the file and the passphrase to yourself. The key works for 90 days. '
          + 'These steps are also in OpsAPI, on your My Tasks page.',
      ].join('\n')
    : '';

  // The key file + passphrase handover (shown once): what someone needs to open the terminal on their own.
  const keyFileSteps = handover && (
    <div className="space-y-4">
      <p className="rounded-lg bg-warning-500/10 p-3 font-medium text-warning-700" role="alert">
        {`Give ${handover.person} the file and the passphrase separately (for example the file by email and the `
          + 'passphrase by phone). This is the only time you’ll see them: OpsAPI keeps just the public half of the key.'}
      </p>
      <div className="space-y-1">
        <p className="font-medium text-secondary-900">1. The key file</p>
        <Button leftIcon={<Download className="h-4 w-4" aria-hidden />} onClick={download} data-testid="air-key-download">
          {handover.downloaded ? 'Download again' : `Download ${fileName}`}
        </Button>
      </div>
      <div className="space-y-1">
        <p className="font-medium text-secondary-900">2. Its passphrase</p>
        <CopyBlock what="Passphrase" text={handover.key.passphrase} testId="air-key-passphrase" />
      </div>
      <div className="space-y-1">
        <div className="flex items-center justify-between gap-2">
          <p className="font-medium text-secondary-900">3. A message to send with the file</p>
          <Button size="sm" variant="ghost" leftIcon={<Copy className="h-3.5 w-3.5" aria-hidden />}
            onClick={() => copy(message, 'Message')} data-testid="air-key-message-copy">
            Copy message
          </Button>
        </div>
        <p className="whitespace-pre-wrap rounded-lg border border-secondary-200 bg-secondary-50 p-3 text-xs text-secondary-700"
          data-testid="air-key-message">{message}</p>
        <p className="text-xs text-secondary-500">
          They sign in on the terminal page with the file and passphrase: no commands to run. They also see these
          steps on their My Tasks page in OpsAPI. The key works for 90 days; you&apos;ll be reminded two weeks before.
        </p>
      </div>
    </div>
  );

  async function close() {
    if (handover) {
      await finishHandover();
      return;
    }
    onClose();
  }

  return (
    <Modal
      isOpen
      onClose={() => void close()}
      size="2xl"
      title={handover ? `Key for ${handover.person}` : `People who can use ${terminal.name}`}
      footer={handover ? <Button onClick={() => void finishHandover()}>Done</Button> : <Button variant="ghost" onClick={onClose}>Close</Button>}
    >
      {handover && terminal.autologin ? (
        <div className="space-y-4 text-sm text-secondary-700" data-testid="air-key-handover">
          <div className="rounded-lg border border-emerald-200 bg-emerald-50 p-3 text-emerald-900" role="status">
            <p className="font-medium">{`${handover.person} is ready. There's nothing to hand over for their tasks.`}</p>
            <ol className="mt-2 list-decimal space-y-1 pl-4">
              <li>They open their task in OpsAPI and click Start with AI.</li>
              <li>They choose to work on it in the terminal and click Open the terminal.</li>
              <li>The first time (then every 12 hours) they type the code we email them. The terminal opens on the task.</li>
            </ol>
          </div>
          <details className="rounded-lg border border-secondary-200 p-3">
            <summary className="cursor-pointer font-medium text-secondary-800">
              Only if they also need the terminal without a task: their key file
            </summary>
            <div className="mt-3">
              {keyFileSteps}
            </div>
          </details>
        </div>
      ) : handover ? (
        <div className="space-y-4 text-sm text-secondary-700" data-testid="air-key-handover">
          {keyFileSteps}
        </div>
      ) : (
        <div className="space-y-4">
          <p className="text-sm text-secondary-600">
            Each person signs in with their own key, so the terminal records who did what. Keys work for 90 days.
            Blocking a key closes that person&apos;s terminals within a minute, and people who leave the workspace lose
            their keys by themselves.
          </p>
          <div className="flex flex-wrap items-end gap-2 rounded-lg border border-secondary-200 p-3" data-testid="air-key-issue">
            <div className="min-w-[16rem] flex-1">
              <SearchableSelect
                label="Give someone access"
                options={options}
                value={person}
                onChange={setPerson}
                placeholder="Pick a person"
                searchPlaceholder="Search people"
                emptyMessage="No one found"
              />
            </div>
            <Button
              leftIcon={<KeyRound className="h-4 w-4" aria-hidden />}
              onClick={() => void issue(person)}
              isLoading={busy}
              disabled={!person}
            >
              Make a key
            </Button>
          </div>
          <ErrorNote error={data.error} product={PRODUCT} />
          {!data.loading && !data.error && keys.length === 0 && (
            <p className="text-sm text-secondary-500">No one has a key for {terminal.name} yet.</p>
          )}
          {keys.length > 0 && (
            <ul className="divide-y divide-secondary-100 rounded-lg border border-secondary-200" data-testid="air-key-list">
              {keys.map((k) => (
                <li key={k.uuid} className={`flex flex-wrap items-center justify-between gap-2 p-3 ${k.status === 'active' ? '' : 'opacity-60'}`}>
                  <div className="min-w-0 text-sm">
                    <p className="flex flex-wrap items-center gap-2 font-medium text-secondary-900">
                      {k.person_name || k.person_email || 'Someone'}
                      <span className="font-mono text-xs font-normal text-secondary-500">as {k.terminal_user}</span>
                      <StatusBadge k={k} />
                    </p>
                    <p className="text-xs text-secondary-500">
                      Issued {day(k.created_at)}
                      {k.created_by_name ? ` by ${k.created_by_name}` : ''}
                      {k.status === 'active' || k.status === 'expired' ? ` · ${k.status === 'active' ? 'works until' : 'stopped'} ${day(k.expires_at)}` : ''}
                      {k.revoked_at && k.status !== 'left' ? ` · ${k.status} ${day(k.revoked_at)}${k.revoked_by_name ? ` by ${k.revoked_by_name}` : ''}` : ''}
                    </p>
                    <p className="truncate font-mono text-[11px] text-secondary-400" title={k.fingerprint}>
                      {k.fingerprint}
                    </p>
                  </div>
                  <div className="flex gap-1">
                    {(k.status === 'active' || k.status === 'expired') && (
                      <Button size="sm" variant="ghost" leftIcon={<ShieldCheck className="h-4 w-4" aria-hidden />}
                        onClick={() => void issue(k.user_uuid)} disabled={busy}>
                        New key
                      </Button>
                    )}
                    {k.status === 'active' && (
                      <Button size="sm" variant="ghost" leftIcon={<Ban className="h-4 w-4" aria-hidden />} onClick={() => void block(k)}>
                        Block
                      </Button>
                    )}
                  </div>
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
    </Modal>
  );
}

export default TerminalPeople;

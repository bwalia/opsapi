'use client';

/**
 * The four actions every Property Deals task has (Prompt 2, deal page): Do it, Let AI do it,
 * Assign, Snooze with reason — plus "Log contact" for calls / WhatsApp made from the task.
 * Buttons a role can't use are hidden; a refused call still shows its reason.
 */
import React, { useEffect, useState } from 'react';
import { CheckCircle2, Sparkles, UserPlus, AlarmClock, PhoneCall } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Modal, Input, Select, Textarea } from '@/components/ui';
import { pdService, pdErrorText, type TaskSummary, type Task, type AgentRun } from '@/services/property-deals.service';
import { namespaceService } from '@/services/namespace.service';
import { usePdMe } from './usePd';
import { useNamespaceStore } from '@/store/namespace.store';

type AnyTask = (TaskSummary | Task) & { task_uuid: string; title: string };

// Per workspace: switching workspace must not offer the last one's people as assignees.
const membersCache: Record<string, { uuid: string; name: string }[]> = {};
async function loadMembers(ns: string): Promise<{ uuid: string; name: string }[]> {
  if (membersCache[ns]) return membersCache[ns];
  // The members route reads per_page (snake case), which PaginationParams doesn't declare.
  const res = await namespaceService.getMembers({ per_page: 100 } as Parameters<typeof namespaceService.getMembers>[0]);
  membersCache[ns] = (res.data || [])
    .filter((m) => m.user)
    .map((m) => ({ uuid: m.user!.uuid, name: `${m.user!.first_name || ''} ${m.user!.last_name || ''}`.trim() || m.user!.email }));
  return membersCache[ns];
}

export function useMembers() {
  const ns = useNamespaceStore((s) => s.currentNamespace?.uuid || 'default');
  const [members, setMembers] = useState<{ uuid: string; name: string }[]>(membersCache[ns] || []);
  useEffect(() => {
    loadMembers(ns).then(setMembers).catch(() => setMembers([]));
  }, [ns]);
  return members;
}

/** Wait up to ~90 s for an agent run to finish; null when it is still going. */
async function waitForRun(runId: string): Promise<AgentRun | null> {
  for (let i = 0; i < 60; i++) {
    await new Promise((r) => setTimeout(r, 1500));
    const r = (await pdService.run(runId)).data;
    if (r.status && !['queued', 'running'].includes(r.status)) return r;
  }
  return null;
}

/**
 * Run the task's agent and say honestly how it went. A run that produced a draft leaves the task
 * awaiting approval (JobShout can ask while its run is still going); a succeeded run with nothing to
 * send hands the task back. Returns [is it good news, message].
 */
async function runAgent(taskId: string): Promise<[boolean, string]> {
  const run = (await pdService.agentRun(taskId)).data;
  toast('AI is working on it…', { icon: '✨' });
  const r = await waitForRun(run.uuid);
  if (r?.status === 'failed') throw new Error(`AI couldn't finish${r.error ? `: ${r.error}` : ''}`);
  if (r?.status === 'cancelled') return [false, 'The AI run was cancelled — the task is back with a person'];
  const status = (await pdService.task(taskId)).data.pd_status;
  if (status === 'awaiting_approval') return [true, 'Draft ready — check Approvals'];
  if (status === 'done') return [true, 'Done — the AI finished the task'];
  if (!r) return [false, 'Still working — the draft will appear in Approvals when it’s ready'];
  return [false, 'AI found nothing to send — the task is back with you'];
}

const RULE_WORDS: Record<string, string> = {
  two_person: 'two people must approve it', manager: 'a manager must approve it', any_operator: 'an operator must approve it',
};

export default function TaskActions({ task, onChanged, compact }: { task: AnyTask; onChanged?: () => void; compact?: boolean }) {
  const { can } = usePdMe();
  const members = useMembers();
  const [busy, setBusy] = useState<string | null>(null);
  const [modal, setModal] = useState<null | 'done' | 'assign' | 'snooze' | 'contact'>(null);
  const [form, setForm] = useState<Record<string, string>>({});
  const open = !['done', 'cancelled'].includes(task.pd_status || '');
  const canUpdate = can('tasks', 'update');
  const aiReady = task.agent_eligible && !['agent_running', 'awaiting_approval'].includes(task.pd_status || '') && can('ai', 'create');
  // Closing it needs someone else's sign-off: ask for it instead of marking it done (PUT /tasks would 409).
  const rule = task.approval_rule || '';
  const needsApproval =
    rule === 'two_person' || (rule === 'manager' && !can('approvals', 'manage')) || (rule === 'any_operator' && !can('approvals', 'update'));
  const close = (evidence?: Record<string, unknown>) =>
    needsApproval
      ? act('done', () => pdService.requestCompletion(task.task_uuid, evidence ? { evidence } : {}), `Sent for approval — ${RULE_WORDS[rule]}`)
      : act('done', () => pdService.updateTask(task.task_uuid, { pd_status: 'done', ...(evidence ? { evidence } : {}) }), evidence ? 'Task closed' : 'Task done');

  async function act(name: string, fn: () => Promise<unknown>, okMsg: string) {
    setBusy(name);
    try {
      await fn();
      toast.success(okMsg);
      setModal(null);
      setForm({});
      onChanged?.();
    } catch (e) {
      toast.error(pdErrorText(e));
    } finally {
      setBusy(null);
    }
  }

  if (!open) return null;
  const size = compact ? 'sm' : 'sm';

  return (
    <div className="flex flex-wrap items-center gap-1.5" data-tour="task-actions">
      {/* awaiting_approval: decide it in Approvals first (the API refuses a status change meanwhile). */}
      {canUpdate && task.pd_status !== 'awaiting_approval' && (
        <Button
          size={size}
          variant="primary"
          leftIcon={<CheckCircle2 className="h-4 w-4" />}
          isLoading={busy === 'done'}
          onClick={() => (task.compliance ? setModal('done') : close())}
        >
          {needsApproval ? 'Send for approval' : 'Do it'}
        </Button>
      )}
      {aiReady && (
        <Button
          size={size}
          variant="outline"
          leftIcon={<Sparkles className="h-4 w-4" />}
          isLoading={busy === 'ai'}
          data-tour="let-ai"
          onClick={async () => {
            setBusy('ai');
            try {
              const [good, msg] = await runAgent(task.task_uuid);
              if (good) toast.success(msg);
              else toast(msg);
              onChanged?.();
            } catch (e) {
              toast.error(pdErrorText(e));
            } finally {
              setBusy(null);
            }
          }}
        >
          Let AI do it
        </Button>
      )}
      {canUpdate && (
        <>
          <Button size={size} variant="ghost" leftIcon={<UserPlus className="h-4 w-4" />} onClick={() => setModal('assign')}>
            Assign
          </Button>
          <Button size={size} variant="ghost" leftIcon={<AlarmClock className="h-4 w-4" />} onClick={() => setModal('snooze')}>
            Snooze
          </Button>
        </>
      )}
      {can('tasks', 'create') && (task.deal_uuid || (task as Task).lead_uuid) && (
        <Button size={size} variant="ghost" leftIcon={<PhoneCall className="h-4 w-4" />} onClick={() => setModal('contact')}>
          Log contact
        </Button>
      )}

      <Modal isOpen={modal === 'done'} onClose={() => setModal(null)} title="Close a compliance task" description="A named person closes compliance tasks, with evidence.">
        <Textarea label="Evidence (what was checked, where it's filed)" value={form.note || ''} onChange={(e) => setForm({ ...form, note: e.target.value })} rows={3} />
        <div className="mt-4 flex justify-end gap-2">
          <Button variant="ghost" onClick={() => setModal(null)}>Cancel</Button>
          <Button
            disabled={!form.note}
            isLoading={busy === 'done'}
            onClick={() => close({ note: form.note })}
          >
            {needsApproval ? 'Send for approval' : 'Close task'}
          </Button>
        </div>
      </Modal>

      <Modal isOpen={modal === 'assign'} onClose={() => setModal(null)} title={`Assign: ${task.title}`}>
        <Select label="Owner" value={form.owner || ''} onChange={(e) => setForm({ ...form, owner: e.target.value })}>
          <option value="">Choose a person…</option>
          {members.map((m) => (
            <option key={m.uuid} value={m.uuid}>{m.name}</option>
          ))}
        </Select>
        <div className="mt-4 flex justify-end gap-2">
          <Button variant="ghost" onClick={() => setModal(null)}>Cancel</Button>
          <Button
            disabled={!form.owner}
            isLoading={busy === 'assign'}
            onClick={() => act('assign', () => pdService.updateTask(task.task_uuid, { owner_user_uuid: form.owner }), 'Assigned')}
          >
            Assign
          </Button>
        </div>
      </Modal>

      <Modal isOpen={modal === 'snooze'} onClose={() => setModal(null)} title={`Snooze: ${task.title}`} description="Snoozing needs a reason; the SLA clock keeps its rules.">
        <div className="space-y-3">
          <Input type="datetime-local" label="Until" value={form.until || ''} onChange={(e) => setForm({ ...form, until: e.target.value })} />
          <Input label="Reason" value={form.reason || ''} onChange={(e) => setForm({ ...form, reason: e.target.value })} placeholder="e.g. waiting for the seller's call back on Monday" />
        </div>
        <div className="mt-4 flex justify-end gap-2">
          <Button variant="ghost" onClick={() => setModal(null)}>Cancel</Button>
          <Button
            disabled={!form.until || !form.reason}
            isLoading={busy === 'snooze'}
            onClick={() =>
              act('snooze', () => pdService.updateTask(task.task_uuid, { snoozed_until: new Date(form.until).toISOString(), snooze_reason: form.reason }), 'Snoozed')
            }
          >
            Snooze
          </Button>
        </div>
      </Modal>

      <Modal isOpen={modal === 'contact'} onClose={() => setModal(null)} title="Log a contact" description="Calls, WhatsApps and emails made outside the system.">
        <div className="space-y-3">
          <Select label="Channel" value={form.channel || 'phone'} onChange={(e) => setForm({ ...form, channel: e.target.value })}>
            {['phone', 'whatsapp', 'sms', 'email', 'letter'].map((c) => (
              <option key={c} value={c}>{c}</option>
            ))}
          </Select>
          <Select label="Outcome" value={form.outcome || ''} onChange={(e) => setForm({ ...form, outcome: e.target.value })}>
            <option value="">—</option>
            {['spoke', 'no_answer', 'left_message', 'sent'].map((c) => (
              <option key={c} value={c}>{c.replace('_', ' ')}</option>
            ))}
          </Select>
          <Input label="Who" value={form.to_name || ''} onChange={(e) => setForm({ ...form, to_name: e.target.value })} />
          <Textarea label="Note" rows={3} value={form.note || ''} onChange={(e) => setForm({ ...form, note: e.target.value })} />
        </div>
        <div className="mt-4 flex justify-end gap-2">
          <Button variant="ghost" onClick={() => setModal(null)}>Cancel</Button>
          <Button
            isLoading={busy === 'contact'}
            onClick={() =>
              act(
                'contact',
                () =>
                  pdService.contactLog(task.task_uuid, {
                    channel: form.channel || 'phone',
                    outcome: form.outcome || undefined,
                    to_name: form.to_name || undefined,
                    note: form.note || undefined,
                  }),
                'Logged',
              )
            }
          >
            Log it
          </Button>
        </div>
      </Modal>
    </div>
  );
}

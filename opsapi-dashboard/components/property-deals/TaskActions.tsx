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
import { pdService, pdErrorText, type TaskSummary, type Task } from '@/services/property-deals.service';
import { namespaceService } from '@/services/namespace.service';
import { usePdMe } from './usePd';

type AnyTask = (TaskSummary | Task) & { task_uuid: string; title: string };

let membersCache: { uuid: string; name: string }[] | null = null;
async function loadMembers(): Promise<{ uuid: string; name: string }[]> {
  if (membersCache) return membersCache;
  // The members route reads per_page (snake case), which PaginationParams doesn't declare.
  const res = await namespaceService.getMembers({ per_page: 100 } as Parameters<typeof namespaceService.getMembers>[0]);
  membersCache = (res.data || [])
    .filter((m) => m.user)
    .map((m) => ({ uuid: m.user!.uuid, name: `${m.user!.first_name || ''} ${m.user!.last_name || ''}`.trim() || m.user!.email }));
  return membersCache;
}

export function useMembers() {
  const [members, setMembers] = useState<{ uuid: string; name: string }[]>(membersCache || []);
  useEffect(() => {
    loadMembers().then(setMembers).catch(() => setMembers([]));
  }, []);
  return members;
}

/** Wait for an agent run to finish (the draft then sits in Approvals). */
async function waitForRun(runId: string): Promise<string> {
  for (let i = 0; i < 60; i++) {
    await new Promise((r) => setTimeout(r, 1500));
    const r = (await pdService.run(runId)).data;
    if (r.status && !['queued', 'running'].includes(r.status)) return r.status === 'failed' ? `failed: ${r.error || ''}` : r.status;
  }
  return 'still running';
}

export default function TaskActions({ task, onChanged, compact }: { task: AnyTask; onChanged?: () => void; compact?: boolean }) {
  const { can } = usePdMe();
  const members = useMembers();
  const [busy, setBusy] = useState<string | null>(null);
  const [modal, setModal] = useState<null | 'done' | 'assign' | 'snooze' | 'contact'>(null);
  const [form, setForm] = useState<Record<string, string>>({});
  const open = !['done', 'cancelled'].includes(task.pd_status || '');
  const canUpdate = can('tasks', 'update');
  const aiReady = task.agent_eligible && !['agent_running', 'awaiting_approval'].includes(task.pd_status || '') && can('ai', 'create');

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
      {canUpdate && (
        <Button
          size={size}
          variant="primary"
          leftIcon={<CheckCircle2 className="h-4 w-4" />}
          isLoading={busy === 'done'}
          onClick={() =>
            task.compliance
              ? setModal('done')
              : act('done', () => pdService.updateTask(task.task_uuid, { pd_status: 'done' }), 'Task done')
          }
        >
          Do it
        </Button>
      )}
      {aiReady && (
        <Button
          size={size}
          variant="outline"
          leftIcon={<Sparkles className="h-4 w-4" />}
          isLoading={busy === 'ai'}
          data-tour="let-ai"
          onClick={() =>
            act(
              'ai',
              async () => {
                const run = (await pdService.agentRun(task.task_uuid)).data;
                toast('AI is working on it…', { icon: '✨' });
                const outcome = await waitForRun(run.uuid);
                if (outcome.startsWith('failed')) throw new Error(`AI couldn't finish: ${outcome.slice(8)}`);
              },
              'Draft ready — check Approvals',
            )
          }
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
            onClick={() => act('done', () => pdService.updateTask(task.task_uuid, { pd_status: 'done', evidence: { note: form.note } }), 'Task closed')}
          >
            Close task
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

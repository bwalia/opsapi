'use client';

/**
 * "Ask my manager" (HOW-IT-WORKS scene 5): the context, the exact question and the PA's recommendation go to a
 * manager's Manager Today as a decision card; the reply comes back onto this deal and into the next brief.
 */
import React, { useEffect, useState } from 'react';
import { Send, UserRoundCheck } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Modal, Select, Textarea } from '@/components/ui';
import { namespaceService } from '@/services/namespace.service';
import { paService, type Opportunity } from '@/services/property-pa.service';
import { pdErrorText } from '@/services/property-deals.service';
import { useAuthStore } from '@/store/auth.store';
import type { NamespaceMember } from '@/types';

const MANAGER_ROLES = new Set(['pd_manager', 'owner', 'admin']);

export default function AskManager({ opportunity }: { opportunity: Opportunity }) {
  const me = useAuthStore((s) => s.user?.uuid);
  const [open, setOpen] = useState(false);
  const [managers, setManagers] = useState<NamespaceMember[]>([]);
  const [to, setTo] = useState('');
  const [question, setQuestion] = useState('');
  const [rec, setRec] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!open) return;
    // The members route reads per_page (snake case), which PaginationParams doesn't declare.
    namespaceService.getMembers({ per_page: 100 } as Parameters<typeof namespaceService.getMembers>[0]).then((r) => {
      const list = (r.data || []).filter((m) => m.user?.uuid && m.user.uuid !== me
        && (m.is_owner || (m.roles || []).some((x) => MANAGER_ROLES.has(x.role_name))));
      setManagers(list);
      if (list[0]?.user?.uuid) setTo(list[0].user.uuid);
    }).catch((e) => toast.error(pdErrorText(e)));
    paService.prepare(opportunity.uuid).then((b) => setRec((r) => r || b.recommended_action)).catch(() => undefined);
  }, [open, me, opportunity.uuid]);

  const send = async () => {
    setBusy(true);
    try {
      const context: Record<string, unknown> = {};
      if (opportunity.expectation_price) context.seller_minimum = opportunity.expectation_price;
      if (opportunity.our_position) context.our_position = `${opportunity.our_position} (judgement)`;
      if (opportunity.decision_makers?.length) context.decision_makers = opportunity.decision_makers.map((d) => d.name).join(', ');
      await paService.handoff({ to_user_uuid: to, question: question.trim(), opportunity_uuid: opportunity.uuid,
        pa_recommendation: rec.trim() || undefined, context });
      toast.success('Sent. The answer will come back to this deal.');
      setOpen(false);
      setQuestion('');
    } catch (e) {
      toast.error(pdErrorText(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <Button variant="outline" leftIcon={<UserRoundCheck className="h-4 w-4" />} onClick={() => setOpen(true)}>Ask my manager</Button>
      <Modal isOpen={open} onClose={() => setOpen(false)} title="Ask my manager">
        <div className="space-y-3">
          <Select label="Who" value={to} onChange={(e) => setTo(e.target.value)}>
            {managers.length === 0 && <option value="">No managers in this workspace</option>}
            {managers.map((m) => (
              <option key={m.user!.uuid} value={m.user!.uuid}>{`${m.user!.first_name ?? ''} ${m.user!.last_name ?? ''}`.trim() || m.user!.email}</option>
            ))}
          </Select>
          <Textarea label="Your question" rows={3} value={question} onChange={(e) => setQuestion(e.target.value)}
            placeholder="Can we go to £230k for a 4-week completion?" />
          <Textarea label="What I'd recommend" rows={2} value={rec} onChange={(e) => setRec(e.target.value)} />
          <p className="text-xs text-secondary-500">The deal&apos;s facts go with it (minimum, our position as a judgement, decision makers).</p>
          <div className="flex justify-end">
            <Button leftIcon={<Send className="h-4 w-4" />} isLoading={busy} disabled={!to || !question.trim()} onClick={send}>Send</Button>
          </div>
        </div>
      </Modal>
    </>
  );
}

'use client';

/**
 * Moving a lead to Lost needs a reason; to Nurture, the date to contact them
 * again. Other stages move straight away (the caller doesn't open this).
 */
import React, { useEffect, useState } from 'react';
import toast from 'react-hot-toast';
import { Button, Modal } from '@/components/ui';
import { leadError, leadsService, type Lead, type LeadStage } from '@/services/leads.service';
import { FieldError } from './ui';

export function StageModal({
  lead, target, lostReasons, onClose, onDone,
}: {
  lead: { uuid: string; first_name?: string | null; last_name?: string | null } | null;
  target: LeadStage | null;
  lostReasons: string[];
  onClose: () => void;
  onDone: (lead: Lead) => void;
}) {
  const [reason, setReason] = useState('');
  const [other, setOther] = useState('');
  const [date, setDate] = useState('');
  const [busy, setBusy] = useState(false);
  const [errors, setErrors] = useState<Record<string, string>>({});

  useEffect(() => {
    setReason(lostReasons[0] ?? ''); setOther(''); setErrors({});
    const d = new Date(Date.now() + 30 * 86400000);
    setDate(d.toISOString().slice(0, 10));
  }, [target, lostReasons]);

  if (!lead || !target) return null;
  const who = `${lead.first_name ?? ''} ${lead.last_name ?? ''}`.trim() || 'this lead';
  const isLost = target === 'lost';

  const submit = async () => {
    setBusy(true); setErrors({});
    try {
      const finalReason = reason === 'Other' && other.trim() ? other.trim() : reason;
      const updated = await leadsService.move(lead.uuid, target, isLost ? { reason: finalReason } : { nurture_until: date });
      toast.success(isLost ? `${who} moved to Lost` : `${who} will come back on ${new Date(date).toLocaleDateString()}`);
      onDone(updated);
    } catch (e) {
      const err = leadError(e);
      setErrors(err.fields ?? {});
      toast.error(err.message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal isOpen onClose={onClose} size="sm"
      title={isLost ? `Why was ${who} lost?` : `When should we contact ${who} again?`}
      description={isLost ? 'The reason shows in reports, so you can see why leads are lost.'
        : 'On that date the lead comes back to Contacting with a call planned for its owner.'}
      footer={<>
        <Button variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
        <Button onClick={submit} isLoading={busy} variant={isLost ? 'danger' : 'primary'}>
          {isLost ? 'Move to Lost' : 'Move to Nurture'}
        </Button>
      </>}>
      {isLost ? (
        <div className="space-y-3">
          <label className="block text-sm font-medium text-secondary-700" htmlFor="lost-reason">Reason</label>
          <select id="lost-reason" value={reason} onChange={(e) => setReason(e.target.value)}
            className="w-full rounded-lg border border-secondary-300 px-3 py-2 text-sm focus:border-primary-500 focus:outline-none focus:ring-2 focus:ring-primary-500/20">
            {lostReasons.map((r) => <option key={r} value={r}>{r}</option>)}
          </select>
          {reason === 'Other' && (
            <input value={other} onChange={(e) => setOther(e.target.value)} maxLength={200} placeholder="Say why, in a few words"
              className="w-full rounded-lg border border-secondary-300 px-3 py-2 text-sm focus:border-primary-500 focus:outline-none focus:ring-2 focus:ring-primary-500/20" />
          )}
          <FieldError message={errors.reason} />
        </div>
      ) : (
        <div className="space-y-2">
          <label className="block text-sm font-medium text-secondary-700" htmlFor="nurture-date">Contact them again on</label>
          <input id="nurture-date" type="date" value={date} min={new Date(Date.now() + 86400000).toISOString().slice(0, 10)}
            onChange={(e) => setDate(e.target.value)}
            className="w-full rounded-lg border border-secondary-300 px-3 py-2 text-sm focus:border-primary-500 focus:outline-none focus:ring-2 focus:ring-primary-500/20" />
          <FieldError message={errors.nurture_until} />
        </div>
      )}
    </Modal>
  );
}

'use client';

/**
 * F-Gas / refrigerant record for a visit. Shared by the manager visit page and
 * the engineer's guided work screen. The on-site engineer logs it (the fields
 * are on the visit's engineer-editable allow-list, so no fs_visits.update).
 */

import React, { useState } from 'react';
import toast from 'react-hot-toast';
import { Button, Input, Textarea, Select } from '@/components/ui';
import { fieldService, type FsVisitDetail } from '@/services/field-service.service';
import { SectionCard, apiError } from './shared';

export const LEAK_LABEL: Record<string, string> = {
  pass: 'Leak check passed',
  fail: 'Leak check FAILED',
  na: 'No leak check',
};
export const LEAK_TONE: Record<string, string> = {
  pass: 'bg-green-50 text-green-700',
  fail: 'bg-red-50 text-red-700',
  na: 'bg-secondary-100 text-secondary-600',
};

export function FGasCard({ visit, canWork, onSaved }: { visit: FsVisitDetail; canWork: boolean; onSaved: () => void }) {
  const blank = () => ({
    refrigerant_type: visit.refrigerant_type || '',
    refrigerant_added_kg: visit.refrigerant_added_kg != null ? String(visit.refrigerant_added_kg) : '',
    refrigerant_recovered_kg: visit.refrigerant_recovered_kg != null ? String(visit.refrigerant_recovered_kg) : '',
    leak_check_result: visit.leak_check_result || '',
    fgas_cylinder_ref: visit.fgas_cylinder_ref || '',
    leak_check_notes: visit.leak_check_notes || '',
  });
  const [editing, setEditing] = useState(false);
  const [saving, setSaving] = useState(false);
  const [f, setF] = useState(blank);

  const has = !!(visit.refrigerant_type || visit.refrigerant_added_kg || visit.refrigerant_recovered_kg ||
    visit.leak_check_result || visit.fgas_cylinder_ref || visit.leak_check_notes);

  const start = () => { setF(blank()); setEditing(true); };
  const set = (k: keyof ReturnType<typeof blank>) =>
    (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>) =>
      setF((prev) => ({ ...prev, [k]: e.target.value }));

  const save = async () => {
    setSaving(true);
    try {
      await fieldService.updateVisit(visit.uuid, {
        refrigerant_type: f.refrigerant_type.trim(),
        refrigerant_added_kg: f.refrigerant_added_kg.trim(),
        refrigerant_recovered_kg: f.refrigerant_recovered_kg.trim(),
        leak_check_result: f.leak_check_result,
        fgas_cylinder_ref: f.fgas_cylinder_ref.trim(),
        leak_check_notes: f.leak_check_notes.trim(),
      });
      toast.success('F-Gas record saved');
      setEditing(false);
      onSaved();
    } catch (err) {
      toast.error(apiError(err, 'Failed to save F-Gas record'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <SectionCard
      title="F-Gas / refrigerant"
      actions={
        canWork && !editing ? (
          <Button size="sm" variant="ghost" onClick={start}>
            {has ? 'Edit' : 'Log F-Gas'}
          </Button>
        ) : undefined
      }
    >
      {editing ? (
        <div className="space-y-3">
          <div className="grid grid-cols-2 gap-3">
            <Input label="Refrigerant type" value={f.refrigerant_type} onChange={set('refrigerant_type')} placeholder="e.g. R32" />
            <Input label="Cylinder ref" value={f.fgas_cylinder_ref} onChange={set('fgas_cylinder_ref')} />
            <Input label="Charged (kg)" inputMode="decimal" value={f.refrigerant_added_kg} onChange={set('refrigerant_added_kg')} />
            <Input label="Recovered (kg)" inputMode="decimal" value={f.refrigerant_recovered_kg} onChange={set('refrigerant_recovered_kg')} />
          </div>
          <Select label="Leak check" value={f.leak_check_result} onChange={set('leak_check_result')}>
            <option value="">Not recorded</option>
            <option value="pass">Passed</option>
            <option value="fail">Failed</option>
            <option value="na">Not applicable</option>
          </Select>
          <Textarea label="Leak check notes" rows={2} value={f.leak_check_notes} onChange={set('leak_check_notes')} />
          <div className="flex justify-end gap-2">
            <Button size="sm" variant="ghost" onClick={() => setEditing(false)} disabled={saving}>Cancel</Button>
            <Button size="sm" onClick={save} isLoading={saving}>Save</Button>
          </div>
        </div>
      ) : has ? (
        <div className="space-y-2 text-sm">
          <div className="grid grid-cols-2 gap-x-4 gap-y-1">
            <p><span className="text-secondary-500">Type: </span>{visit.refrigerant_type || '—'}</p>
            <p><span className="text-secondary-500">Cylinder: </span>{visit.fgas_cylinder_ref || '—'}</p>
            <p><span className="text-secondary-500">Charged: </span>{visit.refrigerant_added_kg != null ? `${visit.refrigerant_added_kg} kg` : '—'}</p>
            <p><span className="text-secondary-500">Recovered: </span>{visit.refrigerant_recovered_kg != null ? `${visit.refrigerant_recovered_kg} kg` : '—'}</p>
          </div>
          {visit.leak_check_result && (
            <span className={`inline-block rounded-md px-2 py-0.5 text-xs font-medium ${LEAK_TONE[visit.leak_check_result] || LEAK_TONE.na}`}>
              {LEAK_LABEL[visit.leak_check_result] || visit.leak_check_result}
            </span>
          )}
          {visit.leak_check_notes && <p className="text-secondary-700 whitespace-pre-line">{visit.leak_check_notes}</p>}
        </div>
      ) : (
        <p className="text-sm text-secondary-500">No refrigerant handled on this visit.</p>
      )}
    </SectionCard>
  );
}

export default FGasCard;

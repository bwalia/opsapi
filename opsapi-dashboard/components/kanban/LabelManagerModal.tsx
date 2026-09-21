'use client';

import React, { memo, useState } from 'react';
import { Pencil, Trash2, Plus, Check, X } from 'lucide-react';
import { toast } from 'react-hot-toast';
import Modal from '@/components/ui/Modal';
import Button from '@/components/ui/Button';
import Input from '@/components/ui/Input';
import type { KanbanLabel } from '@/types';
import { kanbanService, DEFAULT_LABEL_COLORS } from '@/services/kanban.service';

const COLORS = DEFAULT_LABEL_COLORS;

function ColorRow({ value, onChange }: { value: string; onChange: (c: string) => void }) {
  return (
    <div className="flex flex-wrap gap-1.5">
      {COLORS.map((c) => (
        <button
          key={c}
          type="button"
          onClick={() => onChange(c)}
          aria-label={`Colour ${c}`}
          className={`w-6 h-6 rounded-full transition-all ${value === c ? 'ring-2 ring-offset-1 ring-primary-500' : ''}`}
          style={{ backgroundColor: c }}
        />
      ))}
    </div>
  );
}

export interface LabelManagerModalProps {
  isOpen: boolean;
  onClose: () => void;
  projectUuid: string;
  labels: KanbanLabel[];
  /** Reload the project labels after a create/update/delete. */
  onChanged: () => void;
}

/**
 * Create / edit / delete a project's labels. Backend CRUD already existed
 * (routes/kanban-labels.lua, admin-gated) but had no UI — you could only attach
 * existing labels. This is that management surface.
 */
export const LabelManagerModal = memo(function LabelManagerModal({
  isOpen,
  onClose,
  projectUuid,
  labels,
  onChanged,
}: LabelManagerModalProps) {
  const [newName, setNewName] = useState('');
  const [newColor, setNewColor] = useState(COLORS[0]);
  const [busy, setBusy] = useState(false);
  const [editUuid, setEditUuid] = useState<string | null>(null);
  const [editName, setEditName] = useState('');
  const [editColor, setEditColor] = useState('');

  const create = async () => {
    if (!newName.trim() || busy) return;
    setBusy(true);
    try {
      await kanbanService.createLabel(projectUuid, { name: newName.trim(), color: newColor });
      setNewName('');
      onChanged();
    } catch {
      toast.error('Failed to create label');
    } finally {
      setBusy(false);
    }
  };

  const save = async (uuid: string) => {
    if (!editName.trim() || busy) return;
    setBusy(true);
    try {
      await kanbanService.updateLabel(uuid, { name: editName.trim(), color: editColor });
      setEditUuid(null);
      onChanged();
    } catch {
      toast.error('Failed to update label');
    } finally {
      setBusy(false);
    }
  };

  const remove = async (uuid: string) => {
    if (!window.confirm('Delete this label? It will be removed from all tasks.')) return;
    setBusy(true);
    try {
      await kanbanService.deleteLabel(uuid);
      onChanged();
    } catch {
      toast.error('Failed to delete label');
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Manage labels" size="md">
      <div className="space-y-4">
        <div className="space-y-2 max-h-72 overflow-y-auto -mx-1 px-1">
          {labels.length === 0 && <p className="text-sm text-secondary-500">No labels yet — add one below.</p>}
          {labels.map((l) =>
            editUuid === l.uuid ? (
              <div key={l.uuid} className="space-y-2 rounded-lg border border-secondary-200 p-2">
                <ColorRow value={editColor} onChange={setEditColor} />
                <div className="flex items-center gap-2">
                  <Input value={editName} onChange={(e) => setEditName(e.target.value)} className="flex-1" autoFocus />
                  <button onClick={() => save(l.uuid)} disabled={busy} aria-label="Save" className="p-1.5 text-green-600 hover:bg-green-50 rounded">
                    <Check className="w-4 h-4" />
                  </button>
                  <button onClick={() => setEditUuid(null)} aria-label="Cancel" className="p-1.5 text-secondary-500 hover:bg-secondary-100 rounded">
                    <X className="w-4 h-4" />
                  </button>
                </div>
              </div>
            ) : (
              <div key={l.uuid} className="flex items-center gap-2">
                <span className="w-4 h-4 rounded-full shrink-0" style={{ backgroundColor: l.color }} />
                <span className="flex-1 text-sm text-secondary-800 truncate">{l.name}</span>
                <button
                  onClick={() => {
                    setEditUuid(l.uuid);
                    setEditName(l.name);
                    setEditColor(l.color);
                  }}
                  aria-label="Edit label"
                  className="p-1.5 text-secondary-500 hover:text-primary-600 rounded"
                >
                  <Pencil className="w-4 h-4" />
                </button>
                <button onClick={() => remove(l.uuid)} aria-label="Delete label" className="p-1.5 text-secondary-500 hover:text-error-500 rounded">
                  <Trash2 className="w-4 h-4" />
                </button>
              </div>
            )
          )}
        </div>

        <div className="border-t border-secondary-200 pt-4 space-y-2">
          <label className="block text-sm font-medium text-secondary-700">New label</label>
          <ColorRow value={newColor} onChange={setNewColor} />
          <div className="flex gap-2">
            <Input
              value={newName}
              onChange={(e) => setNewName(e.target.value)}
              placeholder="Label name"
              className="flex-1"
              onKeyDown={(e) => {
                if (e.key === 'Enter') {
                  e.preventDefault();
                  create();
                }
              }}
            />
            <Button onClick={create} isLoading={busy} disabled={!newName.trim()} leftIcon={<Plus className="w-4 h-4" />}>
              Add
            </Button>
          </div>
        </div>

        <div className="flex justify-end pt-1">
          <Button variant="outline" onClick={onClose}>
            Done
          </Button>
        </div>
      </div>
    </Modal>
  );
});

export default LabelManagerModal;

'use client';

/**
 * The workspace playbook: how this company operates. The PA (chat on Today) and the follow-up agent read
 * it and follow it, so editing a section changes how the AI works. Markdown sections; managers edit.
 */
import React, { useState } from 'react';
import { BookOpen, Plus } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Card, Input, Textarea } from '@/components/ui';
import { pdService, pdErrorText, type PlaybookSection } from '@/services/property-deals.service';
import { usePdData } from '../usePd';
import { ErrorNote, Spinner, dateText } from '../ui';

export default function PlaybookEditor({ canEdit }: { canEdit: boolean }) {
  const list = usePdData(async () => (await pdService.playbooks()).data, []);
  const [adding, setAdding] = useState(false);
  if (list.loading && !list.data) return <Spinner />;
  return (
    <div className="space-y-4">
      <Card>
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="flex items-start gap-3">
            <BookOpen className="mt-0.5 h-5 w-5 text-primary-600" aria-hidden />
            <div>
              <h3 className="font-semibold text-secondary-900">Playbook — how we operate</h3>
              <p className="text-sm text-secondary-500">
                The PA on the Today page and the follow-up AI read this and work your way: daily priorities, call scripts,
                follow-up rules, objections, compliance and when a person must take over. Change a section and the AI changes with it.
              </p>
            </div>
          </div>
          {canEdit && <Button variant="outline" leftIcon={<Plus className="h-4 w-4" />} onClick={() => setAdding(true)}>Add section</Button>}
        </div>
      </Card>
      <ErrorNote error={list.error} />
      {adding && <Section isNew canEdit onSaved={() => { setAdding(false); list.refresh(); }} onCancel={() => setAdding(false)} />}
      {(list.data || []).map((s) => <Section key={s.key} section={s} canEdit={canEdit} onSaved={list.refresh} />)}
    </div>
  );
}

function Section({ section, canEdit, isNew, onSaved, onCancel }: {
  section?: PlaybookSection; canEdit: boolean; isNew?: boolean; onSaved: () => void; onCancel?: () => void;
}) {
  const [editing, setEditing] = useState(Boolean(isNew));
  const [f, setF] = useState({ key: section?.key || '', title: section?.title || '', body: section?.body || '' });
  const [busy, setBusy] = useState(false);
  return (
    <Card>
      {editing ? (
        <div className="space-y-3">
          {isNew && <Input label="Key (lowercase, e.g. landlord_call)" value={f.key} onChange={(e) => setF({ ...f, key: e.target.value.toLowerCase().replace(/[^a-z0-9_]/g, '_') })} />}
          <Input label="Title" value={f.title} onChange={(e) => setF({ ...f, title: e.target.value })} />
          <Textarea label="What we do (markdown)" rows={10} value={f.body} onChange={(e) => setF({ ...f, body: e.target.value })} />
          <div className="flex justify-end gap-2">
            <Button variant="ghost" onClick={() => { setEditing(false); onCancel?.(); }}>Cancel</Button>
            <Button isLoading={busy} disabled={!f.title || !f.key} onClick={async () => {
              setBusy(true);
              try {
                await pdService.savePlaybook(f.key, { title: f.title, body: f.body });
                toast.success('Saved — the PA uses it from the next message');
                setEditing(false);
                onSaved();
              } catch (e) { toast.error(pdErrorText(e)); } finally { setBusy(false); }
            }}>Save</Button>
          </div>
        </div>
      ) : (
        <div>
          <div className="flex items-start justify-between gap-2">
            <h4 className="font-semibold text-secondary-900">{section?.title}</h4>
            {canEdit && <Button size="sm" variant="ghost" onClick={() => setEditing(true)}>Edit</Button>}
          </div>
          <pre className="mt-2 whitespace-pre-wrap font-sans text-sm text-secondary-700">{section?.body}</pre>
          {section?.updated_at && <p className="mt-2 text-xs text-secondary-400">Updated {dateText(section.updated_at, true)}</p>}
        </div>
      )}
    </Card>
  );
}

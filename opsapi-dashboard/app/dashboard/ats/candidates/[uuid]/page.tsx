'use client';

/**
 * Hiring › Candidate — /dashboard/ats/candidates/[uuid]
 * Contact details, applications, interviews and notes. "Export data" answers a
 * subject access request; "Delete candidate" removes everything (only an
 * audit entry that it happened stays).
 */

import React, { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import { useParams, useRouter } from 'next/navigation';
import toast from 'react-hot-toast';
import { Download, Trash2 } from 'lucide-react';
import { Button, Card, ConfirmDialog, Textarea } from '@/components/ui';
import { AtsShell, StageBadge } from '@/components/ats/AtsShell';
import { apiError } from '@/components/field-service/shared';
import { atsService, when, type Application, type Candidate } from '@/services/ats.service';

type Full = Candidate & { applications: Application[] };

export default function CandidatePage() {
  const { uuid } = useParams<{ uuid: string }>();
  const router = useRouter();
  const [c, setC] = useState<Full | null>(null);
  const [note, setNote] = useState('');
  const [deleting, setDeleting] = useState(false);
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => {
    atsService.candidate(uuid).then(setC).catch((e) => toast.error(apiError(e, 'Could not load the candidate')));
  }, [uuid]);
  useEffect(load, [load]);

  const exportData = async () => {
    try {
      const data = await atsService.exportCandidate(uuid);
      const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = `candidate-${uuid}.json`;
      a.click();
      URL.revokeObjectURL(a.href);
    } catch (e) {
      toast.error(apiError(e, 'Could not export'));
    }
  };

  const addNote = async () => {
    setBusy(true);
    try {
      await atsService.addNote(uuid, note);
      setNote('');
      load();
    } catch (e) {
      toast.error(apiError(e, 'Could not save the note'));
    } finally {
      setBusy(false);
    }
  };

  const remove = async () => {
    setBusy(true);
    try {
      await atsService.deleteCandidate(uuid);
      toast.success('Candidate deleted');
      router.push('/dashboard/ats/candidates');
    } catch (e) {
      toast.error(apiError(e, 'Could not delete'));
      setBusy(false);
    }
  };

  if (!c) return <AtsShell title="Candidate" module="ats_candidates"><p className="text-secondary-500">Loading…</p></AtsShell>;

  return (
    <AtsShell title={c.name} module="ats_candidates" description={[c.email, c.phone, c.reference].filter(Boolean).join(' · ') || undefined}
      actions={<>
        <Button variant="ghost" leftIcon={<Download className="h-4 w-4" />} onClick={exportData}>Export data</Button>
        <Button variant="danger" leftIcon={<Trash2 className="h-4 w-4" />} onClick={() => setDeleting(true)}>Delete candidate</Button>
      </>}>
      <div className="grid gap-6 lg:grid-cols-3">
        <div className="space-y-6 lg:col-span-2">
          <Card>
            <h2 className="mb-3 font-semibold">Applications</h2>
            {c.applications.length === 0 ? <p className="text-sm text-secondary-500">None.</p> : (
              <ul className="divide-y divide-secondary-100">
                {c.applications.map((a) => (
                  <li key={a.uuid} className="flex flex-wrap items-center justify-between gap-2 py-2 text-sm">
                    <Link href={`/dashboard/ats/jobs/${a.job?.uuid}`} className="font-medium text-primary-600 hover:underline">{a.job?.title}</Link>
                    <span className="flex items-center gap-2">
                      <StageBadge stage={a.stage} />
                      {a.decision_reason && <span className="text-xs text-secondary-500">{a.decision_reason} ({a.decided_by})</span>}
                    </span>
                  </li>
                ))}
              </ul>
            )}
          </Card>
          <Card>
            <h2 className="mb-3 font-semibold">Interviews</h2>
            {(c.interviews ?? []).length === 0 ? <p className="text-sm text-secondary-500">None yet.</p> : (
              <ul className="divide-y divide-secondary-100">
                {(c.interviews ?? []).map((i) => (
                  <li key={i.uuid} className="flex flex-wrap items-center justify-between gap-2 py-2 text-sm">
                    <Link href={`/dashboard/ats/interviews/${i.uuid}`} className="font-medium text-primary-600 hover:underline">
                      {i.job_title} · {i.state.replace('_', ' ')}
                    </Link>
                    <span className="text-xs text-secondary-500">
                      {i.source === 'hosted' ? 'Online' : 'Snazzy Pro'} · {i.decision ? `Decision: ${i.decision}` : i.reviewed ? 'Reviewed' : 'Not reviewed'}
                    </span>
                  </li>
                ))}
              </ul>
            )}
          </Card>
        </div>
        <Card>
          <h2 className="mb-3 font-semibold">Notes</h2>
          <Textarea aria-label="New note" rows={3} value={note} onChange={(e) => setNote(e.target.value)} placeholder="Add a note for the team" />
          <Button className="mt-2" size="sm" onClick={addNote} isLoading={busy} disabled={!note.trim()}>Add note</Button>
          <ul className="mt-4 space-y-3">
            {(c.notes ?? []).map((n) => (
              <li key={n.uuid} className="rounded-lg bg-secondary-50 p-3 text-sm">
                <p className="whitespace-pre-wrap text-secondary-800">{n.body}</p>
                <p className="mt-1 text-xs text-secondary-500">{n.author_name} · {when(n.created_at)}</p>
              </li>
            ))}
          </ul>
        </Card>
      </div>
      <ConfirmDialog isOpen={deleting} onClose={() => setDeleting(false)} onConfirm={remove} isLoading={busy}
        title={`Delete ${c.name}?`} confirmText="Delete everything"
        message="This permanently deletes the candidate, their applications, interviews, notes, files and self-ID answers. Only a record that the deletion happened is kept." />
    </AtsShell>
  );
}

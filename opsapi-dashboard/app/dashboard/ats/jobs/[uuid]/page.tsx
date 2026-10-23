'use client';

/**
 * Hiring › Job — /dashboard/ats/jobs/[uuid]
 *
 * The pipeline as a kanban (drag a card, or use its stage menu). The Rejected
 * column only takes a card through the reject dialog, which asks a person for
 * a reason; nothing here moves candidates on its own.
 */

import React, { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import { useParams } from 'next/navigation';
import toast from 'react-hot-toast';
import { Copy, Mail, Sparkles, UserPlus } from 'lucide-react';
import { Button, Card, Input, Modal, Select, Textarea } from '@/components/ui';
import { AtsShell, Empty, StageBadge } from '@/components/ats/AtsShell';
import { apiError } from '@/components/field-service/shared';
import {
  atsService, STAGES, STAGE_LABEL, type Application, type Delivery, type Job, type KitSummary, type Stage,
} from '@/services/ats.service';

type Column = { stage: Stage; applications: Application[] };

function AddCandidateModal({ job, open, onClose, onDone }: { job: Job; open: boolean; onClose: () => void; onDone: () => void }) {
  const [form, setForm] = useState({ name: '', email: '', phone: '', reference: '' });
  const [busy, setBusy] = useState(false);
  const set = (k: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement>) => setForm((f) => ({ ...f, [k]: e.target.value }));
  const save = async () => {
    setBusy(true);
    try {
      await atsService.createCandidate({ ...form, job_uuid: job.uuid });
      setForm({ name: '', email: '', phone: '', reference: '' });
      onDone();
      onClose();
    } catch (e) {
      toast.error(apiError(e, 'Could not add the candidate'));
    } finally {
      setBusy(false);
    }
  };
  return (
    <Modal isOpen={open} onClose={onClose} title={`Add a candidate to ${job.title}`}
      footer={<><Button variant="ghost" onClick={onClose}>Cancel</Button>
        <Button onClick={save} isLoading={busy} disabled={!form.name.trim()}>Add candidate</Button></>}>
      <div className="space-y-3">
        <Input label="Name" value={form.name} onChange={set('name')} required autoFocus />
        <Input label="Email" type="email" value={form.email} onChange={set('email')} />
        <Input label="Phone" value={form.phone} onChange={set('phone')} />
        <Input label="Your reference" value={form.reference} onChange={set('reference')} helperText="For example an ID from another system." />
      </div>
    </Modal>
  );
}

function InviteModal({ app, job, onClose }: { app: Application | null; job: Job; onClose: () => void }) {
  const [kits, setKits] = useState<KitSummary[]>([]);
  const [kit, setKit] = useState('');
  const [days, setDays] = useState('7');
  const [delivery, setDelivery] = useState<Delivery>('online');
  const [link, setLink] = useState<string | null>(null);
  const [appLink, setAppLink] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!app) return;
    setLink(null);
    setAppLink(null);
    atsService.kits({ approved: true }).then((k) => {
      setKits(k);
      setKit(job.kit_uuid && k.some((x) => x.uuid === job.kit_uuid) ? job.kit_uuid : k[0]?.uuid ?? '');
    }).catch(() => undefined);
  }, [app, job.kit_uuid]);

  const invite = async () => {
    if (!app) return;
    setBusy(true);
    try {
      const r = await atsService.invite(app.uuid, kit, Number(days), delivery);
      setLink(r.url);
      setAppLink(r.app_url ?? null);
    } catch (e) {
      toast.error(apiError(e, 'Could not create the invitation'));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal isOpen={!!app} onClose={onClose} title={`Invite ${app?.candidate?.name ?? ''} to an AI interview`} size="lg"
      footer={link ? <Button onClick={onClose}>Done</Button> : <><Button variant="ghost" onClick={onClose}>Cancel</Button>
        <Button onClick={invite} isLoading={busy} disabled={!kit}>Create link</Button></>}>
      {link ? (
        <div className="space-y-3">
          <p className="text-sm text-secondary-600">
            Send this private link to the candidate. <strong>It is shown only now</strong>: only a fingerprint of it is stored.
          </p>
          <div className="flex gap-2">
            <Input aria-label="Interview link" readOnly value={link} onFocus={(e) => e.currentTarget.select()} />
            <Button variant="outline" leftIcon={<Copy className="h-4 w-4" />}
              onClick={() => navigator.clipboard.writeText(link).then(() => toast.success('Link copied'))}>Copy</Button>
          </div>
          {delivery === 'offline' && (
            <p className="text-sm text-secondary-600">
              This interview runs offline in the Snazzy Pro app on the candidate&apos;s Mac: they open the link there
              {appLink ? <> (or this app link: <code className="break-all text-xs">{appLink}</code>)</> : null}.
            </p>
          )}
          {app?.candidate?.email && (
            <a className="inline-flex items-center gap-1 text-sm text-primary-600 underline"
              href={`mailto:${app.candidate.email}?subject=${encodeURIComponent(`Your interview for ${job.title}`)}&body=${encodeURIComponent(
                `Hello ${app.candidate.name},\n\nThank you for applying for ${job.title}. The first step is a short interview you can do ${delivery === 'offline' ? 'in the Snazzy Pro app on your Mac (it runs on your own computer)' : 'online'}, at a time that suits you:\n\n${link}\n\nThe interviewer is an AI; a person on our team reviews your answers and makes the decision. You can ask for adjustments, or to speak to a person instead, on the first page.\n\nKind regards`)}`}>
              <Mail className="h-4 w-4" /> Open an email to {app.candidate.email}
            </a>
          )}
        </div>
      ) : kits.length === 0 ? (
        <p className="text-sm text-secondary-600">
          No approved interview kit yet. <Link className="text-primary-600 underline" href="/dashboard/ats/kits">Create and approve one</Link> first.
        </p>
      ) : (
        <div className="space-y-4">
          <Select label="Interview kit" value={kit} onChange={(e) => setKit(e.target.value)}>
            {kits.map((k) => <option key={k.uuid} value={k.uuid}>{k.title} (v{k.version})</option>)}
          </Select>
          <Select label="Link works for" value={days} onChange={(e) => setDays(e.target.value)}>
            {[3, 7, 14, 30].map((d) => <option key={d} value={d}>{d} days</option>)}
          </Select>
          <Select label="Where it runs" value={delivery} onChange={(e) => setDelivery(e.target.value as Delivery)}>
            <option value="online">Online in the browser</option>
            <option value="offline">Offline in Snazzy Pro (candidate&apos;s Mac)</option>
          </Select>
        </div>
      )}
    </Modal>
  );
}

function RejectModal({ app, reasons, onClose, onDone }: { app: Application | null; reasons: string[]; onClose: () => void; onDone: () => void }) {
  const [reason, setReason] = useState('');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  useEffect(() => { setReason(reasons[0] ?? ''); setNote(''); }, [app, reasons]);
  const save = async () => {
    if (!app) return;
    setBusy(true);
    try {
      await atsService.reject(app.uuid, note.trim() ? `${reason}: ${note.trim()}` : reason);
      onDone();
      onClose();
    } catch (e) {
      toast.error(apiError(e, 'Could not record the decision'));
    } finally {
      setBusy(false);
    }
  };
  return (
    <Modal isOpen={!!app} onClose={onClose} title={`Decline ${app?.candidate?.name ?? ''}?`}
      description="This records your decision. Nothing is sent to the candidate."
      footer={<><Button variant="ghost" onClick={onClose}>Cancel</Button>
        <Button variant="danger" onClick={save} isLoading={busy} disabled={!reason}>Decline</Button></>}>
      <div className="space-y-3">
        <Select label="Reason" value={reason} onChange={(e) => setReason(e.target.value)}>
          {reasons.map((r) => <option key={r}>{r}</option>)}
        </Select>
        <Textarea label="Note (optional)" rows={3} value={note} onChange={(e) => setNote(e.target.value)} />
      </div>
    </Modal>
  );
}

export default function JobPage() {
  const { uuid } = useParams<{ uuid: string }>();
  const [job, setJob] = useState<Job | null>(null);
  const [columns, setColumns] = useState<Column[]>([]);
  const [reasons, setReasons] = useState<string[]>([]);
  const [adding, setAdding] = useState(false);
  const [inviting, setInviting] = useState<Application | null>(null);
  const [rejecting, setRejecting] = useState<Application | null>(null);
  const [dragging, setDragging] = useState<Application | null>(null);
  const [tab, setTab] = useState<'pipeline' | 'details'>('pipeline');

  const load = useCallback(() => {
    atsService.job(uuid).then(setJob).catch((e) => toast.error(apiError(e, 'Could not load the job')));
    atsService.pipeline(uuid).then(setColumns).catch(() => undefined);
  }, [uuid]);
  useEffect(() => {
    load();
    atsService.settings().then((s) => setReasons(s.decline_reasons)).catch(() => undefined);
  }, [load]);

  const move = async (app: Application, stage: Stage) => {
    if (stage === app.stage) return;
    if (stage === 'rejected') { setRejecting(app); return; }
    try {
      await atsService.moveStage(app.uuid, stage);
      load();
    } catch (e) {
      toast.error(apiError(e, 'Could not move the candidate'));
    }
  };

  if (!job) return <AtsShell title="Job"><p className="text-secondary-500">Loading…</p></AtsShell>;

  return (
    <AtsShell title={job.title} description={[job.department, job.location, job.employment_type].filter(Boolean).join(' · ') || undefined}
      actions={<>
        <Link href={job.kit_uuid ? `/dashboard/ats/kits/${job.kit_uuid}` : `/dashboard/ats/kits?job=${job.uuid}`}
          className="inline-flex h-10 items-center gap-2 rounded-lg border-2 border-primary-500 px-4 text-sm font-medium text-primary-600 hover:bg-primary-50">
          <Sparkles className="h-4 w-4" /> {job.kit_uuid ? 'Interview kit' : 'Create interview kit'}
        </Link>
        <Button leftIcon={<UserPlus className="h-4 w-4" />} onClick={() => setAdding(true)}>Add candidate</Button>
      </>}>
      <div role="tablist" className="flex gap-2">
        {(['pipeline', 'details'] as const).map((t) => (
          <button key={t} role="tab" aria-selected={tab === t} onClick={() => setTab(t)}
            className={`rounded-full px-3 py-1 text-sm ${tab === t ? 'bg-primary-500 text-white' : 'bg-secondary-100 text-secondary-700'}`}>
            {t === 'pipeline' ? 'Pipeline' : 'Details'}
          </button>
        ))}
      </div>

      {tab === 'details' && (
        <Card>
          <h2 className="mb-2 font-semibold">Description</h2>
          <p className="whitespace-pre-wrap text-sm text-secondary-700">{job.description || 'No description.'}</p>
          <div className="mt-4 flex gap-2">
            {(['open', 'paused', 'closed'] as const).map((s) => (
              <Button key={s} size="sm" variant={job.status === s ? 'primary' : 'ghost'}
                onClick={() => atsService.updateJob(job.uuid, { status: s }).then(setJob).catch((e) => toast.error(apiError(e, 'Could not update')))}>
                {s[0].toUpperCase() + s.slice(1)}
              </Button>
            ))}
          </div>
        </Card>
      )}

      {tab === 'pipeline' && (columns.every((c) => c.applications.length === 0) ? (
        <Empty>No candidates yet. Add one, then invite them to an AI interview.</Empty>
      ) : (
        <div className="flex gap-3 overflow-x-auto pb-2">
          {columns.map((col) => (
            <section key={col.stage} aria-label={STAGE_LABEL[col.stage]}
              onDragOver={(e) => e.preventDefault()}
              onDrop={() => { if (dragging) move(dragging, col.stage); setDragging(null); }}
              className="flex w-64 shrink-0 flex-col rounded-xl bg-secondary-50 p-2">
              <h3 className="mb-2 flex items-center justify-between px-1 text-sm font-semibold text-secondary-700">
                <StageBadge stage={col.stage} /> <span>{col.applications.length}</span>
              </h3>
              <ul className="space-y-2">
                {col.applications.map((a) => (
                  <li key={a.uuid} draggable onDragStart={() => setDragging(a)}
                    className="cursor-grab rounded-lg border border-secondary-200 bg-white p-3 text-sm shadow-sm">
                    <Link href={`/dashboard/ats/candidates/${a.candidate?.uuid}`} className="font-medium text-secondary-900 hover:underline">
                      {a.candidate?.name}
                    </Link>
                    {a.latest_interview && (
                      <Link href={`/dashboard/ats/interviews/${a.latest_interview.uuid}`}
                        className="mt-1 block text-xs text-primary-600 hover:underline">
                        Interview: {a.latest_interview.state.replace('_', ' ')}{a.latest_interview.reviewed ? ' · reviewed' : ''}
                      </Link>
                    )}
                    {a.decision_reason && <p className="mt-1 text-xs text-secondary-500">{a.decision_reason}</p>}
                    <div className="mt-2 flex items-center gap-2">
                      <select aria-label={`Move ${a.candidate?.name}`} value={a.stage}
                        onChange={(e) => move(a, e.target.value as Stage)}
                        className="flex-1 rounded border border-secondary-200 bg-white px-1 py-0.5 text-xs">
                        {STAGES.map((s) => <option key={s} value={s}>{STAGE_LABEL[s]}</option>)}
                      </select>
                      {a.stage !== 'rejected' && a.stage !== 'hired' && (
                        <button className="text-xs font-medium text-primary-600 hover:underline" onClick={() => setInviting(a)}>Invite</button>
                      )}
                    </div>
                  </li>
                ))}
              </ul>
            </section>
          ))}
        </div>
      ))}

      <AddCandidateModal job={job} open={adding} onClose={() => setAdding(false)} onDone={load} />
      <InviteModal app={inviting} job={job} onClose={() => { setInviting(null); load(); }} />
      <RejectModal app={rejecting} reasons={reasons} onClose={() => setRejecting(null)} onDone={load} />
    </AtsShell>
  );
}

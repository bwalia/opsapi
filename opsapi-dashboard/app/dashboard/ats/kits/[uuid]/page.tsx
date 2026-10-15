'use client';

/**
 * Hiring › Kit editor — /dashboard/ats/kits/[uuid]
 * Every competency needs anchors for levels 1, 3 and 5 and at least one
 * question. The validator runs as you edit (errors block Approve). Saving an
 * approved kit makes it a draft again: it needs approving before new invitations.
 */

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { useParams } from 'next/navigation';
import toast from 'react-hot-toast';
import { AlertTriangle, CheckCircle2, Plus, Trash2, XCircle } from 'lucide-react';
import { Badge, Button, Card, Input, Select, Switch, Textarea } from '@/components/ui';
import { AtsShell } from '@/components/ats/AtsShell';
import { apiError } from '@/components/field-service/shared';
import {
  atsService, when, type Competency, type CoreQuestion, type EligibilityQuestion, type KitIssue, type KitSummary, type RoleKit,
} from '@/services/ats.service';

function nextId(prefix: string, used: string[]) {
  let i = 1;
  while (used.includes(`${prefix}${i}`)) i++;
  return `${prefix}${i}`;
}

export default function KitEditorPage() {
  const { uuid } = useParams<{ uuid: string }>();
  const [summary, setSummary] = useState<KitSummary | null>(null);
  const [kit, setKit] = useState<RoleKit | null>(null);
  const [issues, setIssues] = useState<KitIssue[]>([]);
  const [dirty, setDirty] = useState(false);
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => {
    atsService.kit(uuid).then((k) => {
      setSummary(k);
      setKit(k.kit ?? null);
      setIssues(k.issues ?? []);
      setDirty(false);
    }).catch((e) => toast.error(apiError(e, 'Could not load the kit')));
  }, [uuid]);
  useEffect(load, [load]);

  // Validate as the recruiter edits (debounced).
  useEffect(() => {
    if (!kit || !dirty) return;
    const t = setTimeout(() => atsService.validateKit(kit).then(setIssues).catch(() => undefined), 500);
    return () => clearTimeout(t);
  }, [kit, dirty]);

  const update = (fn: (k: RoleKit) => void) => {
    setKit((k) => {
      if (!k) return k;
      const copy = structuredClone(k);
      fn(copy);
      return copy;
    });
    setDirty(true);
  };

  const errors = issues.filter((i) => i.severity === 'error');
  const issuesFor = (id: string) => issues.filter((i) => i.subject === id);
  const ids = useMemo(() => kit ? [...kit.competencies.map((c) => c.id), ...kit.questions.map((q) => q.id), ...kit.eligibility.map((e) => e.id)] : [], [kit]);

  const save = async () => {
    if (!kit) return;
    setBusy(true);
    try {
      const k = await atsService.updateKit(uuid, kit);
      setSummary(k);
      setIssues(k.issues ?? []);
      setDirty(false);
      toast.success('Saved. Approve the kit to use it.');
    } catch (e) {
      toast.error(apiError(e, 'Could not save'));
    } finally {
      setBusy(false);
    }
  };

  const approve = async () => {
    setBusy(true);
    try {
      if (dirty && kit) await atsService.updateKit(uuid, kit);
      await atsService.approveKit(uuid);
      toast.success('Approved. You can invite candidates with this kit.');
      load();
    } catch (e) {
      toast.error(apiError(e, 'Could not approve'));
    } finally {
      setBusy(false);
    }
  };

  if (!kit || !summary) return <AtsShell title="Interview kit" module="ats_kits"><p className="text-secondary-500">Loading…</p></AtsShell>;

  const weights = kit.competencies.reduce((s, c) => s + (Number(c.weight) || 0), 0);

  return (
    <AtsShell title={kit.title || 'Interview kit'} module="ats_kits"
      description={summary.approved_at ? `Approved v${summary.version} by ${summary.approved_by} on ${when(summary.approved_at)}` : 'Draft: not used until approved'}
      actions={<>
        <Button variant="ghost" onClick={save} isLoading={busy} disabled={!dirty}>Save draft</Button>
        <Button onClick={approve} isLoading={busy} disabled={errors.length > 0}
          leftIcon={<CheckCircle2 className="h-4 w-4" />}>{summary.approved_at && !dirty ? 'Approve again' : 'Approve'}</Button>
      </>}>
      {kit.warnings.length > 0 && (
        <div className="rounded-xl border border-amber-300 bg-amber-50 p-4 text-sm text-amber-900">
          <p className="font-semibold">The job description may exclude people unnecessarily:</p>
          <ul className="mt-1 list-disc pl-5">{kit.warnings.map((w, i) => <li key={i}>{w}</li>)}</ul>
        </div>
      )}

      <div className="grid gap-6 xl:grid-cols-[1fr_320px]">
        <div className="space-y-6">
          <Card>
            <h2 className="mb-3 font-semibold">The role</h2>
            <div className="grid gap-3 sm:grid-cols-2">
              <Input label="Title" value={kit.title} onChange={(e) => update((k) => { k.title = e.target.value; })} />
              <Input label="Organisation" value={kit.organisation} onChange={(e) => update((k) => { k.organisation = e.target.value; })} />
            </div>
            <Textarea className="mt-3" label="Summary (read by the interviewer)" rows={3} value={kit.summary}
              onChange={(e) => update((k) => { k.summary = e.target.value; })} />
          </Card>

          <Card>
            <div className="mb-3 flex items-center justify-between">
              <h2 className="font-semibold">Competencies <span className="text-sm font-normal text-secondary-500">(weights add up to {weights})</span></h2>
              <Button size="sm" variant="ghost" leftIcon={<Plus className="h-4 w-4" />} onClick={() => update((k) => {
                k.competencies.push({ id: nextId('c', ids), name: '', description: '', weight: 0, source: '', anchors: { '1': '', '3': '', '5': '' } });
              })}>Add</Button>
            </div>
            <div className="space-y-4">
              {kit.competencies.map((c: Competency, i) => (
                <fieldset key={c.id} className="rounded-lg border border-secondary-200 p-3">
                  <legend className="px-1 text-xs font-semibold text-secondary-500">{c.id}</legend>
                  <div className="grid gap-3 sm:grid-cols-[1fr_100px_auto]">
                    <Input label="Name" value={c.name} onChange={(e) => update((k) => { k.competencies[i].name = e.target.value; })} />
                    <Input label="Weight" type="number" value={String(c.weight)}
                      onChange={(e) => update((k) => { k.competencies[i].weight = Number(e.target.value) || 0; })} />
                    <Button className="self-end" variant="ghost" aria-label={`Remove ${c.name || c.id}`}
                      onClick={() => update((k) => { k.competencies.splice(i, 1); })}><Trash2 className="h-4 w-4" /></Button>
                  </div>
                  <Input className="mt-2" label="Description" value={c.description}
                    onChange={(e) => update((k) => { k.competencies[i].description = e.target.value; })} />
                  {c.source && <p className="mt-1 text-xs text-secondary-500">From the job description: “{c.source}”</p>}
                  <div className="mt-2 grid gap-2 md:grid-cols-3">
                    {(['1', '3', '5'] as const).map((lvl) => (
                      <Textarea key={lvl} label={`Level ${lvl} looks like`} rows={3} value={c.anchors[lvl]}
                        onChange={(e) => update((k) => { k.competencies[i].anchors[lvl] = e.target.value; })} />
                    ))}
                  </div>
                  <IssueList issues={issuesFor(c.id)} />
                </fieldset>
              ))}
            </div>
          </Card>

          <Card>
            <div className="mb-3 flex items-center justify-between">
              <h2 className="font-semibold">Core questions <span className="text-sm font-normal text-secondary-500">(asked word for word, in this order)</span></h2>
              <Button size="sm" variant="ghost" leftIcon={<Plus className="h-4 w-4" />} onClick={() => update((k) => {
                k.questions.push({ id: nextId('q', ids), text: '', competency: k.competencies[0]?.id ?? '', kind: 'behavioural' });
              })}>Add</Button>
            </div>
            <ol className="space-y-3">
              {kit.questions.map((q: CoreQuestion, i) => (
                <li key={q.id} className="rounded-lg border border-secondary-200 p-3">
                  <Textarea label={`Question ${i + 1} (${q.id})`} rows={2} value={q.text}
                    onChange={(e) => update((k) => { k.questions[i].text = e.target.value; })} />
                  <div className="mt-2 grid gap-2 sm:grid-cols-[1fr_1fr_auto]">
                    <Select label="Evidence for" value={q.competency} onChange={(e) => update((k) => { k.questions[i].competency = e.target.value; })}>
                      {kit.competencies.map((c) => <option key={c.id} value={c.id}>{c.name || c.id}</option>)}
                    </Select>
                    <Select label="Kind" value={q.kind} onChange={(e) => update((k) => { k.questions[i].kind = e.target.value as CoreQuestion['kind']; })}>
                      <option value="behavioural">Behavioural (a time when…)</option>
                      <option value="situational">Situational (what would you do…)</option>
                    </Select>
                    <div className="flex items-end gap-1">
                      <Button variant="ghost" size="sm" aria-label="Move up" disabled={i === 0}
                        onClick={() => update((k) => { [k.questions[i - 1], k.questions[i]] = [k.questions[i], k.questions[i - 1]]; })}>↑</Button>
                      <Button variant="ghost" size="sm" aria-label="Remove question" onClick={() => update((k) => { k.questions.splice(i, 1); })}>
                        <Trash2 className="h-4 w-4" />
                      </Button>
                    </div>
                  </div>
                  <IssueList issues={issuesFor(q.id)} />
                </li>
              ))}
            </ol>
          </Card>

          <Card>
            <div className="mb-3 flex items-center justify-between">
              <h2 className="font-semibold">Eligibility questions <span className="text-sm font-normal text-secondary-500">(hard requirements; answers are shown to you as given)</span></h2>
              <Button size="sm" variant="ghost" leftIcon={<Plus className="h-4 w-4" />} onClick={() => update((k) => {
                k.eligibility.push({ id: nextId('e', ids), text: '', kind: 'yes_no', options: [], accepted: ['Yes'] });
              })}>Add</Button>
            </div>
            <div className="space-y-3">
              {kit.eligibility.map((q: EligibilityQuestion, i) => (
                <div key={q.id} className="rounded-lg border border-secondary-200 p-3">
                  <div className="grid gap-2 sm:grid-cols-[1fr_160px_auto]">
                    <Input label={`Question (${q.id})`} value={q.text} onChange={(e) => update((k) => { k.eligibility[i].text = e.target.value; })} />
                    <Select label="Answer" value={q.kind} onChange={(e) => update((k) => { k.eligibility[i].kind = e.target.value as EligibilityQuestion['kind']; })}>
                      <option value="yes_no">Yes / No</option>
                      <option value="choice">Choice</option>
                      <option value="text">Free text</option>
                    </Select>
                    <Button className="self-end" variant="ghost" aria-label="Remove eligibility question"
                      onClick={() => update((k) => { k.eligibility.splice(i, 1); })}><Trash2 className="h-4 w-4" /></Button>
                  </div>
                  {q.kind === 'choice' && (
                    <Input className="mt-2" label="Options (comma separated)" value={q.options.join(', ')}
                      onChange={(e) => update((k) => { k.eligibility[i].options = e.target.value.split(',').map((s) => s.trim()).filter(Boolean); })} />
                  )}
                  {q.kind !== 'text' && (
                    <Input className="mt-2" label="Answers that meet it (comma separated)" value={q.accepted.join(', ')}
                      onChange={(e) => update((k) => { k.eligibility[i].accepted = e.target.value.split(',').map((s) => s.trim()).filter(Boolean); })} />
                  )}
                  <IssueList issues={issuesFor(q.id)} />
                </div>
              ))}
            </div>
          </Card>

          <Card>
            <h2 className="mb-3 font-semibold">Company facts and settings</h2>
            <Textarea label="Facts the interviewer may share (hours, pay range, team, process)" rows={6} value={kit.company_facts}
              onChange={(e) => update((k) => { k.company_facts = e.target.value; })}
              helperText="Candidates' questions are answered only from these. Anything else is passed on to you." />
            <div className="mt-3 grid gap-3 sm:grid-cols-3">
              <Input label="Interviewer name" value={kit.settings.interviewer_name}
                onChange={(e) => update((k) => { k.settings.interviewer_name = e.target.value; })} />
              <Input label="Minutes" type="number" value={String(kit.settings.minutes)}
                onChange={(e) => update((k) => { k.settings.minutes = Number(e.target.value) || 25; })} />
              <Input label="Follow-ups per question" type="number" value={String(kit.settings.max_follow_ups)}
                onChange={(e) => update((k) => { k.settings.max_follow_ups = Number(e.target.value) || 0; })} />
            </div>
            <Textarea className="mt-3" label="Next steps (told to candidates at the end)" rows={2} value={kit.settings.next_steps}
              onChange={(e) => update((k) => { k.settings.next_steps = e.target.value; })} />
            <div className="mt-3 space-y-2 text-sm">
              <label className="flex items-center gap-3"><Switch checked={kit.settings.allow_pause}
                onChange={(v) => update((k) => { k.settings.allow_pause = v; })} aria-label="Allow pauses" /> Candidates may pause</label>
              <label className="flex items-center gap-3"><Switch checked={kit.settings.ratings_enabled}
                onChange={(v) => update((k) => { k.settings.ratings_enabled = v; })} aria-label="Suggested levels" />
                AI suggests levels (off: evidence only)</label>
              <label className="flex items-center gap-3"><Switch checked={kit.settings.written_communication}
                onChange={(v) => update((k) => { k.settings.written_communication = v; })} aria-label="Written communication" />
                A competency assesses written communication</label>
            </div>
          </Card>
        </div>

        <aside className="space-y-3 xl:sticky xl:top-4 xl:self-start">
          <Card>
            <h2 className="mb-2 flex items-center gap-2 font-semibold">
              Checks {errors.length === 0 ? <Badge variant="success">Ready to approve</Badge> : <Badge variant="error">{errors.length} to fix</Badge>}
            </h2>
            <IssueList issues={issues} showSubject />
            {issues.length === 0 && <p className="text-sm text-secondary-500">No problems found.</p>}
          </Card>
        </aside>
      </div>
    </AtsShell>
  );
}

function IssueList({ issues, showSubject }: { issues: KitIssue[]; showSubject?: boolean }) {
  if (issues.length === 0) return null;
  return (
    <ul className="mt-2 space-y-1 text-sm">
      {issues.map((i, n) => (
        <li key={n} className={`flex gap-2 ${i.severity === 'error' ? 'text-red-700' : 'text-amber-800'}`}>
          {i.severity === 'error' ? <XCircle className="mt-0.5 h-4 w-4 shrink-0" /> : <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />}
          <span>{showSubject && i.subject ? <strong>{i.subject}: </strong> : null}{i.message}</span>
        </li>
      ))}
    </ul>
  );
}

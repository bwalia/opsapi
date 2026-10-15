'use client';

/**
 * Hiring › Interview kits — /dashboard/ats/kits
 * Generate a kit from a job description (AI draft, saved unapproved) or start
 * empty. Kits made in Snazzy Pro on the Mac show up here too.
 */

import React, { Suspense, useEffect, useState } from 'react';
import Link from 'next/link';
import { useRouter, useSearchParams } from 'next/navigation';
import toast from 'react-hot-toast';
import { FilePlus2, Sparkles } from 'lucide-react';
import { Badge, Button, Input, Modal, Textarea } from '@/components/ui';
import { AtsShell, Empty } from '@/components/ats/AtsShell';
import { apiError } from '@/components/field-service/shared';
import { atsService, when, type KitSummary } from '@/services/ats.service';

function KitsPageInner() {
  const router = useRouter();
  const params = useSearchParams();
  const jobUuid = params.get('job') || undefined;
  const [kits, setKits] = useState<KitSummary[] | null>(null);
  const [generating, setGenerating] = useState(!!jobUuid);
  const [jd, setJd] = useState('');
  const [busy, setBusy] = useState(false);
  const [blankTitle, setBlankTitle] = useState('');
  const [blank, setBlank] = useState(false);

  useEffect(() => {
    atsService.kits().then(setKits).catch((e) => toast.error(apiError(e, 'Could not load kits')));
    if (jobUuid) atsService.job(jobUuid).then((j) => setJd(j.description ?? '')).catch(() => undefined);
  }, [jobUuid]);

  const generate = async () => {
    setBusy(true);
    try {
      const kit = await atsService.generateKit(jd, jobUuid);
      toast.success('Draft ready. Check every part, then approve it.');
      router.push(`/dashboard/ats/kits/${kit.uuid}`);
    } catch (e) {
      toast.error(apiError(e, 'The AI could not draft a kit'));
      setBusy(false);
    }
  };

  const createBlank = async () => {
    setBusy(true);
    try {
      const kit = await atsService.createKit({ title: blankTitle, job_uuid: jobUuid });
      router.push(`/dashboard/ats/kits/${kit.uuid}`);
    } catch (e) {
      toast.error(apiError(e, 'Could not create the kit'));
      setBusy(false);
    }
  };

  return (
    <AtsShell title="Interview kits" module="ats_kits"
      description="What each role needs, the questions every candidate gets, and how answers are assessed."
      actions={<>
        <Button variant="ghost" leftIcon={<FilePlus2 className="h-4 w-4" />} onClick={() => setBlank(true)}>Start empty</Button>
        <Button leftIcon={<Sparkles className="h-4 w-4" />} onClick={() => setGenerating(true)}>Generate from a job description</Button>
      </>}>
      {kits && kits.length === 0 && <Empty>No kits yet. Generate one from a job description.</Empty>}
      {kits && kits.length > 0 && (
        <ul className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
          {kits.map((k) => (
            <li key={k.uuid}>
              <Link href={`/dashboard/ats/kits/${k.uuid}`} className="block h-full rounded-xl border border-secondary-200 bg-white p-4 hover:shadow-md">
                <div className="flex items-start justify-between gap-2">
                  <h2 className="font-semibold text-secondary-900">{k.title}</h2>
                  {k.approved_at ? <Badge variant="success">Approved v{k.version}</Badge> : <Badge variant="warning">Draft</Badge>}
                </div>
                <p className="mt-2 text-sm text-secondary-500">
                  {k.competencies} competencies · {k.questions} questions · {k.source === 'snazzy_desktop' ? 'from Snazzy Pro' : k.source}
                </p>
                <p className="mt-1 text-xs text-secondary-400">Updated {when(k.updated_at)}</p>
              </Link>
            </li>
          ))}
        </ul>
      )}

      <Modal isOpen={generating} onClose={() => setGenerating(false)} title="Generate a kit from a job description" size="2xl"
        description="The AI drafts competencies, rubrics, questions and eligibility checks, and flags wording that could exclude people. Nothing is used until you approve it."
        footer={<><Button variant="ghost" onClick={() => setGenerating(false)}>Cancel</Button>
          <Button onClick={generate} isLoading={busy} disabled={jd.trim().length < 40}>Draft the kit</Button></>}>
        <Textarea label="Job description" rows={14} value={jd} onChange={(e) => setJd(e.target.value)} placeholder="Paste the full job advert" />
      </Modal>
      <Modal isOpen={blank} onClose={() => setBlank(false)} title="New empty kit"
        footer={<><Button variant="ghost" onClick={() => setBlank(false)}>Cancel</Button>
          <Button onClick={createBlank} isLoading={busy} disabled={!blankTitle.trim()}>Create</Button></>}>
        <Input label="Role title" value={blankTitle} onChange={(e) => setBlankTitle(e.target.value)} autoFocus />
      </Modal>
    </AtsShell>
  );
}

export default function KitsPage() {
  return (
    <Suspense>
      <KitsPageInner />
    </Suspense>
  );
}

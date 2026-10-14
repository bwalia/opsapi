'use client';

/** Hiring overview — /dashboard/ats */

import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import toast from 'react-hot-toast';
import { Card } from '@/components/ui';
import { AtsShell, ActivationBanner, StageBadge } from '@/components/ats/AtsShell';
import { apiError } from '@/components/field-service/shared';
import { atsService, STAGES, type Overview } from '@/services/ats.service';

export default function AtsOverviewPage() {
  const [data, setData] = useState<Overview | null>(null);

  useEffect(() => {
    atsService.overview().then(setData).catch((e) => toast.error(apiError(e, 'Could not load hiring')));
  }, []);

  const cards = data
    ? [
        { label: 'Open jobs', value: data.open_jobs, href: '/dashboard/ats/jobs' },
        { label: 'Candidates', value: data.candidates, href: '/dashboard/ats/candidates' },
        { label: 'Interviews to review', value: data.to_review, href: '/dashboard/ats/interviews?to_review=1' },
        { label: 'Interviews in progress', value: data.in_progress, href: '/dashboard/ats/interviews' },
      ]
    : [];

  return (
    <AtsShell title="Hiring" description="Jobs, candidates and AI first-round interviews. A person makes every decision.">
      <ActivationBanner activation={data?.activation} />
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        {cards.map((c) => (
          <Link key={c.label} href={c.href}>
            <Card className="h-full transition hover:shadow-md">
              <p className="text-sm text-secondary-500">{c.label}</p>
              <p className="mt-1 text-3xl font-bold text-secondary-900">{c.value}</p>
            </Card>
          </Link>
        ))}
      </div>
      {data && (
        <Card>
          <h2 className="mb-3 font-semibold text-secondary-900">Candidates by stage</h2>
          <ul className="flex flex-wrap gap-3">
            {STAGES.map((s) => (
              <li key={s} className="flex items-center gap-2 text-sm">
                <StageBadge stage={s} /> <span className="font-semibold">{data.stages[s] ?? 0}</span>
              </li>
            ))}
          </ul>
        </Card>
      )}
      <Card>
        <h2 className="font-semibold text-secondary-900">How it works</h2>
        <ol className="mt-2 list-decimal space-y-1 pl-5 text-sm text-secondary-600">
          <li>Create a job, then generate an interview kit from its description, and edit and approve it.</li>
          <li>Add candidates and invite them. Each gets a private link to a short AI interview, with the same questions for everyone.</li>
          <li>Review each interview: quotes from the candidate&apos;s answers are shown against the kit&apos;s rubric, with the AI&apos;s suggestion.</li>
          <li>You decide: advance, hold or decline. Nothing is sent to a candidate unless a person sends it.</li>
        </ol>
      </Card>
    </AtsShell>
  );
}

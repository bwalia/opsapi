'use client';

/**
 * "Form responses" on a customer's or lead's page: the responses that created
 * or matched this record, newest first. Hidden for people without forms.read
 * and where the forms feature isn't deployed.
 */

import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import { formatDistanceToNow } from 'date-fns';
import { ClipboardList } from 'lucide-react';
import { formsService, parseTs, type RecordResponse } from '@/services/forms.service';

export default function RecordFormResponses({ entityType, entityUuid, className }: {
  entityType: 'customer' | 'lead' | 'user' | 'invitation'; entityUuid?: string; className?: string;
}) {
  const [items, setItems] = useState<RecordResponse[] | null>(null);
  useEffect(() => {
    if (!entityUuid) return;
    formsService.forRecord(entityType, entityUuid).then(setItems).catch(() => setItems(null));
  }, [entityType, entityUuid]);
  if (!items || items.length === 0) return null;
  return (
    <section className={className} aria-label="Form responses">
      <h2 className="mb-3 flex items-center gap-2 text-base font-semibold text-secondary-900">
        <ClipboardList className="h-4 w-4 text-secondary-500" aria-hidden="true" /> Form responses
      </h2>
      <ul className="space-y-3">
        {items.map((r) => {
          const d = parseTs(r.created_at);
          return (
            <li key={r.uuid} className="rounded-lg border border-secondary-200 p-3">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <Link href={`/dashboard/forms/${r.form_uuid}?response=${r.uuid}`} className="font-medium text-primary-600 hover:underline">
                  {r.form_title}
                </Link>
                <span className="text-xs text-secondary-500">
                  {d ? formatDistanceToNow(d, { addSuffix: true }) : ''}{r.outcome === 'created' ? ' · created this record' : ''}
                </span>
              </div>
              <dl className="mt-2 grid gap-x-4 gap-y-1 text-sm sm:grid-cols-[minmax(0,10rem)_1fr]">
                {r.answers.slice(0, 6).map((a, i) => (
                  <React.Fragment key={i}>
                    <dt className="truncate text-secondary-500">{a.label}</dt>
                    <dd className="whitespace-pre-wrap break-words text-secondary-800">{a.value}</dd>
                  </React.Fragment>
                ))}
              </dl>
            </li>
          );
        })}
      </ul>
    </section>
  );
}

'use client';

/** Hiring › Candidates — /dashboard/ats/candidates */

import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import toast from 'react-hot-toast';
import { Search } from 'lucide-react';
import { Input, Pagination } from '@/components/ui';
import { AtsShell, Empty } from '@/components/ats/AtsShell';
import { apiError } from '@/components/field-service/shared';
import { atsService, when, type Candidate, type Meta } from '@/services/ats.service';

export default function CandidatesPage() {
  const [items, setItems] = useState<Candidate[] | null>(null);
  const [meta, setMeta] = useState<Meta | undefined>();
  const [q, setQ] = useState('');
  const [page, setPage] = useState(1);

  useEffect(() => {
    const t = setTimeout(() => {
      atsService.candidates({ q, page }).then((r) => { setItems(r.items); setMeta(r.meta); })
        .catch((e) => toast.error(apiError(e, 'Could not load candidates')));
    }, 250);
    return () => clearTimeout(t);
  }, [q, page]);

  return (
    <AtsShell title="Candidates" module="ats_candidates" description="Everyone who has applied, across all jobs.">
      <Input aria-label="Search candidates" placeholder="Search by name, email or reference" value={q}
        onChange={(e) => { setQ(e.target.value); setPage(1); }} leftIcon={<Search className="h-4 w-4" />} />
      {items && items.length === 0 && <Empty>No candidates found. Add candidates from a job&apos;s pipeline.</Empty>}
      {items && items.length > 0 && (
        <div className="overflow-x-auto rounded-xl border border-secondary-200">
          <table className="min-w-full divide-y divide-secondary-200 text-sm">
            <thead className="bg-secondary-50 text-left text-secondary-500">
              <tr><th className="px-4 py-2">Name</th><th className="px-4 py-2">Email</th><th className="px-4 py-2">Applications</th>
                <th className="px-4 py-2">Source</th><th className="px-4 py-2">Added</th></tr>
            </thead>
            <tbody className="divide-y divide-secondary-100">
              {items.map((c) => (
                <tr key={c.uuid} className="hover:bg-secondary-50">
                  <td className="px-4 py-3"><Link className="font-medium text-primary-600 hover:underline" href={`/dashboard/ats/candidates/${c.uuid}`}>{c.name}</Link></td>
                  <td className="px-4 py-3">{c.email || '—'}</td>
                  <td className="px-4 py-3">{typeof c.applications === 'number' ? c.applications : '—'}</td>
                  <td className="px-4 py-3">{c.source || '—'}</td>
                  <td className="px-4 py-3">{when(c.created_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {meta && meta.total_pages > 1 && (
        <Pagination currentPage={page} totalPages={meta.total_pages} totalItems={meta.total} perPage={meta.per_page} onPageChange={setPage} />
      )}
    </AtsShell>
  );
}

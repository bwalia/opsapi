'use client';

/**
 * Hiring › Interviews — /dashboard/ats/interviews
 * Every AI interview: online ones (candidate links) and ones run in Snazzy Pro
 * on a Mac. "Import .snazzy_interview files" adds interviews the app saved
 * while it wasn't connected; each file is checked on the server (format,
 * version, 1 MB, every quote against the transcript).
 */

import React, { Suspense, useCallback, useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import { useSearchParams } from 'next/navigation';
import toast from 'react-hot-toast';
import { Upload } from 'lucide-react';
import { Badge, Button, Pagination, Select } from '@/components/ui';
import { AtsShell, Empty } from '@/components/ats/AtsShell';
import { apiError } from '@/components/field-service/shared';
import { atsService, when, type InterviewSummary, type Meta } from '@/services/ats.service';

const STATE_LABEL: Record<string, string> = {
  invited: 'Invited', in_progress: 'In progress', paused: 'Paused', completed: 'Completed',
  human_requested: 'Asked for a person', abandoned: 'Abandoned', expired: 'Expired', withdrawn: 'Withdrawn',
};

const MAX_FILE = 1024 * 1024;

function InterviewsInner() {
  const params = useSearchParams();
  const [items, setItems] = useState<InterviewSummary[] | null>(null);
  const [meta, setMeta] = useState<Meta | undefined>();
  const [state, setState] = useState('');
  const [toReview, setToReview] = useState(params.get('to_review') === '1');
  const [page, setPage] = useState(1);
  const [importing, setImporting] = useState(false);
  const fileInput = useRef<HTMLInputElement>(null);

  const load = useCallback(() => {
    atsService.interviews({ state, to_review: toReview, page }).then((r) => { setItems(r.items); setMeta(r.meta); })
      .catch((e) => toast.error(apiError(e, 'Could not load interviews')));
  }, [state, toReview, page]);
  useEffect(load, [load]);

  const importFiles = async (files: FileList | null) => {
    if (!files || files.length === 0) return;
    setImporting(true);
    let added = 0;
    for (const file of Array.from(files)) {
      if (file.size > MAX_FILE) {
        toast.error(`${file.name}: larger than 1 MB`);
        continue;
      }
      try {
        const r = await atsService.importFile(await file.text());
        added++;
        toast.success(`${file.name}: ${r.created ? 'added' : 'updated'}`);
      } catch (e) {
        toast.error(`${file.name}: ${apiError(e, 'could not be imported')}`);
      }
    }
    setImporting(false);
    if (fileInput.current) fileInput.current.value = '';
    if (added) load();
  };

  return (
    <AtsShell title="Interviews" module="ats_interviews" description="AI first-round interviews, waiting for a person's review."
      actions={<>
        <input ref={fileInput} type="file" accept=".snazzy_interview,application/json" multiple className="sr-only"
          aria-label="Import .snazzy_interview files" onChange={(e) => importFiles(e.target.files)} />
        <Button variant="ghost" leftIcon={<Upload className="h-4 w-4" />} isLoading={importing}
          onClick={() => fileInput.current?.click()}>Import .snazzy_interview files</Button>
      </>}>
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
        <Select aria-label="State" value={state} onChange={(e) => { setState(e.target.value); setPage(1); }} className="sm:w-56">
          <option value="">All states</option>
          {Object.entries(STATE_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
        </Select>
        <label className="flex items-center gap-2 text-sm text-secondary-700">
          <input type="checkbox" checked={toReview} onChange={(e) => { setToReview(e.target.checked); setPage(1); }} />
          Only waiting for review
        </label>
      </div>
      {items && items.length === 0 && <Empty>No interviews here yet. Invite candidates from a job&apos;s pipeline.</Empty>}
      {items && items.length > 0 && (
        <div className="overflow-x-auto rounded-xl border border-secondary-200">
          <table className="min-w-full divide-y divide-secondary-200 text-sm">
            <thead className="bg-secondary-50 text-left text-secondary-500">
              <tr><th className="px-4 py-2">Candidate</th><th className="px-4 py-2">Job</th><th className="px-4 py-2">State</th>
                <th className="px-4 py-2">Assessment</th><th className="px-4 py-2">Decision</th><th className="px-4 py-2">Flags</th>
                <th className="px-4 py-2">Ended</th></tr>
            </thead>
            <tbody className="divide-y divide-secondary-100">
              {items.map((i) => (
                <tr key={i.uuid} className="hover:bg-secondary-50">
                  <td className="px-4 py-3">
                    <Link href={`/dashboard/ats/interviews/${i.uuid}`} className="font-medium text-primary-600 hover:underline">{i.candidate_name}</Link>
                    <div className="text-xs text-secondary-500">{i.source === 'hosted' ? 'Online' : 'Snazzy Pro'}</div>
                  </td>
                  <td className="px-4 py-3">{i.job_title}</td>
                  <td className="px-4 py-3">{STATE_LABEL[i.state] ?? i.state}</td>
                  <td className="px-4 py-3">{i.evaluation_status === 'done' ? 'Ready' : i.evaluation_status === 'running' ? 'Running…'
                    : i.evaluation_status === 'failed' ? <Badge variant="error">Failed</Badge> : '—'}</td>
                  <td className="px-4 py-3">{i.decision ? <Badge variant={i.decision === 'advance' ? 'success' : i.decision === 'decline' ? 'error' : 'warning'}>
                    {i.decision}</Badge> : i.state === 'completed' || i.state === 'human_requested' ? <Badge variant="warning">To review</Badge> : '—'}</td>
                  <td className="px-4 py-3">{i.flag_count > 0 ? i.flag_count : '—'}</td>
                  <td className="px-4 py-3">{when(i.ended_at)}</td>
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

export default function InterviewsPage() {
  return (
    <Suspense>
      <InterviewsInner />
    </Suspense>
  );
}

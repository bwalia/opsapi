'use client';

/**
 * Hiring › Fairness — /dashboard/ats/reports
 * Advance rates by voluntary self-ID group, for decided interviews. Groups
 * under the minimum size are not shown; an impact ratio under 0.8 (the
 * four-fifths guideline) is a prompt for a person to look closer, not proof.
 */

import React, { useEffect, useState } from 'react';
import toast from 'react-hot-toast';
import { Download } from 'lucide-react';
import { Badge, Button, Card, Select } from '@/components/ui';
import { AtsShell, Empty } from '@/components/ats/AtsShell';
import { apiError } from '@/components/field-service/shared';
import { atsService, type FairnessReport, type Job } from '@/services/ats.service';

export default function FairnessPage() {
  const [question, setQuestion] = useState('gender');
  const [job, setJob] = useState('');
  const [jobs, setJobs] = useState<Job[]>([]);
  const [report, setReport] = useState<FairnessReport | null>(null);

  useEffect(() => { atsService.jobs({}).then((r) => setJobs(r.items)).catch(() => undefined); }, []);
  useEffect(() => {
    atsService.fairness(question, job || undefined).then(setReport).catch((e) => toast.error(apiError(e, 'Could not load the report')));
  }, [question, job]);

  const csv = () => {
    if (!report) return;
    const lines = [['group', 'decided', 'advanced', 'rate', 'impact_ratio'].join(',')]
      .concat(report.rows.map((r) => [JSON.stringify(r.group), r.total, r.selected, r.rate.toFixed(4), r.impact_ratio.toFixed(4)].join(',')));
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([lines.join('\n')], { type: 'text/csv' }));
    a.download = `fairness-${question}${job ? `-${job}` : ''}.csv`;
    a.click();
    URL.revokeObjectURL(a.href);
  };

  return (
    <AtsShell title="Fairness" module="ats_reports"
      description="Who is advanced, by voluntary self-ID group. Self-ID is never shown to reviewers or the AI."
      actions={<Button variant="ghost" leftIcon={<Download className="h-4 w-4" />} onClick={csv} disabled={!report?.rows.length}>Export CSV</Button>}>
      <div className="flex flex-col gap-3 sm:flex-row">
        <Select aria-label="Question" value={question} onChange={(e) => setQuestion(e.target.value)} className="sm:w-64">
          {(report?.questions ?? [{ id: 'gender', label: 'Gender', options: [] }]).map((q) => <option key={q.id} value={q.id}>{q.label}</option>)}
        </Select>
        <Select aria-label="Job" value={job} onChange={(e) => setJob(e.target.value)} className="sm:w-64">
          <option value="">All jobs</option>
          {jobs.map((j) => <option key={j.uuid} value={j.uuid}>{j.title}</option>)}
        </Select>
      </div>
      {report && report.rows.length === 0 && (
        <Empty>Not enough decided interviews with self-ID answers yet. Groups need at least {report.min_group} people to be shown.</Empty>
      )}
      {report && report.rows.length > 0 && (
        <Card padding="none" className="overflow-x-auto">
          <table className="min-w-full divide-y divide-secondary-200 text-sm">
            <thead className="bg-secondary-50 text-left text-secondary-500">
              <tr><th className="px-4 py-2">Group</th><th className="px-4 py-2">Decided</th><th className="px-4 py-2">Advanced</th>
                <th className="px-4 py-2">Rate</th><th className="px-4 py-2">Impact ratio</th></tr>
            </thead>
            <tbody className="divide-y divide-secondary-100">
              {report.rows.map((r) => (
                <tr key={r.group}>
                  <td className="px-4 py-3">{r.group}</td><td className="px-4 py-3">{r.total}</td><td className="px-4 py-3">{r.selected}</td>
                  <td className="px-4 py-3">{Math.round(r.rate * 100)}%</td>
                  <td className="px-4 py-3">{r.impact_ratio.toFixed(2)} {r.warning && <Badge variant="warning">Below 0.8: look closer</Badge>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
      )}
      {report && report.suppressed > 0 && (
        <p className="text-sm text-secondary-500">{report.suppressed} smaller group(s) not shown, to protect people&apos;s privacy.</p>
      )}
    </AtsShell>
  );
}

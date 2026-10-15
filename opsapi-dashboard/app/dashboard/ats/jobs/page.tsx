'use client';

/** Hiring › Jobs — /dashboard/ats/jobs */

import React, { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import toast from 'react-hot-toast';
import { Plus, Search } from 'lucide-react';
import { Badge, Button, Input, Modal, Select, Textarea } from '@/components/ui';
import { AtsShell, Empty } from '@/components/ats/AtsShell';
import { apiError } from '@/components/field-service/shared';
import { atsService, type Job } from '@/services/ats.service';

const STATUS_VARIANT: Record<Job['status'], 'success' | 'warning' | 'secondary'> = {
  open: 'success', paused: 'warning', draft: 'secondary', closed: 'secondary',
};

function NewJobModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const router = useRouter();
  const [form, setForm] = useState({ title: '', department: '', location: '', employment_type: '', description: '' });
  const [busy, setBusy] = useState(false);
  const set = (k: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>) =>
    setForm((f) => ({ ...f, [k]: e.target.value }));

  const create = async () => {
    setBusy(true);
    try {
      const job = await atsService.createJob({ ...form, status: 'open' });
      router.push(`/dashboard/ats/jobs/${job.uuid}`);
    } catch (e) {
      toast.error(apiError(e, 'Could not create the job'));
      setBusy(false);
    }
  };

  return (
    <Modal isOpen={open} onClose={onClose} title="New job" size="lg"
      footer={<><Button variant="ghost" onClick={onClose}>Cancel</Button>
        <Button onClick={create} isLoading={busy} disabled={!form.title.trim()}>Create job</Button></>}>
      <div className="space-y-4">
        <Input label="Job title" value={form.title} onChange={set('title')} required autoFocus />
        <div className="grid gap-4 sm:grid-cols-3">
          <Input label="Department" value={form.department} onChange={set('department')} />
          <Input label="Location" value={form.location} onChange={set('location')} />
          <Select label="Type" value={form.employment_type} onChange={set('employment_type')}>
            <option value="">—</option>
            <option>Full time</option>
            <option>Part time</option>
            <option>Contract</option>
            <option>Temporary</option>
          </Select>
        </div>
        <Textarea label="Job description" rows={8} value={form.description} onChange={set('description')}
          helperText="Used to draft the interview kit. Paste the full advert." />
      </div>
    </Modal>
  );
}

export default function JobsPage() {
  const [jobs, setJobs] = useState<Job[] | null>(null);
  const [q, setQ] = useState('');
  const [status, setStatus] = useState('');
  const [creating, setCreating] = useState(false);

  const load = useCallback(() => {
    atsService.jobs({ q, status }).then((r) => setJobs(r.items)).catch((e) => toast.error(apiError(e, 'Could not load jobs')));
  }, [q, status]);
  useEffect(() => {
    const t = setTimeout(load, 250);
    return () => clearTimeout(t);
  }, [load]);

  return (
    <AtsShell title="Jobs" description="Open roles and their hiring pipelines."
      actions={<Button leftIcon={<Plus className="h-4 w-4" />} onClick={() => setCreating(true)}>New job</Button>}>
      <div className="flex flex-col gap-3 sm:flex-row">
        <Input aria-label="Search jobs" placeholder="Search jobs" value={q} onChange={(e) => setQ(e.target.value)}
          leftIcon={<Search className="h-4 w-4" />} />
        <Select aria-label="Status" value={status} onChange={(e) => setStatus(e.target.value)} className="sm:w-48">
          <option value="">All statuses</option>
          <option value="open">Open</option>
          <option value="paused">Paused</option>
          <option value="draft">Draft</option>
          <option value="closed">Closed</option>
        </Select>
      </div>
      {jobs && jobs.length === 0 && <Empty>No jobs yet. Create one to start hiring.</Empty>}
      {jobs && jobs.length > 0 && (
        <div className="overflow-x-auto rounded-xl border border-secondary-200">
          <table className="min-w-full divide-y divide-secondary-200 text-sm">
            <thead className="bg-secondary-50 text-left text-secondary-500">
              <tr><th className="px-4 py-2">Job</th><th className="px-4 py-2">Status</th><th className="px-4 py-2">Candidates</th>
                <th className="px-4 py-2">Interviews to review</th><th className="px-4 py-2">Kit</th></tr>
            </thead>
            <tbody className="divide-y divide-secondary-100">
              {jobs.map((j) => (
                <tr key={j.uuid} className="hover:bg-secondary-50">
                  <td className="px-4 py-3">
                    <Link href={`/dashboard/ats/jobs/${j.uuid}`} className="font-medium text-primary-600 hover:underline">{j.title}</Link>
                    <div className="text-xs text-secondary-500">{[j.department, j.location, j.employment_type].filter(Boolean).join(' · ')}</div>
                  </td>
                  <td className="px-4 py-3"><Badge variant={STATUS_VARIANT[j.status]}>{j.status}</Badge></td>
                  <td className="px-4 py-3">{j.candidates}</td>
                  <td className="px-4 py-3">{j.to_review > 0 ? <Badge variant="warning">{j.to_review}</Badge> : '0'}</td>
                  <td className="px-4 py-3">{j.kit_uuid ? 'Linked' : <span className="text-secondary-400">None</span>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <NewJobModal open={creating} onClose={() => setCreating(false)} />
    </AtsShell>
  );
}

'use client';

/**
 * Service Jobs — /dashboard/field-service
 *
 * The service manager's board: every field service job for the current
 * namespace with live counters, filters and a "New job" flow. A job's phases
 * are copied from its job type's templates when it is created; engineers are
 * booked onto it as site visits from the job page.
 */

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import toast from 'react-hot-toast';
import {
  Search,
  Plus,
  RefreshCw,
  Wrench,
  CalendarClock,
  AlertTriangle,
  Receipt,
  MapPin,
  UserX,
} from 'lucide-react';
import { Input, Table, Pagination, Card, Button } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import {
  fieldService,
  formatFsDate,
  formatFsDateTime,
  type FsJob,
  type FsJobType,
  type FsStats,
} from '@/services/field-service.service';
import {
  FieldServiceNav,
  FilterSelect,
  JobPriorityPill,
  JobStatusPill,
  JOB_STATUS_OPTIONS,
  PRIORITY_OPTIONS,
  StatCard,
  apiError,
} from '@/components/field-service/shared';
import JobFormModal from '@/components/field-service/JobFormModal';
import type { TableColumn } from '@/types';

const PER_PAGE = 20;

function JobsPageContent() {
  const router = useRouter();
  const [jobs, setJobs] = useState<FsJob[]>([]);
  const [stats, setStats] = useState<FsStats | null>(null);
  const [jobTypes, setJobTypes] = useState<FsJobType[]>([]);
  const [isLoading, setIsLoading] = useState(true);

  const [searchQuery, setSearchQuery] = useState('');
  const [debouncedSearch, setDebouncedSearch] = useState('');
  const [statusFilter, setStatusFilter] = useState('open');
  const [priorityFilter, setPriorityFilter] = useState('all');
  const [typeFilter, setTypeFilter] = useState('all');
  const [quickFilter, setQuickFilter] = useState<'none' | 'overdue' | 'uninvoiced'>('none');

  const [currentPage, setCurrentPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [sortColumn, setSortColumn] = useState('created_at');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('desc');
  const [isCreateOpen, setIsCreateOpen] = useState(false);

  const fetchIdRef = useRef(0);

  useEffect(() => {
    const t = setTimeout(() => {
      setDebouncedSearch(searchQuery.trim());
      setCurrentPage(1);
    }, 300);
    return () => clearTimeout(t);
  }, [searchQuery]);

  const loadStats = useCallback(async () => {
    const s = await fieldService.getStats().catch(() => null);
    if (s) setStats(s);
  }, []);

  useEffect(() => {
    loadStats();
    fieldService.getJobTypes({ includeInactive: true }).then(setJobTypes).catch(() => setJobTypes([]));
  }, [loadStats]);

  const fetchJobs = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);
    try {
      const response = await fieldService.getJobs({
        page: currentPage,
        per_page: PER_PAGE,
        order_by: sortColumn,
        order_dir: sortDirection,
        search: debouncedSearch || undefined,
        status: quickFilter === 'none' ? statusFilter : 'all',
        priority: priorityFilter,
        job_type_uuid: typeFilter === 'all' ? undefined : typeFilter,
        overdue: quickFilter === 'overdue',
        uninvoiced: quickFilter === 'uninvoiced',
      });
      if (fetchId === fetchIdRef.current) {
        setJobs(response.data);
        setTotalPages(response.meta.total_pages || 1);
        setTotalItems(response.meta.total);
      }
    } catch (error) {
      if (fetchId === fetchIdRef.current) toast.error(apiError(error, 'Failed to load jobs'));
    } finally {
      if (fetchId === fetchIdRef.current) setIsLoading(false);
    }
  }, [currentPage, sortColumn, sortDirection, debouncedSearch, statusFilter, priorityFilter, typeFilter, quickFilter]);

  useEffect(() => {
    fetchJobs();
  }, [fetchJobs]);

  const refreshAll = useCallback(() => {
    fetchJobs();
    loadStats();
  }, [fetchJobs, loadStats]);

  const handleSort = useCallback((column: string) => {
    setSortColumn((prev) => {
      if (prev === column) {
        setSortDirection((d) => (d === 'asc' ? 'desc' : 'asc'));
        return prev;
      }
      setSortDirection(column === 'due_date' ? 'asc' : 'desc');
      return column;
    });
  }, []);

  const toggleQuick = (q: 'overdue' | 'uninvoiced') => {
    setQuickFilter((cur) => (cur === q ? 'none' : q));
    setCurrentPage(1);
  };

  const columns: TableColumn<FsJob>[] = useMemo(
    () => [
      {
        key: 'job_number',
        header: 'Job',
        sortable: true,
        render: (job) => (
          <div className="flex items-center gap-3">
            <div
              className="w-10 h-10 rounded-lg flex items-center justify-center bg-primary-50 text-primary-600 shrink-0"
              style={job.job_type_color ? { backgroundColor: `${job.job_type_color}1a`, color: job.job_type_color } : undefined}
            >
              <Wrench className="w-5 h-5" />
            </div>
            <div className="min-w-0">
              <p className="font-medium text-secondary-900 truncate">{job.title}</p>
              <p className="text-xs text-secondary-500">
                {job.job_number}
                {job.job_type_name ? ` · ${job.job_type_name}` : ''}
              </p>
            </div>
          </div>
        ),
      },
      {
        key: 'account_name',
        header: 'Customer / site',
        render: (job) => (
          <div className="text-sm">
            <p className="text-secondary-800">{job.account_name || <span className="text-secondary-400">—</span>}</p>
            {(job.site_name || job.site_postal_code) && (
              <p className="text-xs text-secondary-500 flex items-center gap-1">
                <MapPin className="w-3 h-3" />
                {[job.site_name, job.site_postal_code].filter(Boolean).join(' · ')}
              </p>
            )}
          </div>
        ),
      },
      {
        key: 'status',
        header: 'Status',
        sortable: true,
        render: (job) => <JobStatusPill status={job.status} />,
      },
      {
        key: 'priority',
        header: 'Priority',
        sortable: true,
        render: (job) => <JobPriorityPill priority={job.priority} />,
      },
      {
        key: 'phases',
        header: 'Progress',
        render: (job) => {
          const pct = job.phase_count ? Math.round((job.phases_done / job.phase_count) * 100) : 0;
          return job.phase_count ? (
            <div className="min-w-[120px]">
              <div className="flex justify-between text-xs text-secondary-600 mb-1">
                <span>
                  {job.phases_done}/{job.phase_count} phases
                </span>
                <span>{pct}%</span>
              </div>
              <div className="h-1.5 rounded-full bg-secondary-100 overflow-hidden">
                <div className="h-full bg-primary-500 rounded-full" style={{ width: `${pct}%` }} />
              </div>
              {job.current_phase_name && <p className="text-xs text-secondary-500 mt-1 truncate">Next: {job.current_phase_name}</p>}
            </div>
          ) : (
            <span className="text-xs text-secondary-400">No phases</span>
          );
        },
      },
      {
        key: 'next_visit_at',
        header: 'Next visit',
        render: (job) => (
          <span className="text-sm text-secondary-600">
            {job.next_visit_at ? formatFsDateTime(job.next_visit_at, { dateStyle: 'medium', timeStyle: 'short' }) : '—'}
          </span>
        ),
      },
      {
        key: 'due_date',
        header: 'Due',
        sortable: true,
        render: (job) => {
          const overdue =
            job.due_date && !['completed', 'cancelled'].includes(job.status) && new Date(String(job.due_date).slice(0, 10)) < new Date(new Date().toDateString());
          return (
            <span className={`text-sm ${overdue ? 'text-red-600 font-medium' : 'text-secondary-600'}`}>
              {job.due_date ? formatFsDate(String(job.due_date).slice(0, 10)) : '—'}
            </span>
          );
        },
      },
    ],
    []
  );

  return (
    <div className="space-y-6">
      <PageHeader
        title="Service Jobs"
        description="Plan jobs, track each phase and book engineers onto site visits."
        icon={<Wrench className="w-5 h-5" />}
        actions={
          <>
            <Button variant="ghost" onClick={refreshAll} title="Refresh">
              <RefreshCw className="w-4 h-4" />
            </Button>
            <Button onClick={() => setIsCreateOpen(true)}>
              <Plus className="w-4 h-4 mr-1.5" /> New job
            </Button>
          </>
        }
      />

      <FieldServiceNav />

      <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-4">
        <StatCard title="Open jobs" value={stats?.open_jobs ?? 0} icon={<Wrench className="w-6 h-6" />} color="primary" />
        <StatCard title="In progress" value={stats?.in_progress_jobs ?? 0} icon={<RefreshCw className="w-6 h-6" />} color="warning" />
        <StatCard title="Visits today" value={stats?.visits_today ?? 0} icon={<CalendarClock className="w-6 h-6" />} color="info" />
        <StatCard title="Unassigned visits" value={stats?.unassigned_visits ?? 0} icon={<UserX className="w-6 h-6" />} color="violet" />
        <button type="button" onClick={() => toggleQuick('overdue')} className="text-left" aria-pressed={quickFilter === 'overdue'}>
          <StatCard title={quickFilter === 'overdue' ? 'Overdue ✓' : 'Overdue'} value={stats?.overdue_jobs ?? 0} icon={<AlertTriangle className="w-6 h-6" />} color="error" />
        </button>
        <button type="button" onClick={() => toggleQuick('uninvoiced')} className="text-left" aria-pressed={quickFilter === 'uninvoiced'}>
          <StatCard
            title={quickFilter === 'uninvoiced' ? 'Awaiting invoice ✓' : 'Awaiting invoice'}
            value={stats?.awaiting_invoice ?? 0}
            icon={<Receipt className="w-6 h-6" />}
            color="success"
          />
        </button>
      </div>

      <Card padding="md">
        <div className="flex flex-wrap items-center gap-4">
          <div className="flex-1 min-w-[250px] max-w-md">
            <Input
              placeholder="Search job number, title, customer, postcode…"
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              leftIcon={<Search className="w-4 h-4" />}
            />
          </div>
          <FilterSelect
            ariaLabel="Status"
            value={statusFilter}
            onChange={(v) => {
              setStatusFilter(v);
              setQuickFilter('none');
              setCurrentPage(1);
            }}
            options={JOB_STATUS_OPTIONS}
          />
          <FilterSelect
            ariaLabel="Priority"
            value={priorityFilter}
            onChange={(v) => {
              setPriorityFilter(v);
              setCurrentPage(1);
            }}
            options={[{ value: 'all', label: 'All priorities' }, ...PRIORITY_OPTIONS]}
          />
          <FilterSelect
            ariaLabel="Job type"
            value={typeFilter}
            onChange={(v) => {
              setTypeFilter(v);
              setCurrentPage(1);
            }}
            options={[{ value: 'all', label: 'All job types' }, ...jobTypes.map((t) => ({ value: t.uuid, label: t.name }))]}
          />
          {quickFilter !== 'none' && (
            <Button variant="ghost" size="sm" onClick={() => setQuickFilter('none')}>
              Clear “{quickFilter === 'overdue' ? 'Overdue' : 'Awaiting invoice'}” filter
            </Button>
          )}
        </div>
      </Card>

      <div>
        <Table
          columns={columns}
          data={jobs}
          keyExtractor={(j) => j.uuid}
          onRowClick={(j) => router.push(`/dashboard/field-service/jobs/${j.uuid}`)}
          sortColumn={sortColumn}
          sortDirection={sortDirection}
          onSort={handleSort}
          isLoading={isLoading}
          emptyMessage="No jobs match these filters."
        />
        <Pagination currentPage={currentPage} totalPages={totalPages} totalItems={totalItems} perPage={PER_PAGE} onPageChange={setCurrentPage} />
      </div>

      <JobFormModal
        isOpen={isCreateOpen}
        onClose={() => setIsCreateOpen(false)}
        onSaved={(job) => {
          loadStats();
          router.push(`/dashboard/field-service/jobs/${job.uuid}`);
        }}
      />
    </div>
  );
}

export default function FieldServiceJobsPage() {
  return (
    <ProtectedPage module="fs_jobs" title="Service Jobs">
      <JobsPageContent />
    </ProtectedPage>
  );
}

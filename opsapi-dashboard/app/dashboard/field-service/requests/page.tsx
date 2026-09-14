'use client';

/**
 * Service Requests — /dashboard/field-service/requests
 *
 * The complaint intake queue: customers report faults, managers triage, assign
 * and convert them into jobs. One request can spawn several jobs.
 */

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import toast from 'react-hot-toast';
import { ClipboardList, Pencil, Plus, Search, Trash2, Building2, Package } from 'lucide-react';
import { Input, Table, Pagination, Card, Button, ConfirmDialog, SearchableSelect } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { usePermissions } from '@/contexts/PermissionsContext';
import { fieldService, formatFsDate, type FsAccountLookup, type FsServiceRequest } from '@/services/field-service.service';
import {
  FieldServiceNav,
  FilterSelect,
  RequestStatusPill,
  JobPriorityPill,
  REQUEST_STATUS_OPTIONS,
  PRIORITY_OPTIONS,
  apiError,
} from '@/components/field-service/shared';
import RequestFormModal from '@/components/field-service/RequestFormModal';
import type { TableColumn } from '@/types';

const PER_PAGE = 20;
const PRIORITY_FILTER = [{ value: 'all', label: 'All priorities' }, ...PRIORITY_OPTIONS];

function RequestsPageContent() {
  const router = useRouter();
  const { canCreate, canUpdate, canDelete } = usePermissions();
  const [requests, setRequests] = useState<FsServiceRequest[]>([]);
  const [accounts, setAccounts] = useState<FsAccountLookup[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState('');
  const [debouncedSearch, setDebouncedSearch] = useState('');
  const [statusFilter, setStatusFilter] = useState('open');
  const [priorityFilter, setPriorityFilter] = useState('all');
  const [accountFilter, setAccountFilter] = useState('');
  const [currentPage, setCurrentPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [formOpen, setFormOpen] = useState(false);
  const [editing, setEditing] = useState<FsServiceRequest | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<FsServiceRequest | null>(null);
  const [deleting, setDeleting] = useState(false);
  const fetchIdRef = useRef(0);

  useEffect(() => {
    const t = setTimeout(() => {
      setDebouncedSearch(searchQuery.trim());
      setCurrentPage(1);
    }, 300);
    return () => clearTimeout(t);
  }, [searchQuery]);

  useEffect(() => {
    fieldService.lookupAccounts().then(setAccounts).catch(() => setAccounts([]));
  }, []);

  const fetchRequests = useCallback(async () => {
    const id = ++fetchIdRef.current;
    setIsLoading(true);
    try {
      const res = await fieldService.getRequests({
        page: currentPage,
        per_page: PER_PAGE,
        search: debouncedSearch || undefined,
        status: statusFilter === 'all' ? undefined : statusFilter,
        priority: priorityFilter === 'all' ? undefined : priorityFilter,
        account_uuid: accountFilter || undefined,
      });
      if (id === fetchIdRef.current) {
        setRequests(res.data);
        setTotalPages(res.meta.total_pages || 1);
        setTotalItems(res.meta.total);
      }
    } catch (err) {
      if (id === fetchIdRef.current) toast.error(apiError(err, 'Failed to load service requests'));
    } finally {
      if (id === fetchIdRef.current) setIsLoading(false);
    }
  }, [currentPage, debouncedSearch, statusFilter, priorityFilter, accountFilter]);

  useEffect(() => {
    fetchRequests();
  }, [fetchRequests]);

  const remove = async () => {
    if (!deleteTarget) return;
    setDeleting(true);
    try {
      await fieldService.deleteRequest(deleteTarget.uuid);
      toast.success('Service request deleted');
      setDeleteTarget(null);
      fetchRequests();
    } catch (err) {
      toast.error(apiError(err, 'Could not delete request'));
    } finally {
      setDeleting(false);
    }
  };

  const accountOptions = useMemo(() => accounts.map((a) => ({ value: a.uuid, label: a.name })), [accounts]);
  const allowEdit = canUpdate('fs_service_requests');
  const allowDelete = canDelete('fs_service_requests');

  const columns: TableColumn<FsServiceRequest>[] = useMemo(
    () => [
      {
        key: 'request',
        header: 'Request',
        render: (r) => (
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-lg bg-primary-50 text-primary-600 flex items-center justify-center shrink-0">
              <ClipboardList className="w-5 h-5" />
            </div>
            <div className="min-w-0">
              <p className="font-medium text-secondary-900 truncate">{r.title}</p>
              <p className="text-xs font-mono text-secondary-500">{r.request_number}</p>
            </div>
          </div>
        ),
      },
      {
        key: 'customer',
        header: 'Customer / asset',
        render: (r) => (
          <div className="text-sm">
            <p className="text-secondary-800 flex items-center gap-1">
              {r.account_name ? (
                <>
                  <Building2 className="w-3 h-3 text-secondary-400" /> {r.account_name}
                </>
              ) : (
                <span className="text-secondary-400">—</span>
              )}
            </p>
            {r.asset_name && (
              <p className="text-xs text-secondary-500 flex items-center gap-1">
                <Package className="w-3 h-3" /> {r.asset_name}
              </p>
            )}
          </div>
        ),
      },
      {
        key: 'priority',
        header: 'Priority',
        render: (r) => <JobPriorityPill priority={r.priority} />,
      },
      {
        key: 'status',
        header: 'Status',
        render: (r) => <RequestStatusPill status={r.status} />,
      },
      {
        key: 'manager',
        header: 'Assigned to',
        render: (r) => (
          <span className="text-sm text-secondary-700">
            {r.assigned_manager_name || <span className="text-secondary-400">Unassigned</span>}
          </span>
        ),
      },
      {
        key: 'created',
        header: 'Logged',
        render: (r) => <span className="text-sm text-secondary-600">{formatFsDate(r.created_at)}</span>,
      },
      {
        key: 'actions',
        header: '',
        width: 'w-24',
        render: (r) => (
          <div className="flex items-center gap-1">
            {allowEdit && (
              <button
                type="button"
                onClick={(e) => {
                  e.stopPropagation();
                  setEditing(r);
                  setFormOpen(true);
                }}
                className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg"
                aria-label="Edit request"
                title="Edit request"
              >
                <Pencil className="w-4 h-4" />
              </button>
            )}
            {allowDelete && (
              <button
                type="button"
                onClick={(e) => {
                  e.stopPropagation();
                  setDeleteTarget(r);
                }}
                className="p-1.5 text-secondary-500 hover:text-error-500 hover:bg-error-50 rounded-lg"
                aria-label="Delete request"
                title="Delete request"
              >
                <Trash2 className="w-4 h-4" />
              </button>
            )}
          </div>
        ),
      },
    ],
    [allowEdit, allowDelete]
  );

  return (
    <div className="space-y-6">
      <PageHeader
        title="Service Requests"
        description="Customer complaints and service requests — triage, assign and turn into jobs."
        icon={<ClipboardList className="w-5 h-5" />}
        actions={
          canCreate('fs_service_requests') && (
            <Button
              onClick={() => {
                setEditing(null);
                setFormOpen(true);
              }}
            >
              <Plus className="w-4 h-4 mr-1.5" /> Log request
            </Button>
          )
        }
      />
      <FieldServiceNav />

      <Card padding="md">
        <div className="flex flex-wrap items-end gap-4">
          <div className="flex-1 min-w-[220px] max-w-md">
            <Input
              placeholder="Search number, title, customer…"
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              leftIcon={<Search className="w-4 h-4" />}
            />
          </div>
          <FilterSelect
            value={statusFilter}
            onChange={(v) => {
              setStatusFilter(v);
              setCurrentPage(1);
            }}
            options={REQUEST_STATUS_OPTIONS}
            ariaLabel="Filter by status"
          />
          <FilterSelect
            value={priorityFilter}
            onChange={(v) => {
              setPriorityFilter(v);
              setCurrentPage(1);
            }}
            options={PRIORITY_FILTER}
            ariaLabel="Filter by priority"
          />
          <div className="w-full sm:w-64">
            <SearchableSelect
              options={accountOptions}
              value={accountFilter}
              onChange={(v) => {
                setAccountFilter(v);
                setCurrentPage(1);
              }}
              placeholder="All customers"
              clearable
            />
          </div>
        </div>
      </Card>

      <div>
        <Table
          columns={columns}
          data={requests}
          keyExtractor={(r) => r.uuid}
          onRowClick={(r) => router.push(`/dashboard/field-service/requests/${r.uuid}`)}
          isLoading={isLoading}
          emptyMessage="No service requests match these filters."
        />
        <Pagination
          currentPage={currentPage}
          totalPages={totalPages}
          totalItems={totalItems}
          perPage={PER_PAGE}
          onPageChange={setCurrentPage}
        />
      </div>

      <RequestFormModal
        isOpen={formOpen}
        request={editing}
        onClose={() => setFormOpen(false)}
        onSaved={() => fetchRequests()}
      />
      <ConfirmDialog
        isOpen={!!deleteTarget}
        onClose={() => setDeleteTarget(null)}
        onConfirm={remove}
        title="Delete service request"
        message={`Delete "${deleteTarget?.request_number || ''}"? Jobs already created from it keep their history.`}
        confirmText="Delete"
        variant="danger"
        isLoading={deleting}
      />
    </div>
  );
}

export default function FieldServiceRequestsPage() {
  return (
    <ProtectedPage module="fs_service_requests" title="Service Requests">
      <RequestsPageContent />
    </ProtectedPage>
  );
}

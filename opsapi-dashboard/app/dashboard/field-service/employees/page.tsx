'use client';

/**
 * Employees — /dashboard/field-service/employees
 *
 * Staff directory linked to workspace logins. An engineer is an active employee
 * flagged "Engineer"; site visits are assigned from here.
 */

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import toast from 'react-hot-toast';
import { Users, Pencil, Plus, Search, Trash2, Wrench } from 'lucide-react';
import { Input, Table, Pagination, Card, Button, ConfirmDialog } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { usePermissions } from '@/contexts/PermissionsContext';
import { fieldService, type FsEmployee } from '@/services/field-service.service';
import { FieldServiceNav, Pill, FilterSelect, apiError } from '@/components/field-service/shared';
import EmployeeFormModal from '@/components/field-service/EmployeeFormModal';
import type { TableColumn } from '@/types';

const PER_PAGE = 20;

const ROLE_OPTIONS = [
  { value: 'all', label: 'Everyone' },
  { value: 'engineers', label: 'Engineers only' },
];

const STATUS_OPTIONS = [
  { value: 'all', label: 'Active & inactive' },
  { value: 'active', label: 'Active only' },
  { value: 'inactive', label: 'Inactive only' },
];

function EmployeesPageContent() {
  const { canCreate, canUpdate, canDelete } = usePermissions();
  const [employees, setEmployees] = useState<FsEmployee[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState('');
  const [debouncedSearch, setDebouncedSearch] = useState('');
  const [roleFilter, setRoleFilter] = useState('all');
  const [statusFilter, setStatusFilter] = useState('all');
  const [currentPage, setCurrentPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [formOpen, setFormOpen] = useState(false);
  const [editing, setEditing] = useState<FsEmployee | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<FsEmployee | null>(null);
  const [deleting, setDeleting] = useState(false);
  const fetchIdRef = useRef(0);

  useEffect(() => {
    const t = setTimeout(() => {
      setDebouncedSearch(searchQuery.trim());
      setCurrentPage(1);
    }, 300);
    return () => clearTimeout(t);
  }, [searchQuery]);

  const fetchEmployees = useCallback(async () => {
    const id = ++fetchIdRef.current;
    setIsLoading(true);
    try {
      const res = await fieldService.getEmployees({
        page: currentPage,
        per_page: PER_PAGE,
        search: debouncedSearch || undefined,
        is_engineer: roleFilter === 'engineers' ? true : undefined,
        is_active: statusFilter === 'all' ? undefined : statusFilter === 'active',
      });
      if (id === fetchIdRef.current) {
        setEmployees(res.data);
        setTotalPages(res.meta.total_pages || 1);
        setTotalItems(res.meta.total);
      }
    } catch (err) {
      if (id === fetchIdRef.current) toast.error(apiError(err, 'Failed to load employees'));
    } finally {
      if (id === fetchIdRef.current) setIsLoading(false);
    }
  }, [currentPage, debouncedSearch, roleFilter, statusFilter]);

  useEffect(() => {
    fetchEmployees();
  }, [fetchEmployees]);

  const remove = async () => {
    if (!deleteTarget) return;
    setDeleting(true);
    try {
      await fieldService.deleteEmployee(deleteTarget.uuid);
      toast.success('Employee removed');
      setDeleteTarget(null);
      fetchEmployees();
    } catch (err) {
      toast.error(apiError(err, 'Could not remove employee'));
    } finally {
      setDeleting(false);
    }
  };

  const allowEdit = canUpdate('employees');
  const allowDelete = canDelete('employees');

  const columns: TableColumn<FsEmployee>[] = useMemo(
    () => [
      {
        key: 'name',
        header: 'Employee',
        render: (emp) => (
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-lg bg-violet-50 text-violet-600 flex items-center justify-center shrink-0">
              <Users className="w-5 h-5" />
            </div>
            <div className="min-w-0">
              <p className="font-medium text-secondary-900">{emp.user_name || emp.user_email || '—'}</p>
              {emp.job_title && <p className="text-xs text-secondary-500">{emp.job_title}</p>}
            </div>
          </div>
        ),
      },
      {
        key: 'login',
        header: 'Login / code',
        render: (emp) => (
          <div className="text-sm">
            <p className="text-secondary-800">{emp.user_email || '—'}</p>
            {emp.employee_code && <p className="text-xs text-secondary-500">{emp.employee_code}</p>}
          </div>
        ),
      },
      {
        key: 'roles',
        header: 'Role',
        render: (emp) => (
          <div className="flex flex-wrap items-center gap-1.5">
            {emp.is_engineer && (
              <Pill className="bg-blue-50 text-blue-700">
                <Wrench className="w-3 h-3 mr-1" /> Engineer
              </Pill>
            )}
            <Pill className={emp.is_active ? 'bg-green-50 text-green-700' : 'bg-secondary-100 text-secondary-500'}>
              {emp.is_active ? 'Active' : 'Inactive'}
            </Pill>
          </div>
        ),
      },
      {
        key: 'skills',
        header: 'Skills',
        render: (emp) => {
          const skills = emp.skills || [];
          if (skills.length === 0) return <span className="text-sm text-secondary-400">—</span>;
          return (
            <div className="flex flex-wrap gap-1">
              {skills.slice(0, 3).map((s) => (
                <span key={s} className="px-2 py-0.5 rounded-md bg-secondary-100 text-secondary-600 text-xs">
                  {s}
                </span>
              ))}
              {skills.length > 3 && <span className="text-xs text-secondary-400">+{skills.length - 3}</span>}
            </div>
          );
        },
      },
      {
        key: 'actions',
        header: '',
        width: 'w-24',
        render: (emp) => (
          <div className="flex items-center gap-1">
            {allowEdit && (
              <button
                type="button"
                onClick={(e) => {
                  e.stopPropagation();
                  setEditing(emp);
                  setFormOpen(true);
                }}
                className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg"
                aria-label="Edit employee"
                title="Edit employee"
              >
                <Pencil className="w-4 h-4" />
              </button>
            )}
            {allowDelete && (
              <button
                type="button"
                onClick={(e) => {
                  e.stopPropagation();
                  setDeleteTarget(emp);
                }}
                className="p-1.5 text-secondary-500 hover:text-error-500 hover:bg-error-50 rounded-lg"
                aria-label="Remove employee"
                title="Remove employee"
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
        title="Employees"
        description="Your staff and engineers, linked to their workspace logins."
        icon={<Users className="w-5 h-5" />}
        actions={
          canCreate('employees') && (
            <Button
              onClick={() => {
                setEditing(null);
                setFormOpen(true);
              }}
            >
              <Plus className="w-4 h-4 mr-1.5" /> Add employee
            </Button>
          )
        }
      />
      <FieldServiceNav />

      <Card padding="md">
        <div className="flex flex-wrap items-end gap-4">
          <div className="flex-1 min-w-[250px] max-w-md">
            <Input
              placeholder="Search name, email, job title, code…"
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              leftIcon={<Search className="w-4 h-4" />}
            />
          </div>
          <FilterSelect
            value={roleFilter}
            onChange={(v) => {
              setRoleFilter(v);
              setCurrentPage(1);
            }}
            options={ROLE_OPTIONS}
            ariaLabel="Filter by role"
          />
          <FilterSelect
            value={statusFilter}
            onChange={(v) => {
              setStatusFilter(v);
              setCurrentPage(1);
            }}
            options={STATUS_OPTIONS}
            ariaLabel="Filter by status"
          />
        </div>
      </Card>

      <div>
        <Table
          columns={columns}
          data={employees}
          keyExtractor={(e) => e.uuid}
          onRowClick={
            allowEdit
              ? (emp) => {
                  setEditing(emp);
                  setFormOpen(true);
                }
              : undefined
          }
          isLoading={isLoading}
          emptyMessage="No employees yet."
        />
        <Pagination
          currentPage={currentPage}
          totalPages={totalPages}
          totalItems={totalItems}
          perPage={PER_PAGE}
          onPageChange={setCurrentPage}
        />
      </div>

      <EmployeeFormModal
        isOpen={formOpen}
        employee={editing}
        onClose={() => setFormOpen(false)}
        onSaved={() => fetchEmployees()}
      />
      <ConfirmDialog
        isOpen={!!deleteTarget}
        onClose={() => setDeleteTarget(null)}
        onConfirm={remove}
        title="Remove employee"
        message={`Remove "${deleteTarget?.user_name || deleteTarget?.user_email || ''}"? Their login is not affected.`}
        confirmText="Remove"
        variant="danger"
        isLoading={deleting}
      />
    </div>
  );
}

export default function FieldServiceEmployeesPage() {
  return (
    <ProtectedPage module="employees" title="Employees">
      <EmployeesPageContent />
    </ProtectedPage>
  );
}

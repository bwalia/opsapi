'use client';

/**
 * Parts — /dashboard/field-service/parts
 *
 * The parts / products catalog fitted on jobs. Job items can link to a part;
 * the catalog itself is plain CRUD.
 */

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import toast from 'react-hot-toast';
import { Boxes, Pencil, Plus, Search, Trash2 } from 'lucide-react';
import { Input, Table, Pagination, Card, Button, ConfirmDialog } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { usePermissions } from '@/contexts/PermissionsContext';
import { fieldService, type FsPart } from '@/services/field-service.service';
import { FieldServiceNav, FilterSelect, Pill, apiError, money } from '@/components/field-service/shared';
import PartFormModal from '@/components/field-service/PartFormModal';
import type { TableColumn } from '@/types';

const PER_PAGE = 20;
const STATUS_OPTIONS = [
  { value: 'all', label: 'Active & inactive' },
  { value: 'active', label: 'Active only' },
  { value: 'inactive', label: 'Inactive only' },
];

function PartsPageContent() {
  const { canCreate, canUpdate, canDelete } = usePermissions();
  const [parts, setParts] = useState<FsPart[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState('');
  const [debouncedSearch, setDebouncedSearch] = useState('');
  const [statusFilter, setStatusFilter] = useState('all');
  const [currentPage, setCurrentPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [formOpen, setFormOpen] = useState(false);
  const [editing, setEditing] = useState<FsPart | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<FsPart | null>(null);
  const [deleting, setDeleting] = useState(false);
  const fetchIdRef = useRef(0);

  useEffect(() => {
    const t = setTimeout(() => {
      setDebouncedSearch(searchQuery.trim());
      setCurrentPage(1);
    }, 300);
    return () => clearTimeout(t);
  }, [searchQuery]);

  const fetchParts = useCallback(async () => {
    const id = ++fetchIdRef.current;
    setIsLoading(true);
    try {
      const res = await fieldService.getParts({
        page: currentPage,
        per_page: PER_PAGE,
        search: debouncedSearch || undefined,
        include_inactive: statusFilter !== 'active',
        is_active: statusFilter === 'all' ? undefined : statusFilter === 'active',
      });
      if (id === fetchIdRef.current) {
        setParts(res.data);
        setTotalPages(res.meta.total_pages || 1);
        setTotalItems(res.meta.total);
      }
    } catch (err) {
      if (id === fetchIdRef.current) toast.error(apiError(err, 'Failed to load parts'));
    } finally {
      if (id === fetchIdRef.current) setIsLoading(false);
    }
  }, [currentPage, debouncedSearch, statusFilter]);

  useEffect(() => {
    fetchParts();
  }, [fetchParts]);

  const remove = async () => {
    if (!deleteTarget) return;
    setDeleting(true);
    try {
      await fieldService.deletePart(deleteTarget.uuid);
      toast.success('Part deleted');
      setDeleteTarget(null);
      fetchParts();
    } catch (err) {
      toast.error(apiError(err, 'Could not delete part'));
    } finally {
      setDeleting(false);
    }
  };

  const allowEdit = canUpdate('fs_parts');
  const allowDelete = canDelete('fs_parts');

  const columns: TableColumn<FsPart>[] = useMemo(
    () => [
      {
        key: 'name',
        header: 'Part',
        render: (p) => (
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-lg bg-amber-50 text-amber-600 flex items-center justify-center shrink-0">
              <Boxes className="w-5 h-5" />
            </div>
            <div className="min-w-0">
              <p className="font-medium text-secondary-900">{p.name}</p>
              {p.sku && <p className="text-xs font-mono text-secondary-500">{p.sku}</p>}
            </div>
          </div>
        ),
      },
      {
        key: 'category',
        header: 'Category',
        render: (p) => <span className="text-sm text-secondary-700">{p.category || '—'}</span>,
      },
      {
        key: 'unit_price',
        header: 'Sell price',
        render: (p) => (
          <span className="text-sm text-secondary-800">
            {p.unit_price != null ? money(p.unit_price) : '—'}
            {p.tax_rate ? <span className="text-xs text-secondary-500"> +{p.tax_rate}%</span> : null}
          </span>
        ),
      },
      {
        key: 'stock',
        header: 'Stock',
        render: (p) => <span className="text-sm text-secondary-700">{p.stock_quantity != null ? p.stock_quantity : '—'}</span>,
      },
      {
        key: 'active',
        header: 'Status',
        render: (p) => (
          <Pill className={p.is_active ? 'bg-green-50 text-green-700' : 'bg-secondary-100 text-secondary-500'}>
            {p.is_active ? 'Active' : 'Inactive'}
          </Pill>
        ),
      },
      {
        key: 'actions',
        header: '',
        width: 'w-24',
        render: (p) => (
          <div className="flex items-center gap-1">
            {allowEdit && (
              <button
                type="button"
                onClick={(e) => {
                  e.stopPropagation();
                  setEditing(p);
                  setFormOpen(true);
                }}
                className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg"
                aria-label="Edit part"
                title="Edit part"
              >
                <Pencil className="w-4 h-4" />
              </button>
            )}
            {allowDelete && (
              <button
                type="button"
                onClick={(e) => {
                  e.stopPropagation();
                  setDeleteTarget(p);
                }}
                className="p-1.5 text-secondary-500 hover:text-error-500 hover:bg-error-50 rounded-lg"
                aria-label="Delete part"
                title="Delete part"
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
        title="Parts"
        description="Your parts / products catalog for jobs."
        icon={<Boxes className="w-5 h-5" />}
        actions={
          canCreate('fs_parts') && (
            <Button
              onClick={() => {
                setEditing(null);
                setFormOpen(true);
              }}
            >
              <Plus className="w-4 h-4 mr-1.5" /> New part
            </Button>
          )
        }
      />
      <FieldServiceNav />

      <Card padding="md">
        <div className="flex flex-wrap items-end gap-4">
          <div className="flex-1 min-w-[250px] max-w-md">
            <Input
              placeholder="Search name, SKU, category…"
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
            options={STATUS_OPTIONS}
            ariaLabel="Filter by status"
          />
        </div>
      </Card>

      <div>
        <Table
          columns={columns}
          data={parts}
          keyExtractor={(p) => p.uuid}
          onRowClick={
            allowEdit
              ? (p) => {
                  setEditing(p);
                  setFormOpen(true);
                }
              : undefined
          }
          isLoading={isLoading}
          emptyMessage="No parts yet."
        />
        <Pagination
          currentPage={currentPage}
          totalPages={totalPages}
          totalItems={totalItems}
          perPage={PER_PAGE}
          onPageChange={setCurrentPage}
        />
      </div>

      <PartFormModal isOpen={formOpen} part={editing} onClose={() => setFormOpen(false)} onSaved={() => fetchParts()} />
      <ConfirmDialog
        isOpen={!!deleteTarget}
        onClose={() => setDeleteTarget(null)}
        onConfirm={remove}
        title="Delete part"
        message={`Delete "${deleteTarget?.name || ''}"? Job items already using it keep their copied details.`}
        confirmText="Delete"
        variant="danger"
        isLoading={deleting}
      />
    </div>
  );
}

export default function FieldServicePartsPage() {
  return (
    <ProtectedPage module="fs_parts" title="Parts">
      <PartsPageContent />
    </ProtectedPage>
  );
}

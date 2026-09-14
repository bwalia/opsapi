'use client';

/**
 * Assets — /dashboard/field-service/assets
 *
 * The equipment installed at customer sites (the AC / fridge units a complaint
 * is raised against). Belongs to a CRM account and lives at a site.
 */

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import toast from 'react-hot-toast';
import { Package, Pencil, Plus, Search, Trash2, Building2, MapPin } from 'lucide-react';
import { Input, Table, Pagination, Card, Button, ConfirmDialog, SearchableSelect } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { usePermissions } from '@/contexts/PermissionsContext';
import {
  fieldService,
  formatFsDate,
  type AssetStatus,
  type FsAccountLookup,
  type FsAsset,
} from '@/services/field-service.service';
import { FieldServiceNav, Pill, FilterSelect, apiError } from '@/components/field-service/shared';
import AssetFormModal from '@/components/field-service/AssetFormModal';
import type { TableColumn } from '@/types';

const PER_PAGE = 20;

const STATUS_LABELS: Record<AssetStatus, string> = {
  active: 'Active',
  inactive: 'Inactive',
  decommissioned: 'Decommissioned',
};

const STATUS_COLORS: Record<AssetStatus, string> = {
  active: 'bg-green-50 text-green-700',
  inactive: 'bg-secondary-100 text-secondary-600',
  decommissioned: 'bg-red-50 text-red-700',
};

const STATUS_OPTIONS = [
  { value: 'all', label: 'All statuses' },
  ...(Object.keys(STATUS_LABELS) as AssetStatus[]).map((s) => ({ value: s, label: STATUS_LABELS[s] })),
];

function AssetsPageContent() {
  const { canCreate, canUpdate, canDelete } = usePermissions();
  const [assets, setAssets] = useState<FsAsset[]>([]);
  const [accounts, setAccounts] = useState<FsAccountLookup[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState('');
  const [debouncedSearch, setDebouncedSearch] = useState('');
  const [accountFilter, setAccountFilter] = useState('');
  const [statusFilter, setStatusFilter] = useState('all');
  const [currentPage, setCurrentPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [formOpen, setFormOpen] = useState(false);
  const [editing, setEditing] = useState<FsAsset | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<FsAsset | null>(null);
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

  const fetchAssets = useCallback(async () => {
    const id = ++fetchIdRef.current;
    setIsLoading(true);
    try {
      const res = await fieldService.getAssets({
        page: currentPage,
        per_page: PER_PAGE,
        search: debouncedSearch || undefined,
        account_uuid: accountFilter || undefined,
        status: statusFilter === 'all' ? undefined : statusFilter,
      });
      if (id === fetchIdRef.current) {
        setAssets(res.data);
        setTotalPages(res.meta.total_pages || 1);
        setTotalItems(res.meta.total);
      }
    } catch (err) {
      if (id === fetchIdRef.current) toast.error(apiError(err, 'Failed to load assets'));
    } finally {
      if (id === fetchIdRef.current) setIsLoading(false);
    }
  }, [currentPage, debouncedSearch, accountFilter, statusFilter]);

  useEffect(() => {
    fetchAssets();
  }, [fetchAssets]);

  const remove = async () => {
    if (!deleteTarget) return;
    setDeleting(true);
    try {
      await fieldService.deleteAsset(deleteTarget.uuid);
      toast.success('Asset deleted');
      setDeleteTarget(null);
      fetchAssets();
    } catch (err) {
      toast.error(apiError(err, 'Could not delete asset'));
    } finally {
      setDeleting(false);
    }
  };

  const accountOptions = useMemo(() => accounts.map((a) => ({ value: a.uuid, label: a.name })), [accounts]);
  const allowEdit = canUpdate('fs_assets');
  const allowDelete = canDelete('fs_assets');

  const columns: TableColumn<FsAsset>[] = useMemo(
    () => [
      {
        key: 'name',
        header: 'Asset',
        render: (asset) => (
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-lg bg-blue-50 text-blue-600 flex items-center justify-center shrink-0">
              <Package className="w-5 h-5" />
            </div>
            <div className="min-w-0">
              <p className="font-medium text-secondary-900">{asset.name}</p>
              {asset.category && <p className="text-xs text-secondary-500">{asset.category}</p>}
            </div>
          </div>
        ),
      },
      {
        key: 'location',
        header: 'Customer / site',
        render: (asset) => (
          <div className="text-sm">
            {asset.account_name ? (
              <p className="text-secondary-800 flex items-center gap-1">
                <Building2 className="w-3 h-3 text-secondary-400" /> {asset.account_name}
              </p>
            ) : (
              <p className="text-secondary-400">—</p>
            )}
            {asset.site_name && (
              <p className="text-xs text-secondary-500 flex items-center gap-1">
                <MapPin className="w-3 h-3" /> {asset.site_name}
              </p>
            )}
          </div>
        ),
      },
      {
        key: 'serial',
        header: 'Serial / model',
        render: (asset) => (
          <div className="text-sm">
            <p className="text-secondary-800">{asset.serial_number || '—'}</p>
            {asset.model && <p className="text-xs text-secondary-500">{asset.model}</p>}
          </div>
        ),
      },
      {
        key: 'status',
        header: 'Status',
        render: (asset) => (
          <Pill className={STATUS_COLORS[asset.status] || STATUS_COLORS.inactive}>
            {STATUS_LABELS[asset.status] ?? asset.status}
          </Pill>
        ),
      },
      {
        key: 'warranty',
        header: 'Warranty',
        render: (asset) => <span className="text-sm text-secondary-700">{formatFsDate(asset.warranty_expires_at)}</span>,
      },
      {
        key: 'actions',
        header: '',
        width: 'w-24',
        render: (asset) => (
          <div className="flex items-center gap-1">
            {allowEdit && (
              <button
                type="button"
                onClick={(e) => {
                  e.stopPropagation();
                  setEditing(asset);
                  setFormOpen(true);
                }}
                className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg"
                aria-label="Edit asset"
                title="Edit asset"
              >
                <Pencil className="w-4 h-4" />
              </button>
            )}
            {allowDelete && (
              <button
                type="button"
                onClick={(e) => {
                  e.stopPropagation();
                  setDeleteTarget(asset);
                }}
                className="p-1.5 text-secondary-500 hover:text-error-500 hover:bg-error-50 rounded-lg"
                aria-label="Delete asset"
                title="Delete asset"
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
        title="Assets"
        description="Equipment installed at your customers' sites."
        icon={<Package className="w-5 h-5" />}
        actions={
          canCreate('fs_assets') && (
            <Button
              onClick={() => {
                setEditing(null);
                setFormOpen(true);
              }}
            >
              <Plus className="w-4 h-4 mr-1.5" /> New asset
            </Button>
          )
        }
      />
      <FieldServiceNav />

      <Card padding="md">
        <div className="flex flex-wrap items-end gap-4">
          <div className="flex-1 min-w-[250px] max-w-md">
            <Input
              placeholder="Search name, serial, tag, model…"
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              leftIcon={<Search className="w-4 h-4" />}
            />
          </div>
          <div className="w-full sm:w-72">
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
          data={assets}
          keyExtractor={(a) => a.uuid}
          onRowClick={
            allowEdit
              ? (asset) => {
                  setEditing(asset);
                  setFormOpen(true);
                }
              : undefined
          }
          isLoading={isLoading}
          emptyMessage="No assets yet."
        />
        <Pagination
          currentPage={currentPage}
          totalPages={totalPages}
          totalItems={totalItems}
          perPage={PER_PAGE}
          onPageChange={setCurrentPage}
        />
      </div>

      <AssetFormModal
        isOpen={formOpen}
        asset={editing}
        onClose={() => setFormOpen(false)}
        onSaved={() => fetchAssets()}
      />
      <ConfirmDialog
        isOpen={!!deleteTarget}
        onClose={() => setDeleteTarget(null)}
        onConfirm={remove}
        title="Delete asset"
        message={`Delete "${deleteTarget?.name || ''}"? This can't be undone.`}
        confirmText="Delete"
        variant="danger"
        isLoading={deleting}
      />
    </div>
  );
}

export default function FieldServiceAssetsPage() {
  return (
    <ProtectedPage module="fs_assets" title="Assets">
      <AssetsPageContent />
    </ProtectedPage>
  );
}

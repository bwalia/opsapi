'use client';

/**
 * Service Sites — /dashboard/field-service/sites
 *
 * Customer site addresses jobs are carried out at. A site usually belongs to
 * a CRM account; access notes and the on-site contact are shown to engineers.
 */

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import toast from 'react-hot-toast';
import { MapPin, Pencil, Plus, Search, Trash2, Building2 } from 'lucide-react';
import { Input, Table, Pagination, Card, Button, ConfirmDialog, SearchableSelect } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { usePermissions } from '@/contexts/PermissionsContext';
import { fieldService, type FsAccountLookup, type FsSite } from '@/services/field-service.service';
import { FieldServiceNav, apiError, formatAddress, mapsUrl } from '@/components/field-service/shared';
import SiteFormModal from '@/components/field-service/SiteFormModal';
import type { TableColumn } from '@/types';

const PER_PAGE = 20;

function SitesPageContent() {
  const { canCreate, canUpdate, canDelete } = usePermissions();
  const [sites, setSites] = useState<FsSite[]>([]);
  const [accounts, setAccounts] = useState<FsAccountLookup[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState('');
  const [debouncedSearch, setDebouncedSearch] = useState('');
  const [accountFilter, setAccountFilter] = useState('');
  const [currentPage, setCurrentPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [formOpen, setFormOpen] = useState(false);
  const [editing, setEditing] = useState<FsSite | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<FsSite | null>(null);
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

  const fetchSites = useCallback(async () => {
    const id = ++fetchIdRef.current;
    setIsLoading(true);
    try {
      const res = await fieldService.getSites({
        page: currentPage,
        per_page: PER_PAGE,
        search: debouncedSearch || undefined,
        account_uuid: accountFilter || undefined,
      });
      if (id === fetchIdRef.current) {
        setSites(res.data);
        setTotalPages(res.meta.total_pages || 1);
        setTotalItems(res.meta.total);
      }
    } catch (err) {
      if (id === fetchIdRef.current) toast.error(apiError(err, 'Failed to load sites'));
    } finally {
      if (id === fetchIdRef.current) setIsLoading(false);
    }
  }, [currentPage, debouncedSearch, accountFilter]);

  useEffect(() => {
    fetchSites();
  }, [fetchSites]);

  const remove = async () => {
    if (!deleteTarget) return;
    setDeleting(true);
    try {
      await fieldService.deleteSite(deleteTarget.uuid);
      toast.success('Site deleted');
      setDeleteTarget(null);
      fetchSites();
    } catch (err) {
      toast.error(apiError(err, 'Could not delete site'));
    } finally {
      setDeleting(false);
    }
  };

  const accountOptions = useMemo(() => accounts.map((a) => ({ value: a.uuid, label: a.name })), [accounts]);
  const allowEdit = canUpdate('fs_sites');
  const allowDelete = canDelete('fs_sites');

  const columns: TableColumn<FsSite>[] = useMemo(
    () => [
      {
        key: 'name',
        header: 'Site',
        render: (site) => (
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-lg bg-emerald-50 text-emerald-600 flex items-center justify-center shrink-0">
              <MapPin className="w-5 h-5" />
            </div>
            <div className="min-w-0">
              <p className="font-medium text-secondary-900">{site.name}</p>
              {site.account_name && (
                <p className="text-xs text-secondary-500 flex items-center gap-1">
                  <Building2 className="w-3 h-3" /> {site.account_name}
                </p>
              )}
            </div>
          </div>
        ),
      },
      {
        key: 'address',
        header: 'Address',
        render: (site) => {
          const address = formatAddress(site);
          const url = mapsUrl(address, site.latitude, site.longitude);
          return address ? (
            url ? (
              <a
                href={url}
                target="_blank"
                rel="noopener noreferrer"
                onClick={(e) => e.stopPropagation()}
                className="text-sm text-primary-600 hover:underline"
              >
                {address}
              </a>
            ) : (
              <span className="text-sm text-secondary-700">{address}</span>
            )
          ) : (
            <span className="text-sm text-secondary-400">—</span>
          );
        },
      },
      {
        key: 'contact_name',
        header: 'Site contact',
        render: (site) => (
          <div className="text-sm">
            <p className="text-secondary-800">{site.contact_name || '—'}</p>
            {site.contact_phone && <p className="text-xs text-secondary-500">{site.contact_phone}</p>}
          </div>
        ),
      },
      {
        key: 'job_count',
        header: 'Jobs',
        render: (site) => <span className="text-sm text-secondary-700">{site.job_count}</span>,
      },
      {
        key: 'actions',
        header: '',
        width: 'w-24',
        render: (site) => (
          <div className="flex items-center gap-1">
            {allowEdit && (
              <button
                type="button"
                onClick={(e) => {
                  e.stopPropagation();
                  setEditing(site);
                  setFormOpen(true);
                }}
                className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg"
                title="Edit site"
              >
                <Pencil className="w-4 h-4" />
              </button>
            )}
            {allowDelete && (
              <button
                type="button"
                onClick={(e) => {
                  e.stopPropagation();
                  setDeleteTarget(site);
                }}
                className="p-1.5 text-secondary-500 hover:text-error-500 hover:bg-error-50 rounded-lg"
                title="Delete site"
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
        title="Service Sites"
        description="Customer locations your engineers visit."
        icon={<MapPin className="w-5 h-5" />}
        actions={
          canCreate('fs_sites') && (
            <Button
              onClick={() => {
                setEditing(null);
                setFormOpen(true);
              }}
            >
              <Plus className="w-4 h-4 mr-1.5" /> New site
            </Button>
          )
        }
      />
      <FieldServiceNav />

      <Card padding="md">
        <div className="flex flex-wrap items-end gap-4">
          <div className="flex-1 min-w-[250px] max-w-md">
            <Input
              placeholder="Search name, address, postcode…"
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
        </div>
      </Card>

      <div>
        <Table
          columns={columns}
          data={sites}
          keyExtractor={(s) => s.uuid}
          onRowClick={
            allowEdit
              ? (site) => {
                  setEditing(site);
                  setFormOpen(true);
                }
              : undefined
          }
          isLoading={isLoading}
          emptyMessage="No sites yet."
        />
        <Pagination currentPage={currentPage} totalPages={totalPages} totalItems={totalItems} perPage={PER_PAGE} onPageChange={setCurrentPage} />
      </div>

      <SiteFormModal isOpen={formOpen} site={editing} onClose={() => setFormOpen(false)} onSaved={() => fetchSites()} />
      <ConfirmDialog
        isOpen={!!deleteTarget}
        onClose={() => setDeleteTarget(null)}
        onConfirm={remove}
        title="Delete site"
        message={`Delete "${deleteTarget?.name || ''}"? Sites with open jobs can't be deleted.`}
        confirmText="Delete"
        variant="danger"
        isLoading={deleting}
      />
    </div>
  );
}

export default function FieldServiceSitesPage() {
  return (
    <ProtectedPage module="fs_sites" title="Service Sites">
      <SitesPageContent />
    </ProtectedPage>
  );
}

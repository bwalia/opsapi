'use client';

/**
 * Plugin page — /dashboard/plugins/<plugin>/<key>
 *
 * Either one generic list + form page for a plugin resource declared with
 * `sdk.crud`, or a plugin's own custom page (manifest `pages`) in a sandboxed
 * frame — see PLUGINS.md §6. The backend describes the screen and what the
 * caller may do, so a newly installed plugin appears here (via its sidebar
 * entry) without rebuilding the dashboard. The API enforces the namespace and
 * permissions; this page only mirrors them.
 */

import React, { Suspense, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useParams } from 'next/navigation';
import toast from 'react-hot-toast';
import { AlertTriangle, Pencil, Plus, Puzzle, Search, ShieldOff, Trash2 } from 'lucide-react';
import { Input, Table, Pagination, Card, Button, ConfirmDialog } from '@/components/ui';
import { PageHeader } from '@/components/layout/PageHeader';
import { FilterSelect, apiError, apiStatus } from '@/components/field-service/shared';
import { PluginRecordModal, renderValue, singular } from '@/components/plugins/PluginRecordModal';
import { PluginPageFrame } from '@/components/plugins/PluginPageFrame';
import {
  pluginService,
  type PluginField,
  type PluginRecord,
  type PluginResourceSchema,
  type PluginScreen,
} from '@/services/plugins.service';
import type { TableColumn } from '@/types';

const PER_PAGE = 20;
const CREATED: PluginField = {
  name: 'created_at',
  label: 'Created',
  type: 'datetime',
  required: false,
};

type LoadState = 'loading' | 'ready' | 'forbidden' | 'missing' | 'error';
type Sort = { column: string; direction: 'asc' | 'desc' } | null;

/** A human name for a record: its first non-empty text field. */
function recordName(schema: PluginResourceSchema, row: PluginRecord): string {
  for (const f of schema.fields) {
    const v = row[f.name];
    if ((f.type === 'string' || f.type === 'email') && typeof v === 'string' && v) return v;
  }
  return `this ${singular(schema.label).toLowerCase()}`;
}

function Notice({
  icon,
  title,
  message,
  action,
}: {
  icon: React.ReactNode;
  title: string;
  message: string;
  action?: React.ReactNode;
}) {
  return (
    <Card padding="lg">
      <div className="flex flex-col items-center text-center py-10 gap-3">
        <div className="w-12 h-12 rounded-xl bg-secondary-100 text-secondary-500 flex items-center justify-center">
          {icon}
        </div>
        <h2 className="text-lg font-semibold text-secondary-900">{title}</h2>
        <p className="text-sm text-secondary-500 max-w-md">{message}</p>
        {action}
      </div>
    </Card>
  );
}

/** Loads what /dashboard/plugins/<plugin>/<key> shows, then renders it. */
function PluginScreenLoader({ plugin, resource }: { plugin: string; resource: string }) {
  const [screen, setScreen] = useState<PluginScreen | null>(null);
  const [state, setState] = useState<LoadState>('loading');
  const [reload, setReload] = useState(0);

  useEffect(() => {
    pluginService
      .getResource(plugin, resource)
      .then((s) => {
        setScreen(s);
        setState('ready');
      })
      .catch((err) => {
        const status = apiStatus(err);
        setState(status === 403 ? 'forbidden' : status === 404 ? 'missing' : 'error');
      });
  }, [plugin, resource, reload]);

  if (state === 'loading') {
    return (
      <div className="space-y-6" aria-busy="true">
        <div className="h-12 w-64 rounded-lg bg-secondary-100 animate-pulse" />
        <div className="h-16 rounded-xl bg-secondary-100 animate-pulse" />
        <div className="h-72 rounded-xl bg-secondary-100 animate-pulse" />
      </div>
    );
  }
  if (state === 'forbidden') {
    return (
      <Notice
        icon={<ShieldOff className="w-6 h-6" />}
        title="You don't have access to this page"
        message="Ask a workspace admin to grant your role read access to it in role settings."
      />
    );
  }
  if (state === 'error') {
    return (
      <Notice
        icon={<AlertTriangle className="w-6 h-6" />}
        title="Couldn't load this page"
        message="The server didn't respond as expected. Check your connection and try again."
        action={
          <Button
            variant="outline"
            onClick={() => {
              setState('loading');
              setReload((n) => n + 1);
            }}
          >
            Try again
          </Button>
        }
      />
    );
  }
  if (state === 'missing' || !screen) {
    return (
      <Notice
        icon={<Puzzle className="w-6 h-6" />}
        title="This page isn't available"
        message="The plugin that provides it isn't installed on this server, or no longer offers this page."
      />
    );
  }

  if (screen.kind === 'page') {
    return (
      <div className="space-y-6">
        <PageHeader
          title={screen.label}
          description={screen.description || screen.plugin.name}
          icon={<Puzzle className="w-5 h-5" />}
        />
        <Suspense fallback={null}>
          <PluginPageFrame schema={screen} />
        </Suspense>
      </div>
    );
  }
  return <PluginResource schema={screen} />;
}

function PluginResource({ schema }: { schema: PluginResourceSchema }) {
  const [rows, setRows] = useState<PluginRecord[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState('');
  const [debouncedSearch, setDebouncedSearch] = useState('');
  const [filters, setFilters] = useState<Record<string, string>>({});
  const [sort, setSort] = useState<Sort>(null);
  const [currentPage, setCurrentPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [editing, setEditing] = useState<{
    record: PluginRecord | null;
  } | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<PluginRecord | null>(null);
  const [deleting, setDeleting] = useState(false);
  const fetchIdRef = useRef(0);

  useEffect(() => {
    const t = setTimeout(() => {
      setDebouncedSearch(searchQuery.trim());
      setCurrentPage(1);
    }, 300);
    return () => clearTimeout(t);
  }, [searchQuery]);

  const fetchRows = useCallback(async () => {
    const id = ++fetchIdRef.current;
    setIsLoading(true);
    try {
      const res = await pluginService.list(schema, {
        page: currentPage,
        per_page: PER_PAGE,
        q: debouncedSearch || undefined,
        sort: sort?.column,
        order: sort?.direction,
        filters,
      });
      if (id === fetchIdRef.current) {
        setRows(res.data);
        setTotalPages(res.meta.total_pages || 1);
        setTotalItems(res.meta.total);
      }
    } catch (err) {
      if (id === fetchIdRef.current) toast.error(apiError(err, `Failed to load ${schema.label.toLowerCase()}`));
    } finally {
      if (id === fetchIdRef.current) setIsLoading(false);
    }
  }, [schema, currentPage, debouncedSearch, sort, filters]);

  useEffect(() => {
    fetchRows();
  }, [fetchRows]);

  const remove = async () => {
    if (!deleteTarget) return;
    setDeleting(true);
    try {
      await pluginService.remove(schema, deleteTarget.uuid);
      toast.success(`${singular(schema.label)} deleted`);
      setDeleteTarget(null);
      fetchRows();
    } catch (err) {
      toast.error(apiError(err, `Could not delete ${singular(schema.label).toLowerCase()}`));
    } finally {
      setDeleting(false);
    }
  };

  const columns = useMemo<TableColumn<PluginRecord>[]>(() => {
    const byName = new Map(schema.fields.map((f) => [f.name, f]));
    const cols: TableColumn<PluginRecord>[] = [];
    schema.columns.forEach((name, i) => {
      const field = byName.get(name);
      if (!field) return;
      cols.push({
        key: name,
        header: field.label,
        sortable: schema.sortable.includes(name),
        render: (row) =>
          i === 0 ? (
            <span className="font-medium text-secondary-900">{renderValue(field, row[name])}</span>
          ) : (
            renderValue(field, row[name])
          ),
      });
    });
    cols.push({
      key: 'created_at',
      header: CREATED.label,
      sortable: schema.sortable.includes('created_at'),
      render: (row) => <span className="text-sm text-secondary-500">{renderValue(CREATED, row.created_at)}</span>,
    });
    if (schema.can.update || schema.can.delete) {
      const name = singular(schema.label).toLowerCase();
      cols.push({
        key: 'actions',
        header: '',
        width: 'w-24',
        render: (row) => (
          <div className="flex items-center gap-1">
            {schema.can.update && (
              <button
                type="button"
                onClick={(e) => {
                  e.stopPropagation();
                  setEditing({ record: row });
                }}
                className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg"
                aria-label={`Edit ${name}`}
                title={`Edit ${name}`}
              >
                <Pencil className="w-4 h-4" />
              </button>
            )}
            {schema.can.delete && (
              <button
                type="button"
                onClick={(e) => {
                  e.stopPropagation();
                  setDeleteTarget(row);
                }}
                className="p-1.5 text-secondary-500 hover:text-error-500 hover:bg-error-50 rounded-lg"
                aria-label={`Delete ${name}`}
                title={`Delete ${name}`}
              >
                <Trash2 className="w-4 h-4" />
              </button>
            )}
          </div>
        ),
      });
    }
    return cols;
  }, [schema]);

  const name = singular(schema.label).toLowerCase();
  const filtered = !!debouncedSearch || Object.values(filters).some(Boolean);

  return (
    <div className="space-y-6">
      <PageHeader
        title={schema.label}
        description={schema.plugin.name}
        icon={<Puzzle className="w-5 h-5" />}
        actions={
          schema.can.create ? (
            <Button onClick={() => setEditing({ record: null })}>
              <Plus className="w-4 h-4 mr-1.5" /> New {name}
            </Button>
          ) : undefined
        }
      />

      {(schema.searchable || schema.filters.length > 0) && (
        <Card padding="md">
          <div className="flex flex-wrap items-end gap-4">
            {schema.searchable && (
              <div className="flex-1 min-w-[250px] max-w-md">
                <Input
                  placeholder={`Search ${schema.label.toLowerCase()}…`}
                  aria-label={`Search ${schema.label.toLowerCase()}`}
                  value={searchQuery}
                  onChange={(e) => setSearchQuery(e.target.value)}
                  leftIcon={<Search className="w-4 h-4" />}
                />
              </div>
            )}
            {schema.filters.map((field) => (
              <FilterSelect
                key={field.name}
                value={filters[field.name] ?? ''}
                onChange={(v) => {
                  setFilters((f) => ({ ...f, [field.name]: v }));
                  setCurrentPage(1);
                }}
                options={
                  field.type === 'boolean'
                    ? [
                        { value: '', label: `${field.label}: any` },
                        { value: 'true', label: `${field.label}: yes` },
                        { value: 'false', label: `${field.label}: no` },
                      ]
                    : [
                        {
                          value: '',
                          label: `Any ${field.label.toLowerCase()}`,
                        },
                        ...(field.enum ?? []).map((v) => ({
                          value: v,
                          label: v,
                        })),
                      ]
                }
                ariaLabel={`Filter by ${field.label.toLowerCase()}`}
              />
            ))}
          </div>
        </Card>
      )}

      <div>
        <Table
          columns={columns}
          data={rows}
          keyExtractor={(row) => row.uuid}
          onRowClick={(row) => setEditing({ record: row })}
          sortColumn={sort?.column}
          sortDirection={sort?.direction}
          onSort={(column) => {
            setSort((s) =>
              s?.column === column
                ? { column, direction: s.direction === 'asc' ? 'desc' : 'asc' }
                : { column, direction: 'asc' }
            );
            setCurrentPage(1);
          }}
          isLoading={isLoading}
          emptyMessage={filtered ? 'Nothing matches your search.' : `No ${schema.label.toLowerCase()} yet.`}
          caption={schema.label}
        />
        <Pagination
          currentPage={currentPage}
          totalPages={totalPages}
          totalItems={totalItems}
          perPage={PER_PAGE}
          onPageChange={setCurrentPage}
        />
      </div>

      <PluginRecordModal
        isOpen={!!editing}
        schema={schema}
        record={editing?.record ?? null}
        onClose={() => setEditing(null)}
        onSaved={fetchRows}
      />
      <ConfirmDialog
        isOpen={!!deleteTarget}
        onClose={() => setDeleteTarget(null)}
        onConfirm={remove}
        title={`Delete ${name}`}
        message={`Delete "${deleteTarget ? recordName(schema, deleteTarget) : ''}"? This can't be undone.`}
        confirmText="Delete"
        variant="danger"
        isLoading={deleting}
      />
    </div>
  );
}

export default function PluginResourcePage() {
  const { plugin, resource } = useParams<{
    plugin: string;
    resource: string;
  }>();
  // Keyed so navigating between plugin pages starts from a clean state.
  return <PluginScreenLoader key={`${plugin}/${resource}`} plugin={plugin} resource={resource} />;
}

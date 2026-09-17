'use client';

/**
 * Assets — /dashboard/field-service/assets
 *
 * Simpro's customer asset register: every machine DBS maintain, where it is,
 * the condition it was last surveyed in (1 excellent – 6 replace), the
 * refrigerant it holds, when its next service falls due, and whether it is in
 * step with Simpro.
 */

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import toast from 'react-hot-toast';
import { HardDrive, Search, AlertTriangle, Snowflake, Wrench } from 'lucide-react';
import { Input, Table, Pagination, Card } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { FieldServiceNav, FilterSelect, CheckboxField, apiError } from '@/components/field-service/shared';
import { ConditionPill, SimproBadge, CONDITION_OPTIONS } from '@/components/field-service/simpro';
import { formatFsDate, parseFsDate } from '@/services/field-service.service';
import { simproCrm, type Asset } from '@/services/simpro-crm.service';
import type { TableColumn } from '@/types';

const PER_PAGE = 25;
const DISCIPLINES = [
  { value: 'all', label: 'All disciplines' },
  { value: 'hvac', label: 'HVAC' },
  { value: 'heating', label: 'Heating' },
  { value: 'ventilation', label: 'Ventilation' },
  { value: 'electrical', label: 'Electrical' },
  { value: 'controls', label: 'Controls' },
];

function AssetsPageContent() {
  const router = useRouter();
  const [assets, setAssets] = useState<Asset[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [debounced, setDebounced] = useState('');
  const [discipline, setDiscipline] = useState('all');
  const [conditionMin, setConditionMin] = useState('all');
  const [fgasOnly, setFgasOnly] = useState(false);
  const [overdueOnly, setOverdueOnly] = useState(false);
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [total, setTotal] = useState(0);
  const fetchId = useRef(0);

  useEffect(() => {
    const t = setTimeout(() => {
      setDebounced(search.trim());
      setPage(1);
    }, 300);
    return () => clearTimeout(t);
  }, [search]);

  const load = useCallback(async () => {
    const id = ++fetchId.current;
    setIsLoading(true);
    try {
      const res = await simproCrm.getAssets({
        page,
        per_page: PER_PAGE,
        search: debounced || undefined,
        discipline: discipline === 'all' ? undefined : discipline,
        condition_min: conditionMin === 'all' ? undefined : Number(conditionMin),
        fgas_only: fgasOnly,
        service_overdue: overdueOnly,
      });
      if (id === fetchId.current) {
        setAssets(res.data);
        setTotalPages(res.meta.total_pages || 1);
        setTotal(res.meta.total);
      }
    } catch (err) {
      if (id === fetchId.current) toast.error(apiError(err, 'Failed to load assets'));
    } finally {
      if (id === fetchId.current) setIsLoading(false);
    }
  }, [page, debounced, discipline, conditionMin, fgasOnly, overdueOnly]);

  useEffect(() => {
    load();
  }, [load]);

  const columns: TableColumn<Asset>[] = useMemo(
    () => [
      {
        key: 'asset',
        header: 'Asset',
        render: (a) => (
          <div className="min-w-0">
            <p className="font-medium text-secondary-900">{a.name}</p>
            <p className="text-xs font-mono text-secondary-500">
              {a.asset_tag}
              {a.manufacturer ? ` · ${a.manufacturer}${a.model ? ` ${a.model}` : ''}` : ''}
            </p>
          </div>
        ),
      },
      {
        key: 'asset_type',
        header: 'Type',
        render: (a) => <span className="text-sm text-secondary-700">{a.asset_type || '—'}</span>,
      },
      {
        key: 'site',
        header: 'Customer / site',
        render: (a) => (
          <div className="text-sm">
            <p className="text-secondary-800">{a.customer_name || '—'}</p>
            <p className="text-xs text-secondary-500">{a.site_name}</p>
          </div>
        ),
      },
      { key: 'condition', header: 'Condition', render: (a) => <ConditionPill rating={a.condition_rating} /> },
      {
        key: 'refrigerant',
        header: 'Refrigerant',
        render: (a) =>
          a.refrigerant_type ? (
            <span className="text-sm text-secondary-700 whitespace-nowrap">
              {a.refrigerant_type} · {a.refrigerant_charge_kg} kg
              {a.co2e_tonnes != null && <span className="block text-xs text-secondary-500">{a.co2e_tonnes} tCO₂e</span>}
            </span>
          ) : (
            <span className="text-sm text-secondary-400">—</span>
          ),
      },
      {
        key: 'next_service_date',
        header: 'Next service',
        render: (a) => {
          const due = parseFsDate(a.next_service_date);
          const overdue = !!due && due < new Date(new Date().toDateString());
          return (
            <span className={`text-sm whitespace-nowrap ${overdue ? 'text-red-600 font-medium' : 'text-secondary-700'}`}>
              {overdue && <AlertTriangle className="inline w-3.5 h-3.5 mr-1 -mt-0.5" />}
              {formatFsDate(a.next_service_date)}
            </span>
          );
        },
      },
      {
        key: 'sync',
        header: 'Simpro',
        render: (a) => <SimproBadge state={a.simpro_sync_state} simproId={a.simpro_id} />,
      },
    ],
    []
  );

  return (
    <div className="space-y-6">
      <PageHeader
        title="Assets"
        description="Customer plant under maintenance: condition surveys, refrigerant held and the service schedule."
        icon={<HardDrive className="w-5 h-5" />}
      />
      <FieldServiceNav />

      <Card padding="md">
        <div className="flex flex-wrap items-center gap-4">
          <div className="flex-1 min-w-[240px] max-w-md">
            <Input
              placeholder="Search tag, description, serial, model…"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              leftIcon={<Search className="w-4 h-4" />}
            />
          </div>
          <FilterSelect
            value={discipline}
            onChange={(v) => {
              setDiscipline(v);
              setPage(1);
            }}
            options={DISCIPLINES}
            ariaLabel="Discipline"
          />
          <FilterSelect
            value={conditionMin}
            onChange={(v) => {
              setConditionMin(v);
              setPage(1);
            }}
            options={[{ value: 'all', label: 'Any condition' }, ...CONDITION_OPTIONS.map((o) => ({ ...o, label: `${o.label} or worse` }))]}
            ariaLabel="Condition"
          />
          <CheckboxField
            label="F-Gas systems"
            checked={fgasOnly}
            onChange={(v) => {
              setFgasOnly(v);
              setPage(1);
            }}
          />
          <CheckboxField
            label="Service overdue"
            checked={overdueOnly}
            onChange={(v) => {
              setOverdueOnly(v);
              setPage(1);
            }}
          />
        </div>
      </Card>

      <div>
        <Table
          columns={columns}
          data={assets}
          keyExtractor={(a) => a.uuid}
          onRowClick={(a) => router.push(`/dashboard/field-service/assets/${a.uuid}`)}
          isLoading={isLoading}
          emptyMessage="No assets match these filters."
        />
        <Pagination currentPage={page} totalPages={totalPages} totalItems={total} perPage={PER_PAGE} onPageChange={setPage} />
      </div>

      <p className="flex items-center gap-4 text-xs text-secondary-500">
        <span className="inline-flex items-center gap-1">
          <Wrench className="w-3.5 h-3.5" /> Condition is the DBS survey scale: 1 excellent – 6 budget for replacement.
        </span>
        <span className="inline-flex items-center gap-1">
          <Snowflake className="w-3.5 h-3.5" /> tCO₂e sets the statutory F-Gas leak-check interval.
        </span>
      </p>
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

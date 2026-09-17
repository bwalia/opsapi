'use client';

/**
 * Asset — /dashboard/field-service/assets/[uuid]
 *
 * One machine: its identity, F-Gas position, service levels and survey history,
 * with a form to record a new condition survey and a one-click asset history
 * PDF (the "detailed asset history report" from DBS's Simpro pack).
 */

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import { useParams } from 'next/navigation';
import toast from 'react-hot-toast';
import { ArrowLeft, ClipboardCheck, FileDown, HardDrive } from 'lucide-react';
import { Button, Input, Textarea } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { usePermissions } from '@/contexts/PermissionsContext';
import { FieldServiceNav, SectionCard, apiError } from '@/components/field-service/shared';
import { ConditionPill, SimproBadge, TestResultPill, CONDITION_OPTIONS } from '@/components/field-service/simpro';
import { useNamespaceStore } from '@/store/namespace.store';
import { companyFromNamespace, downloadReportPdf } from '@/lib/report-pdf';
import { formatFsDate, formatFsDateTime, parseFsDate } from '@/services/field-service.service';
import { simproCrm, type Asset } from '@/services/simpro-crm.service';

/** Full-width labelled select for the survey form (FilterSelect sizes to its content). */
function FormSelect({
  label,
  value,
  onChange,
  options,
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  options: { value: string; label: string }[];
}) {
  return (
    <label className="block text-xs font-medium text-secondary-600">
      {label}
      <select
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className="mt-1 block w-full px-3 py-2.5 border border-secondary-300 rounded-lg text-sm text-secondary-900 bg-surface focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
      >
        {options.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
    </label>
  );
}

function Field({ label, value }: { label: string; value?: React.ReactNode }) {
  return (
    <div>
      <dt className="text-xs font-medium text-secondary-500">{label}</dt>
      <dd className="mt-0.5 text-sm text-secondary-900">{value ?? '—'}</dd>
    </div>
  );
}

function AssetPageContent() {
  const { uuid } = useParams<{ uuid: string }>();
  const { canUpdate } = usePermissions();
  const current = useNamespaceStore((s) => s.currentNamespace);
  const namespaces = useNamespaceStore((s) => s.namespaces);
  const company = useMemo(
    () => companyFromNamespace(namespaces.find((n) => n.uuid === current?.uuid) || current),
    [current, namespaces]
  );

  const [asset, setAsset] = useState<Asset | null>(null);
  const [loading, setLoading] = useState(true);
  const [printing, setPrinting] = useState(false);
  const [saving, setSaving] = useState(false);
  const [condition, setCondition] = useState('2');
  const [result, setResult] = useState('pass');
  const [levelUuid, setLevelUuid] = useState('');
  const [added, setAdded] = useState('');
  const [leak, setLeak] = useState('');
  const [notes, setNotes] = useState('');

  const load = useCallback(async () => {
    try {
      const a = await simproCrm.getAsset(uuid);
      setAsset(a);
      if (a.condition_rating) setCondition(String(a.condition_rating));
      if (a.service_levels?.[0]) setLevelUuid((u) => u || a.service_levels![0].uuid);
    } catch (err) {
      toast.error(apiError(err, 'Failed to load asset'));
    } finally {
      setLoading(false);
    }
  }, [uuid]);

  useEffect(() => {
    load();
  }, [load]);

  const printHistory = async () => {
    setPrinting(true);
    try {
      const report = await simproCrm.runReport('asset_history', { asset_uuid: uuid });
      downloadReportPdf(report, company);
    } catch (err) {
      toast.error(apiError(err, 'Could not build the asset history'));
    } finally {
      setPrinting(false);
    }
  };

  const recordSurvey = async () => {
    setSaving(true);
    try {
      await simproCrm.recordTest(uuid, {
        condition_rating: Number(condition),
        result,
        service_level_uuid: levelUuid || undefined,
        refrigerant_added_kg: added ? Number(added) : undefined,
        leak_check_result: leak || undefined,
        notes: notes || undefined,
        readings: [{ key: 'condition', label: 'Condition rating (1 excellent – 6 replace)', value: Number(condition) }],
      });
      toast.success('Survey recorded');
      setNotes('');
      setAdded('');
      setLeak('');
      await load();
    } catch (err) {
      toast.error(apiError(err, 'Could not record the survey'));
    } finally {
      setSaving(false);
    }
  };

  if (loading) return <p className="text-sm text-secondary-500">Loading…</p>;
  if (!asset) return <p className="text-sm text-secondary-500">Asset not found.</p>;

  const today = new Date(new Date().toDateString());

  return (
    <div className="space-y-6">
      <PageHeader
        title={`${asset.asset_tag ? `${asset.asset_tag} · ` : ''}${asset.name}`}
        description={[asset.customer_name, asset.site_name].filter(Boolean).join(' — ')}
        icon={<HardDrive className="w-5 h-5" />}
        actions={
          <div className="flex gap-2">
            <Link href="/dashboard/field-service/assets">
              <Button variant="ghost">
                <ArrowLeft className="w-4 h-4 mr-1.5" /> Assets
              </Button>
            </Link>
            <Button variant="outline" onClick={printHistory} isLoading={printing}>
              <FileDown className="w-4 h-4 mr-1.5" /> Asset history PDF
            </Button>
          </div>
        }
      />
      <FieldServiceNav />

      <div className="grid gap-6 xl:grid-cols-3">
        <SectionCard title="Asset" className="xl:col-span-2" actions={<SimproBadge state={asset.simpro_sync_state} simproId={asset.simpro_id} />}>
          <dl className="grid gap-4 grid-cols-2 md:grid-cols-3">
            <Field label="Type" value={asset.asset_type} />
            <Field label="Condition" value={<ConditionPill rating={asset.condition_rating} />} />
            <Field label="Last surveyed" value={formatFsDate(asset.last_surveyed_at)} />
            <Field label="Manufacturer" value={asset.manufacturer} />
            <Field label="Model" value={asset.model} />
            <Field label="Serial" value={asset.serial_number && <span className="font-mono">{asset.serial_number}</span>} />
            <Field label="Location" value={asset.location_detail} />
            <Field label="Installed" value={formatFsDate(asset.installed_at)} />
            <Field label="Contract" value={asset.contract_name} />
          </dl>
          {asset.condition_notes && (
            <p className="mt-4 rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-800">{asset.condition_notes}</p>
          )}
        </SectionCard>

        <SectionCard title="F-Gas">
          {asset.refrigerant_type ? (
            <dl className="grid gap-4 grid-cols-2">
              <Field label="Refrigerant" value={asset.refrigerant_type} />
              <Field label="Charge" value={`${asset.refrigerant_charge_kg} kg`} />
              <Field label="GWP" value={asset.refrigerant_gwp} />
              <Field label="CO₂ equivalent" value={asset.co2e_tonnes != null ? `${asset.co2e_tonnes} t` : undefined} />
              <Field label="Leak check every" value={asset.leak_check_months ? `${asset.leak_check_months} months` : 'Not required'} />
              <Field label="Next leak check" value={formatFsDate(asset.next_leak_check_at)} />
            </dl>
          ) : (
            <p className="text-sm text-secondary-500">No fluorinated refrigerant recorded on this asset.</p>
          )}
        </SectionCard>
      </div>

      <div className="grid gap-6 xl:grid-cols-3">
        <SectionCard title="Service levels" className="xl:col-span-2">
          <table className="min-w-full text-sm">
            <thead>
              <tr className="text-left text-secondary-500">
                <th className="py-1.5 font-medium">Schedule</th>
                <th className="py-1.5 font-medium">Every</th>
                <th className="py-1.5 font-medium">Last done</th>
                <th className="py-1.5 font-medium">Next due</th>
                <th className="py-1.5 font-medium">Contract</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-secondary-100">
              {(asset.service_levels || []).map((l) => {
                const due = parseFsDate(l.next_service_date);
                return (
                  <tr key={l.uuid}>
                    <td className="py-2 text-secondary-900">{l.name}</td>
                    <td className="py-2">{l.frequency_months} months</td>
                    <td className="py-2">{formatFsDate(l.last_service_date)}</td>
                    <td className={`py-2 ${due && due < today ? 'text-red-600 font-medium' : ''}`}>{formatFsDate(l.next_service_date)}</td>
                    <td className="py-2 text-secondary-600">{l.contract_name || '—'}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </SectionCard>

        {canUpdate('fs_assets') && (
          <SectionCard title="Record a survey">
            <div className="space-y-3">
              <div className="grid grid-cols-2 gap-3">
                <FormSelect label="Condition" value={condition} onChange={setCondition} options={CONDITION_OPTIONS} />
                <FormSelect
                  label="Result"
                  value={result}
                  onChange={setResult}
                  options={[
                    { value: 'pass', label: 'Pass' },
                    { value: 'advisory', label: 'Advisory' },
                    { value: 'fail', label: 'Fail' },
                  ]}
                />
              </div>
              {!!asset.service_levels?.length && (
                <FormSelect
                  label="Against schedule"
                  value={levelUuid}
                  onChange={setLevelUuid}
                  options={asset.service_levels.map((l) => ({ value: l.uuid, label: l.name }))}
                />
              )}
              {asset.refrigerant_type && (
                <div className="grid grid-cols-2 gap-3">
                  <Input label="Refrigerant added (kg)" type="number" step="0.01" value={added} onChange={(e) => setAdded(e.target.value)} />
                  <FormSelect
                    label="Leak check"
                    value={leak}
                    onChange={setLeak}
                    options={[
                      { value: '', label: 'Not done' },
                      { value: 'pass', label: 'Pass' },
                      { value: 'fail', label: 'Fail' },
                    ]}
                  />
                </div>
              )}
              <Textarea label="Notes" rows={3} value={notes} onChange={(e) => setNotes(e.target.value)} />
              <Button onClick={recordSurvey} isLoading={saving} className="w-full">
                <ClipboardCheck className="w-4 h-4 mr-1.5" /> Save survey
              </Button>
            </div>
          </SectionCard>
        )}
      </div>

      <SectionCard title="Survey history">
        <div className="overflow-x-auto">
          <table className="min-w-full text-sm">
            <thead>
              <tr className="text-left text-secondary-500">
                <th className="py-1.5 pr-4 font-medium">Date</th>
                <th className="py-1.5 pr-4 font-medium">Schedule</th>
                <th className="py-1.5 pr-4 font-medium">Engineer</th>
                <th className="py-1.5 pr-4 font-medium">Result</th>
                <th className="py-1.5 pr-4 font-medium">Condition</th>
                <th className="py-1.5 pr-4 font-medium">Readings</th>
                <th className="py-1.5 font-medium">Notes</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-secondary-100 align-top">
              {(asset.recent_tests || []).map((t) => (
                <tr key={t.uuid}>
                  <td className="py-2 pr-4 whitespace-nowrap">{formatFsDateTime(t.tested_at, { dateStyle: 'medium' })}</td>
                  <td className="py-2 pr-4 text-secondary-600">{t.service_level || '—'}</td>
                  <td className="py-2 pr-4">{t.technician_name || '—'}</td>
                  <td className="py-2 pr-4"><TestResultPill result={t.result} /></td>
                  <td className="py-2 pr-4"><ConditionPill rating={t.condition_rating} /></td>
                  <td className="py-2 pr-4 text-xs text-secondary-600">
                    {t.readings
                      .filter((r) => r.key !== 'condition' && r.value !== null && r.value !== undefined)
                      .map((r) => `${r.label}: ${String(r.value)}${r.unit ? ` ${r.unit}` : ''}`)
                      .join(' · ') || '—'}
                    {!!t.failure_points.length && (
                      <span className="block text-red-600">Failure: {t.failure_points.map((f) => f.label).join(', ')}</span>
                    )}
                  </td>
                  <td className="py-2 text-secondary-700">{t.notes || '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </SectionCard>
    </div>
  );
}

export default function FieldServiceAssetPage() {
  return (
    <ProtectedPage module="fs_assets" title="Asset">
      <AssetPageContent />
    </ProtectedPage>
  );
}

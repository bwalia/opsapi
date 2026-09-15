'use client';

/**
 * Job Sheet — /dashboard/field-service/jobs/[uuid]/job-sheet
 *
 * A print-optimised job card (the engineer's paper worksheet). There's no
 * server-side PDF (no wkhtmltopdf), so this renders a clean A4 layout and the
 * browser's "Save as PDF" does the rest. `@media print` isolates #job-sheet so
 * the dashboard chrome never prints.
 */

import React, { useCallback, useEffect, useState } from 'react';
import { useParams } from 'next/navigation';
import Link from 'next/link';
import { ArrowLeft, Printer, Loader2 } from 'lucide-react';
import { Button } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { fieldService, formatFsDate, formatFsDateTime, type FsJobDetail } from '@/services/field-service.service';
import {
  JOB_STATUS_LABELS,
  JOB_PRIORITY_LABELS,
  PHASE_STATUS_LABELS,
  VISIT_STATUS_LABELS,
  siteAddressFromJob,
  money,
  hours,
} from '@/components/field-service/shared';
import { LABOUR_LABEL } from '@/components/field-service/QuoteLineModal';

function Row({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="js-row">
      <span className="js-label">{label}</span>
      <span className="js-value">{value || '—'}</span>
    </div>
  );
}

function JobSheetContent() {
  const { uuid } = useParams<{ uuid: string }>();
  const [job, setJob] = useState<FsJobDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [failed, setFailed] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setJob(await fieldService.getJob(uuid));
    } catch {
      setFailed(true);
    } finally {
      setLoading(false);
    }
  }, [uuid]);

  useEffect(() => {
    load();
  }, [load]);

  if (loading) {
    return (
      <div className="flex items-center justify-center py-24 text-secondary-500">
        <Loader2 className="w-5 h-5 animate-spin mr-2" /> Loading job sheet…
      </div>
    );
  }
  if (failed || !job) {
    return (
      <div className="space-y-4">
        <Link href="/dashboard/field-service" className="inline-flex items-center gap-1 text-sm text-secondary-500 hover:text-secondary-800">
          <ArrowLeft className="w-4 h-4" /> Back
        </Link>
        <p className="text-secondary-600">Job not found.</p>
      </div>
    );
  }

  const address = siteAddressFromJob(job);
  const labourLines = job.items.filter((i) => i.item_type === 'labour');
  const materialLines = job.items.filter((i) => i.item_type === 'part' || i.item_type === 'material');
  const hireLines = job.items.filter((i) => i.item_type === 'hire');
  const fgasVisits = job.visits.filter(
    (v) => v.refrigerant_type || v.refrigerant_added_kg || v.refrigerant_recovered_kg || v.leak_check_result || v.fgas_cylinder_ref
  );

  return (
    <div className="js-wrap">
      <style jsx global>{`
        .js-wrap { max-width: 820px; margin: 0 auto; }
        #job-sheet {
          background: #fff;
          color: #111;
          padding: 32px;
          border: 1px solid #e5e7eb;
          border-radius: 12px;
          font-size: 13px;
          line-height: 1.5;
        }
        #job-sheet h1 { font-size: 20px; font-weight: 700; margin: 0; }
        #job-sheet h2 {
          font-size: 12px; font-weight: 700; text-transform: uppercase;
          letter-spacing: .05em; color: #6b7280; margin: 20px 0 8px;
          border-bottom: 1px solid #e5e7eb; padding-bottom: 4px;
        }
        #job-sheet .js-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 4px 32px; }
        #job-sheet .js-row { display: flex; gap: 8px; padding: 3px 0; }
        #job-sheet .js-label { color: #6b7280; min-width: 120px; }
        #job-sheet .js-value { color: #111; font-weight: 500; }
        #job-sheet table { width: 100%; border-collapse: collapse; margin-top: 4px; }
        #job-sheet th, #job-sheet td { text-align: left; padding: 6px 8px; border-bottom: 1px solid #eee; }
        #job-sheet th { font-size: 11px; text-transform: uppercase; color: #6b7280; }
        #job-sheet td.num, #job-sheet th.num { text-align: right; }
        #job-sheet .js-check { display: flex; gap: 8px; padding: 2px 0; }
        #job-sheet .js-box { width: 14px; height: 14px; border: 1.5px solid #6b7280; border-radius: 3px; display: inline-block; flex: none; }
        #job-sheet .js-box.on { background: #111; border-color: #111; }
        #job-sheet .js-sign { margin-top: 8px; border-top: 1px dashed #9ca3af; padding-top: 24px; }
        @media print {
          body * { visibility: hidden !important; }
          #job-sheet, #job-sheet * { visibility: visible !important; }
          #job-sheet { position: absolute; left: 0; top: 0; width: 100%; border: none; border-radius: 0; padding: 0; }
          .no-print { display: none !important; }
          @page { margin: 16mm; }
        }
      `}</style>

      <div className="no-print mb-4 flex items-center justify-between">
        <Link href={`/dashboard/field-service/jobs/${job.uuid}`} className="inline-flex items-center gap-1 text-sm text-secondary-500 hover:text-secondary-800">
          <ArrowLeft className="w-4 h-4" /> Back to job
        </Link>
        <Button leftIcon={<Printer className="w-4 h-4" />} onClick={() => window.print()}>
          Print / Save as PDF
        </Button>
      </div>

      <div id="job-sheet">
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
          <div>
            <h1>Job Sheet</h1>
            <div style={{ color: '#6b7280', marginTop: 2 }}>{job.job_number}</div>
          </div>
          <div style={{ textAlign: 'right' }}>
            <div style={{ fontWeight: 600 }}>{job.title}</div>
            <div style={{ color: '#6b7280' }}>
              {JOB_STATUS_LABELS[job.status]} · {JOB_PRIORITY_LABELS[job.priority]} priority
            </div>
          </div>
        </div>

        <h2>Customer &amp; Site</h2>
        <div className="js-grid">
          <Row label="Customer" value={job.customer_name} />
          <Row label="Site" value={job.site_name} />
          <Row label="Reference / PO" value={job.customer_reference} />
          <Row label="Phone" value={job.customer_phone} />
          <Row label="Email" value={job.customer_email} />
          <Row label="Service address" value={address} />
          <Row label="Due date" value={job.due_date ? formatFsDate(job.due_date) : null} />
        </div>

        <h2>Equipment</h2>
        <div className="js-grid">
          <Row label="Product" value={job.product_name} />
          <Row label="SKU" value={job.product_sku} />
          <Row label="Unit serial / ref" value={job.product_ref} />
          <Row label="Job type" value={job.job_type_name} />
        </div>

        <h2>Reported fault / work</h2>
        <div style={{ whiteSpace: 'pre-wrap', minHeight: 40 }}>{job.description || '—'}</div>

        <h2>Phases &amp; checklist</h2>
        {job.phases.length === 0 ? (
          <div style={{ color: '#6b7280' }}>No phases.</div>
        ) : (
          job.phases.map((p) => (
            <div key={p.uuid} style={{ marginBottom: 8 }}>
              <div style={{ fontWeight: 600 }}>
                {p.name} <span style={{ color: '#6b7280', fontWeight: 400 }}>· {PHASE_STATUS_LABELS[p.status]}</span>
              </div>
              {p.checklist?.map((c, i) => (
                <div key={i} className="js-check">
                  <span className={`js-box ${c.done ? 'on' : ''}`} />
                  <span>{c.label}</span>
                </div>
              ))}
            </div>
          ))
        )}

        <h2>Visits</h2>
        {job.visits.length === 0 ? (
          <div style={{ color: '#6b7280' }}>No visits booked.</div>
        ) : (
          <table>
            <thead>
              <tr>
                <th>Date</th>
                <th>Engineer</th>
                <th>Status</th>
                <th className="num">Hours</th>
                <th>Work done</th>
              </tr>
            </thead>
            <tbody>
              {job.visits.map((v) => (
                <tr key={v.uuid}>
                  <td>{formatFsDateTime(v.scheduled_start)}</td>
                  <td>{v.engineer_name || '—'}</td>
                  <td>{VISIT_STATUS_LABELS[v.status]}</td>
                  <td className="num">{v.labour_hours != null ? hours(v.labour_hours) : '—'}</td>
                  <td>{v.work_summary || '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}

        {fgasVisits.length > 0 && (
          <>
            <h2>F-Gas / refrigerant log</h2>
            <table>
              <thead>
                <tr>
                  <th>Date</th>
                  <th>Gas</th>
                  <th className="num">Charged (kg)</th>
                  <th className="num">Recovered (kg)</th>
                  <th>Leak check</th>
                  <th>Cylinder</th>
                </tr>
              </thead>
              <tbody>
                {fgasVisits.map((v) => (
                  <tr key={v.uuid}>
                    <td>{formatFsDate(v.scheduled_start)}</td>
                    <td>{v.refrigerant_type || '—'}</td>
                    <td className="num">{v.refrigerant_added_kg ?? '—'}</td>
                    <td className="num">{v.refrigerant_recovered_kg ?? '—'}</td>
                    <td>{v.leak_check_result || '—'}</td>
                    <td>{v.fgas_cylinder_ref || '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </>
        )}

        <h2>Labour</h2>
        {labourLines.length === 0 ? (
          <div style={{ color: '#6b7280' }}>None recorded.</div>
        ) : (
          <table>
            <thead>
              <tr>
                <th>Labour type</th>
                <th className="num">Hours</th>
                <th className="num">Days</th>
              </tr>
            </thead>
            <tbody>
              {labourLines.map((it) => (
                <tr key={it.uuid}>
                  <td>{LABOUR_LABEL[it.labour_category || ''] || it.description}</td>
                  <td className="num">{it.quantity}</td>
                  <td className="num">{it.days ?? '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}

        <h2>Materials</h2>
        {materialLines.length === 0 ? (
          <div style={{ color: '#6b7280' }}>None recorded.</div>
        ) : (
          <table>
            <thead>
              <tr>
                <th>Part type</th>
                <th>Part number</th>
                <th>Supplier</th>
                <th className="num">Qty</th>
                <th className="num">Price per</th>
              </tr>
            </thead>
            <tbody>
              {materialLines.map((it) => (
                <tr key={it.uuid}>
                  <td>{it.description}</td>
                  <td>{it.part_number || '—'}</td>
                  <td>{it.supplier || '—'}</td>
                  <td className="num">{it.quantity}</td>
                  <td className="num">{it.unit_price ? money(it.unit_price, job.currency) : '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}

        {hireLines.length > 0 && (
          <>
            <h2>Specialist tool / access equipment hire</h2>
            <table>
              <thead>
                <tr>
                  <th>Supplier</th>
                  <th>Description</th>
                  <th>Part number</th>
                  <th className="num">Days</th>
                </tr>
              </thead>
              <tbody>
                {hireLines.map((it) => (
                  <tr key={it.uuid}>
                    <td>{it.supplier || '—'}</td>
                    <td>{it.description}</td>
                    <td>{it.part_number || '—'}</td>
                    <td className="num">{it.days ?? '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </>
        )}

        {job.visits.some((v) => v.work_summary || v.follow_up_notes) && (
          <>
            <h2>Engineer notes</h2>
            <div style={{ display: 'grid', gap: 4 }}>
              {job.visits
                .filter((v) => v.work_summary || v.follow_up_notes)
                .map((v) => (
                  <div key={v.uuid}>
                    <strong>{formatFsDate(v.scheduled_start)}:</strong> {v.work_summary || ''}
                    {v.follow_up_notes ? ` — Follow-up: ${v.follow_up_notes}` : ''}
                  </div>
                ))}
            </div>
          </>
        )}

        <h2>Totals</h2>
        <div className="js-grid">
          <Row label="Labour hours" value={hours(job.totals.labour_hours)} />
          <Row label="Billable hours" value={hours(job.totals.billable_hours)} />
          <Row label="Labour value" value={money(job.totals.labour_value, job.currency)} />
          <Row label="Materials value" value={money(job.totals.items_value, job.currency)} />
        </div>

        <div className="js-sign">
          <div className="js-grid" style={{ gridTemplateColumns: '1fr 1fr', gap: 40 }}>
            <div>Engineer signature / date</div>
            <div>Customer signature / date</div>
          </div>
        </div>
      </div>
    </div>
  );
}

export default function JobSheetPage() {
  return (
    <ProtectedPage module="fs_jobs" title="Job Sheet">
      <JobSheetContent />
    </ProtectedPage>
  );
}

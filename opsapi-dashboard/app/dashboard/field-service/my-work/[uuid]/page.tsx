'use client';

/**
 * Guided visit ("work mode") — /dashboard/field-service/my-work/[uuid]
 *
 * The engineer's on-site screen. One big primary action that changes with the
 * visit's state: On my way → I've arrived → (do the work) → Finish. Manager
 * concepts (prices, approval, invoicing, phase jargon, status transitions) are
 * hidden; the engineer sees what to fix and logs what they did.
 */

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { useParams, useRouter } from 'next/navigation';
import toast from 'react-hot-toast';
import {
  ArrowLeft, Phone, Navigation, Car, LogIn, CheckCircle2, Package, Snowflake,
  Loader2, ClipboardList, Wrench, KeyRound,
} from 'lucide-react';
import { Button, Input, Textarea } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { fieldService, type FsVisitDetail } from '@/services/field-service.service';
import { siteAddressFromJob, mapsUrl, apiError } from '@/components/field-service/shared';
import { FGasCard } from '@/components/field-service/FGasCard';
import { PhaseChecklist } from '@/components/field-service/PhasesPanel';
import { ItemFormModal } from '@/components/field-service/ItemsPanel';
import { getPosition } from '@/components/field-service/CheckOutModal';

/** Hours between check-in and now, rounded to 2dp (for the finish default). */
function hoursSince(iso?: string | null): string {
  if (!iso) return '';
  const start = new Date(iso.includes('T') ? iso : iso.replace(' ', 'T') + 'Z').getTime();
  if (Number.isNaN(start)) return '';
  const h = (Date.now() - start) / 3_600_000;
  return h > 0 && h < 24 ? String(Math.round(h * 100) / 100) : '';
}

/** Big tap tile for an optional on-site action. */
function ActionTile({ icon, label, hint, onClick }: { icon: React.ReactNode; label: string; hint?: string; onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="flex-1 rounded-2xl border border-secondary-200 bg-surface p-4 text-left active:scale-[0.98] transition"
      style={{ minHeight: 76 }}
    >
      <div className="flex items-center gap-2 text-secondary-900 font-semibold">{icon}{label}</div>
      {hint && <p className="text-xs text-secondary-500 mt-1">{hint}</p>}
    </button>
  );
}

function FinishSheet({ visit, onClose, onDone }: { visit: FsVisitDetail; onClose: () => void; onDone: () => void }) {
  const [summary, setSummary] = useState(visit.work_summary || '');
  const [labour, setLabour] = useState(() => hoursSince(visit.checked_in_at) || (visit.labour_hours != null ? String(visit.labour_hours) : ''));
  const [signoff, setSignoff] = useState(visit.customer_signoff_name || '');
  const [saving, setSaving] = useState(false);
  const needsHours = !visit.checked_in_at;

  const complete = async () => {
    if (needsHours && !labour.trim()) {
      toast.error('Enter how many hours you were on site');
      return;
    }
    setSaving(true);
    try {
      await fieldService.checkOut(visit.uuid, {
        work_summary: summary.trim() || undefined,
        labour_hours: labour.trim() === '' ? undefined : Number(labour),
        customer_signoff_name: signoff.trim() || undefined,
      });
      toast.success('Job complete');
      onDone();
    } catch (err) {
      toast.error(apiError(err, 'Could not finish the job'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex flex-col justify-end bg-black/40" onClick={onClose}>
      <div
        className="bg-surface rounded-t-3xl p-5 space-y-4 max-h-[90dvh] overflow-y-auto"
        style={{ paddingBottom: 'max(20px, env(safe-area-inset-bottom))' }}
        onClick={(e) => e.stopPropagation()}
      >
        <div className="mx-auto h-1.5 w-10 rounded-full bg-secondary-200" />
        <h2 className="text-xl font-bold text-secondary-900">Finish job</h2>
        <Textarea label="What did you do?" rows={3} value={summary} onChange={(e) => setSummary(e.target.value)} placeholder="e.g. Recharged system, replaced capacitor, tested — cooling OK" />
        <Input label={needsHours ? 'Hours on site *' : 'Hours on site'} inputMode="decimal" value={labour} onChange={(e) => setLabour(e.target.value)} placeholder="e.g. 1.5" />
        <Input label="Customer name (sign-off)" value={signoff} onChange={(e) => setSignoff(e.target.value)} placeholder="Who signed off the work" />
        <div className="flex gap-3 pt-1">
          <Button variant="ghost" onClick={onClose} disabled={saving} className="flex-1">Not yet</Button>
          <Button onClick={complete} isLoading={saving} className="flex-1" leftIcon={<CheckCircle2 className="w-5 h-5" />}>Complete job</Button>
        </div>
      </div>
    </div>
  );
}

function GuidedVisitContent() {
  const { uuid } = useParams<{ uuid: string }>();
  const router = useRouter();
  const [visit, setVisit] = useState<FsVisitDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [notFound, setNotFound] = useState(false);
  const [busy, setBusy] = useState(false);
  const [showFinish, setShowFinish] = useState(false);
  const [showPart, setShowPart] = useState(false);

  const load = useCallback(async () => {
    try {
      setVisit(await fieldService.getVisit(uuid));
      setNotFound(false);
    } catch {
      setNotFound(true);
    } finally {
      setLoading(false);
    }
  }, [uuid]);

  useEffect(() => {
    load();
  }, [load]);

  const address = useMemo(() => (visit ? siteAddressFromJob(visit) : ''), [visit]);
  const maps = useMemo(() => mapsUrl(address), [address]);

  const run = async (fn: () => Promise<FsVisitDetail>, ok: string) => {
    setBusy(true);
    try {
      setVisit(await fn());
      toast.success(ok);
    } catch (err) {
      toast.error(apiError(err, 'Something went wrong'));
    } finally {
      setBusy(false);
    }
  };

  const arrive = async () => {
    setBusy(true);
    try {
      const coords = await getPosition();
      setVisit(await fieldService.checkIn(uuid, coords));
      toast.success("Checked in — you're on site");
    } catch (err) {
      toast.error(apiError(err, 'Could not check in'));
    } finally {
      setBusy(false);
    }
  };

  if (loading) {
    return (
      <div className="flex items-center justify-center py-24 text-secondary-500">
        <Loader2 className="w-6 h-6 animate-spin mr-2" /> Loading job…
      </div>
    );
  }
  if (notFound || !visit) {
    return (
      <div className="mx-auto max-w-xl px-4 py-16 text-center">
        <p className="text-lg font-semibold text-secondary-900">Job not found</p>
        <Button variant="ghost" className="mt-3" onClick={() => router.push('/dashboard/field-service/my-work')}>Back to My Work</Button>
      </div>
    );
  }

  const s = visit.status;
  const onSite = s === 'on_site';
  const done = s === 'completed';
  const parts = visit.items.filter((i) => i.item_type === 'part' || i.item_type === 'material');

  return (
    <div className="mx-auto max-w-xl min-h-dvh px-4 pb-40" style={{ paddingBlock: 16 }}>
      <button
        type="button"
        onClick={() => router.push('/dashboard/field-service/my-work')}
        className="inline-flex items-center gap-1 text-sm text-secondary-500 mb-4"
      >
        <ArrowLeft className="w-4 h-4" /> My Work
      </button>

      {/* Where + who */}
      <h1 className="text-2xl font-bold text-secondary-900 leading-tight">{visit.job_title || 'Service visit'}</h1>
      <p className="text-secondary-600 mt-0.5">{visit.customer_name || 'No customer'}</p>

      <div className="mt-4 flex gap-3">
        {(maps || visit.site_name) && (
          <a href={maps || '#'} target="_blank" rel="noopener noreferrer" className="flex-1 rounded-2xl border border-secondary-200 bg-surface p-3 flex items-center gap-2 text-secondary-800 font-medium active:scale-[0.98] transition" style={{ minHeight: 60 }}>
            <Navigation className="w-5 h-5 text-primary-600 shrink-0" />
            <span className="min-w-0">
              <span className="block text-xs text-secondary-500">{visit.site_name ? 'Site · tap for directions' : 'Directions'}</span>
              <span className="block truncate">{visit.site_name || address}</span>
              {visit.site_name && address && <span className="block text-xs text-secondary-500 truncate">{address}</span>}
            </span>
          </a>
        )}
        {visit.customer_phone && (
          <a href={`tel:${visit.customer_phone}`} className="rounded-2xl border border-secondary-200 bg-surface p-3 flex items-center justify-center text-primary-600 active:scale-[0.98] transition" style={{ minWidth: 60, minHeight: 60 }} aria-label="Call customer">
            <Phone className="w-5 h-5" />
          </a>
        )}
      </div>

      {visit.site_access_notes && (
        <div className="mt-3 rounded-2xl bg-amber-50 border border-amber-200 p-3 text-sm text-amber-800 flex items-start gap-2">
          <KeyRound className="w-4 h-4 mt-0.5 shrink-0" /> <span>{visit.site_access_notes}</span>
        </div>
      )}

      {/* What to fix */}
      <div className="mt-5 rounded-2xl border border-secondary-200 bg-surface p-4">
        <h2 className="text-xs font-bold uppercase tracking-wide text-secondary-400 mb-2 flex items-center gap-1"><ClipboardList className="w-4 h-4" /> What to fix</h2>
        <div className="space-y-1.5 text-sm">
          {visit.product_name && <p><span className="text-secondary-500">Unit: </span><span className="font-medium text-secondary-900">{visit.product_name}</span>{visit.product_ref ? ` · ${visit.product_ref}` : ''}</p>}
          {visit.phase_name && <p><span className="text-secondary-500">Task: </span><span className="font-medium text-secondary-900">{visit.phase_name}</span></p>}
          {visit.instructions ? (
            <p className="text-secondary-800 whitespace-pre-line pt-1">{visit.instructions}</p>
          ) : (
            !visit.product_name && !visit.phase_name && <p className="text-secondary-500">See the customer for details.</p>
          )}
        </div>
      </div>

      {/* Checklist (only meaningful once on site) */}
      {visit.phase && visit.phase.checklist && visit.phase.checklist.length > 0 && (
        <div className="mt-4 rounded-2xl border border-secondary-200 bg-surface p-4">
          <h2 className="text-xs font-bold uppercase tracking-wide text-secondary-400 mb-2">Checklist</h2>
          <PhaseChecklist phase={visit.phase} disabled={!onSite} onChanged={load} />
        </div>
      )}

      {/* On-site tools */}
      {onSite && (
        <>
          <div className="mt-4 flex gap-3">
            <ActionTile icon={<Package className="w-5 h-5 text-primary-600" />} label="Add part" hint={parts.length ? `${parts.length} logged` : 'Parts you fitted'} onClick={() => setShowPart(true)} />
            <ActionTile icon={<Snowflake className="w-5 h-5 text-primary-600" />} label="Refrigerant" hint="F-Gas log" onClick={() => { document.getElementById('fgas')?.scrollIntoView({ behavior: 'smooth' }); }} />
          </div>

          {parts.length > 0 && (
            <ul className="mt-3 space-y-1.5">
              {parts.map((p) => (
                <li key={p.uuid} className="flex items-center gap-2 text-sm text-secondary-700">
                  <Wrench className="w-4 h-4 text-secondary-400" /> {p.quantity}× {p.description}
                </li>
              ))}
            </ul>
          )}

          <div id="fgas" className="mt-4">
            <FGasCard visit={visit} canWork onSaved={load} />
          </div>
        </>
      )}

      {done && (
        <div className="mt-6 rounded-2xl border border-emerald-200 bg-emerald-50 p-5 text-center">
          <CheckCircle2 className="w-12 h-12 text-emerald-500 mx-auto mb-2" />
          <p className="text-lg font-semibold text-emerald-900">Job complete</p>
          {visit.work_summary && <p className="text-sm text-emerald-800 mt-1">{visit.work_summary}</p>}
          {visit.labour_hours != null && <p className="text-xs text-emerald-700 mt-1">{visit.labour_hours} h on site</p>}
        </div>
      )}

      {/* Sticky primary action */}
      <div className="fixed inset-x-0 bottom-0 border-t border-secondary-200 bg-surface/95 backdrop-blur px-4" style={{ paddingTop: 12, paddingBottom: 'max(12px, env(safe-area-inset-bottom))' }}>
        <div className="mx-auto max-w-xl">
          {s === 'scheduled' && (
            <div className="space-y-2">
              <Button className="w-full" size="lg" isLoading={busy} leftIcon={<Car className="w-5 h-5" />} onClick={() => run(() => fieldService.markEnRoute(uuid), "You're on the way")}>
                On my way
              </Button>
              <button type="button" disabled={busy} onClick={arrive} className="w-full text-sm text-secondary-500 py-1">I&apos;m already here — check in</button>
            </div>
          )}
          {s === 'en_route' && (
            <Button className="w-full" size="lg" isLoading={busy} leftIcon={<LogIn className="w-5 h-5" />} onClick={arrive}>
              I&apos;ve arrived
            </Button>
          )}
          {onSite && (
            <Button className="w-full" size="lg" isLoading={busy} leftIcon={<CheckCircle2 className="w-5 h-5" />} onClick={() => setShowFinish(true)}>
              Finish job
            </Button>
          )}
          {(done || s === 'cancelled' || s === 'no_access') && (
            <Button variant="secondary" className="w-full" size="lg" onClick={() => router.push('/dashboard/field-service/my-work')}>
              Back to My Work
            </Button>
          )}
        </div>
      </div>

      {showFinish && (
        <FinishSheet
          visit={visit}
          onClose={() => setShowFinish(false)}
          onDone={() => { setShowFinish(false); load(); }}
        />
      )}
      <ItemFormModal
        isOpen={showPart}
        jobUuid={visit.job_uuid}
        visitUuid={visit.uuid}
        onClose={() => setShowPart(false)}
        onSaved={() => { setShowPart(false); load(); }}
      />
    </div>
  );
}

export default function GuidedVisitPage() {
  return (
    <ProtectedPage module="fs_visits" title="Job">
      <GuidedVisitContent />
    </ProtectedPage>
  );
}

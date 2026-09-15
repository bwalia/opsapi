'use client';

/**
 * Guided visit ("work mode") — /dashboard/field-service/my-work/[uuid]
 *
 * The engineer's on-site screen. One primary action that changes with the
 * visit's state: On my way → I've arrived → (do the work) → Finish. Manager
 * concepts (prices, approval, invoicing, status transitions) are hidden.
 *
 * Responsive: a single focused column on a phone; on desktop it fills the width
 * with a two-column layout (details left, actions/logs right). The primary
 * action is a sticky bottom bar on mobile and a card in the side rail on
 * desktop — same button, one source of truth.
 */

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { useParams, useRouter } from 'next/navigation';
import toast from 'react-hot-toast';
import {
  ArrowLeft, Phone, Navigation, Car, LogIn, CheckCircle2, Package, Snowflake,
  Loader2, ClipboardList, KeyRound, HardHat, Truck,
} from 'lucide-react';
import { Button, Input, Textarea } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { fieldService, type FsVisitDetail } from '@/services/field-service.service';
import { siteAddressFromJob, mapsUrl, apiError } from '@/components/field-service/shared';
import { FGasCard } from '@/components/field-service/FGasCard';
import { PhaseChecklist } from '@/components/field-service/PhasesPanel';
import { QuoteLineModal, LABOUR_LABEL, type LineKind } from '@/components/field-service/QuoteLineModal';
import { getPosition } from '@/components/field-service/CheckOutModal';

/** Hours between check-in and now, rounded to 2dp (for the finish default). */
function hoursSince(iso?: string | null): string {
  if (!iso) return '';
  const start = new Date(iso.includes('T') ? iso : iso.replace(' ', 'T') + 'Z').getTime();
  if (Number.isNaN(start)) return '';
  const h = (Date.now() - start) / 3_600_000;
  return h > 0 && h < 24 ? String(Math.round(h * 100) / 100) : '';
}

function Card({ children, className = '' }: { children: React.ReactNode; className?: string }) {
  return <div className={`rounded-2xl border border-secondary-200 bg-surface p-4 ${className}`}>{children}</div>;
}

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
    <div className="fixed inset-0 z-50 flex flex-col justify-end sm:justify-center sm:items-center bg-black/40 p-0 sm:p-4" onClick={onClose}>
      <div
        className="bg-surface rounded-t-3xl sm:rounded-3xl p-5 space-y-4 w-full sm:max-w-md max-h-[90dvh] overflow-y-auto"
        style={{ paddingBottom: 'max(20px, env(safe-area-inset-bottom))' }}
        onClick={(e) => e.stopPropagation()}
      >
        <div className="sm:hidden mx-auto h-1.5 w-10 rounded-full bg-secondary-200" />
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
  const [line, setLine] = useState<LineKind | null>(null);

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
      <div className="px-4 py-16 text-center">
        <p className="text-lg font-semibold text-secondary-900">Job not found</p>
        <Button variant="ghost" className="mt-3" onClick={() => router.push('/dashboard/field-service/my-work')}>Back to My Work</Button>
      </div>
    );
  }

  const s = visit.status;
  const onSite = s === 'on_site';
  const done = s === 'completed';
  const labourLines = visit.items.filter((i) => i.item_type === 'labour');
  const materialLines = visit.items.filter((i) => i.item_type === 'part' || i.item_type === 'material');
  const hireLines = visit.items.filter((i) => i.item_type === 'hire');
  const loggedCount = labourLines.length + materialLines.length + hireLines.length;

  // One source of truth for the primary action; rendered in the mobile sticky
  // bar and the desktop side rail.
  const primaryAction =
    s === 'scheduled' ? (
      <div className="space-y-2 w-full">
        <Button className="w-full" size="lg" isLoading={busy} leftIcon={<Car className="w-5 h-5" />} onClick={() => run(() => fieldService.markEnRoute(uuid), "You're on the way")}>
          On my way
        </Button>
        <button type="button" disabled={busy} onClick={arrive} className="w-full text-sm text-secondary-500 py-1">I&apos;m already here — check in</button>
      </div>
    ) : s === 'en_route' ? (
      <Button className="w-full" size="lg" isLoading={busy} leftIcon={<LogIn className="w-5 h-5" />} onClick={arrive}>I&apos;ve arrived</Button>
    ) : onSite ? (
      <Button className="w-full" size="lg" isLoading={busy} leftIcon={<CheckCircle2 className="w-5 h-5" />} onClick={() => setShowFinish(true)}>Finish job</Button>
    ) : (
      <Button variant="secondary" className="w-full" size="lg" onClick={() => router.push('/dashboard/field-service/my-work')}>Back to My Work</Button>
    );

  return (
    <div className="min-h-dvh px-4 sm:px-6 lg:px-8 pb-40 lg:pb-10" style={{ paddingBlock: 16 }}>
      <button type="button" onClick={() => router.push('/dashboard/field-service/my-work')} className="inline-flex items-center gap-1 text-sm text-secondary-500 mb-3">
        <ArrowLeft className="w-4 h-4" /> My Work
      </button>

      <header className="mb-5">
        <h1 className="text-2xl font-bold text-secondary-900 leading-tight">{visit.job_title || 'Service visit'}</h1>
        <p className="text-secondary-600 mt-0.5">
          {visit.customer_name || 'No customer'}
          {visit.phase_name ? <span className="text-secondary-400"> · {visit.phase_name}</span> : null}
        </p>
      </header>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-4 lg:gap-6 items-start">
        {/* Main column */}
        <div className="lg:col-span-2 space-y-4">
          <div className="flex gap-3">
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
            <div className="rounded-2xl bg-amber-50 border border-amber-200 p-3 text-sm text-amber-800 flex items-start gap-2">
              <KeyRound className="w-4 h-4 mt-0.5 shrink-0" /> <span>{visit.site_access_notes}</span>
            </div>
          )}

          <Card>
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
          </Card>

          {visit.phase && visit.phase.checklist && visit.phase.checklist.length > 0 && (
            <Card>
              <h2 className="text-xs font-bold uppercase tracking-wide text-secondary-400 mb-2">Checklist</h2>
              <PhaseChecklist phase={visit.phase} disabled={!onSite} onChanged={load} />
            </Card>
          )}
        </div>

        {/* Side rail */}
        <div className="space-y-4">
          {/* Desktop primary action (mobile uses the sticky bar) */}
          <Card className="hidden lg:block">{primaryAction}</Card>

          {onSite && (
            <>
              <div className="grid grid-cols-2 gap-3">
                <ActionTile icon={<HardHat className="w-5 h-5 text-primary-600" />} label="Labour" hint="Engineer / mate time" onClick={() => setLine('labour')} />
                <ActionTile icon={<Package className="w-5 h-5 text-primary-600" />} label="Materials" hint="Parts fitted" onClick={() => setLine('material')} />
                <ActionTile icon={<Truck className="w-5 h-5 text-primary-600" />} label="Hire" hint="Tools / access" onClick={() => setLine('hire')} />
                <ActionTile icon={<Snowflake className="w-5 h-5 text-primary-600" />} label="Refrigerant" hint="F-Gas log" onClick={() => document.getElementById('fgas')?.scrollIntoView({ behavior: 'smooth' })} />
              </div>

              {loggedCount > 0 && (
                <Card>
                  <h2 className="text-xs font-bold uppercase tracking-wide text-secondary-400 mb-2">On this sheet</h2>
                  <ul className="space-y-1.5 text-sm text-secondary-700">
                    {labourLines.map((i) => (
                      <li key={i.uuid} className="flex items-center gap-2">
                        <HardHat className="w-4 h-4 text-secondary-400 shrink-0" />
                        {LABOUR_LABEL[i.labour_category || ''] || 'Labour'} · {i.quantity}h{i.days ? ` · ${i.days}d` : ''}
                      </li>
                    ))}
                    {materialLines.map((i) => (
                      <li key={i.uuid} className="flex items-center gap-2">
                        <Package className="w-4 h-4 text-secondary-400 shrink-0" />
                        {i.quantity}× {i.description}{i.supplier ? ` · ${i.supplier}` : ''}
                      </li>
                    ))}
                    {hireLines.map((i) => (
                      <li key={i.uuid} className="flex items-center gap-2">
                        <Truck className="w-4 h-4 text-secondary-400 shrink-0" />
                        {i.description}{i.days ? ` · ${i.days}d` : ''}{i.supplier ? ` · ${i.supplier}` : ''}
                      </li>
                    ))}
                  </ul>
                </Card>
              )}

              <div id="fgas">
                <FGasCard visit={visit} canWork onSaved={load} />
              </div>
            </>
          )}

          {done && (
            <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-5 text-center">
              <CheckCircle2 className="w-12 h-12 text-emerald-500 mx-auto mb-2" />
              <p className="text-lg font-semibold text-emerald-900">Job complete</p>
              {visit.work_summary && <p className="text-sm text-emerald-800 mt-1">{visit.work_summary}</p>}
              {visit.labour_hours != null && <p className="text-xs text-emerald-700 mt-1">{visit.labour_hours} h on site</p>}
            </div>
          )}
        </div>
      </div>

      {/* Mobile sticky primary action */}
      <div className="lg:hidden fixed inset-x-0 bottom-0 border-t border-secondary-200 bg-surface/95 backdrop-blur px-4" style={{ paddingTop: 12, paddingBottom: 'max(12px, env(safe-area-inset-bottom))' }}>
        <div className="mx-auto max-w-xl">{primaryAction}</div>
      </div>

      {showFinish && <FinishSheet visit={visit} onClose={() => setShowFinish(false)} onDone={() => { setShowFinish(false); load(); }} />}
      <QuoteLineModal
        isOpen={line !== null}
        kind={line || 'material'}
        jobUuid={visit.job_uuid}
        visitUuid={visit.uuid}
        onClose={() => setLine(null)}
        onSaved={() => { setLine(null); load(); }}
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

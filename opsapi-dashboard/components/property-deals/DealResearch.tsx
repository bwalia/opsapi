'use client';

/**
 * The deal autopilot on the deal page (GET /deals/{id}/research): the home pinned on the map, conveyancers from the
 * SRA register with the quote requests drafted for them (sent only once another person approves), and, with Google
 * Gemini, notes on the area and firms nearby from a Google search. Google's terms: those results are shown as they
 * came (never rewritten or reordered), with Google's Search Suggestions, and a firm from them reaches Suppliers or
 * gets a quote request only when a person clicks. Polls every 3 s while the AI is researching.
 */
import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import {
  AlertTriangle, CheckCircle2, ChevronDown, ChevronUp, Clock, Info, Loader2, MapPin, MinusCircle, RefreshCw, Sparkles, XCircle,
} from 'lucide-react';
import toast from 'react-hot-toast';
import { Badge, Button, Card, buttonClass } from '@/components/ui';
import { cn } from '@/lib/utils';
import {
  pdService, pdErrorText, type DealResearch as Research, type ResearchAreaKey, type ResearchFirm, type ResearchRun, type ResearchStep,
  type ResearchSupplier,
} from '@/services/property-deals.service';
import { BASE, ContactLinks, ErrorNote, ExtLink, Spinner, dateText, kindText, label } from './ui';
import { usePdData, usePdMe } from './usePd';

const STEP_NAME: Record<string, string> = {
  pin: 'Pin the home on the map',
  research: 'Google search: the area and firms nearby',
  register: 'Conveyancers from the SRA register',
  quotes: 'Quote requests',
};
const STEP_ICON: Record<ResearchStep['status'], { icon: typeof CheckCircle2; cls: string }> = {
  done: { icon: CheckCircle2, cls: 'text-success-600' },
  skipped: { icon: MinusCircle, cls: 'text-secondary-400' },
  waiting: { icon: Clock, cls: 'text-warning-500' },
  failed: { icon: XCircle, cls: 'text-error-600' },
};
const AREA: [ResearchAreaKey, string][] = [
  ['summary', 'The area'], ['transport', 'Transport'], ['schools', 'Schools'], ['amenities', 'Shops and amenities'],
  ['flood_risk', 'Flood risk'], ['planning', 'Planning nearby'], ['market', 'Prices and sales'],
];
const QUOTE_STATUS: Record<string, { text: string; variant: 'default' | 'success' | 'warning' | 'error' | 'info' | 'secondary' }> = {
  pending: { text: 'Waiting for approval', variant: 'warning' },
  approved: { text: 'Approved, sending', variant: 'info' },
  executed: { text: 'Sent', variant: 'success' },
  rejected: { text: 'Turned down', variant: 'secondary' },
  cancelled: { text: 'Cancelled', variant: 'secondary' },
  failed: { text: "Couldn't send", variant: 'error' },
};

export default function DealResearch({ dealId, dealType }: { dealId: string; dealType?: string }) {
  const { can } = usePdMe();
  const [open, setOpen] = useState(true);
  const [starting, setStarting] = useState(false);
  const r = usePdData(async () => (await pdService.research(dealId)).data, [dealId]);
  const { refresh } = r;
  const run = r.data?.run;
  const running = run?.status === 'running';
  useEffect(() => {
    if (!running) return;
    const t = setInterval(() => {
      if (document.visibilityState === 'visible') refresh();
    }, 3000);
    return () => clearInterval(t);
  }, [running, refresh]);

  async function start() {
    setStarting(true);
    try {
      await pdService.startResearch(dealId);
      toast.success('Researching this deal…');
    } catch (e) {
      toast.error(pdErrorText(e));
    } finally {
      setStarting(false);
      refresh();
    }
  }

  const lat = Number(r.data?.property?.lat ?? NaN);
  const lng = Number(r.data?.property?.lng ?? NaN);
  const onMap = Number.isFinite(lat) && Number.isFinite(lng);

  return (
    <Card data-tour="deal-research">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <h2 className="flex items-center gap-2 font-semibold text-secondary-900">
            <Sparkles className="h-4 w-4 text-primary-500" aria-hidden /> AI research
          </h2>
          <p className="mt-0.5 text-sm text-secondary-500" aria-live="polite">{r.data && <RunStatus run={run} />}</p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          {onMap && (
            <Link className={buttonClass('outline', 'sm')} href={`${BASE}/map?lat=${lat}&lng=${lng}&layers=deals,suppliers`}>
              <MapPin className="h-4 w-4" aria-hidden /> Show on map
            </Link>
          )}
          {can('ai', 'create') && r.data && (
            <Button size="sm" variant="outline" leftIcon={<RefreshCw className="h-4 w-4" />} isLoading={starting} disabled={running} onClick={start}>
              {run ? 'Research again' : 'Research now'}
            </Button>
          )}
          <Button size="sm" variant="ghost" aria-expanded={open} onClick={() => setOpen(!open)}
            rightIcon={open ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}>
            {open ? 'Hide' : 'Show'}
          </Button>
        </div>
      </div>
      {open && (r.loading && !r.data ? <Spinner /> : r.error && !r.data ? <div className="mt-3"><ErrorNote error={r.error} /></div> : r.data && (
        <Body dealId={dealId} dealType={dealType} d={r.data} onChanged={refresh} />
      ))}
    </Card>
  );
}

function RunStatus({ run }: { run?: ResearchRun | null }) {
  if (!run) return <>Not researched yet.</>;
  if (run.status === 'running') {
    return (
      <span className="inline-flex items-center gap-1.5 text-primary-600">
        <Loader2 className="h-4 w-4 animate-spin" aria-hidden /> Researching… (started {dateText(run.started_at, true)})
      </span>
    );
  }
  if (run.status === 'failed') {
    return <span className="text-error-600">Failed {dateText(run.finished_at, true)}{run.error ? `: ${run.error}` : ''}</span>;
  }
  return <>Done {dateText(run.finished_at, true)}</>;
}

function Section({ title, aside, children }: { title: string; aside?: React.ReactNode; children: React.ReactNode }) {
  return (
    <section className="border-t border-secondary-100 pt-4">
      <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
        <h3 className="text-sm font-semibold text-secondary-900">{title}</h3>
        {aside}
      </div>
      {children}
    </section>
  );
}

function Hint({ text, href, link }: { text: string; href: string; link: string }) {
  return (
    <p className="flex flex-wrap items-center gap-x-2 gap-y-1 rounded-lg bg-secondary-50 p-2 text-sm text-secondary-600">
      <Info className="h-4 w-4 shrink-0 text-secondary-400" aria-hidden /> {text}
      <Link className="font-medium text-primary-600 hover:underline" href={href}>{link}</Link>
    </p>
  );
}

function Body({ dealId, dealType, d, onChanged }: { dealId: string; dealType?: string; d: Research; onChanged: () => void }) {
  const area = AREA.filter(([k]) => d.area?.[k]);
  const google = area.length > 0 || d.firms.length > 0;
  return (
    <div className="mt-4 space-y-4">
      {!d.run && !d.gemini && !d.sra && (
        <p className="text-sm text-secondary-600">
          When a deal is added, the AI pins the home on the Deal finder map. With Google Gemini it also searches Google for
          notes on the area and firms nearby. With the SRA register it adds the nearest conveyancers to Suppliers and
          drafts quote requests, which are sent only after someone approves them.
        </p>
      )}
      {(!d.gemini || !d.sra) && (
        <div className="space-y-2">
          {!d.gemini && (
            <Hint text={d.gemini_hint || 'Add Google Gemini to search the web around each deal.'} href={`${BASE}/settings?tab=ai`} link="Open AI settings" />
          )}
          {!d.sra && (
            <Hint text="Add the SRA register (a free key) to find conveyancers near each deal." href={`${BASE}/settings?tab=data`} link="Open Data connectors" />
          )}
        </div>
      )}

      {d.steps.length > 0 && (
        <ul className="space-y-1.5 text-sm">
          {d.steps.map((s, i) => {
            const st = STEP_ICON[s.status] || STEP_ICON.waiting;
            return (
              <li key={`${s.key}:${i}`} className="flex items-start gap-2">
                <st.icon className={cn('mt-0.5 h-4 w-4 shrink-0', st.cls)} aria-hidden />
                <span>
                  <span className="font-medium text-secondary-800">{STEP_NAME[s.key] || label(s.key)}</span>
                  <span className="sr-only"> ({s.status})</span>
                  {s.note && <span className="text-secondary-500"> — {s.note}</span>}
                </span>
              </li>
            );
          })}
        </ul>
      )}

      {d.suppliers.length > 0 && <RegisterFirms dealId={dealId} dealType={dealType} suppliers={d.suppliers} attribution={d.attribution} />}

      {d.quotes.length > 0 && (
        <Section title="Quote requests" aside={<Link className="text-sm text-primary-600 hover:underline" href={`${BASE}/approvals`}>Open Approvals</Link>}>
          <p className="mb-2 text-xs text-secondary-500">Sent only after another person approves it.</p>
          <ul className="divide-y divide-secondary-100 rounded-lg border border-secondary-200">
            {d.quotes.map((q) => {
              const st = QUOTE_STATUS[q.status] || { text: label(q.status), variant: 'default' as const };
              return (
                <li key={q.uuid} className="flex flex-col gap-1 p-3 text-sm sm:flex-row sm:items-center sm:justify-between">
                  <div className="min-w-0">
                    <div className="font-medium text-secondary-900">{q.title}</div>
                    {q.sent_to && <div className="break-all text-secondary-500">To {q.sent_to}</div>}
                  </div>
                  <span className="shrink-0"><Badge size="sm" variant={st.variant}>{st.text}</Badge></span>
                </li>
              );
            })}
          </ul>
        </Section>
      )}

      {google && (
        <Section title="From a Google search">
          <p className="flex items-start gap-2 rounded-lg bg-warning-500/10 p-2 text-sm text-warning-700">
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden /> Found with Google Search — check before relying on it.
          </p>
          {area.length > 0 && (
            <dl className="mt-3 space-y-2 text-sm">
              {area.map(([k, l]) => (
                <div key={k}>
                  <dt className="font-medium text-secondary-800">{l}</dt>
                  <dd className="whitespace-pre-wrap text-secondary-700">{d.area?.[k]}</dd>
                </div>
              ))}
            </dl>
          )}
          {d.firms.length > 0 && d.run && <WebFirms dealId={dealId} runUuid={d.run.uuid} firms={d.firms} onChanged={onChanged} />}
          {d.suggestions && (
            // Google's Search Suggestions, exactly as given: sandboxed (no scripts, no access to this page). The base
            // target only makes a chip open Google in a new tab instead of inside this small frame.
            <iframe
              title="Google Search Suggestions"
              sandbox="allow-popups allow-popups-to-escape-sandbox"
              srcDoc={`<base target="_blank">${d.suggestions}`}
              className="mt-4 h-24 w-full border-0"
            />
          )}
          {d.sources.length > 0 && (
            <div className="mt-3">
              <h4 className="text-sm font-semibold text-secondary-900">Sources</h4>
              <ul className="mt-1 space-y-1 text-sm">
                {d.sources.map((s) => <li key={s.url}><ExtLink href={s.url}>{s.title || s.url}</ExtLink></li>)}
              </ul>
            </div>
          )}
        </Section>
      )}
    </div>
  );
}

/** Conveyancers the autopilot added from the SRA register, nearest first; one can become the deal's solicitor. */
function RegisterFirms({ dealId, dealType, suppliers, attribution }: {
  dealId: string; dealType?: string; suppliers: ResearchSupplier[]; attribution: string;
}) {
  const { can } = usePdMe();
  const role = dealType === 'sell' ? 'seller_solicitor' : 'buyer_solicitor';
  const parties = usePdData(async () => (await pdService.parties(dealId)).data as { role?: string; account_uuid?: string }[], [dealId]);
  const current = (parties.data || []).filter((p) => p.role === role);
  const [busy, setBusy] = useState<string | null>(null);
  async function makeOurSolicitor(s: ResearchSupplier) {
    setBusy(s.uuid);
    try {
      await pdService.addParty({ deal_uuid: dealId, role, account_uuid: s.account_uuid });
      toast.success(`${s.name} is now our solicitor on this deal`);
      parties.refresh();
    } catch (e) {
      toast.error(pdErrorText(e));
    } finally {
      setBusy(null);
    }
  }
  return (
    <Section title="Conveyancers from the SRA register">
      {current.length > 0 && !suppliers.some((s) => current.some((p) => p.account_uuid === s.account_uuid)) && (
        <p className="mb-2 text-xs text-secondary-500">This deal already has a {label(role).toLowerCase()}.</p>
      )}
      <ul className="divide-y divide-secondary-100 rounded-lg border border-secondary-200">
        {suppliers.map((s) => {
          const ours = current.some((p) => p.account_uuid === s.account_uuid);
          const miles = Number(s.distance_miles ?? NaN);
          return (
            <li key={s.uuid} className="flex flex-col gap-2 p-3 sm:flex-row sm:items-start sm:justify-between">
              <div className="min-w-0 space-y-1">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="font-medium text-secondary-900">{s.name}</span>
                  {Number.isFinite(miles) && <span className="text-sm text-secondary-500">{miles.toFixed(1)} mi</span>}
                  {s.created_by_this_run && <Badge size="sm" variant="info">New in Suppliers</Badge>}
                  {ours && <Badge size="sm" variant="success">Our solicitor</Badge>}
                </div>
                <ContactLinks phone={s.phone} email={s.email} website={s.website} />
                {(s.address_line1 || s.postal_code) && (
                  <div className="text-xs text-secondary-500">{[s.address_line1, s.postal_code].filter(Boolean).join(', ')}</div>
                )}
              </div>
              {can('deals', 'create') && !current.length && (
                <Button size="sm" variant="outline" className="shrink-0" isLoading={busy === s.uuid} disabled={!!busy} onClick={() => makeOurSolicitor(s)}>
                  Use as our solicitor
                </Button>
              )}
            </li>
          );
        })}
      </ul>
      <p className="mt-2 text-xs"><ExtLink href="https://www.sra.org.uk/datasharing">{attribution}</ExtLink></p>
    </Section>
  );
}

/** Firms from the Google search, as Google returned them (order and wording unchanged); a person picks what to use. */
function WebFirms({ dealId, runUuid, firms, onChanged }: { dealId: string; runUuid: string; firms: ResearchFirm[]; onChanged: () => void }) {
  const { can } = usePdMe();
  const [busy, setBusy] = useState<string | null>(null);
  async function act(what: 'save' | 'quote', f: ResearchFirm) {
    setBusy(`${what}:${f.index}`);
    try {
      if (what === 'save') {
        const res = (await pdService.saveResearchFirm(dealId, f.index, runUuid)).data;
        toast.success(res.created ? `${f.name} added to Suppliers` : `${f.name} was already in Suppliers`);
      } else {
        await pdService.quoteResearchFirm(dealId, f.index, runUuid);
        toast.success('Quote request drafted — it waits in Approvals');
      }
    } catch (e) {
      toast.error(pdErrorText(e));
    } finally {
      setBusy(null);
      onChanged();
    }
  }
  return (
    <div className="mt-4">
      <h4 className="text-sm font-semibold text-secondary-900">Firms nearby</h4>
      <ul className="mt-2 divide-y divide-secondary-100 rounded-lg border border-secondary-200">
        {firms.map((f) => (
          <li key={f.index} className="flex flex-col gap-2 p-3 sm:flex-row sm:items-start sm:justify-between">
            <div className="min-w-0 space-y-1 text-sm">
              <div className="flex flex-wrap items-center gap-2">
                <span className="font-medium text-secondary-900">{f.name}</span>
                {f.kind && <span className="text-secondary-500">{kindText(f.kind)}</span>}
              </div>
              <ContactLinks phone={f.phone} email={f.email} website={f.website} />
              {(f.address || f.postcode) && <div className="text-secondary-600">{[f.address, f.postcode].filter(Boolean).join(', ')}</div>}
              {f.accreditation && <div className="text-secondary-600">Accreditation: {f.accreditation}</div>}
              {f.fees && <div className="text-secondary-600">Fees: {f.fees}</div>}
              {f.notes && <div className="text-secondary-500">{f.notes}</div>}
            </div>
            <div className="flex shrink-0 flex-wrap gap-2">
              {f.saved_supplier_uuid ? (
                <Badge size="sm" variant="success">In Suppliers</Badge>
              ) : can('suppliers', 'create') && f.can_save && (
                <Button size="sm" variant="outline" isLoading={busy === `save:${f.index}`} disabled={!!busy} onClick={() => act('save', f)}>
                  Add to Suppliers
                </Button>
              )}
              {f.quote_asked ? (
                <Badge size="sm" variant="secondary">Quote asked</Badge>
              ) : can('approvals', 'create') && f.can_quote && (
                <Button size="sm" variant="outline" isLoading={busy === `quote:${f.index}`} disabled={!!busy} onClick={() => act('quote', f)}>
                  Ask for a quote
                </Button>
              )}
            </div>
          </li>
        ))}
      </ul>
    </div>
  );
}

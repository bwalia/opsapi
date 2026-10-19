'use client';

/**
 * Property Deals — Map / Deal finder (SPEC §3.6): drop a pin, radius 5–50 miles (default 25),
 * layer toggles, a property card with comparables and the top 3 matching buyers (score
 * breakdown), saved searches for the deal scout and its alerts. Deep link: ?lat=&lng=&layers=deals,suppliers
 * (the deal page's "Show on map").
 */
import React, { useEffect, useMemo, useState } from 'react';
import dynamic from 'next/dynamic';
import Link from 'next/link';
import { MapPin, Save, Bell, Play, Trash2, Search, Building2 } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, Card, Input, Badge } from '@/components/ui';
import { pdService, pdErrorText, type MapFeature, type MatchWithBreakdown } from '@/services/property-deals.service';
import {
  PdPage, ErrorNote, Spinner, gbp, dateText, label, BASE, HealthBadge, ContactLinks, SupplierSourceBadge, kindText,
} from '@/components/property-deals/ui';
import { useDebounced, usePdData, usePdMe } from '@/components/property-deals/usePd';
import MatchRow from '@/components/property-deals/MatchRow';
import { LAYER_COLOURS } from '@/components/property-deals/mapColours';

const MapView = dynamic(() => import('@/components/property-deals/MapView'), { ssr: false, loading: () => <Spinner label="Loading the map…" /> });

const LAYERS = [
  ['properties', 'My properties'], ['deals', 'Deals'], ['leads', 'Seller leads'], ['holdings', "Buyers' holdings"],
  ['suppliers', 'Suppliers'], ['sold_prices', 'Sold prices'], ['epc', 'EPC ratings'], ['listings', 'Listings'], ['auction_lots', 'Auction lots'],
] as const;

export default function MapPage() {
  return (
    <PdPage module="properties">
      <Finder />
    </PdPage>
  );
}

/** The pin and layers from ?lat=&lng=&layers= (this page only renders in the browser, after /me). */
function fromUrl(): { center?: { lat: number; lng: number }; layers?: string[] } {
  const q = new URLSearchParams(typeof window === 'undefined' ? '' : window.location.search);
  const lat = Number(q.get('lat') || NaN);
  const lng = Number(q.get('lng') || NaN);
  const layers = (q.get('layers') || '').split(',').filter((k) => LAYERS.some(([l]) => l === k));
  return {
    center: Math.abs(lat) <= 90 && Math.abs(lng) <= 180 ? { lat, lng } : undefined,
    layers: layers.length ? layers : undefined,
  };
}

function Finder() {
  const { can } = usePdMe();
  const [linked] = useState(fromUrl);
  const [center, setCenter] = useState(linked.center || { lat: 53.96, lng: -1.08 });
  // No pin in the link: start at the most recent deal that is on the map (the default is for a workspace with none).
  useEffect(() => {
    if (linked.center) return;
    let gone = false;
    pdService.deals({ sort: 'newest', per_page: 20 }).then((r) => {
      const d = (r.data || []).find((x) => x.lat != null && x.lng != null);
      if (d && !gone) setCenter({ lat: Number(d.lat), lng: Number(d.lng) });
    }).catch(() => {});
    return () => { gone = true; };
  }, [linked.center]);
  const [radius, setRadius] = useState(25);
  const [layers, setLayers] = useState<string[]>(linked.layers || ['properties', 'deals', 'sold_prices', 'listings']);
  const [selected, setSelected] = useState<MapFeature | null>(null);
  // The map's "base": your own deals (Google Maps), or the NebulaDB Companies House index.
  const [base, setBase] = useState<'deals' | 'companies'>('deals');
  const [companyQuery, setCompanyQuery] = useState('');
  const [submittedQ, setSubmittedQ] = useState('');
  const radiusQ = useDebounced(radius, 400); // the circle follows the slider; the search waits for it to settle
  const map = usePdData(async () => (await pdService.map({ lat: center.lat, lng: center.lng, radius_miles: radiusQ, layers: layers.join(',') })).data, [center.lat, center.lng, radiusQ, layers.join(',')]);
  // Companies House is a keyword search (not radius): we plot its results as pins and leave the radius alone.
  const companies = usePdData(
    async () => (base === 'companies' && submittedQ ? (await pdService.companies(submittedQ)).data : { companies: [], total: 0, mapped: 0 }),
    [base, submittedQ],
  );
  const companyFeatures = useMemo<MapFeature[]>(
    () => (companies.data?.companies || [])
      .filter((c) => c.lat != null && c.lng != null)
      .map((c) => ({
        layer: 'company', uuid: c.company_number || c.title, lat: c.lat as number, lng: c.lng as number,
        title: c.title, subtitle: c.address_snippet || c.postcode || undefined,
        company_number: c.company_number, company_status: c.company_status, address_snippet: c.address_snippet,
      }) as MapFeature),
    [companies.data],
  );

  return (
    <div className="space-y-6">
      <PageHeader title="Deal finder" description="Google Map — click to drop a search pin. Deals with an address appear as pins within the radius." icon={<MapPin className="h-6 w-6" />} />
      <div className="grid gap-6 xl:grid-cols-[1fr_24rem]">
        <div className="space-y-3">
          <Card padding="sm" data-tour="map-controls">
            <div className="mb-3 inline-flex rounded-lg border border-secondary-200 bg-surface p-1" role="group" aria-label="Map base">
              {([['deals', 'My deals', MapPin], ['companies', 'Companies House', Building2]] as const).map(([key, lbl, Icon]) => (
                <button
                  key={key}
                  type="button"
                  onClick={() => { setBase(key); setSelected(null); }}
                  aria-pressed={base === key}
                  className={`inline-flex items-center gap-1.5 rounded-md px-3 py-1.5 text-sm font-medium transition ${base === key ? 'bg-primary-500 text-white' : 'text-secondary-600 hover:bg-secondary-100'}`}
                >
                  <Icon className="h-4 w-4" /> {lbl}
                </button>
              ))}
            </div>
            {base === 'deals' ? (
              <div className="flex flex-wrap items-center gap-4">
                <label className="flex items-center gap-2 text-sm">
                  Radius <input type="range" min={5} max={50} step={5} value={radius} onChange={(e) => setRadius(Number(e.target.value))} aria-label="Radius in miles" />
                  <span className="w-16 font-medium">{radius} miles</span>
                </label>
                <div className="flex flex-wrap gap-2" role="group" aria-label="Layers">
                  {LAYERS.map(([k, l]) => (
                    <label key={k} className="flex items-center gap-1.5 rounded-full border border-secondary-200 px-2.5 py-1 text-xs">
                      <input type="checkbox" checked={layers.includes(k)} onChange={(e) => setLayers(e.target.checked ? [...layers, k] : layers.filter((x) => x !== k))} />
                      <span className="h-2.5 w-2.5 rounded-full" style={{ background: LAYER_COLOURS[k] }} aria-hidden />
                      {l}{map.data?.counts && (map.data.counts as Record<string, number>)[k] !== undefined ? ` (${(map.data.counts as Record<string, number>)[k]})` : ''}
                    </label>
                  ))}
                </div>
              </div>
            ) : (
              <form className="flex flex-wrap items-center gap-2" onSubmit={(e) => { e.preventDefault(); setSubmittedQ(companyQuery.trim()); setSelected(null); }}>
                <Input placeholder="Company name or number…" value={companyQuery} onChange={(e) => setCompanyQuery(e.target.value)} aria-label="Company search" className="min-w-[14rem] flex-1" />
                <Button type="submit" leftIcon={<Search className="h-4 w-4" />} disabled={!companyQuery.trim() || companies.loading}>Search</Button>
                {companies.data && submittedQ ? (
                  <span className="text-xs text-secondary-500">{companies.data.mapped} of {companies.data.total} on the map{companies.data.total > companies.data.mapped ? ' (others have no UK postcode)' : ''}</span>
                ) : null}
              </form>
            )}
          </Card>
          <ErrorNote error={base === 'deals' ? map.error : companies.error} />
          <MapView
            center={center}
            radiusMiles={radius}
            features={base === 'deals' ? (map.data?.features || []) : companyFeatures}
            onPick={(lat, lng) => { setCenter({ lat, lng }); setSelected(null); }}
            onSelect={setSelected}
            showSearchPin={base === 'deals'}
            fitToFeatures={base === 'companies'}
            selectedUuid={selected?.uuid}
          />
          {base === 'deals' && map.data?.truncated && <p className="text-xs text-secondary-500">Showing the nearest 2,000. Zoom in with a smaller radius for the rest.</p>}
          {base === 'companies' && submittedQ && !companies.loading && companyFeatures.length === 0 && (
            <p className="text-xs text-secondary-500">No companies to place on the map{companies.data && companies.data.total > 0 ? ' — the results have no UK postcode' : ''}. Try a different search.</p>
          )}
        </div>
        <div className="space-y-6">
          {selected ? <Selected f={selected} canSend={can('buyers', 'update')} onClose={() => setSelected(null)} /> : (
            <Card><p className="text-sm text-secondary-500">{base === 'companies' ? 'Search Companies House, then click a company pin to see it and create a lead.' : 'Click a dot for its details. Your properties show a card with comparables and the best matching buyers.'}</p></Card>
          )}
          {base === 'deals' && <Searches center={center} radius={radius} layers={layers} onOpen={(lat, lng, r) => { setCenter({ lat, lng }); setRadius(r); }} />}
        </div>
      </div>
    </div>
  );
}

function Selected({ f, canSend, onClose }: { f: MapFeature; canSend: boolean; onClose: () => void }) {
  const isOwn = f.layer === 'properties' || f.layer === 'deals';
  const card = usePdData(async () => (isOwn ? (await pdService.card(f.uuid)).data : undefined), [f.uuid, isOwn]);
  return (
    <Card>
      <div className="flex items-start justify-between gap-2">
        <div>
          <h2 className="font-semibold text-secondary-900">{f.title}</h2>
          <p className="text-sm text-secondary-500">{label(f.layer)}{f.subtitle ? ` · ${f.subtitle}` : ''}{f.distance_miles !== undefined ? ` · ${Number(f.distance_miles).toFixed(1)} miles` : ''}</p>
        </div>
        <Button size="sm" variant="ghost" onClick={onClose}>Close</Button>
      </div>
      {f.layer === 'company' ? (
        <CompanyPanel f={f} />
      ) : f.layer === 'suppliers' ? (
        <div className="mt-3 space-y-2 text-sm">
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-secondary-700">{(f.kinds || []).map(kindText).join(', ') || 'Supplier'}</span>
            <SupplierSourceBadge source={f.source} />
          </div>
          <ContactLinks phone={f.phone} email={f.email} website={f.website} />
        </div>
      ) : !isOwn ? (
        <dl className="mt-3 grid grid-cols-2 gap-2 text-sm">
          {f.price !== undefined && <><dt className="text-secondary-500">Price</dt><dd>{gbp(f.price)}{f.previous_price ? <span className="ml-1 text-xs text-success-600">was {gbp(f.previous_price)}</span> : null}</dd></>}
          {f.event_date && <><dt className="text-secondary-500">Date</dt><dd>{dateText(f.event_date)}</dd></>}
          {f.epc_rating && <><dt className="text-secondary-500">EPC</dt><dd>{f.epc_rating}</dd></>}
          {f.property_type && <><dt className="text-secondary-500">Type</dt><dd>{label(f.property_type)}</dd></>}
          {f.cash_only && <><dt className="text-secondary-500">Buyers</dt><dd>Cash only</dd></>}
          {f.url && <><dt className="text-secondary-500">Link</dt><dd><a className="text-primary-600 underline" href={f.url} target="_blank" rel="noopener noreferrer">Open</a></dd></>}
        </dl>
      ) : card.loading && !card.data ? <Spinner /> : card.data ? (
        <div className="mt-3 space-y-3 text-sm">
          {card.data.deal && (
            <div className="flex items-center justify-between rounded-lg bg-secondary-50 p-2">
              <Link className="font-medium text-primary-600 hover:underline" href={`${BASE}/deals/${(card.data.deal as { uuid: string }).uuid}`}>{(card.data.deal as { name?: string }).name}</Link>
              <HealthBadge health={(card.data.deal as { health?: string }).health} />
            </div>
          )}
          <dl className="grid grid-cols-2 gap-2">
            <dt className="text-secondary-500">Gross yield</dt><dd>{card.data.gross_yield_pct ?? '—'}{card.data.gross_yield_pct !== undefined ? '%' : ''}</dd>
            <dt className="text-secondary-500">Comparables</dt><dd>{card.data.comps?.count ? `${card.data.comps.count} · median ${gbp(card.data.comps.median)}` : 'none yet'}</dd>
            <dt className="text-secondary-500">Discount vs comps</dt><dd>{card.data.discount_vs_comps_pct !== undefined ? `${card.data.discount_vs_comps_pct}%` : '—'}</dd>
          </dl>
          <div>
            <h3 className="mb-1 font-medium text-secondary-900">Top matching buyers</h3>
            {card.data.top_matches?.length ? (
              <ul className="divide-y divide-secondary-100 rounded-lg border border-secondary-200">
                {(card.data.top_matches as unknown as MatchWithBreakdown[]).map((m) => <MatchRow key={m.uuid} m={m} canSend={canSend} onChanged={card.refresh} />)}
              </ul>
            ) : <p className="text-secondary-500">No buyer profiles match yet.</p>}
          </div>
          {!card.data.deal && (
            <Button size="sm" onClick={async () => {
              try { const d = (await pdService.createDeal({ property_uuid: f.uuid, deal_type: 'buy' })).data; window.location.assign(`${BASE}/deals/${d.uuid}`); } catch (e) { toast.error(pdErrorText(e)); }
            }}>Create a deal for this home</Button>
          )}
        </div>
      ) : null}
    </Card>
  );
}

/** A Companies House result: its details + a one-click "create a lead from this company". */
function CompanyPanel({ f }: { f: MapFeature }) {
  const [busy, setBusy] = useState(false);
  return (
    <div className="mt-3 space-y-3 text-sm">
      <dl className="grid grid-cols-[6rem_1fr] gap-2">
        {f.company_number && <><dt className="text-secondary-500">Number</dt><dd>{f.company_number}</dd></>}
        {f.company_status && <><dt className="text-secondary-500">Status</dt><dd>{label(f.company_status)}</dd></>}
        {f.address_snippet && <><dt className="text-secondary-500">Address</dt><dd>{f.address_snippet}</dd></>}
      </dl>
      {f.company_number && (
        <a className="inline-block text-primary-600 underline" target="_blank" rel="noopener noreferrer"
          href={`https://find-and-update.company-information.service.gov.uk/company/${f.company_number}`}>
          Companies House profile
        </a>
      )}
      <Button size="sm" disabled={busy} onClick={async () => {
        setBusy(true);
        try {
          const r = (await pdService.createCompanyLead({ company_number: f.company_number, title: f.title ?? 'Company', address_snippet: f.address_snippet })).data;
          toast.success('Lead created');
          window.location.assign(`${BASE}/leads/${r.uuid}`);
        } catch (e) { toast.error(pdErrorText(e)); setBusy(false); }
      }}>Create a lead from this company</Button>
    </div>
  );
}

function Searches({ center, radius, layers, onOpen }: { center: { lat: number; lng: number }; radius: number; layers: string[]; onOpen: (lat: number, lng: number, r: number) => void }) {
  const { can } = usePdMe();
  const searches = usePdData(async () => (await pdService.savedSearches()).data, []);
  const alerts = usePdData(async () => (await pdService.scoutAlerts({ unseen: 'true' })).data, []);
  const [name, setName] = useState('');
  return (
    <Card data-tour="map-searches">
      <h2 className="font-semibold text-secondary-900">Saved searches</h2>
      <p className="text-sm text-secondary-500">The deal scout re-runs these every morning and alerts you.</p>
      {can('properties', 'create') && (
        <div className="mt-3 flex gap-2">
          <Input placeholder="Name this pin + radius" value={name} onChange={(e) => setName(e.target.value)} aria-label="Search name" />
          <Button leftIcon={<Save className="h-4 w-4" />} disabled={!name} onClick={async () => {
            try { await pdService.saveSearch({ name, lat: center.lat, lng: center.lng, radius_miles: radius, filters: { layers } }); toast.success('Saved'); setName(''); searches.refresh(); } catch (e) { toast.error(pdErrorText(e)); }
          }}>Save</Button>
        </div>
      )}
      <ul className="mt-3 divide-y divide-secondary-100 text-sm">
        {(searches.data || []).map((s) => (
          <li key={s.uuid} className="flex items-center justify-between gap-2 py-2">
            <button type="button" className="text-left text-primary-600 hover:underline" onClick={() => s.lat !== undefined && s.lng !== undefined && onOpen(Number(s.lat), Number(s.lng), Number(s.radius_miles || 25))}>{s.name}</button>
            <span className="flex gap-1">
              <Button size="sm" variant="ghost" aria-label={`Run ${s.name}`} onClick={async () => { try { const r = (await pdService.runSearch(s.uuid)).data; toast.success(`New ${r.new}, reduced ${r.reduced}, stale ${r.stale}, cash only ${r.cash_only}`); alerts.refresh(); } catch (e) { toast.error(pdErrorText(e)); } }}><Play className="h-4 w-4" /></Button>
              {can('properties', 'delete') && (
                <Button size="sm" variant="ghost" aria-label={`Delete ${s.name}`} onClick={async () => {
                  if (!window.confirm(`Delete the saved search “${s.name}”? The deal scout stops re-running it.`)) return;
                  try { await pdService.deleteSearch(s.uuid); searches.refresh(); } catch (e) { toast.error(pdErrorText(e)); }
                }}><Trash2 className="h-4 w-4" /></Button>
              )}
            </span>
          </li>
        ))}
      </ul>
      <div className="mt-4 flex items-center justify-between">
        <h3 className="flex items-center gap-1.5 font-medium text-secondary-900"><Bell className="h-4 w-4" aria-hidden /> New alerts</h3>
        {(alerts.data || []).length > 0 && <Button size="sm" variant="ghost" onClick={async () => { try { await pdService.markAlertsSeen(); alerts.refresh(); } catch (e) { toast.error(pdErrorText(e)); } }}>Mark all seen</Button>}
      </div>
      <ul className="mt-2 space-y-2 text-sm">
        {(alerts.data || []).length === 0 && <li className="text-secondary-500">Nothing new.</li>}
        {(alerts.data || []).slice(0, 20).map((a) => (
          <li key={a.uuid} className="rounded-lg bg-secondary-50 p-2">
            <Badge size="sm" variant={a.kind === 'reduced' ? 'success' : a.kind === 'new' ? 'info' : 'default'}>{label(a.kind)}</Badge>
            <span className="ml-2 text-secondary-800">{a.address || a.postcode}</span>
            <div className="text-xs text-secondary-500">{a.detail} · {a.saved_search_name}</div>
          </li>
        ))}
      </ul>
    </Card>
  );
}

'use client';

/**
 * Official data about the area around a deal's home (GET /deals/{id}/research → facts): planning constraints from
 * planning.data.gov.uk, Environment Agency flood warnings and alert areas, police.uk crime and the Land Registry
 * house price index. Open Government Licence data, shown to the whole team with its attribution.
 */
import React from 'react';
import type { AreaFacts as Facts } from '@/services/property-deals.service';
import { gbp } from './ui';

const AT_HOME: Record<string, string> = {
  'conservation-area': 'Conservation area',
  'article-4-direction-area': 'Article 4 direction',
  'tree-preservation-zone': 'Tree preservation zone',
  'green-belt': 'Green belt',
  'flood-risk-zone': 'Flood zone',
};

const words = (s?: string | null) => (s || '').replace(/[-_]/g, ' ');

function Box({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="rounded-lg border border-secondary-200 p-3 text-sm">
      <h4 className="mb-1 font-medium text-secondary-900">{title}</h4>
      <div className="space-y-1 text-secondary-700">{children}</div>
    </div>
  );
}

export default function AreaFacts({ facts }: { facts: Facts }) {
  const { planning, flood, crime, prices } = facts;
  return (
    <div className="space-y-3">
      <div className="grid gap-3 md:grid-cols-2">
        {planning && (
          <Box title="Planning">
            {planning.at_the_home.length > 0 ? (
              <ul className="space-y-0.5">
                {planning.at_the_home.map((e, i) => (
                  <li key={i}>
                    <span className="font-medium">{AT_HOME[e.dataset] || words(e.dataset)}</span>
                    {e.level ? ` ${e.level}` : ''}{e.name ? `: ${e.name}` : ''}
                  </li>
                ))}
              </ul>
            ) : (
              <p>No conservation area, Article 4, tree preservation, green belt or flood zone recorded at the home (not every council publishes these).</p>
            )}
            <p>
              {planning.listed_buildings.count} listed building{planning.listed_buildings.count === 1 ? '' : 's'} within about 250 m
              {planning.listed_buildings.nearest.length > 0 && (
                <>: {planning.listed_buildings.nearest.map((b) => `${b.name || 'unnamed'}${b.grade ? ` (grade ${b.grade})` : ''}`).join('; ')}</>
              )}
            </p>
            {planning.brownfield.count > 0 && (
              <p>{planning.brownfield.count} brownfield site{planning.brownfield.count === 1 ? '' : 's'} nearby: {planning.brownfield.sites.map((s) => s.name).filter(Boolean).join('; ')}</p>
            )}
          </Box>
        )}
        {flood && (
          <Box title="Flood">
            {flood.warnings.length > 0 ? (
              <ul className="space-y-0.5 text-error-700">
                {flood.warnings.map((w, i) => <li key={i}>{w.severity || 'Warning'}: {w.area}</li>)}
              </ul>
            ) : (
              <p>No flood warnings in force within 3 km.</p>
            )}
            <p>
              {flood.alert_areas_within_1km} Environment Agency flood-alert area{flood.alert_areas_within_1km === 1 ? '' : 's'} within 1 km
              {flood.alert_areas.length > 0 && <>: {flood.alert_areas.join('; ')}</>}
            </p>
          </Box>
        )}
        {crime && (
          <Box title="Crime">
            <p>{crime.within_1_mile} crimes recorded within a mile{crime.month ? ` in ${crime.month}` : ''}.</p>
            {crime.top.length > 0 && (
              <p>Most common: {crime.top.map((c) => `${words(c.category)} ${c.count}`).join(', ')}.</p>
            )}
          </Box>
        )}
        {prices && (
          <Box title={`House prices in ${prices.area}`}>
            <p>
              Average {gbp(prices.average)} ({prices.month})
              {prices.annual_change_pct != null && <>, {prices.annual_change_pct > 0 ? '+' : ''}{prices.annual_change_pct}% over a year</>}.
            </p>
            <p>
              {[['Detached', prices.detached], ['Semi-detached', prices.semi_detached], ['Terraced', prices.terraced], ['Flat', prices.flat]]
                .filter(([, v]) => v != null)
                .map(([k, v]) => `${k} ${gbp(v as number)}`)
                .join(' · ')}
            </p>
          </Box>
        )}
      </div>
      {facts.missing.length > 0 && <p className="text-xs text-secondary-500">Not available right now: {facts.missing.join(', ')}.</p>}
      {facts.sources.length > 0 && (
        <p className="text-xs text-secondary-500">{facts.sources.join(' · ')}</p>
      )}
    </div>
  );
}

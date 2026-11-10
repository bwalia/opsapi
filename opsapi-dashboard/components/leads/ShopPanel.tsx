'use client';

import React from 'react';
import Link from 'next/link';
import { formatMoney } from '@/lib/shop';
import { SURVEY_QUESTION_ORDER, answerLabel, questionLabel } from '@/lib/shop-survey';
import { Section } from '@/components/leads/ui';

/**
 * What the shop saved on a lead (metadata.shop, written by lib/shop-leads.lua) and the statements ticked on a
 * website form (metadata.consent). Shows nothing when the lead didn't come from the shop or a form with ticks.
 */

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj | null => (v && typeof v === 'object' && !Array.isArray(v) ? (v as Obj) : null);
const list = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const str = (v: unknown): string | null => (typeof v === 'string' && v.trim() ? v : null);
// Stored as "2026-11-09 16:50 UTC" or "2026-11-09 16:50:54Z": shown as written, in plain UTC.
const when = (v: unknown) => str(v)?.replace('T', ' ').replace(/(:\d\d)?Z$/, ' UTC') ?? '';

const REQUIREMENTS: [string, string][] = [
  ['goal', 'Goal'], ['workloads', 'Workloads'], ['models', 'Models'], ['data_size', 'Data'], ['team_size', 'Team'],
  ['budget_gbp', 'Budget (£)'], ['deadline', 'Deadline'], ['in_house', 'Already has'], ['sector', 'Sector'], ['constraints', 'Constraints'],
  ['delivery_postcode', 'Delivery postcode'], ['delivery_country', 'Delivery country'],
];

const DOCS: Record<string, string> = {
  'terms-of-sale': 'Terms of Sale', 'trade-terms': 'Trade terms', 'privacy-notice': 'Privacy notice',
  'ai-assistant': 'AI assistant notice', 'important-information': 'Important information',
};

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex justify-between gap-3">
      <dt className="shrink-0 text-secondary-500">{label}</dt>
      <dd className="min-w-0 text-right text-secondary-900">{children}</dd>
    </div>
  );
}

export function ShopPanel({ metadata }: { metadata: Obj | null | undefined }) {
  const shop = obj(metadata?.shop);
  const consent = obj(metadata?.consent);
  const survey = obj(shop?.survey);
  const answers = obj(survey?.answers);
  const chats = list(survey?.chats).map(obj).filter(Boolean) as Obj[];
  const joins = list(survey?.joins).map(obj).filter(Boolean) as Obj[];
  const quotes = list(shop?.quotes).map(obj).filter((q): q is Obj => !!q && !!str(q.uuid));
  const sessions = list(shop?.chat_sessions).map(str).filter((s): s is string => !!s);
  const reqs = obj(shop?.requirements);
  const ticks = list(consent?.documents).map(obj).filter(Boolean) as Obj[];
  const hasReqs = !!reqs && REQUIREMENTS.some(([k]) => str(String(reqs[k] ?? '')));

  if (!survey && !quotes.length && !sessions.length && !hasReqs && !ticks.length) return null;

  return (
    <>
      {survey && (
        <Section title="“What do I need?” survey">
          <dl className="space-y-2 text-sm">
            {str(survey.ref) && <Row label="Build">{String(survey.ref)}</Row>}
            {str(survey.product_name) && <Row label="Recommended">{String(survey.product_name)}</Row>}
            {answers && SURVEY_QUESTION_ORDER.filter((k) => str(answers[k])).map((k) => (
              <Row key={k} label={questionLabel(k)}>{answerLabel(k, String(answers[k]))}</Row>
            ))}
            {typeof survey.marketing === 'boolean' && <Row label="Marketing emails">{survey.marketing ? 'Yes, opted in' : 'No'}</Row>}
            {str(survey.last_at) && <Row label="Last activity">{when(survey.last_at)}</Row>}
          </dl>
          {joins.length > 0 && (
            <div className="mt-4">
              <p className="text-xs font-medium text-secondary-500">Started joining Trade</p>
              <ul className="mt-1 space-y-1 text-sm text-secondary-800">
                {joins.map((j, i) => (
                  <li key={i}>
                    {j.plan === 'year' ? 'Yearly' : 'Monthly'}{str(j.tier) ? `, ${String(j.tier)} price` : ''}
                    <span className="ml-2 text-xs text-secondary-500">{when(j.at)}</span>
                  </li>
                ))}
              </ul>
            </div>
          )}
          {chats.length > 0 && (
            <details className="mt-4 group">
              <summary className="cursor-pointer text-xs font-medium text-secondary-500 hover:text-secondary-700">
                Asked our AI engineer {chats.length} question{chats.length === 1 ? '' : 's'}
              </summary>
              <ul className="mt-2 space-y-3">
                {chats.map((c, i) => (
                  <li key={i} className="rounded-lg bg-secondary-50 p-3 text-sm">
                    <p className="font-medium text-secondary-900">{String(c.question ?? '')}</p>
                    {str(c.answer) && <p className="mt-1 whitespace-pre-wrap text-secondary-700">{String(c.answer)}</p>}
                    <p className="mt-1 text-[11px] text-secondary-500">{when(c.at)}</p>
                  </li>
                ))}
              </ul>
            </details>
          )}
        </Section>
      )}

      {(quotes.length > 0 || sessions.length > 0 || hasReqs) && (
        <Section title="From the shop">
          {quotes.length > 0 && (
            <ul className="space-y-1 text-sm">
              {quotes.map((q) => (
                <li key={String(q.uuid)} className="flex justify-between gap-3">
                  <Link href={`/dashboard/shop/quotes/${String(q.uuid)}`} className="text-primary-600 hover:underline">
                    Quote {str(q.number) ?? ''}
                  </Link>
                  {typeof q.total_minor === 'number' && <span className="tabular-nums text-secondary-700">{formatMoney(q.total_minor)}</span>}
                </li>
              ))}
            </ul>
          )}
          {sessions.length > 0 && (
            <p className="mt-2 text-sm">
              {sessions.map((s, i) => (
                <React.Fragment key={s}>
                  {i > 0 && ' · '}
                  <Link href={`/dashboard/shop/chats/${s}`} className="text-primary-600 hover:underline">
                    {sessions.length === 1 ? 'Open the AI chat' : `Chat ${i + 1}`}
                  </Link>
                </React.Fragment>
              ))}
            </p>
          )}
          {hasReqs && reqs && (
            <dl className="mt-3 space-y-2 text-sm">
              {REQUIREMENTS.filter(([k]) => str(String(reqs[k] ?? ''))).map(([k, label]) => (
                <Row key={k} label={label}>{String(reqs[k])}</Row>
              ))}
            </dl>
          )}
        </Section>
      )}

      {ticks.length > 0 && (
        <Section title="Ticked on the form">
          <ul className="space-y-2 text-sm">
            {ticks.map((d, i) => (
              <li key={i}>
                <p className="text-secondary-900">{DOCS[String(d.key)] ?? String(d.key ?? '')}
                  {str(d.version) && <span className="ml-1 text-xs text-secondary-500">version {String(d.version)}</span>}</p>
                {str(d.statement) && <p className="text-xs text-secondary-600">“{String(d.statement)}”</p>}
              </li>
            ))}
          </ul>
          <p className="mt-3 text-xs text-secondary-500">
            {str(consent?.accepted_at) ? `${when(consent?.accepted_at)}. ` : ''}The email was typed into the form, so this isn’t proof the owner of that address agreed.
          </p>
        </Section>
      )}
    </>
  );
}

export default ShopPanel;

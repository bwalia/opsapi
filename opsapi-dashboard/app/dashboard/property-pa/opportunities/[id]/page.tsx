'use client';

/**
 * Property PA — one opportunity: the facts (stated vs inferred, where each came from), changes waiting for
 * confirmation, next actions with their reasons, offers and events, the timeline, and each field's change
 * history (P10: source, model, prompt version, who confirmed; P11: corrections keep the history).
 */
import React, { Suspense, useState } from 'react';
import Link from 'next/link';
import { useParams, useSearchParams } from 'next/navigation';
import { ArrowLeft, History, NotebookPen } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { Badge, Button, Card, Modal } from '@/components/ui';
import { ErrorNote, Spinner, dateText, dueText } from '@/components/property-deals/ui';
import { usePdData } from '@/components/property-deals/usePd';
import { valueText } from '@/components/property-pa/ConfirmSheet';
import PaPanels, { type Panel } from '@/components/property-pa/PaPanels';
import AskManager from '@/components/property-pa/AskManager';
import { paService, type Change, type Fact, type Opportunity } from '@/services/property-pa.service';

const FIELDS: { key: keyof Opportunity & string; label: string }[] = [
  { key: 'motivation', label: 'Motivation' },
  { key: 'expectation_price', label: "Seller's stated minimum" },
  { key: 'our_position', label: 'Price that might work' },
  { key: 'decision_makers', label: 'Decision makers' },
  { key: 'primary_concern', label: 'Main concern' },
  { key: 'temperature', label: 'Temperature' },
];

function FactBadge({ fact }: { fact?: Fact }) {
  if (!fact) return null;
  if (fact.is_inferred) return <Badge size="sm" variant="warning">Judgement, unconfirmed</Badge>;
  if (fact.source === 'ai') return <Badge size="sm" variant="info">From a note, confirmed</Badge>;
  if (fact.source === 'import') return <Badge size="sm" variant="secondary">Imported</Badge>;
  return <Badge size="sm" variant="success">Entered by a person</Badge>;
}

function HistoryModal({ oppId, field, label, onClose }: { oppId: string; field: string; label: string; onClose: () => void }) {
  const { data, error, loading } = usePdData(() => paService.history('pa_opportunities', oppId, field), [oppId, field]);
  return (
    <Modal isOpen onClose={onClose} title={`History: ${label}`}>
      <ErrorNote error={error} />
      {loading && !data ? <Spinner /> : (
        <ol className="space-y-3">
          {(data || []).map((c: Change) => (
            <li key={c.uuid} className={c.superseded_by ? 'opacity-60' : ''}>
              <p className="text-sm font-medium text-secondary-900">{valueText({ field, target_table: 'pa_opportunities' }, c.value)}</p>
              <p className="text-xs text-secondary-500">
                {dateText(c.created_at, true)} · {c.action} by {c.source === 'ai' ? 'the PA' : c.source}
                {c.is_inferred ? ' · inferred' : ''}
                {c.model ? ` · ${c.model}` : ''}{c.prompt_version ? ` (${c.prompt_version})` : ''}
                {c.confirmed_by_user_uuid ? ' · confirmed by a person' : c.source === 'ai' ? ' · not confirmed' : ''}
                {c.superseded_by ? ' · replaced' : ' · current'}
              </p>
            </li>
          ))}
          {data && !data.length && <p className="text-sm text-secondary-500">No changes recorded yet.</p>}
        </ol>
      )}
    </Modal>
  );
}

export default function OpportunityPage() {
  return (
    <Suspense fallback={<Spinner />}>
      <OpportunityView />
    </Suspense>
  );
}

function OpportunityView() {
  const { id } = useParams<{ id: string }>();
  const panel = useSearchParams().get('panel');
  const { data: o, error, loading } = usePdData(() => paService.opportunity(id), [id], 30_000);
  const { data: tl } = usePdData(() => paService.timeline(id), [id], 30_000);
  const [hist, setHist] = useState<{ field: string; label: string } | null>(null);

  if (loading && !o) return <Spinner />;
  if (!o) return <ErrorNote error={error} />;
  const waiting = new Map<string, number>();
  for (const p of o.pending_updates || []) {
    if (p.source_interaction_uuid) waiting.set(p.source_interaction_uuid, (waiting.get(p.source_interaction_uuid) || 0) + 1);
  }

  return (
    <div className="space-y-6">
      <Link href="/dashboard/property-pa/opportunities" className="inline-flex items-center gap-1 text-sm text-secondary-500"><ArrowLeft className="h-4 w-4" /> Opportunities</Link>
      <PageHeader title={o.title} description={[o.person_name, o.property_address, o.property_postcode].filter(Boolean).join(' · ')}
        actions={
          <>
            <AskManager opportunity={o} />
            <Link href={`/dashboard/property-pa/capture?opportunity=${o.uuid}`}><Button leftIcon={<NotebookPen className="h-4 w-4" />}>Capture</Button></Link>
          </>
        } />
      <ErrorNote error={error} />

      {waiting.size > 0 && (
        <Card className="border-warning-300 bg-warning-50/40">
          {[...waiting.entries()].map(([it, n]) => (
            <p key={it} className="text-sm">
              {n} change{n === 1 ? '' : 's'} from a note waiting for you.{' '}
              <Link className="text-primary-600 underline" href={`/dashboard/property-pa/capture?interaction=${it}`}>Review</Link>
            </p>
          ))}
        </Card>
      )}

      <div className="grid gap-6 lg:grid-cols-3">
        <Card className="space-y-3 lg:col-span-2">
          <h3 className="font-semibold text-secondary-900">What we know</h3>
          <dl className="divide-y divide-secondary-100">
            {FIELDS.map((f) => {
              const v = o[f.key];
              const empty = v === null || v === undefined || v === '' || (Array.isArray(v) && !v.length);
              return (
                <div key={f.key} className="flex flex-wrap items-start justify-between gap-2 py-2">
                  <dt className="w-48 text-sm text-secondary-500">{f.label}</dt>
                  <dd className="min-w-0 flex-1 text-sm text-secondary-900">
                    {empty ? <span className="text-secondary-400">Not known</span> : valueText({ field: f.key, target_table: 'pa_opportunities' }, v)}
                    <span className="ml-2"><FactBadge fact={o.facts?.[f.key]} /></span>
                  </dd>
                  <Button size="sm" variant="ghost" leftIcon={<History className="h-4 w-4" />} onClick={() => setHist({ field: f.key, label: f.label })}>History</Button>
                </div>
              );
            })}
          </dl>
        </Card>

        <Card className="space-y-3">
          <h3 className="font-semibold text-secondary-900">Next actions</h3>
          {(o.next_actions || []).length === 0 && <p className="text-sm text-secondary-500">None. Every opportunity should have one.</p>}
          <ul className="space-y-2">
            {(o.next_actions || []).map((a) => {
              const d = dueText(a.due_at);
              return (
                <li key={a.task_uuid} className="text-sm">
                  <p className="font-medium text-secondary-900">{a.title}</p>
                  <p className={d.overdue ? 'text-xs text-error-600' : 'text-xs text-secondary-500'}>{dateText(a.due_at, true)} ({d.text})</p>
                  {a.reason && <p className="text-xs text-secondary-600">Why: {a.reason}</p>}
                </li>
              );
            })}
          </ul>
          {(o.offers || []).length > 0 && (
            <>
              <h3 className="pt-2 font-semibold text-secondary-900">Offers</h3>
              {(o.offers || []).map((x) => (
                <p key={x.uuid} className="text-sm">{valueText({ field: 'expectation_price', target_table: 'pa_opportunities' }, x.amount)} · {x.response} · {dateText(x.made_at)}</p>
              ))}
            </>
          )}
        </Card>
      </div>

      <PaPanels opportunityId={o.uuid} initial={(['prepare', 'coach', 'ask'].includes(panel || '') ? panel : 'prepare') as Panel} />

      <Card className="space-y-3">
        <h3 className="font-semibold text-secondary-900">Timeline</h3>
        <ol className="space-y-3">
          {(tl || []).map((t) => (
            <li key={`${t.kind}-${t.uuid}`} className="text-sm">
              <div className="flex flex-wrap items-center gap-2">
                <Badge size="sm" variant={t.kind === 'change' ? (t.source === 'ai' ? 'info' : 'secondary') : 'default'}>{t.kind.replace('_', ' ')}</Badge>
                <span className="font-medium text-secondary-900">{t.title}</span>
                <span className="text-xs text-secondary-400">{dateText(t.at, true)}</span>
              </div>
              {t.detail !== null && t.detail !== undefined && t.kind !== 'event' && (
                <p className="mt-0.5 whitespace-pre-wrap text-secondary-600">{typeof t.detail === 'string' ? t.detail : JSON.stringify(t.detail)}</p>
              )}
            </li>
          ))}
        </ol>
      </Card>

      {hist && <HistoryModal oppId={o.uuid} field={hist.field} label={hist.label} onClose={() => setHist(null)} />}
    </div>
  );
}

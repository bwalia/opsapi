'use client';

/**
 * Property PA — Today (HOW-IT-WORKS scene 1; P01/P07): who to focus on, ranked by explainable rules.
 * Each card: who, property, recommended action, why now, objective. "Why #N?" shows every signal with its weight.
 * "I have 30 minutes" packs the list to fit and says what waits.
 */
import React, { useState } from 'react';
import Link from 'next/link';
import { Sunrise, RefreshCw, HelpCircle, NotebookPen, FileText } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { Badge, Button, Card, buttonClass } from '@/components/ui';
import { ErrorNote, Spinner, Empty } from '@/components/property-deals/ui';
import { usePdData } from '@/components/property-deals/usePd';
import { cn } from '@/lib/utils';
import { paService, type TodayCard } from '@/services/property-pa.service';
import PaPage, { usePaCan } from '@/components/property-pa/PaPage';

const BUDGETS = [0, 30, 60, 120];

function Card1({ c, dimmed, canCapture }: { c: TodayCard; dimmed?: boolean; canCapture: boolean }) {
  const [why, setWhy] = useState(false);
  return (
    <Card className={cn('space-y-2', dimmed && 'opacity-60')} data-testid="today-card">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="text-xs font-semibold uppercase tracking-wide text-primary-600">#{c.rank} · {c.kind === 'buy' ? 'Buyer' : 'Seller'}</p>
          <Link href={`/dashboard/property-pa/opportunities/${c.opportunity_uuid}`} className="text-base font-semibold text-secondary-900 hover:underline">
            {c.person_name || c.title}
          </Link>
          {c.property_address && <p className="text-sm text-secondary-500">{c.property_address}</p>}
        </div>
        <Badge variant="info" size="sm">{c.minutes} min</Badge>
      </div>
      <p className="text-sm"><span className="font-medium text-secondary-900">Do: </span>{c.action}</p>
      <p className="text-sm"><span className="font-medium text-secondary-900">Why now: </span>{c.why_now}</p>
      <p className="text-sm"><span className="font-medium text-secondary-900">Aim: </span>{c.objective}</p>
      <div className="flex flex-wrap gap-2 pt-1">
        <Button size="sm" variant="ghost" leftIcon={<HelpCircle className="h-4 w-4" />} onClick={() => setWhy(!why)}>Why #{c.rank}?</Button>
        <Link className={buttonClass('outline', 'sm')} href={`/dashboard/property-pa/opportunities/${c.opportunity_uuid}?panel=prepare`}><FileText className="h-4 w-4" aria-hidden />Prepare me</Link>
        {canCapture && (
          <Link className={buttonClass('outline', 'sm')} href={`/dashboard/property-pa/capture?opportunity=${c.opportunity_uuid}`}><NotebookPen className="h-4 w-4" aria-hidden />Capture</Link>
        )}
      </div>
      {why && (
        <div className="rounded-lg bg-secondary-50 p-3 text-sm" data-testid="why">
          <p className="mb-1 font-medium text-secondary-900">Score {c.score}: the signals behind it</p>
          {c.signals.length === 0 && <p className="text-secondary-500">Nothing pressing.</p>}
          <ul className="space-y-1">
            {c.signals.map((s) => (
              <li key={s.key} className="flex justify-between gap-3">
                <span>{s.text}</span>
                <span className="shrink-0 font-mono text-secondary-500">+{s.weight}</span>
              </li>
            ))}
          </ul>
          <p className="mt-2 text-xs text-secondary-400">The order comes from these rules, not from the AI.</p>
        </div>
      )}
    </Card>
  );
}

export default function PaTodayPage() {
  return (
    <PaPage>
      <PaToday />
    </PaPage>
  );
}

function PaToday() {
  const { can } = usePaCan();
  const canCapture = can('property_pa_records', 'create') && can('property_pa_updates', 'create');
  const [minutes, setMinutes] = useState(0);
  const { data, error, loading, refresh } = usePdData(() => paService.today(minutes || undefined), [minutes], 60_000);
  const fits = new Set((data?.budget?.fits || []).map((c) => c.opportunity_uuid));
  const shown = data?.budget ? data.budget.fits : (data?.cards || []).filter((c) => c.score > 0);
  const quiet = data && !data.budget ? data.cards.filter((c) => c.score === 0) : [];
  return (
    <div className="mx-auto max-w-3xl space-y-6">
      <PageHeader title="Today" description="Who to focus on, and why" icon={<Sunrise className="h-6 w-6" />}
        actions={<Button variant="outline" leftIcon={<RefreshCw className="h-4 w-4" />} onClick={refresh}>Refresh</Button>} />
      <div className="flex flex-wrap items-center gap-2 text-sm">
        <span className="text-secondary-500">I have</span>
        {BUDGETS.map((b) => (
          <Button key={b} size="sm" variant={minutes === b ? 'primary' : 'outline'} onClick={() => setMinutes(b)}>
            {b === 0 ? 'all day' : `${b} minutes`}
          </Button>
        ))}
      </div>
      <ErrorNote product="Property PA" error={error} />
      {loading && !data ? <Spinner /> : !data?.cards.length ? (
        <Empty title="Nothing on your list">Opportunities you own show here, ranked.</Empty>
      ) : (
        <>
          {data.budget && (
            <p className="text-sm text-secondary-600">
              {data.budget.fits.length} fit in {data.budget.minutes} minutes ({data.budget.used} min).
              {data.budget.waits.length ? ` Waiting: ${data.budget.waits.map((w) => w.title.split(' — ')[0]).join(', ')}.` : ''}
            </p>
          )}
          <div className="space-y-3">{shown.map((c) => <Card1 key={c.opportunity_uuid} c={c} canCapture={canCapture} dimmed={!!data.budget && !fits.has(c.opportunity_uuid)} />)}</div>
          {quiet.length > 0 && <p className="text-sm text-secondary-500">Everything else ({quiet.length}) has nothing pressing today.</p>}
        </>
      )}
    </div>
  );
}

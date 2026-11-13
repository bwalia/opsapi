'use client';

/**
 * My Income — one card per income type the workspace offers (Tax → Income types).
 *
 * The user goes through every card for the tax year: add figures (Start / Continue),
 * or say "Not for me". Progress counts a card as reviewed when it's done or not for
 * them. The figures feed the estimate on Reports and File My Tax.
 * Backend: lapis/routes/tax-my-income.lua (GET /api/v2/tax/my-income).
 */

import React, { Suspense, useCallback, useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import { useRouter, useSearchParams } from 'next/navigation';
import { ArrowRight, Building2, ChevronDown, Info, Loader2, RefreshCw, Undo2, Wallet } from 'lucide-react';
import toast from 'react-hot-toast';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { IncomeIcon } from '@/components/tax/income/IncomeIcon';
import StatusBadge from '@/components/tax/income/StatusBadge';
import { extractApiError, formatCurrency } from '@/lib/utils';
import {
  countOf,
  currentFilingYear,
  myIncomeService,
  recentTaxYears,
  type IncomeOverview,
  type OverviewCard,
} from '@/services/my-income.service';

const gbp = (n: number) => formatCurrency(n, 'GBP', 'en-GB');

function yearLabel(y: string) {
  const s = Number(y.slice(0, 4));
  return `${y} (6 April ${s} – 5 April ${s + 1})`;
}

function TotalsLine({ card }: { card: OverviewCard }) {
  const t = card.totals;
  const parts: string[] = [];
  if (t.income) parts.push(`Income ${gbp(t.income)}`);
  if (t.expense) parts.push(`Costs ${gbp(t.expense)}`);
  if (t.tax_paid) parts.push(`Tax paid ${gbp(t.tax_paid)}`);
  if (t.relief) parts.push(`Reliefs ${gbp(t.relief)}`);
  if (!parts.length) return null;
  return <p className="text-sm font-medium tabular-nums text-secondary-800">{parts.join(' · ')}</p>;
}

function IncomeCard({
  card,
  taxYear,
  busy,
  onNotForMe,
}: {
  card: OverviewCard;
  taxYear: string;
  busy: boolean;
  onNotForMe: (card: OverviewCard, on: boolean) => void;
}) {
  const href = `/dashboard/tax/income/${encodeURIComponent(card.key)}?tax_year=${taxYear}`;
  const action = card.status === 'not_started' ? 'Start' : card.status === 'done' ? 'Review' : 'Continue';
  const entityWord = card.entity_label || 'item';
  return (
    <li className="flex flex-col rounded-xl border border-secondary-200 bg-surface p-5 shadow-sm transition-colors hover:border-primary-300">
      <div className="flex items-start gap-3">
        <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-primary-500/10 text-primary-600">
          <IncomeIcon name={card.icon} />
        </span>
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <h3 className="font-semibold text-secondary-900">{card.name}</h3>
            <StatusBadge status={card.status} />
          </div>
          {card.description && <p className="mt-1 text-sm text-secondary-500">{card.description}</p>}
        </div>
      </div>
      <div className="mt-3 space-y-1">
        <TotalsLine card={card} />
        {card.entity_type && card.entity_count > 0 && (
          <p className="text-xs text-secondary-500">
            {countOf(card.entity_count, entityWord)} · {card.done_count} done
          </p>
        )}
        {card.schedule && <p className="text-xs text-secondary-400">Goes on {card.schedule}</p>}
      </div>
      <div className="mt-4 flex flex-wrap items-center gap-2 pt-1">
        {card.status === 'not_applicable' ? (
          <button
            type="button"
            disabled={busy}
            onClick={() => onNotForMe(card, false)}
            className="inline-flex items-center gap-1.5 rounded-lg px-3 py-2 text-sm font-medium text-secondary-600 hover:bg-secondary-100"
          >
            <Undo2 className="h-4 w-4" aria-hidden="true" /> I did have this
          </button>
        ) : (
          <>
            <Link
              href={href}
              className="inline-flex items-center gap-1.5 rounded-lg bg-primary-600 px-4 py-2 text-sm font-medium text-white hover:bg-primary-700"
              aria-label={`${action} ${card.name}`}
            >
              {action} <ArrowRight className="h-4 w-4" aria-hidden="true" />
            </Link>
            {card.status === 'not_started' && (
              <button
                type="button"
                disabled={busy}
                onClick={() => onNotForMe(card, true)}
                className="rounded-lg px-3 py-2 text-sm font-medium text-secondary-600 hover:bg-secondary-100"
                aria-label={`I didn't have ${card.name} in ${taxYear}`}
              >
                Not for me
              </button>
            )}
          </>
        )}
      </div>
    </li>
  );
}

function MyIncomeContent() {
  const router = useRouter();
  const params = useSearchParams();
  const years = useMemo(() => recentTaxYears(), []);
  const [taxYear, setTaxYear] = useState(() => {
    const y = params.get('tax_year');
    return y && /^\d{4}-\d{2}$/.test(y) ? y : currentFilingYear();
  });
  const [data, setData] = useState<IncomeOverview | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busyKey, setBusyKey] = useState<string | null>(null);
  const [showNotForMe, setShowNotForMe] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      setData(await myIncomeService.overview(taxYear));
    } catch (e) {
      setError(extractApiError(e, 'Could not load your income. Please try again.'));
    } finally {
      setLoading(false);
    }
  }, [taxYear]);

  useEffect(() => {
    load();
  }, [load]);

  const changeYear = (y: string) => {
    setTaxYear(y);
    router.replace(`/dashboard/tax/income?tax_year=${y}`);
  };

  const notForMe = async (card: OverviewCard, on: boolean) => {
    setBusyKey(card.key);
    try {
      await myIncomeService.setNotApplicable(card.key, taxYear, on);
      toast.success(on ? `${card.name}: marked as not for you` : `${card.name}: back on your list`);
      await load();
    } catch (e) {
      toast.error(extractApiError(e, 'Could not update that. Please try again.'));
    } finally {
      setBusyKey(null);
    }
  };

  const cards = data?.types ?? [];
  const yours = cards.filter((c) => c.status === 'in_progress' || c.status === 'done');
  const todo = cards.filter((c) => c.status === 'not_started');
  const notMine = cards.filter((c) => c.status === 'not_applicable');
  const progress = data?.progress ?? { reviewed: 0, total: 0, started: 0 };
  const pct = progress.total ? Math.round((progress.reviewed / progress.total) * 100) : 0;
  const allReviewed = progress.total > 0 && progress.reviewed === progress.total;

  return (
    <div className="space-y-6">
      <PageHeader
        title="My Income"
        description="Tell us about each kind of income you had in the tax year. We use it to work out your tax."
        icon={<Wallet className="h-5 w-5" />}
        actions={
          <button
            type="button"
            onClick={load}
            className="flex items-center gap-2 rounded-lg px-3 py-2 text-secondary-600 hover:bg-secondary-100 hover:text-secondary-900"
          >
            <RefreshCw className="h-4 w-4" aria-hidden="true" /> Refresh
          </button>
        }
      />

      <div className="flex flex-col gap-4 rounded-xl border border-secondary-200 bg-surface p-5 shadow-sm md:flex-row md:items-center md:justify-between">
        <div className="space-y-1">
          <label htmlFor="tax-year" className="text-sm font-medium text-secondary-700">
            Tax year
          </label>
          <select
            id="tax-year"
            value={taxYear}
            onChange={(e) => changeYear(e.target.value)}
            className="block w-full rounded-lg border border-secondary-300 bg-surface px-3 py-2 text-secondary-900 md:w-80"
          >
            {years.map((y) => (
              <option key={y} value={y}>
                {yearLabel(y)}
              </option>
            ))}
          </select>
        </div>
        <div className="w-full md:max-w-sm">
          <div className="flex items-baseline justify-between text-sm">
            <span className="font-medium text-secondary-800">
              {progress.reviewed} of {progress.total} income types reviewed
            </span>
            <span className="tabular-nums text-secondary-500">{pct}%</span>
          </div>
          <div
            className="mt-2 h-2.5 w-full overflow-hidden rounded-full bg-secondary-100"
            role="progressbar"
            aria-valuemin={0}
            aria-valuemax={progress.total}
            aria-valuenow={progress.reviewed}
            aria-label="Income types reviewed"
          >
            <div className="h-full rounded-full bg-primary-600 transition-all" style={{ width: `${pct}%` }} />
          </div>
          <p className="mt-2 text-xs text-secondary-500">
            {allReviewed
              ? 'All done for this year. Your figures are in your estimate.'
              : 'Open each one you had, or choose “Not for me”.'}
          </p>
        </div>
      </div>

      {loading && !data ? (
        <div className="flex items-center justify-center gap-2 py-16 text-secondary-500">
          <Loader2 className="h-5 w-5 animate-spin" aria-hidden="true" /> Loading your income…
        </div>
      ) : error ? (
        <div role="alert" className="rounded-xl border border-red-200 bg-red-50 p-5 text-sm text-red-800">
          {error}{' '}
          <button type="button" onClick={load} className="font-medium underline">
            Try again
          </button>
        </div>
      ) : cards.length === 0 ? (
        <div className="rounded-xl border border-dashed border-secondary-300 p-10 text-center">
          <Info className="mx-auto h-6 w-6 text-secondary-400" aria-hidden="true" />
          <p className="mt-2 font-medium text-secondary-800">No income types are set up for this workspace yet.</p>
          <p className="mt-1 text-sm text-secondary-500">Ask your administrator to add them under Tax → Income types.</p>
        </div>
      ) : (
        <>
          {yours.length > 0 && (
            <section aria-labelledby="yours-h" className="space-y-3">
              <h2 id="yours-h" className="text-lg font-semibold text-secondary-900">
                Your income in {taxYear}
              </h2>
              <ul className="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
                {yours.map((c) => (
                  <IncomeCard key={c.key} card={c} taxYear={taxYear} busy={busyKey === c.key} onNotForMe={notForMe} />
                ))}
              </ul>
            </section>
          )}

          {todo.length > 0 && (
            <section aria-labelledby="todo-h" className="space-y-3">
              <div>
                <h2 id="todo-h" className="text-lg font-semibold text-secondary-900">
                  {yours.length ? 'Did you have any of these too?' : 'Which of these did you have?'}
                </h2>
                <p className="text-sm text-secondary-500">
                  Start the ones you had. For the rest, choose “Not for me” so we know you’ve checked.
                </p>
              </div>
              <ul className="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
                {todo.map((c) => (
                  <IncomeCard key={c.key} card={c} taxYear={taxYear} busy={busyKey === c.key} onNotForMe={notForMe} />
                ))}
              </ul>
            </section>
          )}

          {notMine.length > 0 && (
            <section aria-labelledby="notmine-h" className="space-y-3">
              <h2 id="notmine-h">
                <button
                  type="button"
                  aria-expanded={showNotForMe}
                  onClick={() => setShowNotForMe((v) => !v)}
                  className="flex items-center gap-2 text-sm font-medium text-secondary-600 hover:text-secondary-900"
                >
                  <ChevronDown className={`h-4 w-4 transition-transform ${showNotForMe ? 'rotate-180' : ''}`} aria-hidden="true" />
                  Not for you ({notMine.length})
                </button>
              </h2>
              {showNotForMe && (
                <ul className="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
                  {notMine.map((c) => (
                    <IncomeCard key={c.key} card={c} taxYear={taxYear} busy={busyKey === c.key} onNotForMe={notForMe} />
                  ))}
                </ul>
              )}
            </section>
          )}

          <div className="flex flex-col gap-3 rounded-xl border border-primary-200 bg-primary-50 p-5 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h2 className="font-semibold text-secondary-900">What happens next</h2>
              <p className="mt-0.5 text-sm text-secondary-600">
                Your figures go straight into your tax estimate. When you’ve reviewed everything, check the estimate and
                file in File My Tax.
              </p>
            </div>
            <Link
              href={`/dashboard/tax/file?tax_year=${taxYear}`}
              className="inline-flex shrink-0 items-center justify-center gap-2 rounded-lg border border-primary-300 bg-surface px-4 py-2 text-sm font-medium text-primary-700 hover:bg-primary-100"
            >
              <Building2 className="h-4 w-4" aria-hidden="true" /> Go to File My Tax
            </Link>
          </div>
        </>
      )}
    </div>
  );
}

export default function MyIncomePage() {
  return (
    <ProtectedPage module="tax_statements" title="My Income">
      <Suspense fallback={null}>
        <MyIncomeContent />
      </Suspense>
    </ProtectedPage>
  );
}

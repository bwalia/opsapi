'use client';

import React, { useEffect, useState } from 'react';
import { ClipboardList, Info } from 'lucide-react';
import { Button, Card } from '@/components/ui';
import { SectionTitle } from '@/components/shop/shared';
import { BarList, Funnel, Stat, count, pct } from '@/components/shop/analytics/parts';
import { shopAnalyticsService } from '@/services/shop-analytics.service';
import { extractApiError } from '@/lib/utils';
import { SURVEY_QUESTION_ORDER, SURVEY_STAGES, answerLabel, productLabel, questionLabel } from '@/lib/shop-survey';
import type { ShopAnalyticsQuery, ShopSurveyReport } from '@/types/shop-analytics';

/** Shop → Analytics: the "What do I need?" survey funnel, where people stop, and what they answer. */
export function SurveyPanel({ query, version }: { query: ShopAnalyticsQuery; version: number }) {
  const [report, setReport] = useState<ShopSurveyReport | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [retry, setRetry] = useState(0);

  useEffect(() => {
    const ctrl = new AbortController();
    shopAnalyticsService
      .getSurvey(query, ctrl.signal)
      .then((res) => {
        setReport(res);
        setError(null);
      })
      .catch((err) => !ctrl.signal.aborted && setError(extractApiError(err, 'Could not load the survey report')))
      .finally(() => !ctrl.signal.aborted && setLoading(false));
    return () => ctrl.abort();
  }, [query, version, retry]);

  const title = <SectionTitle>“What do I need?” survey</SectionTitle>;

  if (loading && !report) {
    return (
      <Card>
        {title}
        <p className="py-6 text-center text-sm text-secondary-500">Loading the survey…</p>
      </Card>
    );
  }
  if (error || !report) {
    return (
      <Card>
        {title}
        <div className="flex flex-col items-center gap-3 py-6 text-center">
          <p className="text-sm text-secondary-600">{error ?? 'Could not load the survey report'}</p>
          <Button size="sm" variant="outline" onClick={() => { setError(null); setLoading(true); setReport(null); setRetry((n) => n + 1); }}>Try again</Button>
        </div>
      </Card>
    );
  }

  const r = report;
  const empty = Object.values(r.visitors).every((v) => !v);
  const answers = [...r.answers].sort(
    (a, b) => (SURVEY_QUESTION_ORDER.indexOf(a.question) + 1 || 99) - (SURVEY_QUESTION_ORDER.indexOf(b.question) + 1 || 99)
  );

  if (empty) {
    return (
      <Card className="border-dashed">
        <div className="flex items-start gap-3">
          <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-secondary-100 text-secondary-500">
            <ClipboardList className="h-4 w-4" />
          </span>
          <div>
            <h2 className="text-base font-semibold text-secondary-900">“What do I need?” survey: no visits in this period</h2>
            <p className="mt-1 text-sm text-secondary-600">
              The shop only starts sending survey steps after the privacy sign-off. Until then this stays empty. People who send
              their build still appear in Leads, with their answers.
            </p>
            {r.trade_signups && (
              <p className="mt-2 text-xs text-secondary-500">
                Trade in this period: {count(r.trade_signups.checkouts_started)} started joining, {count(r.trade_signups.joined)} joined.
              </p>
            )}
          </div>
        </div>
      </Card>
    );
  }

  return (
    <div className="space-y-6">
      <div className="grid grid-cols-1 gap-6 xl:grid-cols-3">
        <Card className="xl:col-span-2">
          {title}
          <Funnel
            steps={r.funnel.map((f) => ({ label: SURVEY_STAGES[f.stage] ?? f.stage, value: f.visitors }))}
          />
          {r.dropoff.length > 0 && (
            <>
              <h3 className="mb-2 mt-6 text-sm font-medium text-secondary-700">Where people stop</h3>
              <ol className="divide-y divide-secondary-100 text-sm">
                {r.dropoff.map((s) => (
                  <li key={String(s.step)} className="flex items-baseline justify-between gap-3 py-2">
                    <span className="min-w-0 text-secondary-800">
                      {s.step !== null && <span className="mr-2 text-xs text-secondary-500">Step {s.step}</span>}
                      {s.questions.map((q) => questionLabel(q.question)).join(' / ')}
                    </span>
                    <span className="shrink-0 tabular-nums text-secondary-900">
                      {count(s.visitors)}
                      {s.lost_from_previous != null && s.lost_from_previous > 0 && (
                        <span className="ml-2 text-xs text-error-600">{pct(s.lost_from_previous)} stopped</span>
                      )}
                    </span>
                  </li>
                ))}
              </ol>
              <p className="mt-2 text-xs text-secondary-500">People who answered each question, and the share who stopped since the step before.</p>
            </>
          )}
        </Card>

        <div className="space-y-6">
          <Card>
            <SectionTitle>Recommended</SectionTitle>
            <BarList
              empty="No recommendations shown"
              rows={r.results_by_product.slice(0, 6).map((p) => ({ key: p.product, label: productLabel(p.product), value: p.visitors }))}
            />
          </Card>
          <Card>
            <SectionTitle>Trade</SectionTitle>
            <div className="grid grid-cols-2 gap-2">
              <Stat label="Started from the survey" value={count(r.apply_by_plan.total)} />
              <Stat label="Yearly / monthly" value={`${count(r.apply_by_plan.y)} / ${count(r.apply_by_plan.m)}`} />
              {r.trade_signups && (
                <>
                  <Stat label="All Trade checkouts" value={count(r.trade_signups.checkouts_started)} hint="Every Trade checkout in the period, survey or not" />
                  <Stat label="Joined" value={count(r.trade_signups.joined)} hint="Every Trade join in the period, survey or not" />
                </>
              )}
            </div>
          </Card>
        </div>
      </div>

      {answers.length > 0 && (
        <Card>
          <SectionTitle>What people answered</SectionTitle>
          <div className="grid gap-x-8 gap-y-6 md:grid-cols-2 xl:grid-cols-3">
            {answers.map((q) => (
              <div key={q.question}>
                <h3 className="mb-1 text-sm font-medium text-secondary-800">{questionLabel(q.question)}</h3>
                <BarList
                  empty="No answers"
                  rows={q.answers.slice(0, 5).map((a) => ({ key: a.answer, label: answerLabel(q.question, a.answer), value: a.visitors }))}
                />
              </div>
            ))}
          </div>
          <p className="mt-4 text-xs text-secondary-500">Each person’s final answer, if they went back and changed it.</p>
        </Card>
      )}

      {!r.complete && (
        <p className="flex gap-1.5 text-xs text-secondary-500">
          <Info className="mt-px h-3.5 w-3.5 shrink-0" aria-hidden="true" />
          Survey steps are kept for {r.retention_months} months, so older parts of this period are missing.
        </p>
      )}
    </div>
  );
}

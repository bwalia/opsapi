'use client';

/**
 * The Insights tab: how the form performs (views → starts → responses, per day,
 * the step funnel, where responses come from) and what people answered (exact
 * counts per question, plus an AI-written summary on demand).
 */

import React, { useCallback, useEffect, useState } from 'react';
import toast from 'react-hot-toast';
import { Area, AreaChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts';
import { Eye, Loader2, MousePointerClick, Send, Sparkles, Timer } from 'lucide-react';
import { Button, Card, Select } from '@/components/ui';
import { apiError } from '@/components/field-service/shared';
import { formsService, type Analytics, type ResponseSummary } from '@/services/forms.service';

function Stat({ icon: Icon, label, value, hint }: {
  icon: React.ComponentType<{ className?: string }>; label: string; value: string; hint?: string;
}) {
  return (
    <Card padding="sm">
      <div className="flex items-center gap-2 text-xs font-medium uppercase tracking-wide text-secondary-500">
        <Icon className="h-4 w-4" aria-hidden="true" />{label}
      </div>
      <p className="mt-1.5 text-2xl font-bold text-secondary-900">{value}</p>
      {hint && <p className="text-xs text-secondary-500">{hint}</p>}
    </Card>
  );
}

function Bar({ label, value, max, suffix }: { label: string; value: number; max: number; suffix?: string }) {
  const pct = max > 0 ? Math.round((value / max) * 100) : 0;
  return (
    <div>
      <div className="mb-1 flex justify-between gap-3 text-sm">
        <span className="truncate text-secondary-700">{label}</span>
        <span className="shrink-0 font-medium text-secondary-900">{value}{suffix}</span>
      </div>
      <div className="h-2 overflow-hidden rounded-full bg-secondary-100">
        <div className="h-full rounded-full bg-primary-500" style={{ width: `${pct}%` }} />
      </div>
    </div>
  );
}

export default function FormInsights({ formUuid }: { formUuid: string }) {
  const [days, setDays] = useState(30);
  const [data, setData] = useState<Analytics | null>(null);
  const [summary, setSummary] = useState<ResponseSummary | null>(null);
  const [summarising, setSummarising] = useState(false);

  const load = useCallback(() => {
    setData(null);
    formsService.analytics(formUuid, days).then(setData).catch((e) => toast.error(apiError(e, 'Could not load insights')));
  }, [formUuid, days]);
  useEffect(() => { load(); }, [load]);

  const summarise = async () => {
    setSummarising(true);
    try {
      setSummary(await formsService.summary(formUuid));
    } catch (e) {
      toast.error(apiError(e, 'Could not summarise'));
    } finally {
      setSummarising(false);
    }
  };

  if (!data) {
    return <div className="grid h-48 place-items-center" aria-busy="true"><Loader2 className="h-6 w-6 animate-spin text-secondary-400" /></div>;
  }
  const t = data.totals;
  const funnelMax = Math.max(1, ...data.funnel.map((f) => f.reached));
  const sourceMax = Math.max(1, ...data.sources.map((s) => s.responses));

  return (
    <div className="space-y-5">
      <div className="flex items-center justify-between gap-3">
        <h2 className="text-base font-semibold text-secondary-900">Performance</h2>
        <div className="w-40">
          <Select aria-label="Period" value={String(days)} onChange={(e) => setDays(Number(e.target.value))}>
            <option value="7">Last 7 days</option>
            <option value="30">Last 30 days</option>
            <option value="90">Last 90 days</option>
            <option value="365">Last year</option>
          </Select>
        </div>
      </div>

      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat icon={Eye} label="Views" value={String(t.views)} />
        <Stat icon={MousePointerClick} label="Started" value={String(t.starts)}
          hint={t.completion !== undefined && t.completion !== null ? `${t.completion}% of them finished` : undefined} />
        <Stat icon={Send} label="Responses" value={String(t.responses)}
          hint={t.conversion !== undefined && t.conversion !== null ? `${t.conversion}% of views` : undefined} />
        <Stat icon={Timer} label="Time to fill in" value={t.avg_seconds ? `${t.avg_seconds} s` : '—'} hint="average" />
      </div>

      <Card padding="md">
        <h3 className="mb-3 text-sm font-semibold text-secondary-900">Per day</h3>
        <div className="h-60" aria-label="Views and responses per day">
          <ResponsiveContainer width="100%" height="100%">
            <AreaChart data={data.series} margin={{ left: -20, right: 8, top: 4 }}>
              <CartesianGrid strokeDasharray="3 3" className="stroke-secondary-200" />
              <XAxis dataKey="day" tick={{ fontSize: 11 }} tickFormatter={(d: string) => d.slice(5)} minTickGap={24} />
              <YAxis allowDecimals={false} tick={{ fontSize: 11 }} />
              <Tooltip />
              <Area type="monotone" dataKey="views" name="Views" stroke="#94a3b8" fill="#94a3b8" fillOpacity={0.15} />
              <Area type="monotone" dataKey="responses" name="Responses" stroke="var(--color-primary-500)"
                fill="var(--color-primary-500)" fillOpacity={0.25} />
            </AreaChart>
          </ResponsiveContainer>
        </div>
      </Card>

      <div className="grid gap-5 lg:grid-cols-2">
        <Card padding="md">
          <h3 className="mb-3 text-sm font-semibold text-secondary-900">Where people stop</h3>
          {data.funnel.length > 1 || t.starts > 0 ? (
            <div className="space-y-3">
              {data.funnel.map((f) => <Bar key={f.step} label={`Step ${f.step}`} value={f.reached} max={funnelMax} />)}
              <Bar label="Sent" value={t.responses} max={funnelMax} />
            </div>
          ) : <p className="text-sm text-secondary-500">No visits yet.</p>}
        </Card>
        <Card padding="md">
          <h3 className="mb-3 text-sm font-semibold text-secondary-900">Where responses come from</h3>
          {data.sources.length ? (
            <div className="space-y-3">
              {data.sources.map((s) => <Bar key={s.source} label={s.source} value={s.responses} max={sourceMax} />)}
            </div>
          ) : <p className="text-sm text-secondary-500">No responses yet.</p>}
        </Card>
      </div>

      <Card padding="md">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h3 className="text-sm font-semibold text-secondary-900">What people said</h3>
            <p className="text-xs text-secondary-500">Counts are exact; the summary is written by AI from the latest 500 responses, without contact details.</p>
          </div>
          <Button variant="outline" leftIcon={<Sparkles className="h-4 w-4" />} isLoading={summarising} onClick={summarise}>
            {summary ? 'Summarise again' : 'Summarise with AI'}
          </Button>
        </div>
        {summary && (
          <div className="mt-4 space-y-5">
            {summary.summary ? (
              <div className="whitespace-pre-line rounded-lg bg-primary-500/5 p-4 text-sm leading-relaxed text-secondary-800">{summary.summary}</div>
            ) : (
              <p className="text-sm text-warning-600">{summary.summary_error || 'No summary this time.'}</p>
            )}
            <div className="grid gap-5 md:grid-cols-2">
              {summary.fields.filter((f) => f.counts || f.average !== undefined).map((f) => {
                const counts = Object.entries(f.counts || {}).sort((a, b) => b[1] - a[1]);
                const max = Math.max(1, ...counts.map(([, n]) => n));
                return (
                  <div key={f.key}>
                    <p className="mb-2 text-sm font-medium text-secondary-900">{f.label}</p>
                    {f.average !== undefined && (
                      <p className="text-sm text-secondary-600">Average <strong>{f.average}</strong> (from {f.min} to {f.max}, {f.answered} answers)</p>
                    )}
                    <div className="space-y-2">
                      {counts.map(([label, n]) => <Bar key={label} label={label} value={n} max={max} />)}
                    </div>
                  </div>
                );
              })}
            </div>
          </div>
        )}
      </Card>
    </div>
  );
}

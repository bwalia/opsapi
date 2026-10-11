'use client';

/**
 * Property PA — Insights (managers): is the PA working (capture accuracy, grounded answers, speed,
 * follow-through), the go-live checklist, integrations, and the AI change history (P10: every AI change with its
 * source, model, prompt version and who confirmed it).
 */
import React from 'react';
import { BarChart3, CheckCircle2, XCircle, Mail, Users, RefreshCw } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Badge, Button, Card } from '@/components/ui';
import { ErrorNote, Spinner, Stat, dateText } from '@/components/property-deals/ui';
import { usePdData } from '@/components/property-deals/usePd';
import { paService } from '@/services/property-pa.service';
import { pdErrorText } from '@/services/property-deals.service';

const pct = (v: number | null | undefined) => (v === null || v === undefined ? '—' : `${Math.round(v * 100)}%`);
const secs = (v: number | null | undefined) => (v === null || v === undefined ? '—' : v < 120 ? `${v}s` : `${Math.round(v / 60)} min`);

export default function InsightsPage() {
  const metrics = usePdData(() => paService.metrics(30), []);
  const status = usePdData(() => paService.status(), []);
  const audit = usePdData(() => paService.audit({ per_page: 50 }), []);
  const m = metrics.data;
  const run = async (fn: () => Promise<unknown>, done: (r: never) => string) => {
    try {
      const r = await fn();
      toast.success(done(r as never));
      audit.refresh();
    } catch (e) {
      toast.error(pdErrorText(e));
    }
  };
  return (
    <div className="space-y-6">
      <PageHeader title="PA insights" description="Is the PA helping? Last 30 days" icon={<BarChart3 className="h-6 w-6" />}
        actions={<Button variant="outline" leftIcon={<RefreshCw className="h-4 w-4" />} onClick={() => { metrics.refresh(); status.refresh(); audit.refresh(); }}>Refresh</Button>} />
      <ErrorNote error={metrics.error} />
      {metrics.loading && !m ? <Spinner /> : m && (
        <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
          <Stat label="Notes captured" value={m.capture.captures} hint={`${m.capture.proposals} changes proposed, ${m.capture.waiting} waiting`} />
          <Stat label="Accepted as proposed" value={pct(m.capture.accepted_as_proposed)} hint={`corrected ${pct(m.capture.correction_rate)} · rejected ${pct(m.capture.rejection_rate)}`} />
          <Stat label="Answers grounded" value={pct(m.answers.grounded_rate)} hint={`${m.answers.withheld} withheld · ${m.answers.failed} failed`}
            tone={m.answers.withheld ? 'warning' : undefined} />
          <Stat label="PA answer time" value={secs(m.answers.p50_seconds)} hint={`90% within ${secs(m.answers.p90_seconds)}`} />
          <Stat label="Next actions overdue" value={m.follow_through.next_actions_overdue} tone={m.follow_through.next_actions_overdue ? 'error' : 'success'}
            hint={`${m.follow_through.next_actions_open} open · ${m.follow_through.next_actions_done} done`} />
          <Stat label="Gone quiet (14d+)" value={m.follow_through.opportunities_gone_quiet} tone={m.follow_through.opportunities_gone_quiet ? 'warning' : undefined} />
          <Stat label="Handoffs" value={m.handoffs.total} hint={`${m.handoffs.waiting} waiting · reply in ${secs(m.handoffs.median_seconds_to_reply)}`} />
          <Stat label="Time to confirm" value={secs(m.capture.median_seconds_to_confirm)} hint="From proposal to decision" />
        </div>
      )}

      <div className="grid gap-6 lg:grid-cols-2">
        <Card className="space-y-2">
          <h3 className="font-semibold text-secondary-900">Go-live checklist {status.data && <Badge size="sm" variant={status.data.ready ? 'success' : 'warning'} className="ml-2">{status.data.ready ? 'ready' : 'not ready'}</Badge>}</h3>
          <ErrorNote error={status.error} />
          <ul className="space-y-1 text-sm">
            {(status.data?.checks || []).map((c) => (
              <li key={c.key} className="flex items-start gap-2">
                {c.ok ? <CheckCircle2 className="mt-0.5 h-4 w-4 text-success-600" /> : <XCircle className={`mt-0.5 h-4 w-4 ${c.optional ? 'text-secondary-400' : 'text-error-600'}`} />}
                <span>{c.text}{!c.ok && <span className="text-secondary-500"> — {c.fix}{c.optional ? ' (optional)' : ''}</span>}</span>
              </li>
            ))}
          </ul>
        </Card>
        <Card className="space-y-3">
          <h3 className="font-semibold text-secondary-900">Integrations</h3>
          <p className="text-sm text-secondary-600">Inbound email from people you work with goes onto their timeline every 5 minutes; GoHighLevel contacts are pulled every hour.</p>
          <div className="flex flex-wrap gap-2">
            <Button size="sm" variant="outline" leftIcon={<Mail className="h-4 w-4" />}
              onClick={() => run(paService.importMail, (r: { imported: number }) => `${r.imported} email(s) added to timelines`)}>Import email now</Button>
            <Button size="sm" variant="outline" leftIcon={<Users className="h-4 w-4" />}
              onClick={() => run(paService.syncGhl, (r: { created: number; updated: number }) => `GoHighLevel: ${r.created} new, ${r.updated} updated`)}>Sync GoHighLevel now</Button>
          </div>
        </Card>
      </div>

      <Card className="space-y-2">
        <h3 className="font-semibold text-secondary-900">AI change history</h3>
        <p className="text-xs text-secondary-500">Every change the PA made: where it came from, the model and prompt version, and who confirmed it.</p>
        <ErrorNote error={audit.error} />
        <div className="overflow-x-auto">
          <table className="min-w-full text-sm">
            <thead className="text-left text-xs text-secondary-500">
              <tr><th className="py-1 pr-3">When</th><th className="pr-3">Field</th><th className="pr-3">Value</th><th className="pr-3">Model · prompt</th><th className="pr-3">Confirmed by</th><th /></tr>
            </thead>
            <tbody className="divide-y divide-secondary-100">
              {(audit.data || []).map((a) => (
                <tr key={a.uuid} className={a.superseded ? 'opacity-60' : ''}>
                  <td className="py-1 pr-3 whitespace-nowrap">{dateText(a.created_at, true)}</td>
                  <td className="pr-3">{a.target_table.replace(/^pa_/, '').replace(/_/g, ' ')}.{a.field}</td>
                  <td className="max-w-xs truncate pr-3">{typeof a.value === 'object' ? JSON.stringify(a.value) : String(a.value ?? '—')}{a.is_inferred && <Badge size="sm" variant="warning" className="ml-1">inferred</Badge>}</td>
                  <td className="pr-3 text-xs">{a.model || '—'}{a.prompt_version ? ` · ${a.prompt_version}` : ''}</td>
                  <td className="pr-3">{a.confirmed_by_name || <span className="text-warning-600">not confirmed</span>}</td>
                  <td className="text-xs text-secondary-400">{a.superseded ? 'replaced' : 'current'}</td>
                </tr>
              ))}
            </tbody>
          </table>
          {audit.data && !audit.data.length && <p className="py-2 text-sm text-secondary-500">No AI changes yet.</p>}
        </div>
      </Card>
    </div>
  );
}

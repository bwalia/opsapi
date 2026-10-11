'use client';

/**
 * Property PA — Manager Today (HOW-IT-WORKS scenes 5 and 10): exceptions only. Decision cards for handoffs
 * ([Agree] [Reply] [Open deal]); unusual negotiations, relationship and deal risks, overdue actions and the top
 * opportunities. Everything else is being handled.
 */
import React, { useState } from 'react';
import Link from 'next/link';
import { ShieldCheck, Check, Reply, ExternalLink, RefreshCw } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, Card, Textarea } from '@/components/ui';
import { ErrorNote, Spinner, dateText } from '@/components/property-deals/ui';
import { usePdData } from '@/components/property-deals/usePd';
import { paService, type Handoff, type RefItem } from '@/services/property-pa.service';
import { pdErrorText } from '@/services/property-deals.service';

const opp = (id?: string | null) => (id ? `/dashboard/property-pa/opportunities/${id}` : '#');

function DecisionCard({ h, onDone }: { h: Handoff; onDone: () => void }) {
  const [replying, setReplying] = useState(false);
  const [text, setText] = useState('');
  const [busy, setBusy] = useState(false);
  const send = async (reply: string, decision?: string) => {
    setBusy(true);
    try {
      await paService.reply(h.uuid, reply, decision);
      toast.success('Sent. It goes back onto the deal.');
      onDone();
    } catch (e) {
      toast.error(pdErrorText(e));
    } finally {
      setBusy(false);
    }
  };
  return (
    <Card className="space-y-2" data-testid="decision-card">
      <p className="text-xs text-secondary-500">{h.from_name} asks · {dateText(h.created_at, true)}{h.opportunity_title ? ` · ${h.opportunity_title}` : ''}</p>
      <p className="font-medium text-secondary-900">{h.question}</p>
      {h.pa_recommendation && <p className="text-sm text-secondary-700"><span className="font-medium">PA recommends:</span> {h.pa_recommendation}</p>}
      {h.context && Object.keys(h.context).length > 0 && (
        <p className="text-xs text-secondary-500">Context: {Object.entries(h.context).map(([k, v]) => `${k.replace(/_/g, ' ')}: ${String(v)}`).join(' · ')}</p>
      )}
      {replying && <Textarea rows={2} value={text} onChange={(e) => setText(e.target.value)} placeholder="Your answer" />}
      <div className="flex flex-wrap gap-2">
        {h.pa_recommendation && !replying && (
          <Button size="sm" leftIcon={<Check className="h-4 w-4" />} isLoading={busy}
            onClick={() => send(`Agreed: ${h.pa_recommendation}`, h.pa_recommendation || undefined)}>Agree</Button>
        )}
        {replying ? (
          <Button size="sm" isLoading={busy} disabled={!text.trim()} onClick={() => send(text.trim())}>Send reply</Button>
        ) : (
          <Button size="sm" variant="outline" leftIcon={<Reply className="h-4 w-4" />} onClick={() => setReplying(true)}>Reply</Button>
        )}
        {h.opportunity_uuid && <Link href={opp(h.opportunity_uuid)}><Button size="sm" variant="ghost" leftIcon={<ExternalLink className="h-4 w-4" />}>Open deal</Button></Link>}
      </div>
    </Card>
  );
}

function List({ title, items, render }: { title: string; items: RefItem[]; render: (x: RefItem) => React.ReactNode }) {
  if (!items.length) return null;
  return (
    <Card className="space-y-2">
      <h3 className="font-semibold text-secondary-900">{title}</h3>
      <ul className="space-y-1 text-sm">{items.map((x, i) => <li key={`${x.opportunity_uuid || x.uuid}-${i}`}>{render(x)}</li>)}</ul>
    </Card>
  );
}

export default function ManagerTodayPage() {
  const { data, error, loading, refresh } = usePdData(() => paService.managerToday(), [], 60_000);
  return (
    <div className="mx-auto max-w-3xl space-y-6">
      <PageHeader title="Manager today" description="Only what needs you" icon={<ShieldCheck className="h-6 w-6" />}
        actions={<Button variant="outline" leftIcon={<RefreshCw className="h-4 w-4" />} onClick={refresh}>Refresh</Button>} />
      <ErrorNote error={error} />
      {loading && !data ? <Spinner /> : data && (
        <>
          <p className="text-base font-medium text-secondary-900">{data.summary}</p>
          {data.handoffs.length > 0 && (
            <div className="space-y-3">
              <h3 className="font-semibold text-secondary-900">Decisions waiting ({data.handoffs.length})</h3>
              {data.handoffs.map((h) => <DecisionCard key={h.uuid} h={h} onDone={refresh} />)}
            </div>
          )}
          <List title="Unusual negotiations" items={data.unusual_negotiations}
            render={(x) => <Link className="hover:underline" href={opp(x.opportunity_uuid)}><span className="font-medium">{x.title}:</span> {x.text}</Link>} />
          <List title="Relationship risks" items={data.relationship_risks}
            render={(x) => <Link className="hover:underline" href={opp(x.uuid)}>{x.text}{x.owner_name ? ` · ${x.owner_name}` : ''}</Link>} />
          <List title="Overdue next actions" items={data.overdue_actions}
            render={(x) => <Link className="hover:underline" href={opp(x.uuid)}><span className="font-medium">{x.title}:</span> {x.action} (due {dateText(x.due_at, true)})</Link>} />
          <List title="Deals at risk" items={data.deal_risks}
            render={(x) => <Link className="hover:underline" href={`/dashboard/property-deals/deals/${x.uuid}`}>{x.name}</Link>} />
          <List title="Top opportunities" items={data.top_opportunities}
            render={(x) => <Link className="hover:underline" href={opp(x.opportunity_uuid)}><span className="font-medium">{x.title}</span>{x.why_now ? `: ${x.why_now}` : ''}</Link>} />
        </>
      )}
    </div>
  );
}

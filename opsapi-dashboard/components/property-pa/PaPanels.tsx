'use client';

/**
 * The PA on an opportunity: Prepare me (scene 2), Coach (scene 4) and Ask my PA (any question; the answer runs
 * in JobShout and is checked by OpsAPI before it is shown). Prepare and Coach come straight from the record, so
 * they are instant and every line shows where it came from.
 */
import React, { useEffect, useRef, useState } from 'react';
import { Sparkles, Loader2, ShieldAlert } from 'lucide-react';
import toast from 'react-hot-toast';
import { Badge, Button, Card, Textarea } from '@/components/ui';
import { ErrorNote, Spinner, Tabs } from '@/components/property-deals/ui';
import { usePdData } from '@/components/property-deals/usePd';
import { paService, pollWhileRunning, type BriefLine, type PaMode, type PaRun, type Rule } from '@/services/property-pa.service';
import { pdErrorText } from '@/services/property-deals.service';

export type Panel = 'prepare' | 'coach' | 'ask';

function Line({ l }: { l: BriefLine }) {
  return (
    <li className="text-sm text-secondary-800">
      {l.text}
      {l.label && l.label !== 'stated' && <Badge size="sm" variant="warning" className="ml-2">{l.label}</Badge>}
      <span className="ml-2 font-mono text-[10px] text-secondary-400" title="Source record">{l.ref.split(':')[0]}</span>
    </li>
  );
}

function Section({ title, lines, empty }: { title: string; lines: BriefLine[]; empty?: string }) {
  if (!lines.length && !empty) return null;
  return (
    <div>
      <h4 className="mb-1 text-xs font-semibold uppercase tracking-wide text-secondary-500">{title}</h4>
      {lines.length ? <ul className="space-y-1">{lines.map((l, i) => <Line key={`${l.ref}-${i}`} l={l} />)}</ul> : <p className="text-sm text-secondary-400">{empty}</p>}
    </div>
  );
}

function Rules({ rules }: { rules: Rule[] }) {
  return (
    <div>
      <h4 className="mb-1 text-xs font-semibold uppercase tracking-wide text-secondary-500">Playbook</h4>
      <ul className="space-y-1">
        {rules.filter((r) => r.key !== 'grounded_or_silent').map((r) => (
          <li key={r.ref} className="text-sm"><span className="font-medium text-secondary-900">{r.title}.</span> <span className="text-secondary-700">{r.rule}</span>
            <span className="ml-1 text-[10px] text-secondary-400">{r.scope} v{r.version}</span></li>
        ))}
      </ul>
    </div>
  );
}

function Prepare({ id }: { id: string }) {
  const { data: b, error, loading } = usePdData(() => paService.prepare(id), [id]);
  if (loading && !b) return <Spinner />;
  if (!b) return <ErrorNote product="Property PA" error={error} />;
  return (
    <div className="space-y-4" data-testid="prepare">
      <div className="rounded-lg bg-primary-50 p-3 text-sm">
        <p><span className="font-medium">Do:</span> {b.recommended_action}</p>
        <p><span className="font-medium">Aim:</span> {b.objective}</p>
      </div>
      <Section title="Snapshot" lines={b.snapshot} />
      {b.last_interaction && <Section title="Last meaningful contact" lines={[b.last_interaction]} />}
      <Section title="Price and offers" lines={b.price} empty="No figures recorded yet." />
      <Section title="Decision makers" lines={b.decision_makers} empty="Not known." />
      <Section title="Promises" lines={b.promises} empty="None open." />
      <Section title="Likely objections" lines={b.objections} />
      <div>
        <h4 className="mb-1 text-xs font-semibold uppercase tracking-wide text-secondary-500">Questions to establish</h4>
        <ul className="list-disc space-y-1 pl-5 text-sm">{b.questions.map((q) => <li key={q.field}>{q.question}</li>)}</ul>
      </div>
      <Rules rules={b.playbook} />
    </div>
  );
}

function Coach({ id }: { id: string }) {
  const { data: c, error, loading } = usePdData(() => paService.coach(id), [id]);
  if (loading && !c) return <Spinner />;
  if (!c) return <ErrorNote product="Property PA" error={error} />;
  return (
    <div className="space-y-4" data-testid="coach">
      <Section title="Known" lines={c.known} />
      <Section title="Assumed (check these)" lines={c.assumed} empty="Nothing assumed." />
      <div>
        <h4 className="mb-1 text-xs font-semibold uppercase tracking-wide text-secondary-500">Ask first</h4>
        <ul className="list-disc space-y-1 pl-5 text-sm">{c.questions.map((q) => <li key={q}>{q}</li>)}</ul>
      </div>
      <p className="text-sm text-secondary-700">{c.next_step}</p>
      <Rules rules={c.playbook} />
      <p className="flex items-center gap-1 text-xs text-secondary-400"><ShieldAlert className="h-3 w-3" /> {c.never}</p>
    </div>
  );
}

function Ask({ id, mode }: { id: string; mode: PaMode }) {
  const [msg, setMsg] = useState('');
  const [run, setRun] = useState<PaRun | null>(null);
  const [busy, setBusy] = useState(false);
  const [slow, setSlow] = useState(false); // still running after the poll's 10 minutes
  const ctl = useRef<AbortController | null>(null);
  useEffect(() => () => ctl.current?.abort(), []);
  const poll = async (rid: string) => {
    ctl.current?.abort();
    const c = new AbortController();
    ctl.current = c;
    setSlow(false);
    try {
      if (await pollWhileRunning(() => paService.run(rid), (r) => r.status === 'running', setRun, { signal: c.signal }) === 'timeout') setSlow(true);
    } catch (e) {
      if (!c.signal.aborted) toast.error(pdErrorText(e));
    }
  };
  const send = async () => {
    setBusy(true);
    try {
      const r = await paService.ask({ message: msg.trim(), mode, opportunity_uuid: id });
      setRun(r);
      poll(r.uuid);
    } catch (e) {
      toast.error(pdErrorText(e));
    } finally {
      setBusy(false);
    }
  };
  const out = run?.output;
  return (
    <div className="space-y-3" data-testid="ask">
      <Textarea rows={3} value={msg} onChange={(e) => setMsg(e.target.value)}
        placeholder={mode === 'coach' ? "Sarah won't move below £235k… what would you do?" : 'Ask your PA about this opportunity'} />
      <div className="flex justify-end">
        <Button leftIcon={<Sparkles className="h-4 w-4" />} isLoading={busy} disabled={!msg.trim() || (run?.status === 'running' && !slow)} onClick={send}>Ask</Button>
      </div>
      {run?.status === 'running' && (slow
        ? <p className="text-sm text-warning-700">Still working on it. Come back to this opportunity later for the answer.</p>
        : <p className="flex items-center gap-2 text-sm text-secondary-500"><Loader2 className="h-4 w-4 animate-spin" /> Thinking. On our private model this can take a few minutes.</p>)}
      {run?.status === 'failed' && <p className="text-sm text-error-600">The PA couldn&apos;t answer: {run.error}</p>}
      {out && out.answer && (
        <Card className="space-y-2 bg-secondary-50">
          <p className="whitespace-pre-wrap text-sm text-secondary-900">{out.answer}</p>
          {!!out.unknowns?.length && <p className="text-xs text-secondary-500">Not known: {out.unknowns.join('; ')}</p>}
          {!!out.inferences?.length && <p className="text-xs text-warning-600">Inferences: {out.inferences.join('; ')}</p>}
          {!!out.sources?.length && <p className="text-[10px] text-secondary-400">Sources: {out.sources.map((s) => s.label || s.type).join(', ')}</p>}
          <p className="text-[10px] text-secondary-400">{run?.model} · {run?.prompt_version}</p>
        </Card>
      )}
      {out && !out.answer && out.withheld && <p className="text-sm text-warning-700">{out.withheld}</p>}
    </div>
  );
}

export default function PaPanels({ opportunityId, initial = 'prepare' }: { opportunityId: string; initial?: Panel }) {
  const [tab, setTab] = useState<Panel>(initial);
  return (
    <Card className="space-y-4">
      <Tabs<Panel>
        tabs={[{ key: 'prepare', label: 'Prepare me' }, { key: 'coach', label: 'Coach' }, { key: 'ask', label: 'Ask my PA' }]}
        value={tab}
        onChange={setTab}
      />
      {tab === 'prepare' && <Prepare id={opportunityId} />}
      {tab === 'coach' && (
        <>
          <Coach id={opportunityId} />
          <div className="border-t border-secondary-200 pt-3"><Ask id={opportunityId} mode="coach" /></div>
        </>
      )}
      {tab === 'ask' && <Ask id={opportunityId} mode="ask" />}
    </Card>
  );
}


'use client';

/**
 * Property PA — Capture (HOW-IT-WORKS scene 3, Week 2): say or type what happened, the PA proposes the
 * changes, you confirm or correct them on one sheet. Voice is transcribed on our own speech server;
 * nothing is written to the record until you confirm.
 */
import React, { Suspense, useCallback, useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import { useSearchParams } from 'next/navigation';
import { Mic, Square, Send, NotebookPen, Loader2, Search } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, Card, Input, Textarea } from '@/components/ui';
import { ErrorNote } from '@/components/property-deals/ui';
import ConfirmSheet from '@/components/property-pa/ConfirmSheet';
import { useVoice } from '@/hooks/useVoice';
import { paService, pollWhileRunning, type CaptureSheet, type PersonHit } from '@/services/property-pa.service';
import PaPage, { usePaCan, PA_PRODUCT } from '@/components/property-pa/PaPage';
import { pdError, pdErrorText, type PdError } from '@/services/property-deals.service';

export default function CapturePage() {
  return (
    <PaPage>
      <Suspense fallback={null}>
        <Capture />
      </Suspense>
    </PaPage>
  );
}

function Capture() {
  const params = useSearchParams();
  const [opp, setOpp] = useState<{ uuid: string; title: string } | null>(null);
  const [q, setQ] = useState('');
  const [hits, setHits] = useState<PersonHit[]>([]);
  const [text, setText] = useState('');
  const [fromVoice, setFromVoice] = useState(false);
  const [busy, setBusy] = useState(false);
  const [interaction, setInteraction] = useState<string | null>(null);
  const [paNote, setPaNote] = useState<string | null>(null);
  const [sheet, setSheet] = useState<CaptureSheet | null>(null);
  const [error, setError] = useState<PdError | undefined>();
  const voice = useVoice();
  const { can } = usePaCan();
  // /captures/start: records.create, and the proposals it writes need updates.create.
  const canCapture = can('property_pa_records', 'create') && can('property_pa_updates', 'create');
  const pollCtl = useRef<AbortController | null>(null);
  const [slow, setSlow] = useState(false); // still running after the poll's 10 minutes

  // Poll the sheet while the PA works (it can take minutes on the private model). One chain at a
  // time: a new poll, "Capture another" or leaving the page stops the previous one.
  const poll = useCallback(async (id: string, onFirst?: (s: CaptureSheet) => void) => {
    pollCtl.current?.abort();
    const ctl = new AbortController();
    pollCtl.current = ctl;
    setSlow(false);
    let first = onFirst;
    try {
      const end = await pollWhileRunning(() => paService.sheet(id), (s) => s.run?.status === 'running', (s) => {
        first?.(s);
        first = undefined;
        setSheet(s);
      }, { signal: ctl.signal });
      if (end === 'timeout') setSlow(true);
    } catch (e) {
      if (!ctl.signal.aborted) setError(pdError(e));
    }
  }, []);
  useEffect(() => () => pollCtl.current?.abort(), []);

  // ?opportunity=<uuid> preselects (links from the opportunity page).
  useEffect(() => {
    const id = params.get('opportunity');
    if (!id) return;
    paService.opportunity(id).then((o) => setOpp({ uuid: o.uuid, title: o.title })).catch((e) => setError(pdError(e)));
  }, [params]);

  // ?interaction=<uuid> reopens a sheet (links from the opportunity page: "changes waiting").
  useEffect(() => {
    const id = params.get('interaction');
    if (!id) return;
    setInteraction(id);
    void poll(id, (s) => setText(s.interaction.transcript || s.interaction.raw_text || ''));
  }, [params, poll]);

  useEffect(() => {
    if (q.trim().length < 2) {
      setHits([]);
      return;
    }
    const t = setTimeout(() => {
      paService.people(q.trim()).then(setHits).catch(() => setHits([]));
    }, 250);
    return () => clearTimeout(t);
  }, [q]);

  const record = async () => {
    try {
      if (voice.state === 'listening') {
        const said = await voice.finish();
        if (said) {
          setText((t) => (t ? `${t} ${said}` : said));
          setFromVoice(true);
        } else toast.error("I didn't catch that. Try again, or type it.");
      } else {
        await voice.listen();
      }
    } catch (e) {
      toast.error(window.isSecureContext ? pdErrorText(e) : 'The microphone needs a secure (https) page.');
    }
  };

  const send = async () => {
    setBusy(true);
    setError(undefined);
    try {
      const r = await paService.startCapture({ text: text.trim(), channel: fromVoice ? 'voice' : 'note', opportunity_uuid: opp?.uuid });
      setInteraction(r.interaction.uuid);
      setPaNote(r.pa.error ? `Saved to the timeline. The PA wasn't asked: ${r.pa.error}` : null);
      if (!r.pa.error) void poll(r.interaction.uuid);
    } catch (e) {
      setError(pdError(e));
    } finally {
      setBusy(false);
    }
  };

  const reset = () => {
    pollCtl.current?.abort();
    setSlow(false);
    setText('');
    setFromVoice(false);
    setInteraction(null);
    setSheet(null);
    setPaNote(null);
  };

  const running = !slow && (sheet?.run?.status === 'running' || (interaction && !sheet && !paNote));
  return (
    <div className="mx-auto max-w-3xl space-y-6">
      <PageHeader title="Capture" description="Say or type what happened. Your PA picks out the changes; you confirm them." icon={<NotebookPen className="h-6 w-6" />} />
      <ErrorNote product={PA_PRODUCT} error={error} />

      {!interaction && !canCapture && (
        <ErrorNote product={PA_PRODUCT} error={{ status: 403, message: 'No access' }} />
      )}
      {!interaction && canCapture && (
        <Card className="space-y-4">
          <div>
            <p className="mb-1 text-sm font-medium text-secondary-700">Who is it about?</p>
            {opp ? (
              <div className="flex items-center justify-between rounded-lg bg-secondary-50 px-3 py-2 text-sm">
                <span>{opp.title}</span>
                <Button size="sm" variant="ghost" onClick={() => setOpp(null)}>Change</Button>
              </div>
            ) : (
              <div className="relative">
                <Input placeholder="Name, phone or address (e.g. 22 Station Road)" value={q} onChange={(e) => setQ(e.target.value)} leftIcon={<Search className="h-4 w-4" />} />
                {hits.length > 0 && (
                  <ul className="absolute z-10 mt-1 w-full rounded-lg border border-secondary-200 bg-surface shadow">
                    {hits.map((h) => (
                      <li key={h.uuid}>
                        <button type="button" className="w-full px-3 py-2 text-left text-sm hover:bg-secondary-50" disabled={!h.opportunity_uuid}
                          onClick={() => { if (h.opportunity_uuid) { setOpp({ uuid: h.opportunity_uuid, title: h.opportunity_title || `${h.first_name} ${h.last_name ?? ''}` }); setQ(''); setHits([]); } }}>
                          {h.first_name} {h.last_name} {h.property_address ? `· ${h.property_address}` : ''}
                          {!h.opportunity_uuid && <span className="text-secondary-400"> (no opportunity)</span>}
                        </button>
                      </li>
                    ))}
                  </ul>
                )}
                <p className="mt-1 text-xs text-secondary-400">Optional: the PA can work it out from the note.</p>
              </div>
            )}
          </div>
          <Textarea label="What happened?" rows={6} value={text} onChange={(e) => setText(e.target.value)}
            placeholder="Spoke to Sarah. Second agent valued it at £240k. She won't go below £235k…" />
          <div className="flex flex-wrap items-center justify-between gap-2">
            {voice.status?.stt ? (
              <Button variant={voice.state === 'listening' ? 'danger' : 'outline'} onClick={record} disabled={voice.state === 'transcribing'}
                leftIcon={voice.state === 'listening' ? <Square className="h-4 w-4" /> : voice.state === 'transcribing' ? <Loader2 className="h-4 w-4 animate-spin" /> : <Mic className="h-4 w-4" />}>
                {voice.state === 'listening' ? 'Stop' : voice.state === 'transcribing' ? 'Writing it down…' : 'Record a voice note'}
              </Button>
            ) : (
              <span className="text-xs text-secondary-400">Voice notes aren&apos;t available here yet. Type the note instead.</span>
            )}
            <Button leftIcon={<Send className="h-4 w-4" />} isLoading={busy} disabled={!text.trim() || voice.state !== 'idle'} onClick={send}>
              Send to my PA
            </Button>
          </div>
        </Card>
      )}

      {interaction && (
        <Card className="space-y-2">
          <p className="text-sm text-secondary-500">Your note</p>
          <p className="whitespace-pre-wrap text-sm text-secondary-900">{text}</p>
          {paNote && <p className="text-sm text-warning-600">{paNote}</p>}
          {running && (
            <p className="flex items-center gap-2 text-sm text-secondary-500">
              <Loader2 className="h-4 w-4 animate-spin" /> Your PA is reading it. On our private model this can take a few minutes; you can leave this page and come back from the opportunity.
            </p>
          )}
          {slow && (
            <p className="text-sm text-warning-700">Still working on it. Refresh this page later, or come back from the opportunity.</p>
          )}
          {sheet?.run?.status === 'failed' && <p className="text-sm text-error-600">The PA couldn&apos;t finish: {sheet.run.error}</p>}
          {sheet && sheet.run?.status === 'succeeded' && sheet.proposals.length === 0 && (
            <p className="text-sm text-secondary-500">The PA found nothing to change. The note is on the timeline.</p>
          )}
        </Card>
      )}

      {sheet && sheet.proposals.length > 0 && <ConfirmSheet sheet={sheet} onDecided={setSheet} />}

      {interaction && (
        <div className="flex justify-between">
          <Button variant="ghost" onClick={reset}>Capture another</Button>
          {opp && <Link className="text-sm text-primary-600 underline" href={`/dashboard/property-pa/opportunities/${opp.uuid}`}>Open {opp.title}</Link>}
        </div>
      )}
    </div>
  );
}

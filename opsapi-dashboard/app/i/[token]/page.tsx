'use client';

/**
 * Candidate interview — /i/[token] (no login).
 *
 * Steps: the notice (AI interviewer, a person decides, what isn't analysed,
 * data and rights) → adjustments, or "speak to a person" instead → a practice
 * question (not stored or assessed) → the interview, one question at a time →
 * the candidate's own questions → thank you → optional, voluntary self-ID.
 *
 * Accessibility (WCAG 2.2 AA): keyboard only, visible focus, labelled
 * controls, new questions announced (aria-live), zoom to 200%, and large-text
 * and high-contrast toggles. Mobile first. All text from the server is shown
 * as text, never HTML.
 */

import React, { useCallback, useEffect, useRef, useState } from 'react';
import { useParams } from 'next/navigation';
import { CheckCircle2, Loader2 } from 'lucide-react';
import { interviewPublic, InterviewError, type CandidateView } from '@/services/ats-public.service';

type Phase = 'loading' | 'error' | 'notice' | 'practice' | 'interview' | 'done';

const PRACTICE_QUESTION = 'Practice question (not saved or assessed): what did you have for breakfast today?';

export default function CandidateInterviewPage() {
  const { token } = useParams<{ token: string }>();
  const [view, setView] = useState<CandidateView | null>(null);
  const [phase, setPhase] = useState<Phase>('loading');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [answer, setAnswer] = useState('');
  const [pasted, setPasted] = useState(false);
  const [adjust, setAdjust] = useState<string[]>([]);
  const [other, setOther] = useState('');
  const [practice, setPractice] = useState('');
  const [practiceDone, setPracticeDone] = useState(false);
  const [large, setLarge] = useState(false);
  const [contrast, setContrast] = useState(false);
  const [secondsLeft, setSecondsLeft] = useState<number | null>(null);
  const [selfId, setSelfId] = useState<Record<string, string>>({});
  const [selfIdSaved, setSelfIdSaved] = useState(false);
  const bottom = useRef<HTMLDivElement>(null);
  const box = useRef<HTMLTextAreaElement>(null);

  const apply = useCallback((v: CandidateView) => {
    setView(v);
    setSecondsLeft(v.seconds_left ?? null);
    if (v.state === 'invited') setPhase((p) => (p === 'practice' ? p : 'notice'));
    else if (v.state === 'in_progress' || v.state === 'paused') setPhase('interview');
    else setPhase('done');
  }, []);

  const fail = (e: unknown) => {
    const msg = e instanceof InterviewError ? e.message : 'Something went wrong. Please check your connection and try again.';
    if (e instanceof InterviewError && (e.status === 404 || e.status === 410)) {
      setError(msg);
      setPhase('error');
    } else {
      setError(msg);
    }
  };

  useEffect(() => {
    interviewPublic.view(token).then(apply).catch(fail);
  }, [token, apply]);

  // A local countdown; the server is the authority and closes the interview at zero.
  useEffect(() => {
    if (phase !== 'interview' || view?.state !== 'in_progress' || secondsLeft === null) return;
    if (secondsLeft <= 0) {
      interviewPublic.view(token).then(apply).catch(() => undefined);
      return;
    }
    const t = setTimeout(() => setSecondsLeft((s) => (s === null ? s : s - 1)), 1000);
    return () => clearTimeout(t);
  }, [secondsLeft, phase, view?.state, token, apply]);

  useEffect(() => {
    bottom.current?.scrollIntoView({ behavior: 'smooth', block: 'end' });
    if (!busy) box.current?.focus();
  }, [view?.turns.length, busy]);

  const run = async (fn: () => Promise<CandidateView>) => {
    setBusy(true);
    setError('');
    try {
      apply(await fn());
    } catch (e) {
      fail(e);
    } finally {
      setBusy(false);
    }
  };

  const start = () => {
    if (!view) return;
    const list = [...adjust, ...(other.trim() ? [other.trim()] : [])];
    run(() => interviewPublic.start(token, view.notice_hash, list));
  };

  const send = (text: string, wasPasted = pasted) => {
    if (!text.trim()) return;
    setAnswer('');
    setPasted(false);
    run(() => interviewPublic.answer(token, text, wasPasted ? 'pasted' : 'typed'));
  };

  const event = (type: 'repeat' | 'rephrase' | 'pause' | 'resume' | 'person' | 'withdraw') => run(() => interviewPublic.event(token, type));

  const textSize = large ? 'text-lg' : 'text-base';
  const theme = contrast ? 'bg-black text-white' : 'bg-secondary-50 text-secondary-900';
  const panel = contrast ? 'bg-black border border-white' : 'bg-white shadow-sm';

  const toggles = (
    <div className="flex flex-wrap gap-3 text-sm">
      <label className="flex items-center gap-2"><input type="checkbox" checked={large} onChange={(e) => setLarge(e.target.checked)} /> Larger text</label>
      <label className="flex items-center gap-2"><input type="checkbox" checked={contrast} onChange={(e) => setContrast(e.target.checked)} /> High contrast</label>
    </div>
  );

  const mins = secondsLeft !== null ? Math.max(0, Math.ceil(secondsLeft / 60)) : null;

  return (
    <main className={`min-h-screen ${theme} ${textSize}`}>
      <div className="mx-auto flex max-w-2xl flex-col gap-4 px-4 py-6">
        <header>
          <p className="text-sm opacity-70">{view?.organisation || 'First-round interview'}</p>
          <h1 className="text-2xl font-bold">{view ? `Interview: ${view.role_title}` : 'Interview'}</h1>
        </header>

        {phase === 'loading' && <p className="flex items-center gap-2"><Loader2 className="h-5 w-5 animate-spin" /> Loading…</p>}
        {phase === 'error' && <p role="alert" className={`rounded-xl p-4 ${panel}`}>{error}</p>}
        {error && phase !== 'error' && <p role="alert" className="rounded-lg border border-red-400 bg-red-50 p-3 text-red-900">{error}</p>}

        {phase === 'notice' && view && view.delivery === 'offline' && (
          <section className={`space-y-4 rounded-xl p-5 ${panel}`} aria-labelledby="offline-title">
            <h2 id="offline-title" className="text-xl font-semibold">This interview runs in the Snazzy Pro app</h2>
            <p className="leading-relaxed">
              {view.organisation || 'The hiring team'} has set this interview up to run offline, on your own Mac, in the
              Snazzy Pro app. Nothing is sent while you take it; when it ends, the app sends the transcript to the
              hiring team. The link works on one device.
            </p>
            <div className="flex flex-col gap-3 sm:flex-row">
              <a className="rounded-lg bg-primary-600 px-5 py-3 text-center font-semibold text-white focus:outline-none focus:ring-4 focus:ring-primary-300"
                href={`snazzypro://interview?link=${encodeURIComponent(typeof window !== 'undefined' ? window.location.href : '')}`}>
                Open in Snazzy Pro
              </a>
              <a className="rounded-lg border border-current px-5 py-3 text-center font-semibold" href="https://snazzy.pro/download.html">
                Get Snazzy Pro (free)
              </a>
            </div>
            <p className="text-sm opacity-80">
              You can ask for adjustments, or to speak to a person instead, in the app before you start. If you can&apos;t use
              a Mac, contact the hiring team and they can send you a link that works in the browser.
            </p>
          </section>
        )}

        {phase === 'notice' && view && view.delivery !== 'offline' && (
          <section className={`space-y-4 rounded-xl p-5 ${panel}`} aria-labelledby="notice-title">
            <h2 id="notice-title" className="text-xl font-semibold">Before you start</h2>
            {view.has_pack && (
              <p className="rounded-lg border border-current p-3 text-sm">
                You can take this interview here, or in the Snazzy Pro app on a Mac, which shows the interview deck and
                lets you answer by voice.{' '}
                <a className="font-semibold underline"
                  href={`snazzypro://interview?link=${encodeURIComponent(typeof window !== 'undefined' ? window.location.href : '')}`}>
                  Open in Snazzy Pro
                </a>{' '}
                (<a className="underline" href="https://snazzy.pro/download.html">get it free</a>). The link works on one device.
              </p>
            )}
            {view.notice.split('\n\n').map((p, i) => <p key={i} className="leading-relaxed">{p}</p>)}
            <fieldset className="space-y-2">
              <legend className="font-semibold">Do you need any adjustments?</legend>
              {view.allowed_adjustments.map((a) => (
                <label key={a} className="flex items-center gap-2">
                  <input type="checkbox" checked={adjust.includes(a)}
                    onChange={(e) => setAdjust((l) => (e.target.checked ? [...l, a] : l.filter((x) => x !== a)))} /> {a[0].toUpperCase() + a.slice(1)}
                </label>
              ))}
              <label className="block">
                <span className="text-sm">Something else (sent to the hiring team)</span>
                <input className="mt-1 w-full rounded-lg border border-secondary-300 p-2 text-secondary-900" value={other}
                  onChange={(e) => setOther(e.target.value)} maxLength={500} />
              </label>
            </fieldset>
            {toggles}
            <div className="flex flex-col gap-3 sm:flex-row">
              <button className="rounded-lg bg-primary-600 px-5 py-3 font-semibold text-white focus:outline-none focus:ring-4 focus:ring-primary-300"
                onClick={() => setPhase('practice')}>I&apos;ve read this, continue</button>
              <button className="rounded-lg border border-current px-5 py-3 font-semibold focus:outline-none focus:ring-4 focus:ring-primary-300"
                onClick={() => event('person')} disabled={busy}>I&apos;d prefer to speak to a person</button>
            </div>
          </section>
        )}

        {phase === 'practice' && view && (
          <section className={`space-y-4 rounded-xl p-5 ${panel}`} aria-labelledby="practice-title">
            <h2 id="practice-title" className="text-xl font-semibold">Try it first</h2>
            <p>{PRACTICE_QUESTION}</p>
            {!practiceDone ? (
              <>
                <label className="block">
                  <span className="sr-only">Practice answer</span>
                  <textarea className="w-full rounded-lg border border-secondary-300 p-3 text-secondary-900" rows={3}
                    value={practice} onChange={(e) => setPractice(e.target.value)} />
                </label>
                <button className="rounded-lg border border-current px-4 py-2" onClick={() => setPracticeDone(true)}>Send practice answer</button>
              </>
            ) : <p className="rounded-lg bg-primary-50 p-3 text-secondary-900">That&apos;s how it works. Your practice answer wasn&apos;t saved.</p>}
            <p className="text-sm opacity-80">
              The interview takes about {view.minutes} minutes and has {view.question_count} main questions. Answer in your own words; there are no trick questions.
            </p>
            <button className="rounded-lg bg-primary-600 px-5 py-3 font-semibold text-white focus:outline-none focus:ring-4 focus:ring-primary-300 disabled:opacity-50"
              onClick={start} disabled={busy}>{busy ? 'Starting…' : 'Start the interview'}</button>
          </section>
        )}

        {phase === 'interview' && view && (
          <>
            <div className={`sticky top-0 z-10 rounded-xl p-3 ${panel}`}>
              <div className="flex items-center justify-between text-sm">
                <span>{view.interviewer_name}</span>
                <span aria-live="off">{view.state === 'paused' ? 'Paused' : mins !== null ? `About ${mins} min left` : ''}</span>
              </div>
              <div className="mt-2 h-2 rounded bg-secondary-200" role="progressbar" aria-label="Progress"
                aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(view.progress * 100)}>
                <div className="h-2 rounded bg-primary-500" style={{ width: `${Math.round(view.progress * 100)}%` }} />
              </div>
            </div>

            <ol className="space-y-3" aria-label="Conversation">
              {view.turns.map((t, i) => (
                <li key={t.id} className={`rounded-xl p-4 ${t.role === 'candidate' ? 'ml-8 bg-primary-600 text-white' : `mr-8 ${panel}`}`}
                  aria-live={i === view.turns.length - 1 && t.role === 'interviewer' ? 'polite' : undefined}>
                  <p className="mb-1 text-xs font-semibold uppercase tracking-wide opacity-70">{t.role === 'candidate' ? 'You' : view.interviewer_name}</p>
                  <p className="whitespace-pre-wrap">{t.text}</p>
                </li>
              ))}
            </ol>
            <div ref={bottom} />

            {view.state === 'paused' ? (
              <div className={`rounded-xl p-4 ${panel}`}>
                <p>The interview is paused. Take as long as you need.</p>
                <button className="mt-3 rounded-lg bg-primary-600 px-5 py-3 font-semibold text-white" onClick={() => event('resume')} disabled={busy}>Carry on</button>
              </div>
            ) : (
              <div className={`space-y-3 rounded-xl p-4 ${panel}`}>
                {view.choices && view.choices.length > 0 ? (
                  <div className="flex flex-wrap gap-2" role="group" aria-label="Your answer">
                    {view.choices.map((c) => (
                      <button key={c} className="rounded-lg border-2 border-primary-500 px-5 py-2 font-semibold focus:outline-none focus:ring-4 focus:ring-primary-300"
                        onClick={() => send(c, false)} disabled={busy}>{c}</button>
                    ))}
                  </div>
                ) : (
                  <form onSubmit={(e) => { e.preventDefault(); send(answer); }}>
                    <label className="block">
                      <span className="sr-only">Your answer</span>
                      <textarea ref={box} className="w-full rounded-lg border border-secondary-300 p-3 text-secondary-900" rows={5} maxLength={6000}
                        value={answer} onChange={(e) => setAnswer(e.target.value)} onPaste={() => setPasted(true)} disabled={busy}
                        onKeyDown={(e) => { if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); send(answer); } }} />
                    </label>
                    <div className="mt-2 flex items-center justify-between text-xs opacity-70">
                      <span>Ctrl or ⌘ + Enter sends</span><span>{answer.length} / 6000</span>
                    </div>
                    <button type="submit" className="mt-2 w-full rounded-lg bg-primary-600 px-5 py-3 font-semibold text-white focus:outline-none focus:ring-4 focus:ring-primary-300 disabled:opacity-50"
                      disabled={busy || !answer.trim()}>{busy ? <span className="inline-flex items-center gap-2"><Loader2 className="h-4 w-4 animate-spin" /> Sending…</span> : 'Send answer'}</button>
                  </form>
                )}
                <div className="flex flex-wrap gap-2 text-sm">
                  <button className="rounded-lg border border-current px-3 py-1.5" onClick={() => event('repeat')} disabled={busy}>Repeat the question</button>
                  <button className="rounded-lg border border-current px-3 py-1.5" onClick={() => event('rephrase')} disabled={busy}>Say it another way</button>
                  {view.allow_pause && <button className="rounded-lg border border-current px-3 py-1.5" onClick={() => event('pause')} disabled={busy}>Pause</button>}
                  <button className="rounded-lg border border-current px-3 py-1.5" onClick={() => event('person')} disabled={busy}>Speak to a person instead</button>
                </div>
                {toggles}
              </div>
            )}
          </>
        )}

        {phase === 'done' && view && (
          <section className={`space-y-4 rounded-xl p-5 ${panel}`} aria-labelledby="done-title">
            <h2 id="done-title" className="flex items-center gap-2 text-xl font-semibold"><CheckCircle2 className="h-6 w-6 text-emerald-600" /> Thank you</h2>
            <p>{view.state === 'human_requested'
              ? 'The hiring team knows you’d like to speak to a person and will be in touch. This won’t count against you.'
              : view.state === 'withdrawn' ? 'You’ve withdrawn from this interview.' : view.next_steps}</p>
            {view.self_id && !selfIdSaved && (
              <form className="space-y-3 border-t border-secondary-200 pt-4" onSubmit={(e) => {
                e.preventDefault();
                interviewPublic.selfId(token, selfId).then(() => setSelfIdSaved(true)).catch(fail);
              }}>
                <h3 className="font-semibold">Optional: help us check our hiring is fair</h3>
                <p className="text-sm opacity-80">
                  These questions are voluntary. Your answers are stored separately, are never shown to the people deciding or to the AI,
                  and are only used in totals of at least ten people. Skipping them changes nothing.
                </p>
                {view.self_id.map((q) => (
                  <label key={q.id} className="block">
                    <span className="text-sm font-medium">{q.label}</span>
                    <select className="mt-1 w-full rounded-lg border border-secondary-300 p-2 text-secondary-900" value={selfId[q.id] ?? ''}
                      onChange={(e) => setSelfId((s) => ({ ...s, [q.id]: e.target.value }))}>
                      <option value="">Skip</option>
                      {q.options.map((o) => <option key={o}>{o}</option>)}
                    </select>
                  </label>
                ))}
                <button className="rounded-lg border border-current px-4 py-2 font-semibold" type="submit">Send</button>
              </form>
            )}
            {selfIdSaved && <p className="text-sm">Thank you. That&apos;s everything.</p>}
          </section>
        )}
      </div>
    </main>
  );
}

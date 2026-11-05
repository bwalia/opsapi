'use client';

/**
 * What the AI made of the lead: who they are and what they want, a fit score
 * with reasons, how big the deal is (and how it knows), warnings, the next
 * best action for the situation, partners that could fulfil it, questions for
 * the call and a draft first reply. Everything is a suggestion for a person.
 *
 * Price research from a web search (Google Search grounding) is shown as it
 * came, with Google's Search Suggestions, and only to the person it ran for.
 */
import React, { useState } from 'react';
import Link from 'next/link';
import toast from 'react-hot-toast';
import {
  AlertTriangle, Copy, ExternalLink, Globe2, Loader2, Mail, MessageCircle, RefreshCw, Sparkles, Wand2,
} from 'lucide-react';
import { Button } from '@/components/ui';
import { cn } from '@/lib/utils';
import { leadError, leadsService, type Lead, type NextAction } from '@/services/leads.service';
import { money, ScoreBadge } from './ui';

export type AiAction = NextAction;

function waLink(phone: string | null, text: string): string | null {
  const digits = (phone ?? '').replace(/[^\d]/g, '');
  if (digits.length < 7) return null;
  return `https://wa.me/${digits}?text=${encodeURIComponent(text)}`;
}

export function AiCard({ lead, canWork, onAction, onRefresh }: {
  lead: Lead;
  canWork: boolean;
  onAction: (action: AiAction, partnerUuid?: string) => void;
  onRefresh: () => void;
}) {
  const [busy, setBusy] = useState(false);
  const a = lead.analysis;
  const r = a?.result ?? null;
  const running = a && (a.status === 'pending' || a.status === 'running');

  const rerun = async () => {
    setBusy(true);
    try {
      const res = await leadsService.analyse(lead.uuid);
      toast.success(res.message);
      onRefresh();
    } catch (e) {
      toast.error(leadError(e).message);
    } finally {
      setBusy(false);
    }
  };

  const header = (
    <div className="flex items-center justify-between gap-2">
      <h2 className="flex items-center gap-2 text-sm font-semibold text-secondary-900">
        <Sparkles className="h-4 w-4 text-primary-500" aria-hidden="true" />AI analysis
      </h2>
      {canWork && !running && (
        <Button variant="ghost" size="sm" onClick={rerun} isLoading={busy} leftIcon={<RefreshCw className="h-3.5 w-3.5" />}>
          Run again
        </Button>
      )}
    </div>
  );

  if (!a || running) {
    return (
      <section className="rounded-xl border border-primary-200 bg-gradient-to-br from-primary-50/70 to-white p-5" aria-live="polite">
        {header}
        <p className="mt-3 flex items-center gap-2 text-sm text-secondary-600">
          {running ? <><Loader2 className="h-4 w-4 animate-spin text-primary-500" aria-hidden="true" />The AI is reading this lead and sizing the deal…</>
            : 'The AI hasn’t looked at this lead yet.'}
        </p>
      </section>
    );
  }

  if (a.status !== 'done' || !r) {
    return (
      <section className="rounded-xl border border-secondary-200 bg-white p-5">
        {header}
        <p className="mt-3 text-sm text-secondary-600">{a.error ?? 'No analysis.'}</p>
        {a.error && /AI model is set up|AI analysis is turned off/.test(a.error) && (
          <Link href={/turned off/.test(a.error) ? '/dashboard/leads/settings' : '/dashboard/namespace/ai'}
            className="mt-2 inline-flex text-sm font-medium text-primary-600 hover:underline">
            {/turned off/.test(a.error) ? 'Open lead settings' : 'Set up AI models'}
          </Link>
        )}
      </section>
    );
  }

  const nba = r.next_best_action;
  const reply = [r.first_reply.subject, r.first_reply.body].filter(Boolean).join('\n\n');
  const wa = r.first_reply.body ? waLink(lead.phone, r.first_reply.body) : null;
  const mail = lead.email && r.first_reply.body
    ? `mailto:${lead.email}?subject=${encodeURIComponent(r.first_reply.subject ?? '')}&body=${encodeURIComponent(r.first_reply.body)}` : null;
  const research = r.research;
  const currency = research?.currency || lead.currency || 'GBP';
  const flags = Object.entries(r.flags).filter(([, v]) => v).map(([k]) => k);
  const FLAG: Record<string, string> = { spam: 'Possibly spam', vulnerable: 'May be vulnerable — take care',
    existing_customer: 'Already a customer', out_of_scope: 'May be outside what you do' };

  return (
    <section className="rounded-xl border border-primary-200 bg-gradient-to-br from-primary-50/70 to-white p-5">
      {header}
      <div className="mt-3 flex items-start gap-3">
        <ScoreBadge score={r.score} className="h-9 min-w-[3rem] text-base" />
        <div className="min-w-0">
          {r.summary && <p className="text-sm text-secondary-800">{r.summary}</p>}
          {r.wants && <p className="mt-1 text-xs text-secondary-500">Wants: <span className="font-medium text-secondary-700">{r.wants}</span></p>}
        </div>
      </div>

      {flags.length > 0 && (
        <ul className="mt-3 flex flex-wrap gap-2">
          {flags.map((f) => (
            <li key={f} className={cn('inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium',
              f === 'existing_customer' ? 'bg-sky-50 text-sky-700' : 'bg-amber-50 text-amber-800')}>
              <AlertTriangle className="h-3 w-3" aria-hidden="true" />{FLAG[f] ?? f}
            </li>
          ))}
        </ul>
      )}

      <div className="mt-4 rounded-lg border border-primary-200 bg-white p-3">
        <p className="text-xs font-medium uppercase tracking-wide text-primary-700">Suggested next step</p>
        <div className="mt-1 flex flex-wrap items-center justify-between gap-2">
          <div>
            <p className="text-sm font-semibold text-secondary-900">{nba.label}{nba.when === 'now' ? ' — now' : nba.when === 'today' ? ' — today' : ''}</p>
            {nba.reason && <p className="text-xs text-secondary-600">{nba.reason}</p>}
          </div>
          {canWork && lead.is_open && (
            <Button size="sm" onClick={() => onAction(nba.action, r.partner_suggestions[0]?.partner_uuid)} leftIcon={<Wand2 className="h-3.5 w-3.5" />}>
              Do it
            </Button>
          )}
        </div>
      </div>

      <div className="mt-4 grid grid-cols-1 gap-4 md:grid-cols-2">
        <div>
          <p className="text-xs font-medium text-secondary-500">Deal size</p>
          <p className="mt-0.5 text-lg font-bold tabular-nums text-secondary-900">
            {r.estimated_value !== null ? money(r.estimated_value, currency) : 'Not known yet'}
          </p>
          {(r.value_low !== null || r.value_high !== null) && (
            <p className="text-xs text-secondary-500">Range {money(r.value_low, currency)} – {money(r.value_high, currency)}</p>
          )}
          <p className="mt-1 flex items-center gap-1 text-xs text-secondary-500">
            {r.value_source === 'web_search' ? <><Globe2 className="h-3 w-3" aria-hidden="true" />From a web price search</>
              : 'Estimated by the AI without a web search'}
          </p>
          {r.value_basis && <p className="mt-1 text-xs text-secondary-600">{r.value_basis}</p>}
        </div>
        <div>
          <p className="text-xs font-medium text-secondary-500">Why this score</p>
          <ul className="mt-1 list-disc space-y-0.5 pl-4 text-xs text-secondary-700">
            {r.score_reasons.length ? r.score_reasons.map((s) => <li key={s}>{s}</li>) : <li>No reasons given</li>}
          </ul>
        </div>
      </div>

      {research && (research.hidden ? (
        <p className="mt-3 text-xs text-secondary-500">{research.message}</p>
      ) : research.sources && research.sources.length > 0 && (
        <details className="mt-3 rounded-lg border border-secondary-200 bg-white p-3">
          <summary className="cursor-pointer text-xs font-medium text-secondary-700">Web sources ({research.sources.length})</summary>
          <ul className="mt-2 space-y-1">
            {research.sources.map((s) => (
              <li key={s.url}><a href={s.url} target="_blank" rel="noopener noreferrer"
                className="inline-flex items-center gap-1 text-xs text-primary-600 hover:underline">
                <ExternalLink className="h-3 w-3" aria-hidden="true" />{s.title}</a></li>
            ))}
          </ul>
          {research.suggestions && (
            <iframe title="Google Search suggestions" sandbox="allow-popups allow-popups-to-escape-sandbox"
              srcDoc={research.suggestions} className="mt-2 h-16 w-full rounded border-0" />
          )}
        </details>
      ))}

      {r.partner_suggestions.length > 0 && (
        <div className="mt-4">
          <p className="text-xs font-medium text-secondary-500">Partners who could fulfil this</p>
          <ul className="mt-1 space-y-1.5">
            {r.partner_suggestions.map((p) => (
              <li key={p.partner_uuid} className="flex items-center justify-between gap-2 rounded-lg border border-secondary-200 bg-white px-3 py-2">
                <span className="min-w-0">
                  <span className="text-sm font-medium text-secondary-900">{p.partner_name}</span>
                  {p.fit !== null && <span className="ml-2 text-xs text-secondary-500">fit {p.fit}</span>}
                  {p.reason && <span className="block truncate text-xs text-secondary-500">{p.reason}</span>}
                </span>
                {canWork && <Button size="sm" variant="ghost" onClick={() => onAction('refer_to_partner', p.partner_uuid)}>Pass on</Button>}
              </li>
            ))}
          </ul>
        </div>
      )}

      {r.questions.length > 0 && (
        <div className="mt-4">
          <p className="text-xs font-medium text-secondary-500">Ask on the call</p>
          <ol className="mt-1 list-decimal space-y-0.5 pl-4 text-sm text-secondary-700">
            {r.questions.map((q) => <li key={q}>{q}</li>)}
          </ol>
        </div>
      )}

      {r.first_reply.body && (
        <div className="mt-4">
          <p className="text-xs font-medium text-secondary-500">Draft first reply</p>
          <pre className="mt-1 max-h-40 overflow-y-auto whitespace-pre-wrap rounded-lg border border-secondary-200 bg-white p-3 font-sans text-sm text-secondary-800">{reply}</pre>
          <div className="mt-2 flex flex-wrap gap-2">
            <Button size="sm" variant="ghost" leftIcon={<Copy className="h-3.5 w-3.5" />}
              onClick={() => navigator.clipboard.writeText(reply).then(() => toast.success('Copied')).catch(() => toast.error("Couldn't copy"))}>Copy</Button>
            {mail && <a href={mail} className="inline-flex h-8 items-center gap-1.5 rounded-lg px-3 text-sm font-medium text-secondary-600 hover:bg-secondary-100">
              <Mail className="h-3.5 w-3.5" aria-hidden="true" />Open in email</a>}
            {wa && <a href={wa} target="_blank" rel="noopener noreferrer" className="inline-flex h-8 items-center gap-1.5 rounded-lg px-3 text-sm font-medium text-secondary-600 hover:bg-secondary-100">
              <MessageCircle className="h-3.5 w-3.5" aria-hidden="true" />WhatsApp</a>}
          </div>
        </div>
      )}
      <p className="mt-4 text-[11px] text-secondary-400">
        {a.model ? `${a.provider_name ?? 'AI'} · ${a.model}` : 'AI'} · {a.finished_at ? new Date(a.finished_at).toLocaleString() : ''}. Suggestions only — check before acting.
      </p>
    </section>
  );
}

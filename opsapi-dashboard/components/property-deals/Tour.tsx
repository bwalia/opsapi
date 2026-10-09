'use client';

/**
 * Guided tour of every Property Deals page and option (no dependency): it highlights a
 * `data-tour` anchor, explains it, and walks from page to page. The step survives
 * navigation (localStorage). Start it with startTour() ("Take the tour" on Today); it starts
 * by itself once for demo accounts (email containing "demo").
 */
import React, { useCallback, useEffect, useLayoutEffect, useState } from 'react';
import { usePathname, useRouter } from 'next/navigation';
import { X, ArrowLeft, ArrowRight } from 'lucide-react';
import { Button } from '@/components/ui';
import { pdService } from '@/services/property-deals.service';

const KEY = 'pd-tour';
const SEEN = 'pd-tour-seen';
const B = '/dashboard/property-deals';

type Step = { route: string; target?: string; title: string; body: string };

/** route "deal" = the first deal on the board (resolved when the tour gets there). */
export const STEPS: Step[] = [
  { route: `${B}/today`, title: 'Welcome to Property Deals', body: 'A two-minute tour of every page: what each one does and the options on it. Use Next / Back, or press Esc to stop. You can restart it from Today any time.' },
  { route: `${B}/today`, target: 'today-stats', title: 'Your day at a glance', body: 'Open and overdue tasks, approvals waiting for you, and the money at risk from late penalties if completion dates slip.' },
  { route: `${B}/today`, target: 'today-tasks', title: 'Tasks, most urgent first', body: 'Every task you own across all deals, sorted by an urgency score that the rules calculate (not the AI). Filter to overdue or blocking work.' },
  { route: `${B}/today`, target: 'urgency', title: 'Why is it urgent?', body: 'Hover or tab onto the score to see the reasons: time used, closeness to completion, blocking, open enquiries, silence from the other side and money at risk.' },
  { route: `${B}/today`, target: 'task-actions', title: 'Four actions on every task', body: 'Do it (closes it; compliance tasks need evidence), Let AI do it (an agent drafts the work for approval), Assign, and Snooze with a reason. Log contact records calls and WhatsApps.' },
  { route: `${B}/today`, target: 'today-red-deals', title: 'Deals at risk', body: 'Red deals with the reason and the money at risk. Click one to open the deal page.' },
  { route: `${B}/deals`, target: 'deals-board', title: 'Deals board', body: 'One column per stage of the workflow template. Drag a deal to move it: the move only happens if the stage gate allows it, otherwise you see exactly what is blocking.' },
  { route: `${B}/deals`, target: 'deals-view', title: 'Board or list', body: 'Switch to the list for sorting by money at risk, target date or health, and searching by address or postcode.' },
  { route: `${B}/deals`, target: 'new-deal', title: 'New deal', body: 'Create a deal for a property (or convert a lead from the Leads page). The first stage’s tasks are created for you.' },
  { route: 'deal', target: 'deal-header', title: 'The deal page', body: 'Stage, health colour and why, target dates, the predicted completion (slip) and money at risk, all kept up to date by the rules engine.' },
  { route: 'deal', target: 'stage-track', title: 'Stages and gates', body: 'Where the deal is, what’s done and what’s next. “Next stage” checks the gate first and lists anything missing.' },
  { route: 'deal', target: 'tabs', title: 'Everything about the deal', body: 'Tasks, enquiries & blockers, the chase log, documents (upload to secure storage), compliance, matching buyers and the full timeline (audit trail).' },
  { route: `${B}/approvals`, target: 'approvals-list', title: 'Approvals inbox', body: 'Nothing leaves the system without a person: every AI draft, booking, deal pack and offer waits here with its agent, model, cost and sources.' },
  { route: `${B}/approvals`, target: 'approval-editor', title: 'Approve, edit, or reject', body: 'Edit the draft and see the diff, approve as is, or reject with a note — the agent redrafts using your note. Two-person and manager-only rules are enforced.' },
  { route: `${B}/map`, target: 'map-controls', title: 'Deal finder', body: 'Drop a pin, set the radius (5–50 miles) and switch layers: your properties and deals, leads, buyers’ holdings, sold prices, EPCs, listings and auction lots.' },
  { route: `${B}/map`, target: 'map-searches', title: 'Saved searches', body: 'Save a pin + radius and the deal scout re-runs it daily, alerting you to new, reduced, stale and cash-only homes.' },
  { route: `${B}/buyers`, target: 'buyers-list', title: 'Buyers', body: 'Buyer profiles with proof-of-funds status and expiry, budget, areas and strategies. Company buyers get a Companies House check.' },
  { route: `${B}/buyers`, target: 'buyer-matches', title: 'Matches and deal packs', body: 'Each match has a score with a breakdown (budget, area, strategy, yield, condition) and deal-breakers. “Send deal pack” goes through an approval.' },
  { route: `${B}/suppliers`, target: 'suppliers-list', title: 'Suppliers', body: 'Your directory of EPC assessors, surveyors, solicitors and more, with measured turnaround and on-time %.' },
  { route: `${B}/suppliers`, target: 'book-nearest', title: 'Book nearest', body: 'Find the nearest suitable suppliers for a property and create a booking task the booking agent can work on.' },
  { route: `${B}/compliance`, target: 'compliance-list', title: 'Compliance', body: 'Every check across deals: status, evidence, who signed it off and when it expires. Only a named person can pass or waive a check.' },
  { route: `${B}/reports`, target: 'reports', title: 'Reports', body: 'Time per stage, late days and penalty cost, conversion, supplier and solicitor speed, AI usage and cost. Export any data as CSV or JSON.' },
  { route: `${B}/settings`, target: 'settings-tabs', title: 'Settings', body: 'Workflow templates (editor, versions, import/export), SLA and urgency weights, AI providers and models, agents and JobShout, data connectors, mailboxes, and your notifications.' },
  { route: '/dashboard/leads', title: 'Leads', body: 'Open a lead to see its Property Deals fields — kind, situation, deadline, vulnerability and consent — and turn it into a deal with one click. That’s the tour!' },
];

type State = { active: boolean; step: number; dealUuid?: string };

function read(): State {
  if (typeof window === 'undefined') return { active: false, step: 0 };
  try {
    return JSON.parse(localStorage.getItem(KEY) || '') as State;
  } catch {
    return { active: false, step: 0 };
  }
}
function write(s: State) {
  localStorage.setItem(KEY, JSON.stringify(s));
  window.dispatchEvent(new Event(KEY));
}

export function startTour() {
  write({ active: true, step: 0 });
}

export function maybeAutoStartTour(email?: string) {
  if (typeof window === 'undefined' || !email || !/demo/i.test(email) || localStorage.getItem(SEEN)) return;
  localStorage.setItem(SEEN, '1');
  startTour();
}

export default function TourHost() {
  const router = useRouter();
  const pathname = usePathname();
  const [state, setState] = useState<State>({ active: false, step: 0 });
  const [rect, setRect] = useState<DOMRect | null>(null);

  useEffect(() => {
    const sync = () => setState(read());
    sync();
    window.addEventListener(KEY, sync);
    return () => window.removeEventListener(KEY, sync);
  }, []);

  const step = STEPS[state.step];

  const stop = useCallback(() => {
    localStorage.setItem(SEEN, '1');
    write({ active: false, step: 0 });
  }, []);

  const go = useCallback(
    (to: number) => {
      if (to < 0) return;
      if (to >= STEPS.length) return stop();
      write({ ...read(), active: true, step: to });
    },
    [stop],
  );

  // Navigate to the step's page (the deal page uses the first deal on the board).
  useEffect(() => {
    if (!state.active || !step) return;
    (async () => {
      let target = step.route;
      if (target === 'deal') {
        let id = state.dealUuid;
        if (!id) {
          try {
            const deals = (await pdService.deals({ per_page: 1 })).data;
            id = deals?.[0]?.uuid;
          } catch {
            id = undefined;
          }
          if (!id) {
            // No deal yet: skip the deal-page steps.
            const next = STEPS.findIndex((s, i) => i > state.step && s.route !== 'deal');
            return go(next === -1 ? STEPS.length : next);
          }
          write({ ...state, dealUuid: id });
        }
        target = `${B}/deals/${id}`;
      }
      if (pathname !== target) router.push(target);
    })();
  }, [state, step, pathname, router, go]);

  // Find and follow the highlighted element.
  useLayoutEffect(() => {
    if (!state.active || !step?.target) {
      setRect(null);
      return;
    }
    let raf = 0;
    let tries = 0;
    const find = () => {
      const el = document.querySelector(`[data-tour="${step.target}"]`) as HTMLElement | null;
      if (el) {
        el.scrollIntoView({ block: 'center', behavior: 'smooth' });
        setRect(el.getBoundingClientRect());
      } else if (tries++ < 60) {
        raf = window.setTimeout(find, 150) as unknown as number;
      } else {
        setRect(null);
      }
    };
    find();
    const onScroll = () => {
      const el = document.querySelector(`[data-tour="${step.target}"]`) as HTMLElement | null;
      if (el) setRect(el.getBoundingClientRect());
    };
    window.addEventListener('scroll', onScroll, true);
    window.addEventListener('resize', onScroll);
    return () => {
      clearTimeout(raf);
      window.removeEventListener('scroll', onScroll, true);
      window.removeEventListener('resize', onScroll);
    };
  }, [state, step, pathname]);

  useEffect(() => {
    if (!state.active) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') stop();
      if (e.key === 'ArrowRight') go(state.step + 1);
      if (e.key === 'ArrowLeft') go(state.step - 1);
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [state, go, stop]);

  if (!state.active || !step) return null;
  const pad = 6;
  const pop = rect
    ? {
        top: Math.min(window.innerHeight - 220, rect.bottom + 12),
        left: Math.max(12, Math.min(window.innerWidth - 372, rect.left)),
      }
    : { top: window.innerHeight / 2 - 110, left: window.innerWidth / 2 - 180 };

  return (
    <div className="fixed inset-0 z-[2000]" aria-live="polite">
      {rect ? (
        <div
          className="pointer-events-none absolute rounded-xl ring-4 ring-primary-500 transition-all"
          style={{
            top: rect.top - pad,
            left: rect.left - pad,
            width: rect.width + pad * 2,
            height: rect.height + pad * 2,
            boxShadow: '0 0 0 9999px rgba(15, 23, 42, 0.55)',
          }}
        />
      ) : (
        <div className="absolute inset-0 bg-slate-900/55" />
      )}
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="pd-tour-title"
        className="absolute w-[360px] rounded-xl border border-secondary-200 bg-surface-elevated p-4 shadow-2xl"
        style={pop}
      >
        <div className="flex items-start justify-between gap-2">
          <h2 id="pd-tour-title" className="font-semibold text-secondary-900">{step.title}</h2>
          <button type="button" onClick={stop} aria-label="Close the tour" className="rounded p-1 text-secondary-500 hover:bg-secondary-100">
            <X className="h-4 w-4" />
          </button>
        </div>
        <p className="mt-1.5 text-sm text-secondary-600">{step.body}</p>
        <div className="mt-4 flex items-center justify-between">
          <span className="text-xs text-secondary-500">{state.step + 1} / {STEPS.length}</span>
          <div className="flex gap-2">
            <Button size="sm" variant="ghost" onClick={() => go(state.step - 1)} disabled={state.step === 0} leftIcon={<ArrowLeft className="h-4 w-4" />}>
              Back
            </Button>
            <Button size="sm" onClick={() => go(state.step + 1)} rightIcon={<ArrowRight className="h-4 w-4" />} autoFocus>
              {state.step === STEPS.length - 1 ? 'Finish' : 'Next'}
            </Button>
          </div>
        </div>
      </div>
    </div>
  );
}

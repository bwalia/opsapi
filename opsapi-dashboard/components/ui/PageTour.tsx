'use client';

/**
 * A short guided tour of one page (same look as the Property Deals tour): each step highlights an element marked
 * `data-tour="<target>"` (or shows in the middle when it has no target) and explains it, with Back / Next, Esc to stop.
 * Render it only while the tour is open (it starts at step 1 each time it mounts).
 */
import React, { useEffect, useLayoutEffect, useState } from 'react';
import { ArrowLeft, ArrowRight, X } from 'lucide-react';
import Button from './Button';

export interface TourStep {
  /** The `data-tour` value of the element to highlight; none = centred. */
  target?: string;
  title: string;
  body: React.ReactNode;
}

export function PageTour({ steps, onClose }: { steps: TourStep[]; onClose: () => void }) {
  const [i, setI] = useState(0);
  // Where the step's element is: [target, its box]. A box measured for another step is ignored.
  const [box, setBox] = useState<[string, DOMRect] | null>(null);
  const step = steps[i];
  const rect = step?.target && box?.[0] === step.target ? box[1] : null;

  // Bring the step's element into view and follow it while the page scrolls.
  useLayoutEffect(() => {
    const target = step?.target;
    if (!target) return;
    const el = () => document.querySelector(`[data-tour="${target}"]`) as HTMLElement | null;
    el()?.scrollIntoView({ block: 'center', behavior: 'smooth' });
    const follow = () => {
      const r = el()?.getBoundingClientRect();
      setBox(r ? [target, r] : null);
    };
    const raf = requestAnimationFrame(follow);
    const t = window.setTimeout(follow, 350); // after the smooth scroll
    window.addEventListener('scroll', follow, true);
    window.addEventListener('resize', follow);
    return () => {
      cancelAnimationFrame(raf);
      clearTimeout(t);
      window.removeEventListener('scroll', follow, true);
      window.removeEventListener('resize', follow);
    };
  }, [step]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
      if (e.key === 'ArrowRight') setI((x) => Math.min(x + 1, steps.length - 1));
      if (e.key === 'ArrowLeft') setI((x) => Math.max(x - 1, 0));
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose, steps.length]);

  if (!step) return null;
  const last = i === steps.length - 1;
  const pad = 6;
  const below = rect && rect.bottom + 230 < window.innerHeight;
  const pop = rect
    ? {
        top: below ? rect.bottom + 12 : Math.max(12, rect.top - 222),
        left: Math.max(12, Math.min(window.innerWidth - 372, rect.left)),
      }
    : { top: window.innerHeight / 2 - 110, left: Math.max(12, window.innerWidth / 2 - 180) };

  return (
    <div className="fixed inset-0 z-[2000]" aria-live="polite" data-testid="page-tour">
      {rect ? (
        <div
          className="pointer-events-none absolute rounded-xl ring-4 ring-primary-500 transition-all"
          style={{
            top: rect.top - pad, left: rect.left - pad, width: rect.width + pad * 2, height: rect.height + pad * 2,
            boxShadow: '0 0 0 9999px rgba(15, 23, 42, 0.55)',
          }}
        />
      ) : (
        <div className="absolute inset-0 bg-slate-900/55" onClick={onClose} aria-hidden />
      )}
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="page-tour-title"
        className="absolute w-[min(360px,calc(100vw-24px))] rounded-xl border border-secondary-200 bg-surface-elevated p-4 shadow-2xl"
        style={pop}
      >
        <div className="flex items-start justify-between gap-2">
          <h2 id="page-tour-title" className="font-semibold text-secondary-900">{step.title}</h2>
          <button type="button" onClick={onClose} aria-label="Close the tour" className="rounded p-1 text-secondary-500 hover:bg-secondary-100">
            <X className="h-4 w-4" />
          </button>
        </div>
        <div className="mt-1.5 text-sm text-secondary-600">{step.body}</div>
        <div className="mt-4 flex items-center justify-between">
          <span className="text-xs text-secondary-500">{i + 1} / {steps.length}</span>
          <div className="flex gap-2">
            <Button size="sm" variant="ghost" onClick={() => setI(i - 1)} disabled={i === 0} leftIcon={<ArrowLeft className="h-4 w-4" />}>
              Back
            </Button>
            <Button size="sm" onClick={() => (last ? onClose() : setI(i + 1))} rightIcon={last ? undefined : <ArrowRight className="h-4 w-4" />} autoFocus>
              {last ? 'Got it' : 'Next'}
            </Button>
          </div>
        </div>
      </div>
    </div>
  );
}

export default PageTour;

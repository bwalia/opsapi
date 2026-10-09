'use client';

/**
 * Small Property Deals building blocks on top of components/ui: health and status badges,
 * money, the urgency score with its "why", tabs, empty/error states and the page guard
 * (plugin off, no access, setup not done).
 */
import React, { useState } from 'react';
import Link from 'next/link';
import { AlertTriangle, Info, Lock, Power, Loader2 } from 'lucide-react';
import { Badge, Button, Card } from '@/components/ui';
import { cn } from '@/lib/utils';
import type { UrgencyFactor } from '@/services/property-deals.service';
import { pdService, pdErrorText, type PdError } from '@/services/property-deals.service';
import { usePdMe, type PdModule } from './usePd';
import TourHost, { maybeAutoStartTour } from './Tour';
import { useAuthStore } from '@/store/auth.store';
import toast from 'react-hot-toast';

export const BASE = '/dashboard/property-deals';

export function gbp(v: unknown, decimals = 0): string {
  const n = typeof v === 'number' ? v : Number(v);
  if (v === null || v === undefined || Number.isNaN(n)) return '—';
  return n.toLocaleString('en-GB', { style: 'currency', currency: 'GBP', maximumFractionDigits: decimals, minimumFractionDigits: decimals });
}

export function dateText(v?: string | null, withTime = false): string {
  if (!v) return '—';
  const d = new Date(v.length === 10 ? `${v}T00:00:00` : v);
  if (Number.isNaN(d.getTime())) return v;
  return withTime
    ? d.toLocaleString('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })
    : d.toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
}

/** "in 3h" / "2d overdue" for a due time. */
export function dueText(v?: string | null): { text: string; overdue: boolean } {
  if (!v) return { text: 'no deadline', overdue: false };
  const ms = new Date(v).getTime() - Date.now();
  const abs = Math.abs(ms);
  const h = abs / 36e5;
  const part = h < 1 ? `${Math.round(abs / 6e4)}m` : h < 48 ? `${Math.round(h)}h` : `${Math.round(h / 24)}d`;
  return ms < 0 ? { text: `${part} overdue`, overdue: true } : { text: `in ${part}`, overdue: false };
}

const HEALTH = {
  red: { label: 'Red', cls: 'bg-error-500/10 text-error-600 ring-error-500/30', dot: 'bg-error-500' },
  amber: { label: 'Amber', cls: 'bg-warning-500/10 text-warning-600 ring-warning-500/30', dot: 'bg-warning-500' },
  green: { label: 'Green', cls: 'bg-success-500/10 text-success-600 ring-success-500/30', dot: 'bg-success-500' },
} as const;

export function HealthBadge({ health, reasons }: { health?: string; reasons?: string[] }) {
  const h = HEALTH[(health as keyof typeof HEALTH) || 'green'] || HEALTH.green;
  return (
    <span
      className={cn('inline-flex items-center gap-1.5 rounded-full px-2.5 py-0.5 text-xs font-semibold ring-1', h.cls)}
      title={reasons?.length ? reasons.join('\n') : undefined}
    >
      <span className={cn('h-2 w-2 rounded-full', h.dot)} aria-hidden />
      {h.label}
    </span>
  );
}

const STATUS: Record<string, { label: string; variant: 'default' | 'success' | 'warning' | 'error' | 'info' | 'secondary' }> = {
  todo: { label: 'To do', variant: 'default' },
  in_progress: { label: 'In progress', variant: 'info' },
  waiting_third_party: { label: 'Waiting on others', variant: 'warning' },
  agent_running: { label: 'AI working', variant: 'info' },
  awaiting_approval: { label: 'Awaiting approval', variant: 'warning' },
  done: { label: 'Done', variant: 'success' },
  cancelled: { label: 'Cancelled', variant: 'secondary' },
};

export function TaskStatusBadge({ status }: { status?: string }) {
  const s = STATUS[status || 'todo'] || STATUS.todo;
  return <Badge variant={s.variant} size="sm">{s.label}</Badge>;
}

export function label(v?: string | null): string {
  if (!v) return '—';
  return v.replace(/_/g, ' ').replace(/^\w/, (c) => c.toUpperCase());
}

/** The urgency score; the "why" shows on hover and on keyboard focus. */
export function UrgencyScore({ score, why }: { score?: number; why?: UrgencyFactor[] }) {
  const [open, setOpen] = useState(false);
  const v = Math.round(Number(score || 0));
  const tone = v >= 70 ? 'bg-error-500 text-white' : v >= 40 ? 'bg-warning-500 text-white' : 'bg-secondary-200 text-secondary-800';
  return (
    <span className="relative inline-block" onMouseEnter={() => setOpen(true)} onMouseLeave={() => setOpen(false)}>
      <button
        type="button"
        className={cn('min-w-[2.5rem] rounded-md px-2 py-0.5 text-xs font-bold focus:outline-none focus:ring-2 focus:ring-primary-500', tone)}
        onFocus={() => setOpen(true)}
        onBlur={() => setOpen(false)}
        aria-label={`Urgency ${v}. ${why?.map((w) => w.why).join('. ') || ''}`}
        data-tour="urgency"
      >
        {v}
      </button>
      {open && why && why.length > 0 && (
        <span
          role="tooltip"
          className="absolute left-0 top-full z-30 mt-1 w-72 rounded-lg border border-secondary-200 bg-surface-elevated p-3 text-left text-xs shadow-lg"
        >
          <span className="mb-1 block font-semibold text-secondary-900">Why {v}?</span>
          {why.map((w) => (
            <span key={w.factor} className="flex justify-between gap-3 py-0.5 text-secondary-700">
              <span>{w.why}</span>
              <span className="shrink-0 font-mono text-secondary-500">+{Math.round(w.points)}</span>
            </span>
          ))}
        </span>
      )}
    </span>
  );
}

export function Stat({ label: l, value, tone, hint, tour }: { label: string; value: React.ReactNode; tone?: 'error' | 'warning' | 'success'; hint?: string; tour?: string }) {
  return (
    <Card padding="sm" data-tour={tour}>
      <div className="text-xs font-medium uppercase tracking-wide text-secondary-500">{l}</div>
      <div
        className={cn(
          'mt-1 text-2xl font-bold',
          tone === 'error' && 'text-error-600',
          tone === 'warning' && 'text-warning-600',
          tone === 'success' && 'text-success-600',
          !tone && 'text-secondary-900',
        )}
      >
        {value}
      </div>
      {hint && <div className="mt-0.5 text-xs text-secondary-500">{hint}</div>}
    </Card>
  );
}

export function Tabs<T extends string>({ tabs, value, onChange }: { tabs: { key: T; label: string; count?: number }[]; value: T; onChange: (k: T) => void }) {
  return (
    <div role="tablist" className="flex flex-wrap gap-1 border-b border-secondary-200" data-tour="tabs">
      {tabs.map((t) => (
        <button
          key={t.key}
          role="tab"
          type="button"
          aria-selected={value === t.key}
          onClick={() => onChange(t.key)}
          className={cn(
            '-mb-px border-b-2 px-3 py-2 text-sm font-medium transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-primary-500',
            value === t.key ? 'border-primary-500 text-primary-600' : 'border-transparent text-secondary-500 hover:text-secondary-800',
          )}
        >
          {t.label}
          {t.count !== undefined && <span className="ml-1.5 rounded-full bg-secondary-100 px-1.5 text-xs text-secondary-600">{t.count}</span>}
        </button>
      ))}
    </div>
  );
}

export function Empty({ title, children }: { title: string; children?: React.ReactNode }) {
  return (
    <div className="rounded-xl border border-dashed border-secondary-300 p-8 text-center">
      <Info className="mx-auto mb-2 h-6 w-6 text-secondary-400" aria-hidden />
      <div className="font-medium text-secondary-800">{title}</div>
      {children && <div className="mt-1 text-sm text-secondary-500">{children}</div>}
    </div>
  );
}

export function ErrorNote({ error }: { error?: PdError }) {
  if (!error) return null;
  if (error.status === 403) {
    return (
      <div className="flex items-center gap-2 rounded-lg bg-warning-500/10 p-3 text-sm text-warning-700">
        <Lock className="h-4 w-4" aria-hidden /> You don&apos;t have access to this. Ask a workspace admin for a Property Deals role.
      </div>
    );
  }
  return (
    <div className="flex items-center gap-2 rounded-lg bg-error-500/10 p-3 text-sm text-error-700" role="alert">
      <AlertTriangle className="h-4 w-4" aria-hidden /> {error.message}
    </div>
  );
}

export function Spinner({ label: l = 'Loading…' }: { label?: string }) {
  return (
    <div className="flex items-center gap-2 py-10 text-secondary-500" role="status">
      <Loader2 className="h-5 w-5 animate-spin" aria-hidden /> {l}
    </div>
  );
}

/**
 * Wraps every Property Deals page: waits for /me, then shows the page, or why it can't
 * (plugin off in this workspace, no access, setup not done yet).
 */
export function PdPage({ module, children }: { module?: PdModule; children: React.ReactNode }) {
  return (
    <>
      <PdPageBody module={module}>{children}</PdPageBody>
      <TourHost />
    </>
  );
}

function PdPageBody({ module, children }: { module?: PdModule; children: React.ReactNode }) {
  const { me, error, loading, can, reload } = usePdMe();
  const [settingUp, setSettingUp] = useState(false);
  const email = useAuthStore((s) => s.user?.email);
  React.useEffect(() => {
    if (me?.setup_done) maybeAutoStartTour(email);
  }, [me?.setup_done, email]);
  if (loading && !me) return <Spinner />;
  if (error?.code === 'PLUGIN_DISABLED' || (error?.status === 404 && /turned off/i.test(error.message))) {
    return (
      <Card className="mx-auto mt-10 max-w-xl text-center">
        <Power className="mx-auto mb-3 h-8 w-8 text-secondary-400" aria-hidden />
        <h2 className="text-lg font-semibold text-secondary-900">Property Deals is switched off for this workspace</h2>
        <p className="mt-1 text-sm text-secondary-500">
          A workspace admin can switch it on under <Link className="text-primary-600 underline" href="/dashboard/namespace/plugins">Plugins</Link>.
        </p>
      </Card>
    );
  }
  if (error) return <div className="mt-6"><ErrorNote error={error} /></div>;
  if (me && me.setup_done === false) {
    const canSetup = can('settings', 'manage');
    return (
      <Card className="mx-auto mt-10 max-w-xl text-center">
        <h2 className="text-lg font-semibold text-secondary-900">Set up Property Deals</h2>
        <p className="mt-1 text-sm text-secondary-500">This creates the deals board, the roles, the two workflow templates and the bank holidays.</p>
        {canSetup ? (
          <Button
            className="mt-4"
            isLoading={settingUp}
            onClick={async () => {
              setSettingUp(true);
              try {
                await pdService.setup();
                toast.success('Property Deals is set up');
                reload();
              } catch (e) {
                toast.error(pdErrorText(e));
              } finally {
                setSettingUp(false);
              }
            }}
          >
            Set up now
          </Button>
        ) : (
          <p className="mt-3 text-sm text-secondary-500">Ask a manager to set it up.</p>
        )}
      </Card>
    );
  }
  if (module && !can(module, 'read')) return <div className="mt-6"><ErrorNote error={{ status: 403, message: 'No access' }} /></div>;
  return <>{children}</>;
}

import type { ReactNode } from 'react';
import { AlertTriangle, Info, Lightbulb } from 'lucide-react';

type Kind = 'note' | 'warning' | 'tip';

const STYLES: Record<
  Kind,
  { border: string; bg: string; iconColor: string; label: string }
> = {
  note: {
    border: 'border-info-500/30',
    bg: 'bg-info-500/5',
    iconColor: 'text-info-600',
    label: 'Note',
  },
  warning: {
    border: 'border-warning-500/30',
    bg: 'bg-warning-500/5',
    iconColor: 'text-warning-600',
    label: 'Warning',
  },
  tip: {
    border: 'border-accent-500/30',
    bg: 'bg-accent-500/5',
    iconColor: 'text-accent-600',
    label: 'Tip',
  },
};

const ICONS: Record<Kind, typeof Info> = {
  note: Info,
  warning: AlertTriangle,
  tip: Lightbulb,
};

export function Callout({
  kind = 'note',
  children,
}: {
  kind?: Kind;
  children: ReactNode;
}) {
  const s = STYLES[kind];
  const Icon = ICONS[kind];
  return (
    <div className={`flex gap-3 rounded-md border ${s.border} ${s.bg} p-3 text-sm`}>
      <Icon className={`h-5 w-5 shrink-0 ${s.iconColor}`} />
      <div className="text-secondary-700">
        <div className={`text-xs font-semibold uppercase ${s.iconColor}`}>
          {s.label}
        </div>
        <div className="mt-1">{children}</div>
      </div>
    </div>
  );
}

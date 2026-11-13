import React from 'react';
import { CheckCircle2, Circle, CircleDashed, MinusCircle } from 'lucide-react';
import { STATUS_LABEL, type IncomeStatus } from '@/services/my-income.service';

const STYLE: Record<IncomeStatus, { cls: string; Icon: typeof Circle }> = {
  not_started: { cls: 'bg-secondary-100 text-secondary-600', Icon: Circle },
  in_progress: { cls: 'bg-amber-50 text-amber-800', Icon: CircleDashed },
  done: { cls: 'bg-green-50 text-green-700', Icon: CheckCircle2 },
  not_applicable: { cls: 'bg-secondary-100 text-secondary-500', Icon: MinusCircle },
};

/** Status pill with an icon, so it doesn't rely on colour alone. */
export default function StatusBadge({ status }: { status: IncomeStatus }) {
  const { cls, Icon } = STYLE[status];
  return (
    <span className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium ${cls}`}>
      <Icon className="h-3.5 w-3.5" aria-hidden="true" />
      {STATUS_LABEL[status]}
    </span>
  );
}

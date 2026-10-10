'use client';

/**
 * Today: leads whose last reply was hot — call them now, while they're active. Each has a "call now" task
 * (due in a few minutes; the SLA engine escalates it if nobody calls). Hidden when there are none.
 */
import React from 'react';
import Link from 'next/link';
import { Flame, Phone, Check } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Card } from '@/components/ui';
import { pdService, pdErrorText } from '@/services/property-deals.service';
import { usePdData } from './usePd';
import { dueText, label } from './ui';
import { cn } from '@/lib/utils';

export default function HotLeads() {
  const { data, refresh } = usePdData(async () => (await pdService.hotLeads()).data, [], 30_000);
  if (!data?.length) return null;
  return (
    <Card padding="none" className="border-error-200" data-tour="today-hot">
      <div className="flex items-center gap-2 border-b border-secondary-200 p-4">
        <Flame className="h-5 w-5 text-error-600" aria-hidden />
        <h2 className="font-semibold text-secondary-900">Hot leads — call now</h2>
        <span className="rounded-full bg-error-500/10 px-2 text-xs font-medium text-error-700">{data.length}</span>
      </div>
      <ul className="divide-y divide-secondary-100">
        {data.map((h) => {
          const name = `${h.first_name || ''} ${h.last_name || ''}`.trim() || h.company_name || 'Lead';
          const due = h.call_due_at ? dueText(h.call_due_at) : null;
          return (
            <li key={h.lead_uuid} className="flex flex-col gap-2 p-4 sm:flex-row sm:items-center">
              <div className="min-w-0 flex-1">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="font-medium text-secondary-900">{name}</span>
                  {h.company_name && name !== h.company_name && <span className="text-sm text-secondary-500">{h.company_name}</span>}
                  {h.lead_kind && <span className="rounded bg-secondary-100 px-1.5 text-xs text-secondary-600">{label(h.lead_kind)}</span>}
                  <span className="rounded-full bg-error-500/10 px-2 text-xs font-medium text-error-700">{h.hot_score ?? ''}</span>
                </div>
                {h.hot_reason && <p className="mt-0.5 text-sm text-secondary-600">{h.hot_reason}</p>}
                {due && h.call_task_uuid && (
                  <p className={cn('mt-0.5 text-xs', due.overdue ? 'font-semibold text-error-600' : 'text-secondary-500')}>
                    Call {due.overdue ? `— ${due.text}` : due.text}
                  </p>
                )}
              </div>
              <div className="flex flex-wrap gap-2">
                {h.phone ? (
                  <a href={`tel:${h.phone.replace(/\s+/g, '')}`}>
                    <Button size="sm" leftIcon={<Phone className="h-4 w-4" />}>Call {h.phone}</Button>
                  </a>
                ) : (
                  <Link href="/dashboard/leads"><Button size="sm" variant="outline">No number — open lead</Button></Link>
                )}
                {h.call_task_uuid && (
                  <Button
                    size="sm"
                    variant="outline"
                    leftIcon={<Check className="h-4 w-4" />}
                    onClick={async () => {
                      try {
                        await pdService.updateTask(h.call_task_uuid as string, { pd_status: 'done' } as never);
                        toast.success('Call logged as done');
                        refresh();
                      } catch (e) { toast.error(pdErrorText(e)); }
                    }}
                  >
                    Called
                  </Button>
                )}
              </div>
            </li>
          );
        })}
      </ul>
    </Card>
  );
}

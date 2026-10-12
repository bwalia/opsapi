'use client';

/** Property PA — my opportunities (sellers and buyers), with the next action and a quick capture. */
import React from 'react';
import Link from 'next/link';
import { Users, NotebookPen, RefreshCw } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { Badge, Button, Card, buttonClass } from '@/components/ui';
import { ErrorNote, Spinner, Empty, gbp, dateText, dueText } from '@/components/property-deals/ui';
import { usePdData } from '@/components/property-deals/usePd';
import { paService } from '@/services/property-pa.service';
import PaPage, { usePaCan } from '@/components/property-pa/PaPage';

const TEMP: Record<string, 'error' | 'warning' | 'info'> = { hot: 'error', warm: 'warning', cold: 'info' };

export default function OpportunitiesPage() {
  return (
    <PaPage>
      <Opportunities />
    </PaPage>
  );
}

function Opportunities() {
  const { can } = usePaCan();
  const { data, error, loading, refresh } = usePdData(async () => (await paService.opportunities({ status: 'open', mine: true, per_page: 100 })).data, [], 60_000);
  return (
    <div className="space-y-6">
      <PageHeader title="My opportunities" description="Sellers and buyers you're working with" icon={<Users className="h-6 w-6" />}
        actions={
          <>
            {can('property_pa_records', 'create') && can('property_pa_updates', 'create') && (
              <Link className={buttonClass()} href="/dashboard/property-pa/capture"><NotebookPen className="h-4 w-4" aria-hidden />Capture</Link>
            )}
            <Button variant="outline" leftIcon={<RefreshCw className="h-4 w-4" />} onClick={refresh}>Refresh</Button>
          </>
        } />
      <ErrorNote product="Property PA" error={error} />
      {loading && !data ? <Spinner /> : !data?.length ? (
        <Empty title="No open opportunities">Ask a manager to load the demo data, or add one from a capture.</Empty>
      ) : (
        <Card className="overflow-hidden p-0">
          <ul className="divide-y divide-secondary-200">
            {data.map((o) => {
              const due = dueText(o.next_action_at);
              return (
                <li key={o.uuid}>
                  <Link href={`/dashboard/property-pa/opportunities/${o.uuid}`} className="flex flex-wrap items-center justify-between gap-3 px-4 py-3 hover:bg-secondary-50">
                    <div className="min-w-0">
                      <p className="truncate font-medium text-secondary-900">{o.title}</p>
                      <p className="text-xs text-secondary-500">
                        {o.kind === 'buy' ? 'Buyer' : 'Seller'} · last contact {dateText(o.last_meaningful_contact_at)}
                        {o.expectation_price ? ` · minimum ${gbp(o.expectation_price)}` : ''}
                      </p>
                    </div>
                    <div className="flex items-center gap-2">
                      {o.temperature && <Badge size="sm" variant={TEMP[o.temperature]}>{o.temperature}</Badge>}
                      <span className={due.overdue ? 'text-xs text-error-600' : 'text-xs text-secondary-500'}>
                        {o.next_action_at ? `next action ${due.text}` : 'no next action'}
                      </span>
                    </div>
                  </Link>
                </li>
              );
            })}
          </ul>
        </Card>
      )}
    </div>
  );
}

'use client';

/**
 * File My Tax — AI assistant, full page.
 *
 * The same chat that docks beside the File My Tax wizard (components/tax/TaxAgentChat),
 * on its own page for deep links. Not in the sidebar any more: users reach it from
 * File My Tax ("Do it with the AI assistant"). Optional ?tax_year= pins the year.
 */

import React, { Suspense } from 'react';
import Link from 'next/link';
import { useSearchParams } from 'next/navigation';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import TaxAgentChat from '@/components/tax/TaxAgentChat';

function TaxAgentContent() {
  const year = useSearchParams().get('tax_year') || undefined;
  const back = year ? `/dashboard/tax/file?tax_year=${encodeURIComponent(year)}` : '/dashboard/tax/file';
  return (
    <div className="space-y-6">
      <PageHeader
        title="File My Tax — AI assistant"
        description="Chat with the tax assistant — it collects your figures, classifies them, and shows your estimate."
        actions={(
          <Link
            href={back}
            className="rounded-lg border border-secondary-300 px-3 py-2 text-sm font-medium text-secondary-700 hover:bg-secondary-50"
          >
            ← Back to File My Tax
          </Link>
        )}
      />
      <TaxAgentChat taxYear={year} />
    </div>
  );
}

export default function TaxAgentPage() {
  return (
    <ProtectedPage module="tax_transactions" title="File My Tax — AI assistant">
      <Suspense fallback={null}>
        <TaxAgentContent />
      </Suspense>
    </ProtectedPage>
  );
}

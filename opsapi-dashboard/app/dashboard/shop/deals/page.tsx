'use client';

import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { Lock, Search } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { Card, Input } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { shopService } from '@/services/shop.service';
import { dealHref } from '@/components/shop/DealCode';
import { extractApiError } from '@/lib/utils';
import type { ShopDealSearchResult } from '@/types/shop';

const MATCHED_BY: Record<ShopDealSearchResult['matched_by'], string> = {
  deal_code: 'Deal code',
  quote_number: 'Quote number',
  order_number: 'Order number',
  supplier_quote_ref: 'Supplier quote reference',
  customer_email: 'Customer email',
};

function DealsSearch() {
  const router = useRouter();
  const [q, setQ] = useState('');
  const [results, setResults] = useState<ShopDealSearchResult[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  // Search as they type; a full deal code opens the deal page.
  useEffect(() => {
    const term = q.trim();
    if (term.length < 2) return;
    let active = true;
    const t = setTimeout(() => {
      shopService
        .searchDeals(term)
        .then((r) => {
          if (!active) return;
          setError(null);
          if (r.exact) {
            router.push(dealHref(r.exact));
            return;
          }
          setResults(r.results);
        })
        .catch((e) => active && setError(extractApiError(e, 'Search failed')));
    }, 250);
    return () => {
      active = false;
      clearTimeout(t);
    };
  }, [q, router]);

  const shown = q.trim().length >= 2 ? results : null;

  return (
    <div className="space-y-6">
      <PageHeader
        title="Deals"
        description="Each deal has one private code that links the customer’s quotes and orders to supplier requests and purchase orders. Staff only."
        icon={<Lock className="h-5 w-5" />}
      />
      <Card>
        <Input
          label="Find a deal"
          id="deal-search"
          autoFocus
          leftIcon={<Search className="h-4 w-4" />}
          placeholder="WS-DT5Z-994X, WSQ-2026-00021, an order number, a supplier quote ref or the customer’s email"
          value={q}
          onChange={(e) => setQ(e.target.value)}
        />
        {error && <p className="mt-3 text-sm text-error-700" role="alert">{error}</p>}
        {shown && shown.length === 0 && <p className="mt-4 text-sm text-secondary-500">No deal matches “{q.trim()}”.</p>}
        {shown && shown.length > 0 && (
          <ul className="mt-4 divide-y divide-secondary-100">
            {shown.map((r) => (
              <li key={r.deal_code}>
                <Link href={dealHref(r.deal_code)} className="flex flex-wrap items-center justify-between gap-2 py-3 hover:bg-secondary-50">
                  <span className="font-mono text-sm font-semibold text-primary-700">{r.deal_code}</span>
                  <span className="min-w-0 text-xs text-secondary-500">
                    {MATCHED_BY[r.matched_by] ?? r.matched_by}: <span className="text-secondary-800">{r.match}</span>
                    {r.customer && ` · ${r.customer}`}
                  </span>
                </Link>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </div>
  );
}

export default function DealsPage() {
  return (
    <ProtectedPage module="shop" title="Deals">
      <DealsSearch />
    </ProtectedPage>
  );
}

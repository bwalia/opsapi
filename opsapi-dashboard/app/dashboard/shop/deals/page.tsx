'use client';

import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { Lock, Search } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { Card, Input } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { useCurrentNamespace } from '@/contexts/NamespaceContext';
import { shopService } from '@/services/shop.service';
import { dealHref } from '@/components/shop/DealCode';
import { extractApiError, formatDate } from '@/lib/utils';
import type { ShopDealSearchResult, ShopRecentDeal } from '@/types/shop';

const MATCHED_BY: Record<ShopDealSearchResult['matched_by'], string> = {
  deal_code: 'Deal code',
  quote_number: 'Quote number',
  order_number: 'Order number',
  supplier_quote_ref: 'Supplier quote reference',
  customer_email: 'Customer email',
};

/** Looks like a whole deal code ("WS-6VBE-MKFV"): a miss then means "not in this workspace". */
const looksLikeCode = (s: string) => /^[A-Za-z0-9]{1,6}[\s_-]*[A-Za-z0-9]{4}[\s_-]*[A-Za-z0-9]{2,}/.test(s.trim());

function count(n: number, one: string) {
  return `${n} ${one}${n === 1 ? '' : 's'}`;
}

function DealsSearch() {
  const router = useRouter();
  const workspace = useCurrentNamespace();
  const [q, setQ] = useState('');
  const [results, setResults] = useState<ShopDealSearchResult[] | null>(null);
  const [searched, setSearched] = useState('');
  const [recent, setRecent] = useState<ShopRecentDeal[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  // The newest deals, so there is something to open before anyone types.
  useEffect(() => {
    let active = true;
    shopService
      .recentDeals(20)
      .then((r) => active && setRecent(r))
      .catch((e) => active && setError(extractApiError(e, 'Could not load the latest deals')));
    return () => {
      active = false;
    };
  }, []);

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
          setSearched(term);
        })
        .catch((e) => active && setError(extractApiError(e, 'Search failed')));
    }, 250);
    return () => {
      active = false;
      clearTimeout(t);
    };
  }, [q, router]);

  const term = q.trim();
  // Only answers for what is typed now: an older answer is never shown under a newer query.
  const shown = term.length >= 2 && searched === term ? results : null;

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
          placeholder="A deal code, quote or order number, supplier quote ref or the customer’s email"
          value={q}
          onChange={(e) => setQ(e.target.value)}
        />
        {error && <p className="mt-3 text-sm text-error-700" role="alert">{error}</p>}
        {shown && shown.length === 0 && (
          <div className="mt-4 text-sm text-secondary-600" role="status">
            <p>No deal matches “{term}”.</p>
            {looksLikeCode(term) && (
              <p className="mt-1 text-secondary-500">
                Deal codes belong to one workspace. Check the code, and that you are in the workspace it came from
                {workspace?.name ? ` (you are in ${workspace.name})` : ''}. Emails from a test system carry that system’s codes.
              </p>
            )}
          </div>
        )}
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

      {term.length < 2 && (
        <Card>
          <h2 className="text-base font-semibold text-secondary-900">Latest deals</h2>
          {recent === null && !error && <p className="mt-3 text-sm text-secondary-500">Loading…</p>}
          {recent && recent.length === 0 && (
            <p className="mt-3 text-sm text-secondary-500">No deals yet. A deal starts with a new lead, quote or order.</p>
          )}
          {recent && recent.length > 0 && (
            <ul className="mt-2 divide-y divide-secondary-100">
              {recent.map((d) => (
                <li key={d.deal_code}>
                  <Link href={dealHref(d.deal_code)} className="flex flex-wrap items-center justify-between gap-2 py-3 hover:bg-secondary-50">
                    <span className="min-w-0">
                      <span className="font-mono text-sm font-semibold text-primary-700">{d.deal_code}</span>
                      <span className="ml-2 text-sm text-secondary-800">{d.customer ?? 'No customer yet'}</span>
                    </span>
                    <span className="text-xs text-secondary-500">
                      {[count(d.quotes, 'quote'), count(d.orders, 'order'), count(d.purchase_orders, 'PO')].join(' · ')} · {formatDate(d.created_at)}
                    </span>
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </Card>
      )}
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

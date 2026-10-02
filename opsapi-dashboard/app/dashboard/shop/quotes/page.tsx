'use client';

import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { FileText, Plus, Search } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Badge, Button, Card, Input, Pagination, Table } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { usePermissions } from '@/contexts/PermissionsContext';
import { shopService } from '@/services/shop.service';
import { FilterSelect, QuoteStatusBadge, SHOP_MODULE } from '@/components/shop/shared';
import { extractApiError, formatDate, formatDateTime } from '@/lib/utils';
import { formatMoney, humanize } from '@/lib/shop';
import { SHOP_QUOTE_STATUSES, type ShopQuote, type ShopQuoteStatus, type TableColumn } from '@/types';

const PER_PAGE = 25;

function QuotesContent() {
  const router = useRouter();
  const { canCreate } = usePermissions();
  const [rows, setRows] = useState<ShopQuote[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [q, setQ] = useState('');
  const [status, setStatus] = useState<ShopQuoteStatus | ''>('');
  const [page, setPage] = useState(1);

  useEffect(() => {
    const t = setTimeout(() => {
      setQ(search.trim());
      setPage(1);
    }, 300);
    return () => clearTimeout(t);
  }, [search]);

  useEffect(() => {
    let active = true;
    shopService
      .getQuotes({ status, q: q || undefined, limit: PER_PAGE, offset: (page - 1) * PER_PAGE })
      .then((res) => {
        if (!active) return;
        setRows(res.data);
        setTotal(res.meta.total);
      })
      .catch((err) => active && toast.error(extractApiError(err, 'Failed to load quotes')))
      .finally(() => active && setLoading(false));
    return () => {
      active = false;
    };
  }, [status, q, page]);

  const expired = (qt: ShopQuote) => !!qt.valid_until && new Date(qt.valid_until) < new Date() && ['draft', 'sent'].includes(qt.status);

  const columns: TableColumn<ShopQuote>[] = [
    {
      key: 'quote_number',
      header: 'Quote',
      render: (qt) => (
        <div>
          <p className="font-mono font-medium text-secondary-900">{qt.quote_number}</p>
          <p className="text-xs text-secondary-500">
            {qt.source ? humanize(qt.source) : ''}
            {qt.viewed_at ? ' · viewed' : ''}
          </p>
        </div>
      ),
    },
    {
      key: 'customer',
      header: 'Customer',
      render: (qt) => (
        <div className="min-w-0">
          <p className="truncate text-secondary-900">{qt.customer?.name || qt.customer?.email || '—'}</p>
          <p className="truncate text-xs text-secondary-500">{qt.customer?.company || qt.customer?.email}</p>
        </div>
      ),
    },
    {
      key: 'total',
      header: 'Total',
      render: (qt) => (
        <div>
          <p className="font-medium tabular-nums">{formatMoney(qt.subtotal_minor, qt.currency)} <span className="text-xs font-normal text-secondary-500">ex VAT</span></p>
          <p className="text-xs tabular-nums text-secondary-500">{formatMoney(qt.total_minor, qt.currency)} inc VAT</p>
        </div>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      render: (qt) => (
        <div className="flex flex-wrap gap-1">
          <QuoteStatusBadge status={qt.status} />
          {expired(qt) && <Badge size="sm" variant="error">Past validity</Badge>}
        </div>
      ),
    },
    { key: 'valid_until', header: 'Valid until', render: (qt) => <span className="text-sm text-secondary-600">{qt.valid_until ? formatDate(qt.valid_until) : '—'}</span> },
    { key: 'created_at', header: 'Created', render: (qt) => <span className="text-sm text-secondary-600">{formatDateTime(qt.created_at)}</span> },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="Shop quotes"
        description="Quotes from the cart, the AI assistant and phone/email enquiries"
        icon={<FileText className="h-5 w-5" />}
        actions={
          canCreate(SHOP_MODULE) ? (
            <Link href="/dashboard/shop/quotes/new">
              <Button leftIcon={<Plus className="h-4 w-4" />}>Create quote</Button>
            </Link>
          ) : undefined
        }
      />

      <Card padding="md">
        <div className="flex flex-wrap items-center gap-4">
          <div className="min-w-[200px] max-w-sm flex-1">
            <Input placeholder="Quote number, email, company…" aria-label="Search quotes" value={search} onChange={(e) => setSearch(e.target.value)} leftIcon={<Search className="h-4 w-4" />} />
          </div>
          <FilterSelect
            aria-label="Status"
            value={status}
            onChange={(e) => {
              setStatus(e.target.value as ShopQuoteStatus | '');
              setPage(1);
            }}
          >
            <option value="">All statuses</option>
            {SHOP_QUOTE_STATUSES.map((s) => (
              <option key={s} value={s}>{humanize(s)}</option>
            ))}
          </FilterSelect>
        </div>
      </Card>

      <div>
        <Table
          columns={columns}
          data={rows}
          keyExtractor={(qt) => qt.uuid}
          onRowClick={(qt) => router.push(`/dashboard/shop/quotes/${qt.uuid}`)}
          isLoading={loading}
          emptyMessage="No quotes found"
          caption="Shop quotes"
        />
        <Pagination currentPage={page} totalPages={Math.max(1, Math.ceil(total / PER_PAGE))} totalItems={total} perPage={PER_PAGE} onPageChange={setPage} />
      </div>
    </div>
  );
}

export default function ShopQuotesPage() {
  return (
    <ProtectedPage module="shop" title="Shop Quotes">
      <QuotesContent />
    </ProtectedPage>
  );
}

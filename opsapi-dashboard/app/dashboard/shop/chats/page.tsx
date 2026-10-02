'use client';

import React, { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { MessageSquare, Search } from 'lucide-react';
import toast from 'react-hot-toast';
import { PageHeader } from '@/components/layout/PageHeader';
import { Badge, Card, Input, Pagination, Table } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { shopService } from '@/services/shop.service';
import { extractApiError, formatDateTime, truncate } from '@/lib/utils';
import type { ShopChatSession, TableColumn } from '@/types';

const PER_PAGE = 25;

function firstUserMessage(c: ShopChatSession): string {
  return c.summary || c.first_user_message || c.messages?.find((m) => m.role === 'user')?.content || '';
}

function ChatsContent() {
  const router = useRouter();
  const [rows, setRows] = useState<ShopChatSession[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [q, setQ] = useState('');
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
      .getChats({ q: q || undefined, limit: PER_PAGE, offset: (page - 1) * PER_PAGE })
      .then((res) => {
        if (!active) return;
        setRows(res.data);
        setTotal(res.meta.total);
      })
      .catch((err) => active && toast.error(extractApiError(err, 'Failed to load chats')))
      .finally(() => active && setLoading(false));
    return () => {
      active = false;
    };
  }, [q, page]);

  const columns: TableColumn<ShopChatSession>[] = [
    {
      key: 'session',
      header: 'Conversation',
      render: (c) => (
        <div className="min-w-0 max-w-xl">
          <p className="truncate text-secondary-900">{truncate(firstUserMessage(c), 120) || <span className="text-secondary-400">No messages</span>}</p>
          <p className="text-xs text-secondary-500">{c.email || 'Anonymous visitor'}</p>
        </div>
      ),
    },
    { key: 'message_count', header: 'Messages', render: (c) => <span className="tabular-nums">{c.message_count ?? c.messages?.length ?? 0}</span> },
    {
      key: 'outcome',
      header: 'Outcome',
      render: (c) => (
        <div className="flex flex-wrap gap-1">
          {(c.order || c.order_uuid) && <Badge size="sm" variant="success">Order</Badge>}
          {(c.quote || c.quote_uuid) && <Badge size="sm" variant="info">Quote</Badge>}
          {(c.cart || c.cart_uuid) && !(c.order || c.order_uuid) && <Badge size="sm" variant="default">Cart</Badge>}
        </div>
      ),
    },
    { key: 'updated_at', header: 'Last activity', render: (c) => <span className="text-sm text-secondary-600">{formatDateTime(c.updated_at || c.created_at)}</span> },
  ];

  return (
    <div className="space-y-6">
      <PageHeader title="AI assistant chats" description="Transcripts from the shop's AI sales assistant" icon={<MessageSquare className="h-5 w-5" />} />
      <Card padding="md">
        <div className="max-w-sm">
          <Input placeholder="Search email or text…" aria-label="Search chats" value={search} onChange={(e) => setSearch(e.target.value)} leftIcon={<Search className="h-4 w-4" />} />
        </div>
      </Card>
      <div>
        <Table
          columns={columns}
          data={rows}
          keyExtractor={(c) => c.uuid}
          onRowClick={(c) => router.push(`/dashboard/shop/chats/${c.uuid}`)}
          isLoading={loading}
          emptyMessage="No chat sessions yet"
          caption="Chat sessions"
        />
        <Pagination currentPage={page} totalPages={Math.max(1, Math.ceil(total / PER_PAGE))} totalItems={total} perPage={PER_PAGE} onPageChange={setPage} />
      </div>
    </div>
  );
}

export default function ShopChatsPage() {
  return (
    <ProtectedPage module="shop" title="Shop Chats">
      <ChatsContent />
    </ProtectedPage>
  );
}

'use client';

import React, { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import { useParams } from 'next/navigation';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { ArrowLeft, Bot, MessageSquare, User, Wrench } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, Card } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { shopService } from '@/services/shop.service';
import { KeyValue, SectionTitle, ShopError, ShopLoading } from '@/components/shop/shared';
import { cn, extractApiError, formatDateTime } from '@/lib/utils';
import type { ShopChatMessage, ShopChatSession } from '@/types/shop';

function Bubble({ m }: { m: ShopChatMessage }) {
  const isUser = m.role === 'user';
  const isAssistant = m.role === 'assistant';
  const Icon = isUser ? User : isAssistant ? Bot : Wrench;
  return (
    <li className={cn('flex gap-3', isUser && 'flex-row-reverse')}>
      <span
        className={cn(
          'flex h-8 w-8 shrink-0 items-center justify-center rounded-full',
          isUser ? 'bg-primary-500/10 text-primary-600' : isAssistant ? 'bg-secondary-100 text-secondary-700' : 'bg-warning-500/10 text-warning-600'
        )}
        aria-hidden="true"
      >
        <Icon className="h-4 w-4" />
      </span>
      <div className={cn('max-w-[80%] min-w-0', isUser && 'text-right')}>
        <div
          className={cn(
            'inline-block rounded-2xl px-4 py-2.5 text-left text-sm',
            isUser ? 'rounded-tr-sm bg-primary-500 text-white' : 'rounded-tl-sm border border-secondary-200 bg-surface text-secondary-900'
          )}
        >
          {isUser ? (
            <p className="whitespace-pre-wrap break-words">{m.content}</p>
          ) : (
            <div className="prose prose-sm max-w-none break-words dark:prose-invert [&_a]:text-primary-600 [&_p]:my-1 [&_table]:text-xs [&_ul]:my-1">
              <ReactMarkdown remarkPlugins={[remarkGfm]}>{m.content || ''}</ReactMarkdown>
            </div>
          )}
        </div>
        <p className="mt-1 text-xs text-secondary-400">
          <span className="sr-only">{m.role} </span>
          {m.at ? formatDateTime(m.at) : ''}
          {m.tools?.length ? ` · tools: ${m.tools.join(', ')}` : ''}
        </p>
      </div>
    </li>
  );
}

function ChatDetail() {
  const params = useParams();
  const uuid = String(params?.uuid ?? '');
  const [chat, setChat] = useState<ShopChatSession | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [version, setVersion] = useState(0);
  const reload = useCallback(() => setVersion((v) => v + 1), []);

  useEffect(() => {
    let active = true;
    shopService
      .getChat(uuid)
      .then((c) => {
        if (!active) return;
        setChat(c);
        setError(null);
      })
      .catch((err) => active && setError(extractApiError(err, 'Failed to load chat')));
    return () => {
      active = false;
    };
  }, [uuid, version]);

  if (error) return <ShopError message={error} onRetry={reload} />;
  if (!chat) return <ShopLoading label="Loading transcript…" />;

  const messages = chat.messages ?? [];
  const quoteUuid = chat.quote?.uuid ?? chat.quote_uuid;
  const orderUuid = chat.order?.uuid ?? chat.order_uuid;
  const cartUuid = chat.cart?.uuid ?? chat.cart_uuid;

  return (
    <div className="space-y-6">
      <PageHeader
        title="Chat transcript"
        description={`${chat.email || 'Anonymous visitor'} · started ${formatDateTime(chat.created_at)}`}
        icon={<MessageSquare className="h-5 w-5" />}
        actions={
          <Link href="/dashboard/shop/chats">
            <Button variant="ghost" leftIcon={<ArrowLeft className="h-4 w-4" />}>Chats</Button>
          </Link>
        }
      />
      <div className="grid grid-cols-1 gap-6 xl:grid-cols-3">
        <Card className="xl:col-span-2">
          <SectionTitle>{messages.length} messages</SectionTitle>
          {messages.length === 0 ? (
            <p className="py-8 text-center text-sm text-secondary-500">No messages recorded.</p>
          ) : (
            <ol className="space-y-4" aria-label="Transcript">
              {messages.map((m, i) => (
                <Bubble key={i} m={m} />
              ))}
            </ol>
          )}
        </Card>
        <div className="space-y-6">
          <Card>
            <SectionTitle>Linked</SectionTitle>
            <dl className="divide-y divide-secondary-100">
              <KeyValue label="Email">{chat.email ? <a href={`mailto:${chat.email}`} className="text-primary-600 hover:underline">{chat.email}</a> : '—'}</KeyValue>
              <KeyValue label="Cart">{cartUuid ? <span className="font-mono text-xs">{cartUuid}</span> : '—'}</KeyValue>
              <KeyValue label="Quote">
                {quoteUuid ? (
                  <Link href={`/dashboard/shop/quotes/${quoteUuid}`} className="text-primary-600 hover:underline">
                    {chat.quote?.quote_number ?? chat.quote?.number ?? 'View quote'}
                  </Link>
                ) : (
                  '—'
                )}
              </KeyValue>
              <KeyValue label="Order">
                {orderUuid ? (
                  <Link href={`/dashboard/shop/orders/${orderUuid}`} className="text-primary-600 hover:underline">
                    {chat.order?.order_number ?? chat.order?.number ?? 'View order'}
                  </Link>
                ) : (
                  '—'
                )}
              </KeyValue>
              <KeyValue label="Messages">{chat.message_count ?? messages.length}</KeyValue>
              {chat.updated_at && <KeyValue label="Last activity">{formatDateTime(chat.updated_at)}</KeyValue>}
            </dl>
          </Card>
          {chat.summary && (
            <Card>
              <SectionTitle>Summary</SectionTitle>
              <p className="whitespace-pre-wrap text-sm text-secondary-700">{chat.summary}</p>
            </Card>
          )}
        </div>
      </div>
    </div>
  );
}

export default function ShopChatPage() {
  return (
    <ProtectedPage module="shop" title="Shop Chat">
      <ChatDetail />
    </ProtectedPage>
  );
}

'use client';

import React, { useCallback, useEffect, useState } from 'react';
import { MessageSquare } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { marketingService } from '@/services/opsapi-marketing.service';

type Reply = {
  uuid: string;
  channel: string;
  classification: string;
  confidence?: number;
  subject?: string;
  body_text?: string;
  address?: string;
  needs_human?: boolean;
  created_at?: string;
};

export default function MarketingConversationsPage() {
  const [replies, setReplies] = useState<Reply[]>([]);
  const [filter, setFilter] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const res = await marketingService.listReplies({
        per_page: 50,
        ...(filter ? { classification: filter } : {}),
      });
      const data = res.data?.data ?? res.data ?? [];
      setReplies(Array.isArray(data) ? data : data.data || []);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Failed to load replies');
    } finally {
      setLoading(false);
    }
  }, [filter]);

  useEffect(() => {
    void load();
  }, [load]);

  return (
    <div className="space-y-6 p-6">
      <PageHeader
        title="Conversations"
        description="Inbound replies are classified in code. Nothing is auto-sent from a classification."
        icon={<MessageSquare className="h-6 w-6" />}
      />
      <div className="flex flex-wrap gap-2 items-center">
        <label className="text-sm text-muted-foreground">Classification</label>
        <select
          className="rounded border border-border bg-background px-2 py-1 text-sm"
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
        >
          <option value="">All</option>
          {[
            'interested', 'more_info', 'pricing', 'meeting', 'not_interested',
            'unsubscribe', 'out_of_office', 'complaint', 'bounce', 'human_assist', 'uncertain',
          ].map((c) => (
            <option key={c} value={c}>{c}</option>
          ))}
        </select>
        <button type="button" className="text-sm underline" onClick={() => void load()}>
          Refresh
        </button>
      </div>
      {error && <p className="text-sm text-destructive">{error}</p>}
      {loading ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : replies.length === 0 ? (
        <p className="text-sm text-muted-foreground">No replies yet.</p>
      ) : (
        <ul className="divide-y divide-border rounded-lg border border-border">
          {replies.map((r) => (
            <li key={r.uuid} className="p-4 space-y-1">
              <div className="flex flex-wrap gap-2 text-sm">
                <span className="font-medium">{r.classification}</span>
                <span className="text-muted-foreground">{r.channel}</span>
                {r.needs_human && (
                  <span className="text-amber-700 dark:text-amber-400">needs human</span>
                )}
                {r.confidence != null && (
                  <span className="text-muted-foreground">
                    conf {(Number(r.confidence) * 100).toFixed(0)}%
                  </span>
                )}
              </div>
              {r.subject && <p className="text-sm font-medium">{r.subject}</p>}
              {r.body_text && (
                <p className="text-sm text-muted-foreground line-clamp-3">{r.body_text}</p>
              )}
              <p className="text-xs text-muted-foreground">
                {r.address || '—'} · {r.created_at || ''}
              </p>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

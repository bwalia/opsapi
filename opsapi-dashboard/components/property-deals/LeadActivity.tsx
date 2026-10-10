'use client';

/**
 * On the lead drawer: "Recent news" (Companies House events found daily + posts a person captured) for
 * personal follow-ups, and "Replies" (emails matched by sender + WhatsApp / SMS / calls logged here), each
 * scored hot / warm / cold. A hot reply raises a "call now" task and alerts the lead's owner.
 */
import React, { useState } from 'react';
import Link from 'next/link';
import { Newspaper, MessageSquareReply, Trash2, ExternalLink, Flame } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button, Input, Select, Textarea } from '@/components/ui';
import { pdService, pdErrorText, type LeadReply, type LeadSignal, type ReplyChannel, type SignalKind } from '@/services/property-deals.service';
import { usePdData } from './usePd';
import { dateText, label } from './ui';
import { cn } from '@/lib/utils';

const CAPTURE: SignalKind[] = ['social_post', 'website', 'news', 'note'];
const CHANNELS: ReplyChannel[] = ['whatsapp', 'sms', 'phone', 'social', 'email', 'other'];
const TEMP_STYLE: Record<string, string> = {
  hot: 'bg-error-500/10 text-error-700',
  warm: 'bg-warning-500/10 text-warning-700',
  cold: 'bg-secondary-100 text-secondary-600',
};

export function TemperatureBadge({ temperature, score }: { temperature?: string | null; score?: number | null }) {
  if (!temperature) return null;
  return (
    <span className={cn('inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium', TEMP_STYLE[temperature])}>
      {temperature === 'hot' && <Flame className="h-3 w-3" aria-hidden />}
      {label(temperature)}
      {score !== null && score !== undefined ? ` · ${score}` : ''}
    </span>
  );
}

export default function LeadActivity({ leadUuid }: { leadUuid: string }) {
  const news = usePdData(async () => (await pdService.leadSignals(leadUuid)).data, [leadUuid]);
  const replies = usePdData(async () => (await pdService.leadReplies(leadUuid)).data, [leadUuid]);
  return (
    <div className="mt-4 grid gap-4 lg:grid-cols-2">
      <News items={news.data || []} leadUuid={leadUuid} onChanged={news.refresh} />
      <Replies items={replies.data || []} leadUuid={leadUuid} onChanged={replies.refresh} />
    </div>
  );
}

function News({ items, leadUuid, onChanged }: { items: LeadSignal[]; leadUuid: string; onChanged: () => void }) {
  const [f, setF] = useState<{ kind: SignalKind; url: string; text: string }>({ kind: 'social_post', url: '', text: '' });
  const [busy, setBusy] = useState(false);
  return (
    <section aria-labelledby={`news-${leadUuid}`}>
      <h4 id={`news-${leadUuid}`} className="mb-2 flex items-center gap-2 text-sm font-semibold text-secondary-900">
        <Newspaper className="h-4 w-4" aria-hidden /> Recent news
      </h4>
      <p className="mb-2 text-xs text-secondary-500">
        Companies House is checked daily. Paste a post they made (we never fetch social networks) to make the follow-up personal.
      </p>
      <ul className="mb-3 max-h-64 space-y-2 overflow-y-auto">
        {items.length === 0 && <li className="text-sm text-secondary-400">Nothing yet.</li>}
        {items.map((s) => (
          <li key={s.uuid} className="rounded-lg border border-secondary-200 p-2 text-sm">
            <div className="flex items-start justify-between gap-2">
              <span className="font-medium text-secondary-900">{s.title}</span>
              {s.source === 'manual' && (
                <button
                  type="button"
                  aria-label="Delete"
                  className="text-secondary-400 hover:text-error-600"
                  onClick={async () => {
                    try { await pdService.deleteSignal(s.uuid); onChanged(); } catch (e) { toast.error(pdErrorText(e)); }
                  }}
                >
                  <Trash2 className="h-4 w-4" />
                </button>
              )}
            </div>
            <div className="mt-0.5 flex flex-wrap gap-x-2 text-xs text-secondary-500">
              <span>{label(s.kind)}</span>
              <span>{dateText(s.occurred_at)}</span>
              {s.source === 'companies_house' && <span>Companies House</span>}
              {s.url && (
                <a href={s.url} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-0.5 text-primary-600 hover:underline">
                  Open <ExternalLink className="h-3 w-3" aria-hidden />
                </a>
              )}
            </div>
          </li>
        ))}
      </ul>
      <div className="grid gap-2 rounded-lg bg-secondary-50 p-2">
        <div className="grid gap-2 sm:grid-cols-2">
          <Select label="What" value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value as SignalKind })}>
            {CAPTURE.map((k) => <option key={k} value={k}>{label(k)}</option>)}
          </Select>
          <Input label="Link" placeholder="https://…" value={f.url} onChange={(e) => setF({ ...f, url: e.target.value })} />
        </div>
        <Textarea label="What they posted" rows={2} value={f.text} onChange={(e) => setF({ ...f, text: e.target.value })} />
        <div className="flex justify-end">
          <Button
            size="sm"
            variant="outline"
            isLoading={busy}
            disabled={!f.text && !f.url}
            onClick={async () => {
              setBusy(true);
              try {
                await pdService.addLeadSignal(leadUuid, { kind: f.kind, url: f.url || undefined, text: f.text || undefined });
                setF({ ...f, url: '', text: '' });
                onChanged();
              } catch (e) { toast.error(pdErrorText(e)); } finally { setBusy(false); }
            }}
          >
            Add to news
          </Button>
        </div>
      </div>
    </section>
  );
}

function Replies({ items, leadUuid, onChanged }: { items: LeadReply[]; leadUuid: string; onChanged: () => void }) {
  const [f, setF] = useState<{ channel: ReplyChannel; text: string }>({ channel: 'whatsapp', text: '' });
  const [busy, setBusy] = useState(false);
  return (
    <section aria-labelledby={`replies-${leadUuid}`}>
      <h4 id={`replies-${leadUuid}`} className="mb-2 flex items-center gap-2 text-sm font-semibold text-secondary-900">
        <MessageSquareReply className="h-4 w-4" aria-hidden /> Replies
      </h4>
      <p className="mb-2 text-xs text-secondary-500">
        Emails from this lead arrive here automatically. Log WhatsApp, SMS or call replies below: a hot one alerts the owner to call now.
      </p>
      <ul className="mb-3 max-h-64 space-y-2 overflow-y-auto">
        {items.length === 0 && <li className="text-sm text-secondary-400">No replies yet.</li>}
        {items.map((r) => (
          <li key={r.uuid} className="rounded-lg border border-secondary-200 p-2 text-sm">
            <div className="flex flex-wrap items-center gap-2">
              <TemperatureBadge temperature={r.reply_temperature} score={r.reply_score} />
              <span className="text-xs text-secondary-500">{label(r.channel)} · {dateText(r.received_at, true)}</span>
              {r.hot_task_uuid && (
                <Link href="/dashboard/property-deals/today" className="text-xs font-medium text-error-600 hover:underline">Call task</Link>
              )}
            </div>
            <p className="mt-1 line-clamp-3 text-secondary-800">{r.body_text || r.subject}</p>
            {r.reply_reason && <p className="mt-0.5 text-xs text-secondary-500">{r.reply_reason}</p>}
          </li>
        ))}
      </ul>
      <div className="grid gap-2 rounded-lg bg-secondary-50 p-2">
        <Select label="Came by" value={f.channel} onChange={(e) => setF({ ...f, channel: e.target.value as ReplyChannel })}>
          {CHANNELS.map((c) => <option key={c} value={c}>{label(c)}</option>)}
        </Select>
        <Textarea label="What they said" rows={2} value={f.text} onChange={(e) => setF({ ...f, text: e.target.value })} />
        <div className="flex justify-end">
          <Button
            size="sm"
            isLoading={busy}
            disabled={!f.text.trim()}
            onClick={async () => {
              setBusy(true);
              try {
                const r = (await pdService.logLeadReply(leadUuid, { channel: f.channel, text: f.text })).data;
                if (r.reply_temperature === 'hot') toast.success(`Hot lead — call task created, ${r.alerted ?? 0} person alerted`);
                else toast.success(`Logged (${r.reply_temperature})`);
                setF({ ...f, text: '' });
                onChanged();
              } catch (e) { toast.error(pdErrorText(e)); } finally { setBusy(false); }
            }}
          >
            Log reply
          </Button>
        </div>
      </div>
    </section>
  );
}

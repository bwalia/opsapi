'use client';

/** One buyer ↔ property match: score, per-factor breakdown with the why, deal-breakers, send deal pack. */
import React from 'react';
import { Send } from 'lucide-react';
import toast from 'react-hot-toast';
import { Button } from '@/components/ui';
import { pdService, pdErrorText, type MatchWithBreakdown } from '@/services/property-deals.service';
import { label } from './ui';
import { cn } from '@/lib/utils';

export default function MatchRow({ m, canSend, onChanged, showProperty }: { m: MatchWithBreakdown; canSend: boolean; onChanged: () => void; showProperty?: boolean }) {
  const b = m.breakdown as Record<string, { weight?: number; fit?: number; points?: number; why?: string } | string[]>;
  const factors = ['budget', 'area', 'strategy', 'yield', 'condition'] as const;
  const breakers = (b.deal_breakers as string[]) || [];
  return (
    <li className="p-4 text-sm">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-3">
          <span className={cn('rounded-md px-2 py-0.5 text-sm font-bold', Number(m.score) >= 70 ? 'bg-success-500 text-white' : Number(m.score) >= 40 ? 'bg-warning-500 text-white' : 'bg-secondary-200 text-secondary-800')}>{Math.round(Number(m.score))}</span>
          <span className="font-medium text-secondary-900">{showProperty ? `${m.address_line1 || ''} ${m.postcode || ''}` : m.buyer_name}</span>
          <span className="text-xs text-secondary-500">{label(m.status)}</span>
        </div>
        {canSend && m.status === 'suggested' && !breakers.length && (
          <Button size="sm" variant="outline" leftIcon={<Send className="h-4 w-4" />} onClick={async () => {
            try { await pdService.sendDealPack(m.uuid); toast.success('Deal pack is waiting for approval'); onChanged(); } catch (e) { toast.error(pdErrorText(e)); }
          }}>Send deal pack</Button>
        )}
      </div>
      {breakers.length > 0 && <p className="mt-1 text-xs font-medium text-error-600">Deal-breaker: {breakers.map(label).join(', ')}</p>}
      <div className="mt-2 grid gap-1 sm:grid-cols-5">
        {factors.map((k) => {
          const f = b[k] as { weight?: number; fit?: number; points?: number; why?: string } | undefined;
          return (
            <div key={k} className="rounded-lg bg-secondary-50 p-2" title={f?.why}>
              <div className="flex justify-between text-xs text-secondary-500"><span>{label(k)}</span><span>{f?.points ?? 0}/{f?.weight ?? 0}</span></div>
              <div className="mt-1 h-1.5 rounded-full bg-secondary-200"><div className="h-1.5 rounded-full bg-primary-500" style={{ width: `${Math.round((f?.fit ?? 0) * 100)}%` }} /></div>
              <div className="mt-1 truncate text-xs text-secondary-600">{f?.why}</div>
            </div>
          );
        })}
      </div>
    </li>
  );
}


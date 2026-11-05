'use client';

/**
 * The pipeline board: one column per stage with its count, value and cards.
 * Drag a card to another column to move the lead (Lost asks why, Nurture asks
 * when to come back; Converted happens on the lead page). Every card also has
 * a "Move to" menu so the board works without a mouse.
 */
import React, { useState } from 'react';
import Link from 'next/link';
import toast from 'react-hot-toast';
import { AlertTriangle, CalendarClock, GripVertical, Phone, Sparkles } from 'lucide-react';
import { cn } from '@/lib/utils';
import {
  leadError, leadsService, type Board, type BoardCard, type LeadStage,
} from '@/services/leads.service';
import { Avatar, dueText, fullName, money, ScoreBadge, STAGE_STYLE, STEP_LABEL } from './ui';
import { StageModal } from './StageModal';

export function PipelineBoard({
  board, lostReasons, onChanged,
}: {
  board: Board;
  lostReasons: string[];
  onChanged: () => void;
}) {
  const [dragging, setDragging] = useState<BoardCard | null>(null);
  const [over, setOver] = useState<LeadStage | null>(null);
  const [parked, setParked] = useState<{ card: BoardCard; target: LeadStage } | null>(null);
  const [moving, setMoving] = useState<string | null>(null);

  const move = async (card: BoardCard, target: LeadStage) => {
    if (card.status === target) return;
    if (target === 'converted') {
      toast('Open the lead and press “Convert to deal” — it creates the contact and the deal.');
      return;
    }
    if (card.status === 'converted') {
      toast.error('A converted lead stays converted. Work continues on its deal.');
      return;
    }
    if (target === 'lost' || target === 'nurture') {
      setParked({ card, target });
      return;
    }
    setMoving(card.uuid);
    try {
      await leadsService.move(card.uuid, target);
      toast.success(`${fullName(card)} → ${board.stages.find((s) => s.key === target)?.label ?? target}`);
      onChanged();
    } catch (e) {
      toast.error(leadError(e).message);
    } finally {
      setMoving(null);
    }
  };

  return (
    <>
      <div className="-mx-1 flex gap-3 overflow-x-auto pb-3" role="list" aria-label="Lead pipeline">
        {board.stages.map((col) => {
          const style = STAGE_STYLE[col.key];
          const isOver = over === col.key && dragging && dragging.status !== col.key;
          return (
            <section key={col.key} role="listitem" aria-label={`${col.label}: ${col.count} leads`}
              onDragOver={(e) => { if (dragging) { e.preventDefault(); setOver(col.key); } }}
              onDragLeave={() => setOver((o) => (o === col.key ? null : o))}
              onDrop={(e) => { e.preventDefault(); setOver(null); if (dragging) move(dragging, col.key); setDragging(null); }}
              className={cn('flex w-72 shrink-0 flex-col rounded-xl border bg-secondary-50/70 transition-colors',
                isOver ? 'border-primary-400 bg-primary-50/60' : 'border-secondary-200')}>
              <header className="sticky top-0 rounded-t-xl border-b border-secondary-200 bg-white/90 px-3 py-2.5 backdrop-blur">
                <div className="flex items-center justify-between gap-2">
                  <h3 className="flex items-center gap-2 text-sm font-semibold text-secondary-900">
                    <span className={cn('h-2 w-2 rounded-full', style.dot)} aria-hidden="true" />
                    {col.label}
                    <span className="rounded-full bg-secondary-100 px-2 py-0.5 text-xs font-medium text-secondary-600">{col.count}</span>
                  </h3>
                  {col.overdue > 0 && (
                    <span className="inline-flex items-center gap-1 rounded-full bg-error-50 px-2 py-0.5 text-[11px] font-medium text-error-700"
                      title="Next steps past their time">
                      <AlertTriangle className="h-3 w-3" aria-hidden="true" />{col.overdue} late
                    </span>
                  )}
                </div>
                <p className="mt-0.5 text-xs text-secondary-500">
                  {col.value > 0 ? `${money(col.value, board.currency, true)} estimated` : 'No value estimated yet'}
                  {!col.open && col.key !== 'nurture' ? ` · last ${board.recent_days} days` : ''}
                </p>
              </header>
              <div className="flex max-h-[62vh] min-h-[6rem] flex-1 flex-col gap-2 overflow-y-auto p-2">
                {col.leads.length === 0 && (
                  <p className="px-2 py-6 text-center text-xs text-secondary-400">
                    {col.key === 'new' ? 'New leads land here.' : 'Drag a lead here.'}
                  </p>
                )}
                {col.leads.map((card) => {
                  const due = dueText(card.next_action_at);
                  return (
                    <article key={card.uuid} draggable={card.status !== 'converted'}
                      onDragStart={(e) => { setDragging(card); e.dataTransfer.effectAllowed = 'move'; }}
                      onDragEnd={() => { setDragging(null); setOver(null); }}
                      className={cn('group rounded-lg border border-secondary-200 bg-white p-3 shadow-sm transition hover:border-primary-300 hover:shadow',
                        moving === card.uuid && 'opacity-50', dragging?.uuid === card.uuid && 'ring-2 ring-primary-300')}>
                      <div className="flex items-start gap-2">
                        <GripVertical className="mt-0.5 h-4 w-4 shrink-0 cursor-grab text-secondary-300 group-hover:text-secondary-400" aria-hidden="true" />
                        <div className="min-w-0 flex-1">
                          <div className="flex items-start justify-between gap-2">
                            <Link href={`/dashboard/leads/${card.uuid}`} className="truncate text-sm font-semibold text-secondary-900 hover:text-primary-600 focus:outline-none focus-visible:underline">
                              {fullName(card)}
                            </Link>
                            {card.ai_status === 'pending' || card.ai_status === 'running'
                              ? <Sparkles className="h-4 w-4 shrink-0 animate-pulse text-primary-400" aria-label="AI is analysing" />
                              : <ScoreBadge score={card.ai_score} />}
                          </div>
                          {card.company_name && <p className="truncate text-xs text-secondary-500">{card.company_name}</p>}
                          {card.ai_summary && <p className="mt-1 line-clamp-2 text-xs text-secondary-600">{card.ai_summary}</p>}
                          <div className="mt-2 flex items-center justify-between gap-2">
                            <span className="text-xs font-medium text-secondary-700">
                              {card.estimated_value ? money(card.estimated_value, card.currency || board.currency, true) : ''}
                            </span>
                            <Avatar name={card.owner_name} />
                          </div>
                          {card.next_action_at && (
                            <p className={cn('mt-2 flex items-center gap-1 text-[11px]',
                              due.overdue ? 'font-medium text-error-600' : due.soon ? 'font-medium text-amber-700' : 'text-secondary-500')}>
                              {card.next_action_type === 'call' ? <Phone className="h-3 w-3" aria-hidden="true" />
                                : <CalendarClock className="h-3 w-3" aria-hidden="true" />}
                              {STEP_LABEL[card.next_action_type ?? ''] ?? 'Next step'} {due.text}
                            </p>
                          )}
                          {card.status !== 'converted' && (
                            <label className="sr-only" htmlFor={`move-${card.uuid}`}>Move {fullName(card)} to</label>
                          )}
                          {card.status !== 'converted' && (
                            <select id={`move-${card.uuid}`} value="" onChange={(e) => e.target.value && move(card, e.target.value as LeadStage)}
                              className="mt-2 w-full rounded-md border border-transparent bg-transparent px-1 py-0.5 text-[11px] text-secondary-500 hover:border-secondary-200 focus:border-primary-300 focus:outline-none">
                              <option value="">Move to…</option>
                              {board.stages.filter((s) => s.key !== card.status && s.key !== 'converted').map((s) => (
                                <option key={s.key} value={s.key}>{s.label}</option>
                              ))}
                            </select>
                          )}
                        </div>
                      </div>
                    </article>
                  );
                })}
                {col.count > col.leads.length && (
                  <Link href={`/dashboard/leads?view=list&stage=${col.key}`} className="px-2 py-1 text-center text-xs font-medium text-primary-600 hover:underline">
                    See all {col.count}
                  </Link>
                )}
              </div>
            </section>
          );
        })}
      </div>
      <StageModal lead={parked?.card ?? null} target={parked?.target ?? null} lostReasons={lostReasons}
        onClose={() => setParked(null)} onDone={() => { setParked(null); onChanged(); }} />
    </>
  );
}

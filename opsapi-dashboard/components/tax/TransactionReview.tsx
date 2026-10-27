'use client';

/**
 * "Check your transactions" — every row we read from the customer's statements for a
 * tax year, with how we classified it and why, so they can confirm it before anything
 * is filed. Picking a category or pressing "Looks right" confirms a row; "Confirm the
 * rest" confirms every AI-sorted row after an explicit consent tick. Flagged rows are
 * never bulk-confirmed. Filing requires every row confirmed (routes/tax-filing).
 */

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import Link from 'next/link';
import {
  AlertTriangle,
  CheckCircle2,
  ChevronDown,
  ChevronUp,
  ExternalLink,
  FileText,
  Loader2,
  Search,
  ShieldCheck,
  Undo2,
} from 'lucide-react';
import toast from 'react-hot-toast';
import { Input, Modal, Pagination, SearchableSelect, Table } from '@/components/ui';
import { taxService, type TaxCategory, type TaxTransaction } from '@/services/tax.service';
import { formatCurrency, formatDate, snakeToTitle, extractApiError } from '@/lib/utils';
import type { TableColumn } from '@/types';

const PER_PAGE = 25;
const gbp = (n?: number) => formatCurrency(Math.abs(Number(n ?? 0)), 'GBP', 'en-GB');

type Filter = 'TO_CHECK' | 'UNCONFIRMED' | 'CREDIT' | 'DEBIT' | 'ALL';

const isConfirmed = (t: TaxTransaction) => t.classification_status === 'CONFIRMED';
const isFlagged = (t: TaxTransaction) => t.classification_status === 'NEEDS_REVIEW' || t.classification_status === 'PENDING';
const isUncategorised = (t: TaxTransaction) => !t.category || t.category === 'uncategorised_expense';

// Where the row ends up on the return, in plain English.
function treatment(t: TaxTransaction): { text: string; tone: 'in' | 'out' | 'off' } {
  const box = t.hmrc_box ? ` · Box ${t.hmrc_box}` : '';
  if (t.non_business) {
    return { text: t.transaction_type === 'CREDIT' ? 'Not income — left off your return' : 'Personal — not claimed', tone: 'off' };
  }
  if (t.transaction_type === 'CREDIT') return { text: `Business income${box}`, tone: 'in' };
  if (t.is_tax_deductible && t.hmrc_box) return { text: `Allowable expense${box}`, tone: 'out' };
  return { text: 'Not an allowable expense', tone: 'off' };
}

function sourceLabel(t: TaxTransaction): string {
  if (t.is_manually_reviewed) return 'You';
  if (t.classified_by === 'rule_engine') return 'Known merchant';
  if (t.classified_by === 'ai') {
    return t.confidence_score != null ? `AI · ${Math.round(Number(t.confidence_score) * 100)}% sure` : 'AI';
  }
  return 'Best guess';
}

interface Props {
  taxYear: string;
  total: number;      // rows for the year (from the filing overview)
  confirmed: number;
  toCheck: number;    // flagged by the classifier
  onChanged: () => void;
}

export default function TransactionReview({ taxYear, total, confirmed, toCheck, onChanged }: Props) {
  const allDone = total > 0 && confirmed >= total;
  const [open, setOpen] = useState(!allDone);
  const [filter, setFilter] = useState<Filter>(toCheck > 0 ? 'TO_CHECK' : 'UNCONFIRMED');
  const [rows, setRows] = useState<TaxTransaction[]>([]);
  const [count, setCount] = useState(0);
  const [pages, setPages] = useState(0);
  const [page, setPage] = useState(1);
  const [loading, setLoading] = useState(false);
  const [search, setSearch] = useState('');
  const [debounced, setDebounced] = useState('');
  const [categories, setCategories] = useState<TaxCategory[]>([]);
  const [editing, setEditing] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [consentOpen, setConsentOpen] = useState(false);
  const [consent, setConsent] = useState(false);
  const [confirmingAll, setConfirmingAll] = useState(false);
  const fetchId = useRef(0);

  useEffect(() => {
    const t = setTimeout(() => setDebounced(search), 350);
    return () => clearTimeout(t);
  }, [search]);
  useEffect(() => { setPage(1); }, [debounced, filter, taxYear]);
  useEffect(() => { if (allDone) setOpen(false); }, [allDone]);

  useEffect(() => {
    taxService.getCategories().then(setCategories).catch(() => { /* labels fall back to keys */ });
  }, []);
  const labelFor = useMemo(() => {
    const m: Record<string, string> = {};
    for (const c of categories) if (c.key) m[c.key] = c.name;
    return (key?: string) => (key ? m[key] || snakeToTitle(key) : '');
  }, [categories]);

  const load = useCallback(async () => {
    const id = ++fetchId.current;
    setLoading(true);
    try {
      const res = await taxService.getTransactions({
        tax_year: taxYear,
        page,
        limit: PER_PAGE,
        search: debounced || undefined,
        classification_status: filter === 'TO_CHECK' || filter === 'UNCONFIRMED' ? filter : undefined,
        transaction_type: filter === 'CREDIT' || filter === 'DEBIT' ? filter : undefined,
        sort_by: 'transaction_date',
        sort_order: 'ASC',
      });
      if (id !== fetchId.current) return;
      setRows(res.data);
      setCount(res.total);
      setPages(res.total_pages);
    } catch {
      if (id === fetchId.current) toast.error('Could not load your transactions');
    } finally {
      if (id === fetchId.current) setLoading(false);
    }
  }, [taxYear, page, debounced, filter]);

  useEffect(() => { if (open) load(); }, [open, load]);

  const refresh = () => { load(); onChanged(); };

  const setStatus = async (t: TaxTransaction, status: 'CONFIRMED' | 'CLASSIFIED') => {
    setBusy(t.uuid);
    try {
      await taxService.updateTransaction(t.uuid, { classification_status: status });
      refresh();
    } catch {
      toast.error('Could not update this transaction');
    } finally {
      setBusy(null);
    }
  };

  // Choosing a category is the customer's own decision → confirmed.
  const recategorise = async (t: TaxTransaction, category: string) => {
    setEditing(null);
    if (!category || category === t.category) return;
    setBusy(t.uuid);
    try {
      await taxService.updateTransaction(t.uuid, { category, classification_status: 'CONFIRMED' });
      toast.success(`Moved to ${labelFor(category)}`);
      refresh();
    } catch {
      toast.error('Could not change the category');
    } finally {
      setBusy(null);
    }
  };

  const confirmRest = async () => {
    setConfirmingAll(true);
    try {
      const r = await taxService.confirmTransactionsForYear(taxYear);
      setConsentOpen(false);
      setConsent(false);
      toast.success(
        r.still_to_check > 0
          ? `Confirmed ${r.confirmed}. ${r.still_to_check} still need your look.`
          : `Confirmed ${r.confirmed} — all done.`,
      );
      if (r.still_to_check > 0) setFilter('UNCONFIRMED');
      refresh();
    } catch (err: unknown) {
      toast.error(extractApiError(err, 'Could not confirm your transactions'));
    } finally {
      setConfirmingAll(false);
    }
  };

  const openStatement = async (statementUuid: string) => {
    // Open the tab inside the click so pop-up blockers allow it, then point it at the file.
    const w = window.open('', '_blank');
    try {
      const url = await taxService.getStatementFileUrl(statementUuid);
      if (!url) throw new Error('no url');
      if (w) { w.opener = null; w.location.href = url; } else window.location.assign(url);
    } catch {
      w?.close();
      toast.error('Could not open the original statement');
    }
  };

  const optionsFor = (t: TaxTransaction) =>
    categories
      .filter((c) => (t.transaction_type === 'CREDIT' ? c.category_type === 'income' || c.non_business : c.category_type === 'expense'))
      .map((c) => ({
        value: c.key || c.name,
        label: c.name,
        hint: c.non_business ? 'Not on return' : c.category_type === 'income' ? 'Income' : 'Expense',
      }));

  const columns: TableColumn<TaxTransaction>[] = [
    {
      key: 'transaction_date',
      header: 'Date',
      width: 'w-28',
      render: (t) => <span className="whitespace-nowrap text-sm text-secondary-700">{formatDate(t.transaction_date)}</span>,
    },
    {
      key: 'description',
      header: 'What we read',
      render: (t) => (
        <div className="min-w-[200px] max-w-md">
          <p className="text-sm font-medium text-secondary-900 wrap-break-word">{t.description}</p>
          <p className="mt-0.5 flex flex-wrap items-center gap-x-2 text-xs text-secondary-500">
            {t.statement_uuid ? (
              <button
                type="button"
                onClick={() => openStatement(t.statement_uuid!)}
                className="inline-flex items-center gap-1 hover:text-primary-600 hover:underline"
                title="Open the original statement"
              >
                <FileText className="h-3 w-3" />
                <span className="max-w-[180px] truncate">{t.statement_file_name || 'Statement'}</span>
                <ExternalLink className="h-3 w-3" />
              </button>
            ) : null}
            {t.balance != null && <span className="tabular-nums">Balance {formatCurrency(Number(t.balance), 'GBP', 'en-GB')}</span>}
          </p>
        </div>
      ),
    },
    {
      key: 'amount',
      header: 'Amount',
      width: 'w-32',
      render: (t) => {
        const credit = t.transaction_type === 'CREDIT';
        return (
          <div className="whitespace-nowrap text-right">
            <p className={`text-sm font-semibold tabular-nums ${credit ? 'text-green-700' : 'text-secondary-900'}`}>
              {credit ? '+' : '−'}{gbp(t.amount)}
            </p>
            <p className="text-[11px] text-secondary-400">{credit ? 'Money in' : 'Money out'}</p>
          </div>
        );
      },
    },
    {
      key: 'category',
      header: 'How we sorted it',
      render: (t) => {
        const tr = treatment(t);
        return (
          <div className="min-w-[220px] max-w-sm space-y-1">
            {editing === t.uuid ? (
              <SearchableSelect
                options={optionsFor(t)}
                value={t.category || ''}
                onChange={(v) => recategorise(t, v)}
                onClose={() => setEditing(null)}
                placeholder="Choose a category…"
                searchPlaceholder="Search categories…"
                size="sm"
                autoFocus
              />
            ) : (
              <button
                type="button"
                onClick={() => setEditing(t.uuid)}
                className="group inline-flex max-w-full items-center gap-1 rounded-md border border-transparent px-1.5 py-0.5 -ml-1.5 text-left text-sm font-medium text-secondary-900 hover:border-secondary-200 hover:bg-secondary-50"
                title="Change category"
              >
                <span className="truncate">
                  {isUncategorised(t) ? <span className="italic text-amber-700">Not sorted yet</span> : labelFor(t.category)}
                </span>
                <ChevronDown className="h-3.5 w-3.5 shrink-0 text-secondary-400 group-hover:text-secondary-600" />
              </button>
            )}
            <p className={`text-xs ${tr.tone === 'in' ? 'text-green-700' : tr.tone === 'out' ? 'text-primary-700' : 'text-secondary-500'}`}>
              {tr.text}
            </p>
            <p className="text-[11px] text-secondary-400">
              <span className="font-medium text-secondary-500">{sourceLabel(t)}</span>
              {t.reasoning && !t.is_manually_reviewed && (
                <span className="line-clamp-2" title={t.reasoning}> — {t.reasoning}</span>
              )}
            </p>
          </div>
        );
      },
    },
    {
      key: 'classification_status',
      header: 'Your check',
      width: 'w-40',
      render: (t) => {
        if (busy === t.uuid) return <Loader2 className="h-4 w-4 animate-spin text-secondary-400" />;
        if (isConfirmed(t)) {
          return (
            <div className="flex items-center gap-2 whitespace-nowrap">
              <span className="inline-flex items-center gap-1 rounded-full bg-green-100 px-2 py-0.5 text-xs font-medium text-green-700">
                <CheckCircle2 className="h-3.5 w-3.5" /> Confirmed
              </span>
              <button
                type="button"
                onClick={() => setStatus(t, 'CLASSIFIED')}
                className="text-secondary-400 hover:text-secondary-700"
                title="Undo"
                aria-label="Undo confirmation"
              >
                <Undo2 className="h-3.5 w-3.5" />
              </button>
            </div>
          );
        }
        return (
          <div className="space-y-1">
            {isFlagged(t) && (
              <span className="inline-flex items-center gap-1 whitespace-nowrap rounded-full bg-amber-100 px-2 py-0.5 text-[11px] font-medium text-amber-800">
                <AlertTriangle className="h-3 w-3" /> Please check
              </span>
            )}
            {isUncategorised(t) ? (
              <button
                type="button"
                onClick={() => setEditing(t.uuid)}
                className="block whitespace-nowrap rounded-lg border border-amber-300 px-2.5 py-1 text-xs font-medium text-amber-800 hover:bg-amber-50"
              >
                Choose a category
              </button>
            ) : (
              <button
                type="button"
                onClick={() => setStatus(t, 'CONFIRMED')}
                className="block whitespace-nowrap rounded-lg border border-primary-300 px-2.5 py-1 text-xs font-medium text-primary-700 hover:bg-primary-50"
              >
                Looks right
              </button>
            )}
          </div>
        );
      },
    },
  ];

  const pct = total > 0 ? Math.round((confirmed / total) * 100) : 0;
  const rest = Math.max(total - confirmed - toCheck, 0);
  const tabs: Array<{ key: Filter; label: string }> = [
    { key: 'TO_CHECK', label: `Please check (${toCheck})` },
    { key: 'UNCONFIRMED', label: `Not confirmed (${Math.max(total - confirmed, 0)})` },
    { key: 'CREDIT', label: 'Money in' },
    { key: 'DEBIT', label: 'Money out' },
    { key: 'ALL', label: `All (${total})` },
  ];

  if (total === 0) {
    return (
      <p className="flex items-start gap-2 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
        <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
        <span>
          No transactions for {taxYear} yet — upload your bank statements in{' '}
          <Link href="/dashboard/tax/agent" className="font-medium underline">File with AI</Link>.
        </span>
      </p>
    );
  }

  return (
    <div className="space-y-4">
      {/* Progress + bulk confirm */}
      <div className="flex flex-col gap-3 rounded-xl border border-secondary-200 bg-secondary-50/60 p-4 sm:flex-row sm:items-center">
        <div className="min-w-0 flex-1">
          <div className="flex items-baseline justify-between gap-2">
            <p className="text-sm font-medium text-secondary-900">
              {allDone ? 'Every transaction confirmed' : `${confirmed} of ${total} confirmed`}
            </p>
            <p className="text-xs tabular-nums text-secondary-500">{pct}%</p>
          </div>
          <div className="mt-2 h-2 overflow-hidden rounded-full bg-secondary-200" role="progressbar" aria-valuenow={pct} aria-valuemin={0} aria-valuemax={100}>
            <div className={`h-full rounded-full transition-all ${allDone ? 'bg-green-500' : 'bg-primary-500'}`} style={{ width: `${pct}%` }} />
          </div>
          {!allDone && toCheck > 0 && (
            <p className="mt-2 text-xs text-amber-800">
              {toCheck}{' '}we weren&apos;t sure about — please look at each one.
            </p>
          )}
        </div>
        <div className="flex shrink-0 items-center gap-2">
          {!allDone && rest > 0 && (
            <button
              type="button"
              onClick={() => setConsentOpen(true)}
              className="inline-flex items-center gap-2 rounded-lg bg-primary-600 px-3.5 py-2 text-sm font-medium text-white hover:bg-primary-700"
            >
              <ShieldCheck className="h-4 w-4" /> Confirm the rest ({rest})
            </button>
          )}
          <button
            type="button"
            onClick={() => setOpen((o) => !o)}
            aria-expanded={open}
            className="inline-flex items-center gap-1.5 rounded-lg border border-secondary-300 bg-surface px-3 py-2 text-sm font-medium text-secondary-700 hover:bg-secondary-100"
          >
            {open ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}
            {open ? 'Hide' : 'Show'} transactions
          </button>
        </div>
      </div>

      {open && (
        <>
          <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
            <div className="flex flex-wrap gap-1.5" role="tablist" aria-label="Filter transactions">
              {tabs.map((t) => (
                <button
                  key={t.key}
                  type="button"
                  role="tab"
                  aria-selected={filter === t.key}
                  onClick={() => setFilter(t.key)}
                  className={`rounded-full px-3 py-1.5 text-xs font-medium transition-colors ${
                    filter === t.key
                      ? 'bg-secondary-900 text-white'
                      : 'bg-secondary-100 text-secondary-600 hover:bg-secondary-200'
                  }`}
                >
                  {t.label}
                </button>
              ))}
            </div>
            <div className="w-full lg:w-64">
              <Input
                placeholder="Search descriptions…"
                value={search}
                onChange={(e) => setSearch(e.target.value)}
                leftIcon={<Search className="h-4 w-4" />}
              />
            </div>
          </div>

          <Table
            columns={columns}
            data={rows}
            keyExtractor={(t) => t.uuid}
            isLoading={loading && rows.length === 0}
            caption={`Transactions for ${taxYear}`}
            emptyMessage={
              filter === 'TO_CHECK' ? 'Nothing left to check here.'
                : filter === 'UNCONFIRMED' ? 'Everything here is confirmed.' : 'No transactions match.'
            }
          />

          {pages > 1 && (
            <Pagination currentPage={page} totalPages={pages} onPageChange={setPage} totalItems={count} perPage={PER_PAGE} />
          )}
        </>
      )}

      <Modal
        isOpen={consentOpen}
        onClose={() => { setConsentOpen(false); setConsent(false); }}
        title="Confirm your transactions"
        size="md"
        footer={(
          <div className="flex justify-end gap-2">
            <button
              type="button"
              onClick={() => { setConsentOpen(false); setConsent(false); }}
              className="rounded-lg border border-secondary-300 px-4 py-2 text-sm font-medium text-secondary-700 hover:bg-secondary-50"
            >
              Not yet
            </button>
            <button
              type="button"
              onClick={confirmRest}
              disabled={!consent || confirmingAll}
              className="flex items-center gap-2 rounded-lg bg-primary-600 px-4 py-2 text-sm font-medium text-white hover:bg-primary-700 disabled:opacity-50"
            >
              {confirmingAll && <Loader2 className="h-4 w-4 animate-spin" />}
              Confirm {rest}
            </button>
          </div>
        )}
      >
        <div className="space-y-3 text-sm text-secondary-600">
          <p>
            This confirms the <strong>{rest}</strong> transactions we sorted for {taxYear}{' '}that you haven&apos;t
            confirmed yet. {toCheck > 0 && <>The {toCheck}{' '}we weren&apos;t sure about stay for you to check one by one.</>}
          </p>
          <label className="flex items-start gap-2 rounded-lg border border-secondary-200 p-3 text-secondary-800">
            <input type="checkbox" checked={consent} onChange={(e) => setConsent(e.target.checked)} className="mt-0.5" />
            <span>
              I&apos;ve checked these transactions — what was read from my bank statements and how each one is
              categorised — and they&apos;re correct.
            </span>
          </label>
        </div>
      </Modal>
    </div>
  );
}

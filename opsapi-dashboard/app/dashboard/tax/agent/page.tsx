'use client';

/**
 * File my tax — conversational agent.
 *
 * One chat that drives UK self-assessment prep end to end: the AI asks the
 * profile, asks for a bank statement (uploaded + classified via the existing tax
 * endpoints), reviews the classifications and shows a DETERMINISTIC running tax
 * estimate (computed server-side by lib/tax-calc — never by the model).
 */

import React, { useCallback, useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import toast from 'react-hot-toast';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { Modal } from '@/components/ui';
import { formatCurrency } from '@/lib/utils';
import taxAgentService, { type TaxEstimate, type UploadPrompt, type StatementStatus } from '@/services/tax-agent.service';
import taxService from '@/services/tax.service';

interface ChatMsg {
  id: string;
  role: 'user' | 'assistant';
  text: string;
  uploadPrompt?: UploadPrompt | null;
  quickReplies?: string[] | null;
}

let msgSeq = 0;
const newId = () => `m${Date.now()}_${msgSeq++}`;

// Starter prompts shown in the empty state so users know how to begin.
const STARTERS = [
  "I'm self-employed and want to file my tax",
  "I'm a landlord with rental income",
  'I have both self-employment and rental income',
  'What do I need to file my tax return?',
];

// UK tax years, newest first (the current one leads). Tax year runs 6 Apr–5 Apr.
function ukTaxYears(count = 3): string[] {
  const now = new Date();
  let start = now.getFullYear();
  if (now.getMonth() < 3 || (now.getMonth() === 3 && now.getDate() < 6)) start -= 1;
  return Array.from({ length: count }, (_, i) => {
    const y = start - i;
    return `${y}-${String((y + 1) % 100).padStart(2, '0')}`;
  });
}

// Suggestions to show under the question: the agent's own quick replies, or a
// sensible fallback for the tax-year question (current year first).
function suggestionsFor(message: string | undefined, quickReplies: string[] | null | undefined): string[] {
  if (quickReplies && quickReplies.length > 0) return quickReplies;
  if (message && /tax year/i.test(message)) return ukTaxYears();
  return [];
}

function stageLabel(p: StatementStatus): string {
  switch (p.processing_status) {
    case 'QUEUED': return 'Queued…';
    case 'EXTRACTING':
    case 'PROCESSING': return 'Reading transactions…';
    case 'CLASSIFYING':
      return p.transaction_count
        ? `Categorising (${p.classified_count ?? 0}/${p.transaction_count})…`
        : 'Categorising…';
    case 'ERROR': return "Couldn't process";
    default: return 'Working…';
  }
}

function EstimatePanel({ estimate }: { estimate: TaxEstimate | null }) {
  if (!estimate) {
    return (
      <div className="rounded-xl border border-secondary-200 bg-secondary-50 p-5 text-sm text-secondary-500">
        Your estimated tax will appear here as we go — once we&apos;ve classified some transactions.
      </div>
    );
  }
  const row = (label: string, value: string, strong = false) => (
    <div className="flex items-center justify-between py-1.5">
      <span className={strong ? 'font-medium text-secondary-900' : 'text-secondary-600'}>{label}</span>
      <span className={strong ? 'font-semibold text-secondary-900' : 'text-secondary-800'}>{value}</span>
    </div>
  );
  return (
    <div className="rounded-xl border border-primary-200 bg-linear-to-b from-primary-50 to-white p-5">
      <div className="text-xs font-medium uppercase tracking-wide text-primary-500">Estimated tax {estimate.tax_year}</div>
      <div className="mt-1 text-3xl font-bold text-primary-700">{formatCurrency(estimate.total_tax_due)}</div>
      <div className="mt-0.5 text-xs text-secondary-500">Estimate only — the figure HMRC confirms at filing is the one that counts.</div>
      <div className="mt-4 divide-y divide-secondary-100 text-sm">
        {row('Income', formatCurrency(estimate.gross_income))}
        {row('Allowable expenses', formatCurrency(estimate.total_expenses))}
        {row('Taxable profit', formatCurrency(estimate.trading_profit), true)}
        {row('Personal allowance', formatCurrency(estimate.personal_allowance))}
        {row('Income tax', formatCurrency(estimate.income_tax.total))}
        {row(
          'National Insurance',
          estimate.nic_applied === false ? 'N/A — property income' : formatCurrency(estimate.national_insurance.total),
        )}
        {row('Effective rate', `${estimate.effective_rate}%`)}
      </div>
      {!!estimate.unreviewed_count && estimate.unreviewed_count > 0 && (
        <div className="mt-3 rounded-lg bg-amber-50 px-3 py-2 text-xs text-amber-800">
          {estimate.unreviewed_count} transaction{estimate.unreviewed_count === 1 ? '' : 's'} still need review — the estimate will firm up once they&apos;re categorised.
        </div>
      )}
      {/* Binding filing is done on the dedicated File screen — a deliberate, explicit
          step for a legally-binding declaration, not a chat action. */}
      <Link
        href="/dashboard/tax/file"
        className="mt-4 flex items-center justify-center gap-2 rounded-lg bg-primary-600 px-4 py-2.5 text-sm font-medium text-white hover:bg-primary-700"
      >
        Ready to file? Open the File screen →
      </Link>
    </div>
  );
}

function TaxAgentChat() {
  const [sessionId, setSessionId] = useState<string | null>(null);
  const [taxYear, setTaxYear] = useState<string>('');
  const [messages, setMessages] = useState<ChatMsg[]>([]);
  const [estimate, setEstimate] = useState<TaxEstimate | null>(null);
  const [awaitingConfirm, setAwaitingConfirm] = useState<string | null>(null);
  const [quickReplies, setQuickReplies] = useState<string[]>([]);
  const [processing, setProcessing] = useState<StatementStatus[]>([]);
  const [input, setInput] = useState('');
  const [busy, setBusy] = useState(false);
  const [loading, setLoading] = useState(true);
  const [showNewChat, setShowNewChat] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const wasProcessing = useRef(false);

  const stopPolling = useCallback(() => {
    if (pollRef.current) { clearInterval(pollRef.current); pollRef.current = null; }
  }, []);

  // Poll the server-side processing status. Runs independently of the upload, so
  // it resumes after a reload/navigation (the work continues in the background).
  const pollOnce = useCallback(async () => {
    try {
      const st = await taxAgentService.processStatus();
      setProcessing(st);
      if (st.length > 0) {
        wasProcessing.current = true;
      } else if (wasProcessing.current) {
        wasProcessing.current = false;
        stopPolling();
        setMessages((prev) => [...prev, {
          id: newId(), role: 'assistant',
          text: '✅ Your statement(s) are processed and categorised. Want to see your tax estimate?',
          quickReplies: ['Show my estimate'],
        }]);
        setQuickReplies(['Show my estimate']);
        // Figures just landed — show the estimate panel without waiting for a click.
        if (sessionId) taxAgentService.getEstimate(sessionId).then((est) => { if (est) setEstimate(est); });
      }
    } catch {
      /* transient poll error — keep trying */
    }
  }, [stopPolling, sessionId]);

  const startPolling = useCallback(() => {
    stopPolling();
    wasProcessing.current = true;
    void pollOnce();
    pollRef.current = setInterval(() => { void pollOnce(); }, 2500);
  }, [pollOnce, stopPolling]);

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight, behavior: 'smooth' });
  }, [messages, busy]);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const s = await taxAgentService.createSession();
        if (cancelled) return;
        setSessionId(s.id);
        setTaxYear(s.tax_year || '');
        const existing: ChatMsg[] = (s.messages || []).map((m) => ({
          id: newId(), role: m.role, text: m.text, uploadPrompt: m.upload_prompt, quickReplies: m.quick_replies,
        }));
        if (existing.length === 0) {
          existing.push({
            id: newId(), role: 'assistant',
            text: "Hi! I'm your tax assistant — I'll help you get your Self Assessment sorted, step by step. Tell me a bit about you to start (tap a suggestion below, or type your own).",
          });
        }
        setMessages(existing);
        setAwaitingConfirm(s.pending?.summary ?? null);
        const lastA = [...existing].reverse().find((m) => m.role === 'assistant');
        setQuickReplies(lastA ? suggestionsFor(lastA.text, lastA.quickReplies) : []);
        // Re-show the estimate if this session already has classified figures.
        taxAgentService.getEstimate(s.id).then((est) => { if (!cancelled && est) setEstimate(est); });
      } catch {
        toast.error('Could not start the tax assistant.');
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, []);

  // On mount / reload: if the server is still processing statements, resume the
  // progress display and polling (the work keeps running server-side regardless).
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const st = await taxAgentService.processStatus().catch(() => [] as StatementStatus[]);
      if (!cancelled && st.length > 0) { setProcessing(st); startPolling(); }
    })();
    return () => { cancelled = true; stopPolling(); };
  }, [startPolling, stopPolling]);

  const applyTurn = useCallback((turn: Awaited<ReturnType<typeof taxAgentService.sendMessage>>) => {
    setMessages((prev) => [...prev, { id: newId(), role: 'assistant', text: turn.message, uploadPrompt: turn.upload_prompt, quickReplies: turn.quick_replies }]);
    if (turn.estimate) setEstimate(turn.estimate);
    if (turn.progress?.tax_year) setTaxYear(turn.progress.tax_year);
    setAwaitingConfirm(turn.awaiting_confirm ? (turn.confirm_card?.summary ?? 'Confirm this change?') : null);
    setQuickReplies(suggestionsFor(turn.message, turn.quick_replies));
  }, []);

  const send = useCallback(async (text: string) => {
    if (!sessionId || !text.trim() || busy) return;
    setMessages((prev) => [...prev, { id: newId(), role: 'user', text }]);
    setInput('');
    setQuickReplies([]);
    setBusy(true);
    try {
      applyTurn(await taxAgentService.sendMessage(sessionId, text));
    } catch {
      toast.error('The assistant did not respond. Please try again.');
      setMessages((prev) => [...prev, { id: newId(), role: 'assistant', text: 'Sorry — something went wrong. Please try again.' }]);
    } finally {
      setBusy(false);
    }
  }, [sessionId, busy, applyTurn]);

  const confirm = useCallback(async (approve: boolean) => {
    if (!sessionId || busy) return;
    setBusy(true);
    setAwaitingConfirm(null);
    try {
      applyTurn(await taxAgentService.confirm(sessionId, approve));
    } catch {
      toast.error('Could not record your choice. Please try again.');
    } finally {
      setBusy(false);
    }
  }, [sessionId, busy, applyTurn]);

  // Upload one or more statements: each is uploaded, extracted and classified. The
  // bank is auto-detected from the first statement (with a fallback note if it can't
  // be read). One failed file doesn't stop the rest.
  const handleUpload = useCallback(async (files: File[]) => {
    if (!sessionId || busy || files.length === 0) return;
    setBusy(true);
    const names = files.map((f) => f.name).join(', ');
    setMessages((prev) => [...prev, {
      id: newId(), role: 'user',
      text: `📎 Uploading ${files.length} statement${files.length > 1 ? 's' : ''}: ${names}`,
    }]);
    try {
      const accounts = await taxService.getBankAccounts();
      let acct = accounts[0] as { id?: string; uuid?: string; bank_name?: string } | undefined;
      let acctId = acct?.id;
      if (!acctId) {
        const created = await taxService.createBankAccount({ bank_name: 'My bank account' } as never);
        acctId = (created.id || created.uuid) as string;
        acct = created as never;
      }
      const ids: string[] = [];
      let detectedBank: string | undefined;
      for (const file of files) {
        try {
          const stmt = await taxService.uploadStatement(file, acctId as string);
          const s = stmt as { statement_id?: number | string; id?: number | string; uuid?: string };
          const stmtId = s.statement_id ?? s.id ?? s.uuid;
          if (stmtId === undefined || stmtId === null || stmtId === '') continue;
          ids.push(String(stmtId));
          if (!detectedBank) {
            const bd = await taxAgentService.detectBankDetails(stmtId);
            if (bd?.bank_name) detectedBank = bd.bank_name;
          }
        } catch {
          // skip this file, keep going with the others
        }
      }
      // Name the account from the detected bank if it's still the generic default.
      if (detectedBank && acctId && (!acct?.bank_name || /my (bank|business) account/i.test(acct.bank_name))) {
        try { await taxService.updateBankAccount(acctId as string, { bank_name: detectedBank }); } catch { /* non-fatal */ }
      }
      if (ids.length === 0) throw new Error('no statements uploaded');
      // Hand off to the SERVER-SIDE worker — extract + classify keep running even
      // if the user reloads or leaves. The UI follows progress by polling.
      await taxAgentService.processStatements(ids, taxYear || undefined);
      const bankLine = detectedBank ? `I read your bank as ${detectedBank}. ` : '';
      setMessages((prev) => [...prev, {
        id: newId(), role: 'assistant',
        text: `${bankLine}Got ${ids.length} statement${ids.length > 1 ? 's' : ''}. I'm reading and categorising the transactions now — this keeps running in the background, so you can reload or leave this page and come back.`,
      }]);
      startPolling();
    } catch {
      toast.error('Upload failed. You can also upload from Tax → Statements.');
      setMessages((prev) => [...prev, { id: newId(), role: 'assistant', text: "That upload didn't work. You can also upload on the Tax → Statements page, then come back and tell me it's ready." }]);
    } finally {
      setBusy(false);
    }
  }, [sessionId, busy, startPolling, taxYear]);

  const confirmNewChat = useCallback(async () => {
    if (busy || loading || !sessionId) return;
    setShowNewChat(false);
    setBusy(true);
    stopPolling();
    setProcessing([]);
    try {
      await taxAgentService.archive(sessionId, true); // purge old statements/transactions
      const s = await taxAgentService.createSession({ force_new: true });
      setSessionId(s.id);
      setTaxYear(s.tax_year || '');
      setEstimate(null);
      setAwaitingConfirm(null);
      setQuickReplies([]);
      setInput('');
      setMessages([{
        id: newId(), role: 'assistant',
        text: "Fresh start! Tell me a bit about you to begin (tap a suggestion below, or type your own).",
      }]);
    } catch {
      toast.error('Could not start a new chat.');
    } finally {
      setBusy(false);
    }
  }, [sessionId, busy, loading, stopPolling]);

  const latestUpload = [...messages].reverse().find((m) => m.role === 'assistant' && m.uploadPrompt)?.uploadPrompt;

  return (
    <div className="grid grid-cols-1 gap-6 lg:grid-cols-[1fr_340px]">
      {/* Conversation */}
      <div className="flex min-h-[70vh] flex-col overflow-hidden rounded-xl border border-secondary-200 bg-white">
        <div className="flex items-center justify-between border-b border-secondary-200 px-4 py-2.5">
          <span className="text-sm font-medium text-secondary-700">Tax assistant</span>
          <button
            type="button"
            onClick={() => setShowNewChat(true)}
            disabled={busy || loading}
            title="Clear this conversation and start a fresh one"
            className="inline-flex items-center gap-1.5 rounded-lg border border-secondary-300 px-2.5 py-1 text-xs font-medium text-secondary-600 transition hover:bg-secondary-50 disabled:opacity-50"
          >
            ↻ New chat
          </button>
        </div>
        <div ref={scrollRef} className="flex-1 space-y-4 overflow-y-auto p-4 sm:p-6">
          {loading ? (
            <div className="flex h-40 items-center justify-center text-sm text-secondary-500">Starting your tax assistant…</div>
          ) : (
            messages.map((m) => (
              <div key={m.id} className={m.role === 'user' ? 'flex justify-end' : 'flex justify-start'}>
                <div
                  className={
                    m.role === 'user'
                      ? 'max-w-[85%] rounded-2xl rounded-br-sm bg-primary-600 px-4 py-2.5 text-sm text-white'
                      : 'max-w-[85%] rounded-2xl rounded-bl-sm bg-secondary-100 px-4 py-2.5 text-sm text-secondary-900'
                  }
                >
                  <p className="whitespace-pre-wrap">{m.text}</p>
                  {m.uploadPrompt && (
                    <button
                      type="button"
                      onClick={() => fileRef.current?.click()}
                      disabled={busy}
                      className="mt-3 inline-flex items-center gap-2 rounded-lg bg-white px-3 py-1.5 text-xs font-medium text-primary-700 shadow-sm ring-1 ring-primary-200 hover:bg-primary-50 disabled:opacity-50"
                    >
                      ⬆ {m.uploadPrompt.button_label}
                    </button>
                  )}
                </div>
              </div>
            ))
          )}
          {!loading && !messages.some((m) => m.role === 'user') && (
            <div className="space-y-2 pl-1">
              <p className="text-xs text-secondary-400">Get started:</p>
              <div className="flex flex-wrap gap-2">
                {STARTERS.map((s) => (
                  <button
                    key={s}
                    type="button"
                    onClick={() => send(s)}
                    disabled={busy}
                    className="rounded-full border border-primary-200 bg-primary-50 px-3.5 py-1.5 text-left text-sm text-primary-700 transition hover:bg-primary-100 disabled:opacity-50"
                  >
                    {s}
                  </button>
                ))}
              </div>
            </div>
          )}
          {processing.length > 0 && (
            <div className="rounded-xl border border-primary-200 bg-primary-50 p-3.5">
              <div className="flex items-center gap-2 text-sm font-medium text-primary-800">
                <span className="inline-block h-2 w-2 animate-pulse rounded-full bg-primary-500" />
                Processing {processing.length} statement{processing.length > 1 ? 's' : ''}…
              </div>
              <div className="mt-2 space-y-1.5">
                {processing.map((p, i) => (
                  <div key={p.uuid} className="flex items-center justify-between gap-3 text-sm">
                    <span className="truncate text-primary-900">{p.file_name || `Statement ${i + 1}`}</span>
                    <span className={p.processing_status === 'ERROR' ? 'shrink-0 text-red-600' : 'shrink-0 text-primary-600'}>{stageLabel(p)}</span>
                  </div>
                ))}
              </div>
              <div className="mt-2 text-xs text-primary-500">This keeps running in the background — you can reload or leave this page.</div>
            </div>
          )}
          {busy && (
            <div className="flex justify-start">
              <div className="rounded-2xl rounded-bl-sm bg-secondary-100 px-4 py-2.5 text-sm text-secondary-500">…thinking</div>
            </div>
          )}
        </div>

        {/* Confirm bar */}
        {awaitingConfirm && (
          <div className="border-t border-amber-200 bg-amber-50 px-4 py-3 sm:px-6">
            <p className="text-sm text-amber-900">{awaitingConfirm}</p>
            <div className="mt-2 flex gap-2">
              <button type="button" onClick={() => confirm(true)} disabled={busy}
                className="rounded-lg bg-primary-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-primary-700 disabled:opacity-50">
                Confirm
              </button>
              <button type="button" onClick={() => confirm(false)} disabled={busy}
                className="rounded-lg bg-white px-3 py-1.5 text-sm font-medium text-secondary-700 ring-1 ring-secondary-300 hover:bg-secondary-50 disabled:opacity-50">
                Cancel
              </button>
            </div>
          </div>
        )}

        {/* Composer */}
        <div className="border-t border-secondary-200 p-3 sm:p-4">
          {quickReplies.length > 0 && !awaitingConfirm && (
            <div className="mb-2 flex flex-wrap gap-2">
              {quickReplies.map((q) => (
                <button
                  key={q}
                  type="button"
                  onClick={() => send(q)}
                  disabled={busy}
                  className="rounded-full border border-primary-200 bg-primary-50 px-3 py-1.5 text-xs font-medium text-primary-700 transition hover:bg-primary-100 disabled:opacity-50"
                >
                  {q}
                </button>
              ))}
            </div>
          )}
          <form
            onSubmit={(e) => { e.preventDefault(); send(input); }}
            className="flex items-end gap-2"
          >
            {latestUpload && (
              <button type="button" onClick={() => fileRef.current?.click()} disabled={busy}
                title="Upload a bank statement"
                className="shrink-0 rounded-lg border border-secondary-300 px-3 py-2 text-sm text-secondary-600 hover:bg-secondary-50 disabled:opacity-50">
                📎
              </button>
            )}
            <textarea
              value={input}
              onChange={(e) => setInput(e.target.value)}
              onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(input); } }}
              rows={1}
              placeholder="Type your answer…"
              disabled={busy || loading}
              className="min-h-[42px] flex-1 resize-none rounded-lg border border-secondary-300 px-3 py-2 text-sm focus:border-primary-500 focus:outline-none focus:ring-1 focus:ring-primary-500 disabled:bg-secondary-50"
            />
            <button type="submit" disabled={busy || loading || !input.trim()}
              className="shrink-0 rounded-lg bg-primary-600 px-4 py-2 text-sm font-medium text-white hover:bg-primary-700 disabled:opacity-50">
              Send
            </button>
          </form>
          <input
            ref={fileRef}
            type="file"
            accept=".pdf,.csv,image/*"
            multiple
            className="hidden"
            onChange={(e) => { const fs = e.target.files ? Array.from(e.target.files) : []; if (fs.length) handleUpload(fs); e.target.value = ''; }}
          />
        </div>
      </div>

      {/* Live estimate */}
      <div className="lg:sticky lg:top-6 lg:self-start">
        <EstimatePanel estimate={estimate} />
        <p className="mt-3 px-1 text-xs text-secondary-400">
          The assistant never calculates tax itself — every figure is computed by OpsAPI and confirmed by HMRC at filing.
        </p>
      </div>

      <Modal
        isOpen={showNewChat}
        onClose={() => setShowNewChat(false)}
        title="Start a new chat?"
        size="sm"
        footer={(
          <div className="flex justify-end gap-2">
            <button
              type="button"
              onClick={() => setShowNewChat(false)}
              className="rounded-lg border border-secondary-300 px-4 py-2 text-sm font-medium text-secondary-700 transition hover:bg-secondary-50"
            >
              Cancel
            </button>
            <button
              type="button"
              onClick={confirmNewChat}
              className="rounded-lg bg-primary-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-primary-700"
            >
              Start new chat
            </button>
          </div>
        )}
      >
        <p className="text-sm text-secondary-600">
          This clears the current conversation <span className="font-medium">and the bank statements you uploaded in it</span>, so you can begin completely from scratch — useful if the chat has the wrong details.
        </p>
        <p className="mt-2 text-sm text-secondary-500">
          You can upload your statements again in the new chat.
        </p>
      </Modal>
    </div>
  );
}

export default function TaxAgentPage() {
  return (
    <ProtectedPage module="tax_transactions">
      <div className="space-y-6">
        <PageHeader
          title="File with AI"
          description="Chat with the tax assistant — it collects your figures, classifies them, and shows your estimate."
        />
        <TaxAgentChat />
      </div>
    </ProtectedPage>
  );
}

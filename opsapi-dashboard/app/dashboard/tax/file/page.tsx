'use client';

/**
 * Guided "File your tax" wizard.
 *
 * One linear path so a non-expert can file without hopping between pages:
 *   1. Connect to HMRC          (OAuth)
 *   2. Select your business     (pull from HMRC, pick the self-employment)
 *   3. Fetch obligations        (which period HMRC says is open to file)
 *   4. Check your figures       (aggregate classified tx; fix mis-filed credits inline)
 *   5. Preview calculation      (submit cumulative + in-year calc — non-binding)
 *   6. Finalise & declare       (the binding final declaration — next phase)
 *
 * Steps unlock in order; each shows done / active / locked. The hard gate before the
 * HMRC calculation is step 4: it must report no blocking issues (e.g. a negative period
 * field from a credit mis-filed as an expense), which the user fixes right here.
 *
 * Auto-advance: the read-only pulls run themselves so the user never hunts for a
 * "Load…" / "Fetch…" button. Once connected with a NINO on file we fetch the business,
 * auto-pick it, fetch its obligations, and aggregate the figures — all without a click.
 * The only deliberate actions left are the ones that genuinely need a human: the OAuth
 * connect, entering the NINO, choosing between multiple businesses, fixing a flagged
 * figure, and the step-5 calculation (the one call that submits data to HMRC).
 */

import React, { useEffect, useState, useCallback, useRef, Suspense } from 'react';
import Link from 'next/link';
import { useSearchParams } from 'next/navigation';
import {
  Link2,
  Building2,
  CalendarClock,
  ListChecks,
  Calculator,
  FileCheck2,
  CheckCircle2,
  Lock,
  Loader2,
  AlertTriangle,
  AlertCircle,
  RefreshCw,
} from 'lucide-react';
import { Card } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import {
  taxService,
  type HmrcBusiness,
  type HmrcObligation,
  type HmrcAggregatePreview,
  type HmrcOffendingTransaction,
} from '@/services/tax.service';
import { formatCurrency, extractApiError } from '@/lib/utils';
import toast from 'react-hot-toast';

type CalcResult = Awaited<ReturnType<typeof taxService.calculateHmrcPreview>>;

// "2025-26" → { from: "2025-04-06", to: "2026-04-05" }. Returns null on bad input.
function taxYearBounds(ty: string): { from: string; to: string } | null {
  const m = /^(\d{4})-(\d{2})$/.exec(ty.trim());
  if (!m) return null;
  const start = parseInt(m[1], 10);
  return { from: `${start}-04-06`, to: `${start + 1}-04-05` };
}

// Derive the UK tax year ("YYYY-YY") a date falls in (year boundary 6 April).
// e.g. "2018-04-06" → "2018-19", "2019-01-06" → "2018-19".
function taxYearOf(dateStr: string): string {
  const m = /^(\d{4})-(\d{2})/.exec(dateStr || '');
  if (!m) return '';
  const y = parseInt(m[1], 10);
  const mo = parseInt(m[2], 10);
  const start = mo >= 4 ? y : y - 1;
  return `${start}-${String((start + 1) % 100).padStart(2, '0')}`;
}

const bizId = (b: HmrcBusiness) => b.business_id || b.businessId || '';
const bizType = (b: HmrcBusiness) => b.type_of_business || b.typeOfBusiness || '';
const bizName = (b: HmrcBusiness) => b.trading_name || b.tradingName || '';
const isOpen = (o: HmrcObligation) => /^o/i.test(o.status || '');

// How a flagged credit can be corrected. Income → included under the right box;
// "exclude" clears the HMRC box so it never reaches the period summary.
const FIX_OPTIONS: Array<{ value: string; label: string; category: string; hmrc_category: string }> = [
  { value: 'turnover', label: 'Business income (sales / turnover)', category: 'sales_income', hmrc_category: 'turnover' },
  { value: 'other_income', label: 'Other business income', category: 'income_other', hmrc_category: 'other_income' },
  { value: 'exclude', label: 'Personal / transfer — exclude from return', category: 'transfer', hmrc_category: '' },
];

// Plain-English labels for the HMRC MTD self-employment fields we actually submit, so the
// user can see exactly what's going to HMRC rather than raw API field names.
const HMRC_SECTION_LABELS: Record<string, string> = {
  periodIncome: 'Income',
  periodExpenses: 'Expenses',
  periodDisallowableExpenses: 'Disallowable expenses (added back to profit)',
};
const HMRC_FIELD_LABELS: Record<string, string> = {
  turnover: 'Sales / turnover',
  other: 'Other business income',
  costOfGoods: 'Cost of goods bought for resale',
  paymentsToSubcontractors: 'Payments to subcontractors',
  wagesAndStaffCosts: 'Wages & staff costs',
  carVanTravelExpenses: 'Car, van & travel',
  premisesRunningCosts: 'Premises running costs',
  maintenanceCosts: 'Repairs & maintenance',
  adminCosts: 'Office & admin costs',
  businessEntertainmentCosts: 'Business entertainment',
  advertisingCosts: 'Advertising & marketing',
  interestOnBankOtherLoans: 'Interest on loans',
  financeCharges: 'Bank & finance charges',
  irrecoverableDebts: 'Bad debts written off',
  professionalFees: 'Accountancy, legal & professional fees',
  depreciation: 'Depreciation & loss on sale',
  otherExpenses: 'Other business expenses',
};

// Render the exact MTD body (income / expense lines) we'll submit to HMRC, with friendly
// labels and per-section totals. Only non-zero lines are shown to keep it readable.
function FiguresBreakdown({ body, taxYear }: { body?: Record<string, Record<string, number>>; taxYear: string }) {
  const fmt = (n: number) => formatCurrency(n, 'GBP', 'en-GB');
  const sections = ['periodIncome', 'periodExpenses', 'periodDisallowableExpenses'].filter(
    (s) => body?.[s] && Object.values(body[s]).some((v) => Number(v) !== 0),
  );
  if (sections.length === 0) return null;
  return (
    <div className="rounded-lg border border-secondary-200 bg-surface p-3 space-y-3">
      <p className="text-sm font-medium text-secondary-900">Exactly what we&apos;ll send to HMRC</p>
      {sections.map((s) => {
        const entries = Object.entries(body![s]).filter(([, v]) => Number(v) !== 0);
        const total = entries.reduce((a, [, v]) => a + Number(v), 0);
        return (
          <div key={s} className="space-y-1">
            <p className="text-xs font-semibold uppercase tracking-wide text-secondary-500">
              {HMRC_SECTION_LABELS[s] || s}
            </p>
            <div className="divide-y divide-secondary-100">
              {entries.map(([k, v]) => (
                <div key={k} className="flex items-center justify-between py-1 text-sm">
                  <span className="text-secondary-700">{HMRC_FIELD_LABELS[k] || k}</span>
                  <span className="font-medium text-secondary-900 tabular-nums">{fmt(Number(v))}</span>
                </div>
              ))}
            </div>
            <div className="flex items-center justify-between pt-1 text-sm font-semibold border-t border-secondary-200">
              <span className="text-secondary-600">Total {(HMRC_SECTION_LABELS[s] || s).toLowerCase()}</span>
              <span className="tabular-nums text-secondary-900">{fmt(total)}</span>
            </div>
          </div>
        );
      })}
      <p className="text-xs text-secondary-400">
        These figures come from your classified transactions for tax year {taxYear}. HMRC works out the tax
        and allowances from them in the next step.
      </p>
    </div>
  );
}

type StepState = 'done' | 'active' | 'locked';

function StepHeader({
  index,
  title,
  subtitle,
  state,
  icon,
}: {
  index: number;
  title: string;
  subtitle: string;
  state: StepState;
  icon: React.ReactNode;
}) {
  return (
    <div className="flex items-start gap-3">
      <div
        className={`mt-0.5 w-9 h-9 rounded-full flex items-center justify-center shrink-0 ${
          state === 'done'
            ? 'bg-green-100 text-green-600'
            : state === 'active'
              ? 'bg-primary-100 text-primary-600'
              : 'bg-secondary-100 text-secondary-400'
        }`}
      >
        {state === 'done' ? (
          <CheckCircle2 className="w-5 h-5" />
        ) : state === 'locked' ? (
          <Lock className="w-4 h-4" />
        ) : (
          icon
        )}
      </div>
      <div className="flex-1">
        <p className={`font-semibold ${state === 'locked' ? 'text-secondary-400' : 'text-secondary-900'}`}>
          <span className="text-secondary-400 mr-1">{index}.</span>
          {title}
        </p>
        <p className="text-sm text-secondary-500">{subtitle}</p>
      </div>
    </div>
  );
}

function FileWizardContent() {
  const searchParams = useSearchParams();

  const [taxYear, setTaxYear] = useState('2025-26');

  // Step 1 — connection
  const [connected, setConnected] = useState(false);
  const [valid, setValid] = useState(false);
  const [loadingStatus, setLoadingStatus] = useState(true);
  const [connecting, setConnecting] = useState(false);

  // NINO (required by HMRC's business/obligations APIs)
  const [hasNino, setHasNino] = useState<boolean | null>(null);
  const [ninoLast4, setNinoLast4] = useState<string | undefined>(undefined);
  const [ninoInput, setNinoInput] = useState('');
  const [savingNino, setSavingNino] = useState(false);
  const [editingNino, setEditingNino] = useState(false);
  const [ninoConsent, setNinoConsent] = useState(false);
  const [removingNino, setRemovingNino] = useState(false);

  // Step 2 — business
  const [businesses, setBusinesses] = useState<HmrcBusiness[]>([]);
  const [selectedBusiness, setSelectedBusiness] = useState('');
  const [loadingBiz, setLoadingBiz] = useState(false);
  const [bizError, setBizError] = useState<string | null>(null);
  const [bizErrorCode, setBizErrorCode] = useState<string | null>(null);

  // Step 3 — obligations. The SELECTED open obligation drives the tax year we file for
  // (keyed by "period_start|period_end"), instead of a hardcoded year.
  const [obligations, setObligations] = useState<HmrcObligation[] | null>(null);
  const [loadingObl, setLoadingObl] = useState(false);
  const [selectedObligation, setSelectedObligation] = useState<string | null>(null);

  // Step 4 — figures
  const [preview, setPreview] = useState<HmrcAggregatePreview | null>(null);
  const [loadingPreview, setLoadingPreview] = useState(false);
  const [fixing, setFixing] = useState<string | null>(null);
  const [fixChoice, setFixChoice] = useState<Record<string, string>>({});

  // Step 5 — calculation
  const [calc, setCalc] = useState<CalcResult | null>(null);
  const [calculating, setCalculating] = useState(false);

  // Step 6 — final declaration (the binding filing)
  const [declarationAccepted, setDeclarationAccepted] = useState(false);
  const [filing, setFiling] = useState(false);
  const [filed, setFiled] = useState<Awaited<ReturnType<typeof taxService.submitHmrcFinalDeclaration>> | null>(null);

  // Auto-advance guards: remember what each read-only pull last auto-ran for, so the
  // effects fire exactly once per change instead of looping. Keyed by the input that
  // should trigger a fresh pull (the NINO for businesses, the chosen business for
  // obligations, the tax year for figures).
  const autoBizFor = useRef<string>('');
  const autoOblFor = useRef<string>('');
  const autoPreviewFor = useRef<string>('');

  const gbp = (n?: number) => (n == null ? '—' : formatCurrency(n, 'GBP', 'en-GB'));

  // ── Step 1: connection ──────────────────────────────────────────────────────
  const fetchStatus = useCallback(async () => {
    setLoadingStatus(true);
    try {
      const s = await taxService.getHmrcStatus();
      setConnected(!!s.connected);
      setValid(!!s.is_valid);
    } catch {
      // leave as not-connected
    } finally {
      setLoadingStatus(false);
    }
  }, []);

  useEffect(() => {
    fetchStatus();
  }, [fetchStatus]);

  useEffect(() => {
    if (searchParams.get('hmrc_connected') === 'true') {
      toast.success('Connected to HMRC');
      fetchStatus();
    }
    const err = searchParams.get('hmrc_error');
    if (err) toast.error(`HMRC connection failed: ${err.replace(/_/g, ' ')}`);
  }, [searchParams, fetchStatus]);

  const handleConnect = async () => {
    setConnecting(true);
    try {
      // Pass the BASE; the backend callback appends "/file" (source=file) and the
      // hmrc_connected flag → .../dashboard/tax/file?...&hmrc_connected=true.
      const redirectUrl = `${window.location.origin}/dashboard/tax`;
      const authUrl = await taxService.initiateHmrcConnect(redirectUrl, 'file');
      if (!authUrl) throw new Error('No auth URL');
      window.location.href = authUrl;
    } catch {
      toast.error('Failed to start HMRC connection');
      setConnecting(false);
    }
  };

  // ── NINO ──────────────────────────────────────────────────────────────────────
  const loadNino = useCallback(async () => {
    try {
      const s = await taxService.getHmrcNinoStatus();
      setHasNino(!!s.has_nino);
      setNinoLast4(s.last4);
    } catch {
      setHasNino(false);
    }
  }, []);

  useEffect(() => {
    loadNino();
  }, [loadNino]);

  const saveNino = async () => {
    if (!ninoConsent) {
      toast.error('Please tick the consent box first');
      return;
    }
    setSavingNino(true);
    try {
      const r = await taxService.saveHmrcNino(ninoInput, ninoConsent);
      setHasNino(true);
      setNinoLast4(r.last4);
      setNinoInput('');
      setEditingNino(false);
      setNinoConsent(false);
      // A NINO change invalidates the previously-loaded business list.
      setBusinesses([]);
      setBizError(null);
      setBizErrorCode(null);
      toast.success('National Insurance number saved');
    } catch (err: unknown) {
      toast.error(extractApiError(err, 'Failed to save NINO'));
    } finally {
      setSavingNino(false);
    }
  };

  const removeNino = async () => {
    if (!confirm('Remove your stored National Insurance number? You will need to re-enter it to file.')) return;
    setRemovingNino(true);
    try {
      await taxService.deleteHmrcNino();
      setHasNino(false);
      setNinoLast4(undefined);
      setEditingNino(false);
      setBusinesses([]);
      setBizError(null);
      setBizErrorCode(null);
      toast.success('National Insurance number removed');
    } catch (err: unknown) {
      toast.error(extractApiError(err, 'Failed to remove NINO'));
    } finally {
      setRemovingNino(false);
    }
  };

  // ── Step 2: business ────────────────────────────────────────────────────────
  const loadBusinesses = useCallback(async () => {
    setLoadingBiz(true);
    setBizError(null);
    setBizErrorCode(null);
    try {
      const list = await taxService.fetchHmrcBusinesses();
      // The fileable sandbox (test-support) business isn't returned by the Business
      // Details list, so merge in our stored default if it's missing.
      const stored = await taxService.getDefaultHmrcBusiness().catch(() => null);
      if (stored && !list.some((b) => bizId(b) === stored)) {
        list.unshift({ businessId: stored, typeOfBusiness: 'self-employment', tradingName: 'Your filing business' });
      }
      setBusinesses(list);
      if (list.length === 0) {
        setBizError('HMRC returned no businesses for this NINO. In the sandbox, set one up under HMRC settings → Set up sandbox business.');
      }
      // Prefer the stored/provisioned business; else the sole self-employment / only one.
      const se = list.filter((b) => /self-employment/i.test(bizType(b)));
      const auto = (stored && list.find((b) => bizId(b) === stored))
        || (se.length === 1 ? se[0] : list.length === 1 ? list[0] : null);
      if (auto) {
        setSelectedBusiness(bizId(auto));
        await taxService.selectHmrcBusiness(bizId(auto));
      }
    } catch (err: unknown) {
      // If a NINO is missing, reflect that so the inline NINO form shows.
      const code = (err as { response?: { data?: { code?: string } } })?.response?.data?.code;
      if (code === 'NINO_REQUIRED') setHasNino(false);
      setBizErrorCode(code || null);
      const msg = extractApiError(err, 'Could not load businesses from HMRC');
      setBizError(msg);
      // Fall back to anything we cached previously so the user isn't fully stuck.
      try {
        const cached = await taxService.getHmrcBusinesses();
        if (cached.length > 0) setBusinesses(cached);
      } catch {
        /* ignore */
      }
    } finally {
      setLoadingBiz(false);
    }
  }, []);

  const chooseBusiness = async (id: string) => {
    setSelectedBusiness(id);
    try {
      await taxService.selectHmrcBusiness(id);
    } catch {
      toast.error('Failed to save business selection');
    }
  };

  // Auto-fetch the business once we're connected and have a NINO — no button needed.
  // Re-runs only when the NINO changes (keyed by last-4); a failed pull won't loop
  // because the key is marked done either way (user can retry via "Refresh from HMRC").
  useEffect(() => {
    if (!(connected && valid) || !hasNino || loadingBiz) return;
    const key = ninoLast4 || 'nino';
    if (autoBizFor.current === key) return;
    autoBizFor.current = key;
    if (businesses.length === 0) loadBusinesses();
  }, [connected, valid, hasNino, ninoLast4, loadingBiz, businesses.length, loadBusinesses]);

  // ── Step 3: obligations ─────────────────────────────────────────────────────
  const loadObligations = useCallback(async () => {
    if (!selectedBusiness) return;
    const b = taxYearBounds(taxYear);
    if (!b) {
      toast.error('Tax year must look like 2025-26');
      return;
    }
    setLoadingObl(true);
    try {
      const list = await taxService.fetchHmrcObligations(selectedBusiness, b.from, b.to);
      setObligations(list);
      // Drive the filing tax year from the open obligation HMRC actually has — never a
      // hardcoded year. Auto-select the first open period; the user can pick another.
      const open = list.filter(isOpen);
      if (open.length > 0) {
        const o = open[0];
        setSelectedObligation(`${o.period_start}|${o.period_end}`);
        const derived = taxYearOf(o.period_start);
        if (derived) {
          setTaxYear(derived);
          setPreview(null);
          setCalc(null);
        }
      }
    } catch (err: unknown) {
      // Obligations are informational — don't hard-block filing — but show the real reason.
      setObligations([]);
      const msg = extractApiError(err, 'No obligations returned (common in the HMRC sandbox).');
      toast(msg, { icon: 'ℹ️' });
    } finally {
      setLoadingObl(false);
    }
  }, [selectedBusiness, taxYear]);

  // Auto-fetch obligations once a business is chosen (the obvious next step), once per
  // business. The user can still re-pull with "Refresh" if HMRC's answer changes.
  useEffect(() => {
    if (!selectedBusiness || loadingObl) return;
    if (autoOblFor.current === selectedBusiness) return;
    autoOblFor.current = selectedBusiness;
    loadObligations();
  }, [selectedBusiness, loadingObl, loadObligations]);

  // ── Step 4: figures ─────────────────────────────────────────────────────────
  const loadPreview = useCallback(async () => {
    setLoadingPreview(true);
    setCalc(null); // a figures change invalidates any prior calculation
    try {
      const p = await taxService.getHmrcAggregatePreview(taxYear);
      setPreview(p);
    } catch (err: unknown) {
      toast.error(extractApiError(err, 'Failed to aggregate your figures'));
    } finally {
      setLoadingPreview(false);
    }
  }, [taxYear]);

  // Auto-aggregate the figures once a business is chosen, re-running when the filing
  // tax year settles (it's derived from the selected obligation). Read-only — it only
  // tallies already-classified transactions; nothing is sent to HMRC here.
  useEffect(() => {
    if (!selectedBusiness || loadingPreview) return;
    if (autoPreviewFor.current === taxYear) return;
    autoPreviewFor.current = taxYear;
    loadPreview();
  }, [selectedBusiness, taxYear, loadingPreview, loadPreview]);

  const applyFix = async (tx: HmrcOffendingTransaction) => {
    const choiceKey = fixChoice[tx.uuid];
    const opt = FIX_OPTIONS.find((o) => o.value === choiceKey);
    if (!opt) {
      toast.error('Pick how to correct this transaction first');
      return;
    }
    setFixing(tx.uuid);
    try {
      await taxService.updateTransaction(tx.uuid, {
        category: opt.category,
        hmrc_category: opt.hmrc_category,
        classification_status: 'CONFIRMED',
      });
      toast.success('Transaction corrected');
      await loadPreview(); // re-aggregate so the blocker clears
    } catch {
      toast.error('Failed to update transaction');
    } finally {
      setFixing(null);
    }
  };

  // ── Step 5: calculation ─────────────────────────────────────────────────────
  const runCalculation = async () => {
    setCalculating(true);
    setCalc(null);
    try {
      const res = await taxService.calculateHmrcPreview(taxYear);
      setCalc(res);
      toast.success('Calculation retrieved from HMRC');
    } catch (err: unknown) {
      toast.error(extractApiError(err, 'Calculation failed'));
    } finally {
      setCalculating(false);
    }
  };

  // ── Step 6: final declaration (the binding filing) ──────────────────────────────
  const submitFinalDeclaration = async () => {
    if (!declarationAccepted) {
      toast.error('Please tick the declaration box first');
      return;
    }
    setFiling(true);
    try {
      const res = await taxService.submitHmrcFinalDeclaration(taxYear);
      setFiled(res);
      toast.success('Your return has been filed with HMRC');
    } catch (err: unknown) {
      toast.error(extractApiError(err, 'Final declaration failed'));
    } finally {
      setFiling(false);
    }
  };

  // ── Derived step states ───────────────────────────────────────────────────────
  const s1: StepState = connected && valid ? 'done' : 'active';
  const s2: StepState = s1 !== 'done' ? 'locked' : selectedBusiness ? 'done' : 'active';
  const s3: StepState = s2 !== 'done' ? 'locked' : obligations !== null ? 'done' : 'active';
  // Obligations are informational, so step 4 unlocks once a business is chosen.
  // An empty aggregate (no classified tx in the obligation's tax year) is NOT ready to file.
  const figuresEmpty = !!preview && (((preview.stats.applied as number) ?? 0) === 0);
  const figuresOk = preview !== null && !preview.blocking && !figuresEmpty;
  const s4: StepState = s2 !== 'done' ? 'locked' : figuresOk ? 'done' : 'active';
  const s5: StepState = !figuresOk ? 'locked' : calc ? 'done' : 'active';
  const s6: StepState = filed ? 'done' : !calc ? 'locked' : 'active';

  const openObligations = (obligations || []).filter(isOpen);

  return (
    <div className="space-y-5 max-w-3xl">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">File your tax</h1>
          <p className="text-sm text-secondary-500 mt-1">
            A guided path from connecting HMRC to previewing your Self Assessment calculation.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <label className="text-xs font-medium text-secondary-500">Tax year</label>
          <input
            value={taxYear}
            onChange={(e) => {
              setTaxYear(e.target.value);
              // Year change invalidates downstream data.
              setObligations(null);
              setPreview(null);
              setCalc(null);
            }}
            className="px-3 py-1.5 border border-secondary-300 rounded-lg text-sm bg-surface w-28"
            placeholder="2025-26"
          />
        </div>
      </div>

      {/* Step 1 — Connect */}
      <Card padding="lg">
        <StepHeader index={1} state={s1} icon={<Link2 className="w-4 h-4" />}
          title="Connect to HMRC"
          subtitle={s1 === 'done' ? 'Your HMRC authorisation is active.' : 'Authorise access to file via Making Tax Digital.'}
        />
        {s1 !== 'done' && (
          <div className="mt-4 pl-12">
            {loadingStatus ? (
              <span className="text-sm text-secondary-500 flex items-center gap-2">
                <Loader2 className="w-4 h-4 animate-spin" /> Checking…
              </span>
            ) : (
              <div className="space-y-2">
                {connected && !valid && (
                  <p className="text-sm text-amber-600">Your authorisation expired — reconnect to continue.</p>
                )}
                <button
                  onClick={handleConnect}
                  disabled={connecting}
                  className="flex items-center gap-2 px-4 py-2 bg-primary-600 text-white rounded-lg hover:bg-primary-700 disabled:opacity-50"
                >
                  {connecting ? <Loader2 className="w-4 h-4 animate-spin" /> : <Link2 className="w-4 h-4" />}
                  {connected ? 'Reconnect to HMRC' : 'Connect to HMRC'}
                </button>
                <p className="text-xs text-secondary-400">
                  Need a sandbox test login first? Use{' '}
                  <Link href="/dashboard/tax/settings" className="text-primary-600 underline">
                    Sandbox testing
                  </Link>
                  .
                </p>
              </div>
            )}
          </div>
        )}
      </Card>

      {/* Step 2 — Business */}
      <Card padding="lg">
        <StepHeader index={2} state={s2} icon={<Building2 className="w-4 h-4" />}
          title="Select your business"
          subtitle={
            s2 === 'done'
              ? `Filing for ${selectedBusiness}`
              : 'Pick the self-employment HMRC holds for you.'
          }
        />
        {s2 === 'active' && (
          <div className="mt-4 pl-12 space-y-3">
            {/* NINO — required by HMRC to look up the business. */}
            {hasNino && !editingNino ? (
              <p className="text-xs text-secondary-500">
                Using National Insurance number on file
                {ninoLast4 ? <span className="font-mono"> ••• {ninoLast4}</span> : ''}{' '}
                <span className="text-secondary-400">(stored encrypted)</span>.{' '}
                <button
                  onClick={() => { setEditingNino(true); setNinoInput(''); setNinoConsent(false); }}
                  className="text-primary-600 hover:underline"
                >
                  Change
                </button>
                {' · '}
                <button
                  onClick={removeNino}
                  disabled={removingNino}
                  className="text-red-600 hover:underline disabled:opacity-50"
                >
                  Remove
                </button>
              </p>
            ) : (
              <div className="rounded-lg border border-amber-200 bg-amber-50 p-3 space-y-2">
                <p className="text-sm text-amber-900">
                  HMRC needs your <strong>National Insurance number</strong> to find your business.
                  {' '}It must match the test user you sign in to HMRC as.
                </p>
                <div className="flex items-center gap-2">
                  <input
                    value={ninoInput}
                    onChange={(e) => setNinoInput(e.target.value.toUpperCase())}
                    placeholder="QQ123456C"
                    className="px-3 py-1.5 border border-secondary-300 rounded-lg text-sm bg-surface font-mono w-40"
                  />
                  <button
                    onClick={saveNino}
                    disabled={savingNino || ninoInput.trim().length < 9 || !ninoConsent}
                    className="flex items-center gap-2 px-3 py-1.5 bg-primary-600 text-white rounded-lg text-sm hover:bg-primary-700 disabled:opacity-50"
                  >
                    {savingNino ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Save'}
                  </button>
                  {hasNino && (
                    <button
                      onClick={() => { setEditingNino(false); setNinoInput(''); setNinoConsent(false); }}
                      className="text-xs text-secondary-500 hover:underline"
                    >
                      Cancel
                    </button>
                  )}
                </div>
                <label className="flex items-start gap-2 text-xs text-amber-900">
                  <input
                    type="checkbox"
                    checked={ninoConsent}
                    onChange={(e) => setNinoConsent(e.target.checked)}
                    className="mt-0.5"
                  />
                  <span>
                    I consent to OpsAPI securely storing my National Insurance number (encrypted) so it
                    can file my Self Assessment with HMRC. I can remove it at any time.
                  </span>
                </label>
                <p className="text-xs text-amber-700">
                  Testing? Create a sandbox test user under{' '}
                  <Link href="/dashboard/tax/settings" className="underline font-medium">
                    HMRC settings
                  </Link>{' '}
                  — then connect signing in with that test user.
                </p>
              </div>
            )}

            {loadingBiz && businesses.length === 0 ? (
              <p className="text-sm text-secondary-500 flex items-center gap-2">
                <Loader2 className="w-4 h-4 animate-spin" /> Finding your business at HMRC…
              </p>
            ) : businesses.length === 0 ? (
              // Auto-fetch ran but came back empty or errored — offer a manual retry.
              <button
                onClick={loadBusinesses}
                disabled={loadingBiz || !hasNino}
                title={!hasNino ? 'Add your NINO first' : undefined}
                className="flex items-center gap-2 px-4 py-2 border border-secondary-300 text-secondary-700 rounded-lg hover:bg-secondary-100 disabled:opacity-50"
              >
                {loadingBiz ? <Loader2 className="w-4 h-4 animate-spin" /> : <Building2 className="w-4 h-4" />}
                Try again
              </button>
            ) : (
              <div className="space-y-2">
                {businesses.map((b) => (
                  <button
                    key={bizId(b)}
                    onClick={() => chooseBusiness(bizId(b))}
                    className={`w-full text-left px-4 py-3 rounded-lg border transition-colors ${
                      selectedBusiness === bizId(b)
                        ? 'border-primary-400 bg-primary-50'
                        : 'border-secondary-200 hover:border-primary-300'
                    }`}
                  >
                    <p className="font-medium text-secondary-900">{bizName(b) || bizType(b) || 'Business'}</p>
                    <p className="text-xs text-secondary-500 font-mono">
                      {bizType(b)} · {bizId(b)}
                    </p>
                  </button>
                ))}
                <button onClick={loadBusinesses} className="text-xs text-primary-600 underline">
                  Refresh from HMRC
                </button>
              </div>
            )}

            {/* Real HMRC failure reason, instead of a silent empty list. */}
            {bizError && (
              <div className="rounded-lg border border-red-200 bg-red-50 p-3 space-y-2">
                <div className="flex items-start gap-2 text-xs text-red-700">
                  <AlertCircle className="w-4 h-4 mt-0.5 shrink-0" />
                  <span>{bizError}</span>
                </div>
                {bizErrorCode === 'CLIENT_OR_AGENT_NOT_AUTHORISED' && (
                  <button
                    onClick={handleConnect}
                    disabled={connecting}
                    className="flex items-center gap-2 px-3 py-1.5 bg-primary-600 text-white rounded-lg text-xs hover:bg-primary-700 disabled:opacity-50"
                  >
                    {connecting ? <Loader2 className="w-4 h-4 animate-spin" /> : <Link2 className="w-4 h-4" />}
                    Reconnect to HMRC
                  </button>
                )}
              </div>
            )}

            <p className="text-xs text-secondary-400">
              No business yet (sandbox)? Create one under{' '}
              <Link href="/dashboard/tax/settings" className="text-primary-600 underline">
                Sandbox testing → Set up sandbox business
              </Link>
              .
            </p>
          </div>
        )}
      </Card>

      {/* Step 3 — Obligations */}
      <Card padding="lg">
        <StepHeader index={3} state={s3} icon={<CalendarClock className="w-4 h-4" />}
          title="Your filing period"
          subtitle="We check with HMRC which period is open to file — no action needed."
        />
        {s3 !== 'locked' && (
          <div className="mt-4 pl-12 space-y-3">
            {loadingObl && obligations === null && (
              <p className="text-sm text-secondary-500 flex items-center gap-2">
                <Loader2 className="w-4 h-4 animate-spin" /> Checking what HMRC needs from you…
              </p>
            )}

            {obligations !== null && (
              openObligations.length > 0 ? (
                <div className="space-y-2">
                  <p className="text-xs text-secondary-500">
                    Pick the period you&apos;re filing for — this sets the tax year for the rest of the flow.
                  </p>
                  {openObligations.map((o, i) => {
                    const key = `${o.period_start}|${o.period_end}`;
                    const selected = selectedObligation === key;
                    return (
                      <button
                        key={i}
                        onClick={() => {
                          setSelectedObligation(key);
                          const derived = taxYearOf(o.period_start);
                          if (derived) { setTaxYear(derived); setPreview(null); setCalc(null); }
                        }}
                        className={`w-full text-left rounded-lg border p-3 text-sm transition-colors ${
                          selected ? 'border-primary-400 bg-primary-50' : 'border-amber-200 bg-amber-50 hover:border-primary-300'
                        }`}
                      >
                        <div className="flex items-center justify-between">
                          <span className="font-medium text-secondary-900">
                            {o.period_start} → {o.period_end}
                            <span className="ml-2 text-xs text-secondary-500">(tax year {taxYearOf(o.period_start)})</span>
                          </span>
                          <span className="text-xs font-semibold uppercase text-amber-700">
                            {selected ? '✓ Selected' : 'Open'}
                          </span>
                        </div>
                        {o.due_date && <p className="text-xs text-secondary-500 mt-0.5">Due {o.due_date}</p>}
                      </button>
                    );
                  })}
                  <p className="text-xs text-secondary-500">
                    Filing for tax year <strong>{taxYear}</strong>.
                  </p>
                </div>
              ) : (
                <p className="text-sm text-secondary-500">
                  No open obligations returned. You can still preview figures for tax year{' '}
                  <strong>{taxYear}</strong> below.
                </p>
              )
            )}

            {obligations !== null && !loadingObl && (
              <button onClick={loadObligations} className="flex items-center gap-1.5 text-xs text-primary-600 hover:underline">
                <RefreshCw className="w-3 h-3" /> Refresh from HMRC
              </button>
            )}
          </div>
        )}
      </Card>

      {/* Step 4 — Check figures */}
      <Card padding="lg">
        <StepHeader index={4} state={s4} icon={<ListChecks className="w-4 h-4" />}
          title="Check your figures"
          subtitle="Aggregate your classified transactions and fix anything that would be rejected."
        />
        {s4 !== 'locked' && (
          <div className="mt-4 pl-12 space-y-3">
            <p className="text-xs text-secondary-500">
              Checking figures for tax year <strong>{taxYear}</strong>
              {selectedObligation ? ' (from your selected HMRC obligation)' : ''}.
            </p>
            {loadingPreview && !preview && (
              <p className="text-sm text-secondary-500 flex items-center gap-2">
                <Loader2 className="w-4 h-4 animate-spin" /> Adding up your figures…
              </p>
            )}
            {preview && !loadingPreview && (
              <button onClick={loadPreview} className="flex items-center gap-1.5 text-xs text-primary-600 hover:underline">
                <ListChecks className="w-3 h-3" /> Re-check figures
              </button>
            )}

            {preview && (
              <div className="space-y-3">
                {/* counts */}
                <div className="grid grid-cols-2 sm:grid-cols-4 gap-2">
                  {[
                    ['Rows', preview.stats.rows],
                    ['In return', preview.stats.applied],
                    ['Need review', preview.stats.excluded_unreviewed],
                    ['Off-summary', preview.stats.excluded_no_mtd_field],
                  ].map(([label, v]) => (
                    <div key={label as string} className="rounded-lg border border-secondary-200 bg-surface p-2 text-center">
                      <p className="text-lg font-semibold text-secondary-900">{(v as number) ?? 0}</p>
                      <p className="text-[11px] text-secondary-500">{label}</p>
                    </div>
                  ))}
                </div>

                {/* The exact income/expense lines we'll submit to HMRC. */}
                <FiguresBreakdown body={preview.body} taxYear={taxYear} />

                {/* blocking: offending credits with inline fix */}
                {preview.blocking && (
                  <div className="rounded-lg border border-red-200 bg-red-50 p-3 space-y-3">
                    <p className="text-sm font-medium text-red-800 flex items-center gap-2">
                      <AlertTriangle className="w-4 h-4" />
                      These credits are filed as expenses and make a field negative — HMRC would reject them. Fix each one:
                    </p>
                    {(preview.offending_transactions || []).map((tx) => (
                      <div key={tx.uuid} className="rounded-md bg-surface border border-red-200 p-2.5">
                        <div className="flex items-center justify-between gap-2">
                          <div className="min-w-0">
                            <p className="text-sm font-medium text-secondary-900 truncate">{tx.description}</p>
                            <p className="text-xs text-secondary-500">
                              {tx.transaction_date} · <span className="font-mono">{tx.field}</span> ·{' '}
                              <span className="text-green-700">+{gbp(tx.amount)}</span>
                            </p>
                          </div>
                        </div>
                        <div className="mt-2 flex items-center gap-2">
                          <select
                            value={fixChoice[tx.uuid] || ''}
                            onChange={(e) => setFixChoice((p) => ({ ...p, [tx.uuid]: e.target.value }))}
                            className="flex-1 px-2 py-1.5 border border-secondary-300 rounded-md text-sm bg-surface"
                          >
                            <option value="">Correct this to…</option>
                            {FIX_OPTIONS.map((o) => (
                              <option key={o.value} value={o.value}>
                                {o.label}
                              </option>
                            ))}
                          </select>
                          <button
                            onClick={() => applyFix(tx)}
                            disabled={fixing === tx.uuid || !fixChoice[tx.uuid]}
                            className="flex items-center gap-1 px-3 py-1.5 bg-primary-600 text-white rounded-md text-sm hover:bg-primary-700 disabled:opacity-50"
                          >
                            {fixing === tx.uuid ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Fix'}
                          </button>
                        </div>
                      </div>
                    ))}
                  </div>
                )}

                {/* non-blocking warnings */}
                {!preview.blocking && preview.warnings.length > 0 && (
                  <div className="rounded-lg border border-amber-200 bg-amber-50 p-3 space-y-1">
                    {preview.warnings.map((w, i) => (
                      <p key={i} className="text-xs text-amber-800 flex items-start gap-1.5">
                        <AlertCircle className="w-3.5 h-3.5 mt-0.5 shrink-0" />
                        {w}
                      </p>
                    ))}
                  </div>
                )}

                {figuresEmpty && (
                  <div className="flex items-start gap-2 rounded-lg border border-amber-200 bg-amber-50 p-3 text-xs text-amber-800">
                    <AlertTriangle className="w-4 h-4 mt-0.5 shrink-0" />
                    <span>
                      No classified transactions fall in tax year <strong>{taxYear}</strong>. Your
                      statements are likely for a different year than this obligation — upload/classify
                      transactions for {taxYear}, or select the obligation that matches your data.
                    </span>
                  </div>
                )}

                {figuresOk && (
                  <p className="text-sm text-green-700 flex items-center gap-1.5">
                    <CheckCircle2 className="w-4 h-4" /> Your figures are ready to submit.
                  </p>
                )}
              </div>
            )}
          </div>
        )}
      </Card>

      {/* Step 5 — Preview calculation */}
      <Card padding="lg">
        <StepHeader index={5} state={s5} icon={<Calculator className="w-4 h-4" />}
          title="Preview your calculation"
          subtitle="Submit your figures to HMRC and get a non-binding tax calculation. This does not file your return."
        />
        {s5 !== 'locked' && (
          <div className="mt-4 pl-12 space-y-3">
            <p className="text-xs text-secondary-500">
              Submitting tax year <strong>{taxYear}</strong> for business{' '}
              <span className="font-mono">{selectedBusiness || '—'}</span>.
            </p>
            <button
              onClick={runCalculation}
              disabled={calculating}
              className="flex items-center gap-2 px-4 py-2 bg-primary-600 text-white rounded-lg hover:bg-primary-700 disabled:opacity-50"
            >
              {calculating ? <Loader2 className="w-4 h-4 animate-spin" /> : <Calculator className="w-4 h-4" />}
              {calculating ? 'Calculating…' : 'Run preview calculation'}
            </button>

            {calculating && !calc && (
              <p className="flex items-start gap-2 text-xs text-secondary-500">
                <Loader2 className="w-3.5 h-3.5 mt-0.5 shrink-0 animate-spin" />
                <span>
                  Setting things up with HMRC and working out your figures — the first run can take
                  a little longer. Please don&apos;t close this page.
                </span>
              </p>
            )}

            {calc && (
              <div className="space-y-3">
                {calc.sandbox_placeholder && (
                  <div className="flex items-start gap-2 rounded-lg bg-blue-50 border border-blue-200 p-3 text-xs text-blue-800">
                    <AlertCircle className="w-4 h-4 mt-0.5 shrink-0" />
                    <span>Sandbox returns a fixed placeholder for the total — the breakdown is illustrative.</span>
                  </div>
                )}
                <div className="grid grid-cols-2 sm:grid-cols-3 gap-2">
                  {[
                    ['Tax & NICs due', calc.figures.total_income_tax_and_nics_due],
                    ['Taxable income', calc.figures.total_taxable_income],
                    ['Income tax', calc.figures.income_tax_charged],
                    ['Personal allowance', calc.figures.personal_allowance],
                    ['Class 2 NIC', calc.figures.class2_nics],
                    ['Class 4 NIC', calc.figures.class4_nics],
                  ].map(([label, value]) => (
                    <div key={label as string} className="rounded-lg border border-secondary-200 bg-surface p-2.5">
                      <p className="text-xs text-secondary-500">{label}</p>
                      <p className="text-base font-semibold text-secondary-900">
                        {calc.sandbox_placeholder && label === 'Tax & NICs due' ? '—' : gbp(value as number | undefined)}
                      </p>
                    </div>
                  ))}
                </div>
              </div>
            )}
          </div>
        )}
      </Card>

      {/* Step 6 — Finalise */}
      <Card padding="lg">
        <StepHeader index={6} state={s6} icon={<FileCheck2 className="w-4 h-4" />}
          title="Finalise & declare"
          subtitle="The binding final declaration that files your return with HMRC."
        />
        {s6 !== 'locked' && (
          <div className="mt-4 pl-12 space-y-3">
            {filed ? (
              // Done — the return is filed with HMRC.
              <div className="rounded-lg border border-green-200 bg-green-50 p-4 space-y-2">
                <p className="flex items-center gap-2 font-semibold text-green-800">
                  <CheckCircle2 className="w-5 h-5" /> Your tax return has been filed with HMRC.
                </p>
                <p className="text-sm text-green-700">
                  Tax year <strong>{filed.tax_year}</strong> · business{' '}
                  <span className="font-mono">{filed.business_id}</span>
                </p>
                {filed.calculation_id && (
                  <p className="text-xs text-green-700">
                    HMRC calculation reference: <span className="font-mono">{filed.calculation_id}</span>
                  </p>
                )}
                {filed.sandbox && (
                  <p className="flex items-start gap-1.5 text-xs text-green-700">
                    <AlertCircle className="w-3.5 h-3.5 mt-0.5 shrink-0" />
                    Sandbox test submission — no real return was filed with HMRC.
                  </p>
                )}
              </div>
            ) : (
              <>
                <div className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900 flex items-start gap-2">
                  <AlertTriangle className="w-4 h-4 mt-0.5 shrink-0" />
                  <span>
                    This is the <strong>binding final declaration</strong> for tax year <strong>{taxYear}</strong>.
                    Once submitted, you are confirming the figures are correct and complete — this files your
                    Self Assessment return with HMRC.
                  </span>
                </div>

                <label className="flex items-start gap-2 text-sm text-secondary-700">
                  <input
                    type="checkbox"
                    checked={declarationAccepted}
                    onChange={(e) => setDeclarationAccepted(e.target.checked)}
                    className="mt-0.5"
                  />
                  <span>
                    I declare that the information I have given is correct and complete to the best of my
                    knowledge and belief, and I want to submit this as my final declaration to HMRC.
                  </span>
                </label>

                <button
                  onClick={submitFinalDeclaration}
                  disabled={filing || !declarationAccepted}
                  className="flex items-center gap-2 px-4 py-2 bg-primary-600 text-white rounded-lg hover:bg-primary-700 disabled:opacity-50"
                >
                  {filing ? <Loader2 className="w-4 h-4 animate-spin" /> : <FileCheck2 className="w-4 h-4" />}
                  {filing ? 'Filing your return…' : 'Submit final declaration & file'}
                </button>

                {filing && (
                  <p className="flex items-start gap-2 text-xs text-secondary-500">
                    <Loader2 className="w-3.5 h-3.5 mt-0.5 shrink-0 animate-spin" />
                    <span>Sending your figures and final declaration to HMRC — please don&apos;t close this page.</span>
                  </p>
                )}
              </>
            )}
          </div>
        )}
      </Card>
    </div>
  );
}

export default function FileWizardPage() {
  return (
    <ProtectedPage module="tax_statements" title="File your tax">
      <Suspense fallback={null}>
        <FileWizardContent />
      </Suspense>
    </ProtectedPage>
  );
}

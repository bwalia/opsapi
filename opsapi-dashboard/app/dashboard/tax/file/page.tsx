'use client';

/**
 * Guided "File your tax" wizard.
 *
 * One linear path so a non-expert can file without hopping between pages:
 *   1. National Insurance number (both paths)
 *   2. Check your transactions   (every extracted + classified row; the customer confirms
 *                                 each — nothing is filed until all are confirmed)
 *   then either "our accountant files it" (FileForMe) or, filing directly:
 *   3. Connect to HMRC          (OAuth)
 *   4. Select your business     (pull from HMRC, pick the self-employment)
 *   5. Fetch obligations        (which period HMRC says is open to file)
 *   6. Check your figures       (aggregate classified tx; fix mis-filed credits inline)
 *   7. Preview calculation      (submit cumulative + in-year calc — non-binding)
 *   8. Finalise & declare       (the binding final declaration)
 *
 * Layout: full-width main column + a sticky summary rail (figures, progress, key dates).
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
  Download,
  Fingerprint,
  Landmark,
  UserCheck,
  ClipboardCheck,
  CalendarDays,
} from 'lucide-react';
import { Card, Modal } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import FileForMe from '@/components/tax/FileForMe';
import TransactionReview from '@/components/tax/TransactionReview';
import { taxFilingService, type FilingOverview } from '@/services/tax-filing.service';
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

// The tax year people file now: the last COMPLETED one (years start 6 April).
// On 22 Oct 2026 that's "2025-26".
function currentFilingYear(now = new Date()): string {
  const afterApr6 = now.getMonth() > 3 || (now.getMonth() === 3 && now.getDate() >= 6);
  const start = (afterApr6 ? now.getFullYear() : now.getFullYear() - 1) - 1;
  return `${start}-${String((start + 1) % 100).padStart(2, '0')}`;
}

// UK NINO: two letters, six digits, suffix A–D (spaces allowed while typing).
const NINO_RE = /^[A-Z]{2}\d{6}[A-D]$/;
const cleanNino = (s: string) => s.replace(/\s+/g, '').toUpperCase();

function PathOption({ active, onClick, icon, title, text, badge }: {
  active: boolean; onClick: () => void; icon: React.ReactNode; title: string; text: string; badge?: string;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={active}
      className={`w-full rounded-xl border p-4 text-left transition-colors ${
        active ? 'border-primary-400 bg-primary-50 ring-1 ring-primary-300' : 'border-secondary-200 bg-surface hover:border-primary-300'
      }`}
    >
      <div className="flex items-center gap-2">
        <span className={active ? 'text-primary-600' : 'text-secondary-500'}>{icon}</span>
        <span className="font-semibold text-secondary-900">{title}</span>
        {badge && (
          <span className="ml-auto rounded-full bg-primary-100 px-2 py-0.5 text-xs font-medium text-primary-700">{badge}</span>
        )}
      </div>
      <p className="mt-1 text-sm text-secondary-500">{text}</p>
    </button>
  );
}

// One step in the direct-filing stepper: a vertical connector runs from this step's
// icon down to the next one, so the steps read as a single flow.
function StepBlock({ children, last }: { children: React.ReactNode; last?: boolean }) {
  return (
    <div className={`relative ${last ? '' : 'pb-7'}`}>
      {!last && <span aria-hidden className="absolute left-[17px] top-11 bottom-1 w-px bg-secondary-200" />}
      {children}
    </div>
  );
}

function CheckItem({ state, label, hint }: { state: 'done' | 'warn' | 'todo'; label: string; hint?: string }) {
  return (
    <li className="flex items-start gap-3">
      <span
        className={`mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full ${
          state === 'done' ? 'bg-green-100 text-green-600'
            : state === 'warn' ? 'bg-amber-100 text-amber-600' : 'border-2 border-secondary-200'
        }`}
      >
        {state === 'done' && <CheckCircle2 className="h-3.5 w-3.5" />}
        {state === 'warn' && <AlertTriangle className="h-3 w-3" />}
      </span>
      <span className="min-w-0">
        <span className={`block text-sm ${state === 'todo' ? 'text-secondary-500' : 'text-secondary-900'}`}>{label}</span>
        {hint && <span className="block text-xs text-secondary-500">{hint}</span>}
      </span>
    </li>
  );
}

// What went wrong coming back from HMRC, in words anyone can act on (the callback's
// ?hmrc_error= codes, plus HMRC's own OAuth error names).
const HMRC_CONNECT_ERRORS: Record<string, string> = {
  access_denied: 'You didn’t give permission on the HMRC website, so we couldn’t connect. Press the button again and choose “Give permission” (or “Grant authority”) at the end.',
  invalid_state: 'The HMRC sign-in took too long or was opened in another window. Please press the button again — it only takes a minute.',
  missing_params: 'We didn’t get an answer back from HMRC. Please press the button again.',
  token_exchange_failed: 'HMRC didn’t accept the connection just now. Please wait a minute and press the button again.',
  token_store_failed: 'We couldn’t save your HMRC connection. Please press the button again; if it keeps happening, contact us.',
  server_misconfigured: 'Connecting to HMRC isn’t switched on here yet. Please contact us, or choose “Our accountant files it”.',
};
const hmrcConnectError = (code: string) =>
  HMRC_CONNECT_ERRORS[code] || 'Something went wrong connecting to HMRC. Please press the button again.';

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

  // "Ready to file?" in File with AI passes ?tax_year=; else the year people file now.
  const [taxYear, setTaxYear] = useState(() => searchParams.get('tax_year') || currentFilingYear());

  // Your figures + the downloadable tax sheet + any accountant request (routes/tax-filing).
  const [overview, setOverview] = useState<FilingOverview | null>(null);
  const [loadingOverview, setLoadingOverview] = useState(true);
  const [downloadingSheet, setDownloadingSheet] = useState(false);
  // How to file. Coming back from the HMRC OAuth redirect means the direct path.
  const [path, setPath] = useState<'accountant' | 'direct'>(
    searchParams.get('hmrc_connected') || searchParams.get('hmrc_error') ? 'direct' : 'accountant',
  );
  const [confirmRemoveNino, setConfirmRemoveNino] = useState(false);

  // Step 2 — connection
  const [connected, setConnected] = useState(false);
  const [valid, setValid] = useState(false);
  const [loadingStatus, setLoadingStatus] = useState(true);
  const [connecting, setConnecting] = useState(false);
  // HMRC's test service (sandbox) — only then do we show test-login help.
  const [sandbox, setSandbox] = useState(false);
  // Why the last HMRC connect failed, shown in the step itself (a toast is easy to miss).
  const [connectError, setConnectError] = useState<string | null>(() => {
    const e = searchParams.get('hmrc_error');
    return e ? hmrcConnectError(e) : null;
  });

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

  // ── Your figures (both paths) ───────────────────────────────────────────────
  const loadOverview = useCallback(async () => {
    if (!taxYearBounds(taxYear)) {
      setOverview(null);
      setLoadingOverview(false);
      return;
    }
    setLoadingOverview(true);
    try {
      setOverview(await taxFilingService.overview(taxYear));
    } catch {
      setOverview(null);
    } finally {
      setLoadingOverview(false);
    }
  }, [taxYear]);

  useEffect(() => {
    loadOverview();
  }, [loadOverview]);

  // Direct filing can be switched off (until we're an HMRC-recognised filer).
  useEffect(() => {
    if (overview && !overview.direct_filing_enabled) setPath('accountant');
  }, [overview]);

  const downloadSheet = async () => {
    setDownloadingSheet(true);
    try {
      await taxFilingService.downloadCalculation(taxYear);
    } catch (err: unknown) {
      toast.error(extractApiError(err, 'Could not download your tax sheet'));
    } finally {
      setDownloadingSheet(false);
    }
  };

  // ── Step 1: connection ──────────────────────────────────────────────────────
  const fetchStatus = useCallback(async () => {
    setLoadingStatus(true);
    try {
      const s = await taxService.getHmrcStatus();
      setConnected(!!s.connected);
      setValid(!!s.is_valid);
      setSandbox(!!s.sandbox);
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
      toast.success('You’re connected to HMRC');
      fetchStatus();
    }
    // Back from HMRC either way: bring the HMRC steps into view so nobody is lost.
    if (searchParams.get('hmrc_connected') || searchParams.get('hmrc_error')) {
      setTimeout(() => document.getElementById('file-direct')?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 400);
    }
  }, [searchParams, fetchStatus]);

  const handleConnect = async () => {
    setConnecting(true);
    setConnectError(null);
    try {
      // Pass the BASE; the backend callback appends "/file" (source=file) and the
      // hmrc_connected flag → .../dashboard/tax/file?...&hmrc_connected=true.
      const redirectUrl = `${window.location.origin}/dashboard/tax`;
      const authUrl = await taxService.initiateHmrcConnect(redirectUrl, 'file');
      if (!authUrl) throw new Error('No auth URL');
      window.location.href = authUrl;
    } catch (err: unknown) {
      setConnectError(extractApiError(err, 'We couldn’t open the HMRC website. Please check your internet connection and try again.'));
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
      const r = await taxService.saveHmrcNino(cleanNino(ninoInput), ninoConsent);
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

  // Confirmed via the "Remove NINO?" modal.
  const removeNino = async () => {
    setRemovingNino(true);
    try {
      await taxService.deleteHmrcNino();
      setConfirmRemoveNino(false);
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
        setBizError('HMRC has no self-employed business for this National Insurance number. Check the number in step 1 is right, or choose “Our accountant files it”.');
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
      if (res.already_filed) toast.success(res.message || `Your ${taxYear} return was already filed with HMRC`);
      else toast.success('Your return has been filed with HMRC');
    } catch (err: unknown) {
      toast.error(extractApiError(err, 'Final declaration failed'));
    } finally {
      setFiling(false);
    }
  };

  // ── Derived step states ───────────────────────────────────────────────────────
  // NINO first (both paths), then — for direct filing — connect, business, obligations…
  const sNino: StepState = hasNino ? 'done' : 'active';
  // Nothing is filed until the customer has confirmed every transaction (step 2).
  const txTotal = overview?.estimate.transactions ?? 0;
  const txConfirmed = overview?.estimate.confirmed ?? 0;
  const allConfirmed = txTotal > 0 && txConfirmed >= txTotal;
  const sReview: StepState = allConfirmed ? 'done' : 'active';
  const s1: StepState = !hasNino ? 'locked' : connected && valid ? 'done' : 'active';
  const ninoClean = cleanNino(ninoInput);
  const ninoValid = NINO_RE.test(ninoClean);
  const s2: StepState = s1 !== 'done' ? 'locked' : selectedBusiness ? 'done' : 'active';
  const s3: StepState = s2 !== 'done' ? 'locked' : obligations !== null ? 'done' : 'active';
  // Obligations are informational, so step 4 unlocks once a business is chosen.
  // An empty aggregate (no classified tx in the obligation's tax year) is NOT ready to file.
  const figuresEmpty = !!preview && (((preview.stats.applied as number) ?? 0) === 0);
  const figuresOk = preview !== null && !preview.blocking && !figuresEmpty;
  const s4: StepState = s2 !== 'done' ? 'locked' : figuresOk ? 'done' : 'active';
  const s5: StepState = !figuresOk || !allConfirmed ? 'locked' : calc ? 'done' : 'active';
  const s6: StepState = filed ? 'done' : !calc ? 'locked' : 'active';

  const openObligations = (obligations || []).filter(isOpen);

  const changeYear = (y: string) => {
    setTaxYear(y);
    // Year change invalidates downstream data.
    setObligations(null);
    setPreview(null);
    setCalc(null);
  };
  const yearOptions = Array.from({ length: 4 }, (_, i) => {
    const y = parseInt(currentFilingYear().slice(0, 4), 10) - i;
    return `${y}-${String((y + 1) % 100).padStart(2, '0')}`;
  });
  if (!yearOptions.includes(taxYear)) yearOptions.unshift(taxYear);
  const startYear = taxYearBounds(taxYear) ? parseInt(taxYear.slice(0, 4), 10) : null;

  // Sidebar progress: the accountant path tracks the request, the direct path HMRC.
  const req = overview?.request;
  const sent = !!req && (req.open || req.status === 'filed');
  const isFiled = path === 'accountant' ? req?.status === 'filed' : !!filed;

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div className="min-w-0">
          <p className="text-xs font-semibold uppercase tracking-wider text-primary-600">Self Assessment</p>
          <h1 className="mt-1 text-2xl font-bold tracking-tight text-secondary-900 sm:text-3xl">File your tax return</h1>
          <p className="mt-1.5 max-w-2xl text-sm text-secondary-500">
            Check what we read from your bank statements, confirm it, then choose how to file — our accountant
            files it for you, or you file directly with HMRC.
          </p>
        </div>
        <label className="flex shrink-0 items-center gap-2 text-sm">
          <span className="font-medium text-secondary-600">Tax year</span>
          <select
            value={taxYear}
            onChange={(e) => changeYear(e.target.value)}
            className="rounded-lg border border-secondary-300 bg-surface px-3 py-2 text-sm font-medium text-secondary-900 focus:outline-none focus:ring-2 focus:ring-primary-500"
          >
            {yearOptions.map((y) => <option key={y} value={y}>{y}</option>)}
          </select>
        </label>
      </div>

      <div className="grid grid-cols-1 gap-6 xl:grid-cols-[minmax(0,1fr)_360px] 2xl:grid-cols-[minmax(0,1fr)_400px]">
        {/* Summary rail: first on mobile, a sticky right column on wide screens. */}
        <aside className="space-y-5 xl:sticky xl:top-6 xl:col-start-2 xl:row-start-1 xl:self-start">
          <Card padding="none" className="overflow-hidden">
            {loadingOverview && !overview ? (
              <p className="flex items-center gap-2 p-5 text-sm text-secondary-500">
                <Loader2 className="w-4 h-4 animate-spin" /> Loading your figures…
              </p>
            ) : !overview ? (
              <p className="p-5 text-sm text-secondary-500">Pick a tax year to see your figures.</p>
            ) : (
              <>
                <div className="bg-linear-to-br from-primary-600 to-primary-800 px-5 py-5 text-white">
                  <p className="text-xs font-medium uppercase tracking-wider text-white/75">
                    Estimated tax · {overview.tax_year}
                  </p>
                  <p className="mt-1 text-3xl font-bold tabular-nums">{gbp(overview.estimate.total_tax_and_nic)}</p>
                  <p className="mt-0.5 text-xs text-white/75">Income Tax and National Insurance</p>
                </div>
                <dl className="divide-y divide-secondary-100 px-5 text-sm">
                  {([
                    ['Income', overview.estimate.income],
                    ['Allowable expenses', overview.estimate.expenses],
                    ['Profit', overview.estimate.profit],
                    ['Income Tax', overview.estimate.income_tax],
                    ['Class 4 National Insurance', overview.estimate.class4_nic],
                    ['Due by 31 January*', overview.estimate.total_due_31_jan],
                  ] as Array<[string, number]>).map(([label, value], i, all) => (
                    <div key={label} className="flex items-center justify-between gap-3 py-2.5">
                      <dt className="text-secondary-500">{label}</dt>
                      <dd className={`tabular-nums ${i === all.length - 1 ? 'font-semibold text-secondary-900' : 'font-medium text-secondary-800'}`}>
                        {gbp(value)}
                      </dd>
                    </div>
                  ))}
                </dl>
                <div className="space-y-3 border-t border-secondary-100 p-5">
                  <button
                    onClick={downloadSheet}
                    disabled={downloadingSheet || overview.estimate.transactions === 0}
                    className="flex w-full items-center justify-center gap-2 rounded-lg border border-secondary-300 px-3 py-2 text-sm font-medium text-secondary-700 hover:bg-secondary-100 disabled:opacity-50"
                  >
                    {downloadingSheet ? <Loader2 className="w-4 h-4 animate-spin" /> : <Download className="w-4 h-4" />}
                    Download tax sheet (.xlsx)
                  </button>
                  <p className="text-xs leading-relaxed text-secondary-400">
                    *Includes your first payment on account for next year. The tax sheet lists your figures by HMRC
                    box (SA103F) with the matching Making Tax Digital field — ready for other HMRC-recognised
                    software such as My Tax Digital.
                  </p>
                </div>
              </>
            )}
          </Card>

          <Card padding="lg">
            <p className="text-sm font-semibold text-secondary-900">Your progress</p>
            <ul className="mt-3 space-y-3">
              <CheckItem
                state={hasNino ? 'done' : 'todo'}
                label="National Insurance number"
                hint={hasNino ? `Ending ${ninoLast4 ?? '••••'}` : 'Needed whichever way you file'}
              />
              <CheckItem
                state={allConfirmed ? 'done' : txConfirmed > 0 ? 'warn' : 'todo'}
                label="Transactions checked"
                hint={txTotal ? `${txConfirmed} of ${txTotal} confirmed` : 'Upload your statements first'}
              />
              {path === 'accountant' ? (
                <CheckItem
                  state={sent ? 'done' : 'todo'}
                  label="Sent to our accountant"
                  hint={sent ? (req?.status === 'needs_info' ? 'They have a question for you' : 'With our accountant') : undefined}
                />
              ) : (
                <CheckItem state={connected && valid ? 'done' : 'todo'} label="Connected to HMRC" />
              )}
              <CheckItem
                state={isFiled ? 'done' : 'todo'}
                label="Filed with HMRC"
                hint={isFiled && req?.hmrc_reference ? `Reference ${req.hmrc_reference}` : undefined}
              />
            </ul>
          </Card>

          {startYear && (
            <Card padding="lg">
              <p className="flex items-center gap-2 text-sm font-semibold text-secondary-900">
                <CalendarDays className="h-4 w-4 text-secondary-400" /> Key dates
              </p>
              <dl className="mt-3 space-y-2.5 text-sm">
                {([
                  ['Tax year', `6 Apr ${startYear} – 5 Apr ${startYear + 1}`],
                  ['Online return + tax due', `31 Jan ${startYear + 2}`],
                  ['2nd payment on account (if due)', `31 Jul ${startYear + 2}`],
                ] as Array<[string, string]>).map(([label, value]) => (
                  <div key={label} className="flex items-start justify-between gap-3">
                    <dt className="text-secondary-500">{label}</dt>
                    <dd className="text-right font-medium text-secondary-900">{value}</dd>
                  </div>
                ))}
              </dl>
            </Card>
          )}
        </aside>

        <div className="min-w-0 space-y-5 xl:col-start-1 xl:row-start-1">
      {/* Step 1 — NINO (both paths) */}
      <Card padding="lg" id="step-nino">
        <StepHeader index={1} state={sNino} icon={<Fingerprint className="w-4 h-4" />}
          title="Your National Insurance number"
          subtitle={
            hasNino
              ? `Saved, ending ${ninoLast4 ?? '••••'} — stored encrypted.`
              : 'HMRC identifies you by it, so it’s needed whichever way you file.'
          }
        />
        {hasNino === null ? (
          <p className="mt-3 pl-12 text-sm text-secondary-500 flex items-center gap-2">
            <Loader2 className="w-4 h-4 animate-spin" /> Checking…
          </p>
        ) : hasNino && !editingNino ? (
          <p className="mt-3 pl-12 text-xs text-secondary-500">
            <button
              onClick={() => { setEditingNino(true); setNinoInput(''); setNinoConsent(false); }}
              className="text-primary-600 hover:underline"
            >
              Change
            </button>
            {' · '}
            <button
              onClick={() => setConfirmRemoveNino(true)}
              disabled={removingNino}
              className="text-red-600 hover:underline disabled:opacity-50"
            >
              Remove
            </button>
          </p>
        ) : (
          <div className="mt-4 pl-12">
            <div className="rounded-lg border border-amber-200 bg-amber-50 p-3 space-y-2">
              <div className="flex flex-wrap items-center gap-2">
                <input
                  value={ninoInput}
                  onChange={(e) => setNinoInput(e.target.value.toUpperCase())}
                  placeholder="QQ 12 34 56 C"
                  maxLength={13}
                  aria-label="National Insurance number"
                  className="px-3 py-1.5 border border-secondary-300 rounded-lg text-sm bg-surface font-mono w-44"
                />
                <button
                  onClick={saveNino}
                  disabled={savingNino || !ninoValid || !ninoConsent}
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
              {ninoClean.length >= 9 && !ninoValid && (
                <p className="text-xs text-red-700">
                  That doesn’t look like a National Insurance number — 2 letters, 6 numbers, then A, B, C or D.
                </p>
              )}
              <label className="flex items-start gap-2 text-xs text-amber-900">
                <input
                  type="checkbox"
                  checked={ninoConsent}
                  onChange={(e) => setNinoConsent(e.target.checked)}
                  className="mt-0.5"
                />
                <span>
                  I consent to my National Insurance number being stored securely (encrypted) so my Self Assessment
                  can be filed with HMRC — by me or by your accountant. I can remove it at any time.
                </span>
              </label>
              <p className="text-xs text-amber-800">
                You can find it on your payslip, P60, or letters from HMRC or the DWP.
              </p>
              {sandbox && (
                <p className="text-xs text-amber-700">
                  Testing with HMRC&apos;s test service? It must match the test user you sign in to HMRC with — create
                  one under{' '}
                  <Link href="/dashboard/tax/settings" className="underline font-medium">HMRC settings</Link>.
                </p>
              )}
            </div>
          </div>
        )}
      </Card>

      {/* Step 2 — the customer checks every extracted + classified transaction */}
      <Card padding="lg">
        <StepHeader index={2} state={sReview} icon={<ClipboardCheck className="w-4 h-4" />}
          title="Check your transactions"
          subtitle={
            allConfirmed
              ? `All ${txTotal} confirmed by you.`
              : 'What we read from your statements and how we sorted each one. Confirm them before anything is filed.'
          }
        />
        <div className="mt-4">
          {overview ? (
            <TransactionReview
              key={taxYear}
              taxYear={taxYear}
              total={txTotal}
              confirmed={txConfirmed}
              toCheck={overview.estimate.unreviewed ?? 0}
              onChanged={loadOverview}
            />
          ) : loadingOverview ? (
            <p className="flex items-center gap-2 text-sm text-secondary-500">
              <Loader2 className="w-4 h-4 animate-spin" /> Loading your transactions…
            </p>
          ) : null}
        </div>
      </Card>

      {/* How to file */}
      {overview?.direct_filing_enabled !== false && (
        <div className="space-y-2">
          <p className="text-sm font-semibold text-secondary-900">How would you like to file?</p>
          <div className="grid gap-3 sm:grid-cols-2">
            <PathOption
              active={path === 'accountant'}
              onClick={() => setPath('accountant')}
              icon={<UserCheck className="w-4 h-4" />}
              title="Our accountant files it"
              badge="Recommended"
              text="A qualified accountant checks your figures and files with HMRC-recognised software."
            />
            <PathOption
              active={path === 'direct'}
              onClick={() => {
                setPath('direct');
                setTimeout(() => document.getElementById('file-direct')?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 100);
              }}
              icon={<Landmark className="w-4 h-4" />}
              title="File directly with HMRC"
              text="Sign in to HMRC once to link your account, then send your return yourself. We guide you through every step."
            />
          </div>
        </div>
      )}

      {path === 'accountant' && overview && (
        <FileForMe overview={overview} taxYear={taxYear} hasNino={!!hasNino} onChanged={loadOverview} />
      )}

      {path === 'direct' && (<Card padding="lg" id="file-direct" className="scroll-mt-6">
      {/* Step 3 — Connect */}
      <StepBlock>
        <StepHeader index={3} state={s1} icon={<Link2 className="w-4 h-4" />}
          title="Connect to HMRC"
          subtitle={
            s1 === 'done'
              ? 'Done — you’re connected to HMRC.'
              : s1 === 'locked'
                ? 'First add your National Insurance number (step 1).'
                : 'Sign in to HMRC once, so we can send your return for you.'
          }
        />
        {s1 === 'locked' && hasNino === false && (
          <div className="mt-4 pl-12">
            <button
              onClick={() => document.getElementById('step-nino')?.scrollIntoView({ behavior: 'smooth', block: 'start' })}
              className="flex items-center gap-2 rounded-lg border border-primary-300 bg-primary-50 px-4 py-2.5 text-sm font-medium text-primary-700 hover:bg-primary-100"
            >
              <Fingerprint className="w-4 h-4" /> Add my National Insurance number
            </button>
          </div>
        )}
        {s1 === 'active' && (
          <div className="mt-4 pl-12">
            {loadingStatus ? (
              <span className="text-sm text-secondary-500 flex items-center gap-2">
                <Loader2 className="w-4 h-4 animate-spin" /> Checking…
              </span>
            ) : (
              <div className="space-y-4">
                {connectError && (
                  <div role="alert" className="flex items-start gap-2 rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-800">
                    <AlertCircle className="w-5 h-5 mt-0.5 shrink-0" />
                    <span>{connectError}</span>
                  </div>
                )}
                {connected && !valid && !connectError && (
                  <p className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800">
                    Your link to HMRC has run out (HMRC asks for this every so often). Please connect again — it only
                    takes a minute.
                  </p>
                )}
                <div className="rounded-lg border border-secondary-200 bg-secondary-50 p-4">
                  <p className="text-sm font-semibold text-secondary-900">What happens when you press the button</p>
                  <ol className="mt-2 space-y-2 text-sm text-secondary-700">
                    {[
                      'We open the HMRC website (GOV.UK) for you.',
                      'Sign in with your Government Gateway user ID and password — the same ones you use for your HMRC online account.',
                      'HMRC may send a code to your phone. Type it in.',
                      'At the end, press “Give permission” (it may say “Grant authority”).',
                      'You come straight back to this page, ready for the next step.',
                    ].map((line, i) => (
                      <li key={i} className="flex items-start gap-2.5">
                        <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-primary-100 text-xs font-semibold text-primary-700">
                          {i + 1}
                        </span>
                        <span className="pt-0.5">{line}</span>
                      </li>
                    ))}
                  </ol>
                </div>
                <button
                  onClick={handleConnect}
                  disabled={connecting}
                  className="flex w-full items-center justify-center gap-2 rounded-lg bg-primary-600 px-5 py-3 text-base font-semibold text-white hover:bg-primary-700 disabled:opacity-50 sm:w-auto"
                >
                  {connecting ? <Loader2 className="w-5 h-5 animate-spin" /> : <Link2 className="w-5 h-5" />}
                  {connecting ? 'Opening the HMRC website…' : connected ? 'Connect to HMRC again' : 'Go to HMRC to connect'}
                </button>
                <p className="text-sm text-secondary-500">
                  No Government Gateway user ID?{' '}
                  <a
                    href="https://www.gov.uk/log-in-register-hmrc-online-services"
                    target="_blank"
                    rel="noopener noreferrer"
                    className="font-medium text-primary-600 underline"
                  >
                    Create one on GOV.UK
                  </a>
                  , then come back here. Prefer not to? Choose <strong>Our accountant files it</strong> above.
                </p>
                {sandbox && (
                  <p className="text-xs text-secondary-400">
                    Testing with HMRC&apos;s test service? Get a test login under{' '}
                    <Link href="/dashboard/tax/settings" className="text-primary-600 underline">
                      Sandbox testing
                    </Link>
                    .
                  </p>
                )}
              </div>
            )}
          </div>
        )}
      </StepBlock>

      {/* Step 2 — Business */}
      <StepBlock>
        <StepHeader index={4} state={s2} icon={<Building2 className="w-4 h-4" />}
          title="Your business"
          subtitle={
            s2 === 'done'
              ? `Filing for ${bizName(businesses.find((b) => bizId(b) === selectedBusiness) || {}) || 'your self-employed business'}.`
              : 'We ask HMRC for the self-employed business it holds for you.'
          }
        />
        {s2 === 'active' && (
          <div className="mt-4 pl-12 space-y-3">
            {/* The NINO is now step 1, so it's always on file by the time we get here. */}
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
                    <p className="font-medium text-secondary-900">{bizName(b) || 'Your business'}</p>
                    <p className="text-xs text-secondary-500">
                      {/self-employment/i.test(bizType(b)) ? 'Self-employed' : bizType(b).replace(/-/g, ' ')}
                      {selectedBusiness === bizId(b) ? ' · ✓ Chosen' : ' · Press to choose'}
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

            {sandbox && (
              <p className="text-xs text-secondary-400">
                No business yet (test service)? Create one under{' '}
                <Link href="/dashboard/tax/settings" className="text-primary-600 underline">
                  Sandbox testing → Set up sandbox business
                </Link>
                .
              </p>
            )}
          </div>
        )}
      </StepBlock>

      {/* Step 3 — Obligations */}
      <StepBlock>
        <StepHeader index={5} state={s3} icon={<CalendarClock className="w-4 h-4" />}
          title="Your filing period"
          subtitle="We check with HMRC which dates you're filing for — nothing for you to do."
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
                    These are the dates HMRC is waiting for. We&apos;ve picked the first one — press another to change it.
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
                  HMRC isn&apos;t waiting on any dates right now. You can carry on with tax year{' '}
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
      </StepBlock>

      {/* Step 4 — Check figures */}
      <StepBlock>
        <StepHeader index={6} state={s4} icon={<ListChecks className="w-4 h-4" />}
          title="Check your figures"
          subtitle="We add up your income and expenses, and point out anything HMRC would turn down."
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
                    ['Transactions', preview.stats.rows],
                    ['In your return', preview.stats.applied],
                    ['Still to check', preview.stats.excluded_unreviewed],
                    ['Not needed by HMRC', preview.stats.excluded_no_mtd_field],
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
                      Some money coming in has been sorted as an expense, so HMRC would turn the return down. Tell us what each one is:
                    </p>
                    {(preview.offending_transactions || []).map((tx) => (
                      <div key={tx.uuid} className="rounded-md bg-surface border border-red-200 p-2.5">
                        <div className="flex items-center justify-between gap-2">
                          <div className="min-w-0">
                            <p className="text-sm font-medium text-secondary-900 truncate">{tx.description}</p>
                            <p className="text-xs text-secondary-500">
                              {tx.transaction_date} ·{' '}
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
                      We have no transactions for tax year <strong>{taxYear}</strong>. Your bank statements may be
                      for a different year — upload statements for {taxYear}, or pick the dates above that match
                      your statements.
                    </span>
                  </div>
                )}

                {figuresOk && allConfirmed && (
                  <p className="text-sm text-green-700 flex items-center gap-1.5">
                    <CheckCircle2 className="w-4 h-4" /> Your figures are ready to submit.
                  </p>
                )}
                {figuresOk && !allConfirmed && (
                  <p className="flex items-start gap-2 rounded-lg border border-amber-200 bg-amber-50 p-3 text-xs text-amber-800">
                    <AlertTriangle className="w-4 h-4 mt-0.5 shrink-0" />
                    Confirm your transactions in step 2 before sending anything to HMRC.
                  </p>
                )}
              </div>
            )}
          </div>
        )}
      </StepBlock>

      {/* Step 5 — Preview calculation */}
      <StepBlock>
        <StepHeader index={7} state={s5} icon={<Calculator className="w-4 h-4" />}
          title="See your tax bill from HMRC"
          subtitle="We send your figures to HMRC and they work out your tax. This does not file your return yet."
        />
        {s5 !== 'locked' && (
          <div className="mt-4 pl-12 space-y-3">
            <p className="text-sm text-secondary-500">
              For tax year <strong>{taxYear}</strong>. You can do this as many times as you like.
            </p>
            <button
              onClick={runCalculation}
              disabled={calculating}
              className="flex w-full items-center justify-center gap-2 rounded-lg bg-primary-600 px-5 py-3 text-base font-semibold text-white hover:bg-primary-700 disabled:opacity-50 sm:w-auto"
            >
              {calculating ? <Loader2 className="w-5 h-5 animate-spin" /> : <Calculator className="w-5 h-5" />}
              {calculating ? 'HMRC is working it out…' : calc ? 'Ask HMRC again' : 'Ask HMRC to work out my tax'}
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
                    <span>HMRC&apos;s test service shows a made-up total, so it&apos;s hidden — the other figures are a guide.</span>
                  </div>
                )}
                <div className="grid grid-cols-2 sm:grid-cols-3 gap-2">
                  {[
                    ['Tax & National Insurance due', calc.figures.total_income_tax_and_nics_due],
                    ['Taxable income', calc.figures.total_taxable_income],
                    ['Income tax', calc.figures.income_tax_charged],
                    ['Personal allowance', calc.figures.personal_allowance],
                    ['Class 2 National Insurance', calc.figures.class2_nics],
                    ['Class 4 National Insurance', calc.figures.class4_nics],
                  ].map(([label, value]) => (
                    <div key={label as string} className="rounded-lg border border-secondary-200 bg-surface p-2.5">
                      <p className="text-xs text-secondary-500">{label}</p>
                      <p className="text-base font-semibold text-secondary-900">
                        {calc.sandbox_placeholder && label === 'Tax & National Insurance due' ? '—' : gbp(value as number | undefined)}
                      </p>
                    </div>
                  ))}
                </div>
              </div>
            )}
          </div>
        )}
      </StepBlock>

      {/* Step 6 — Finalise */}
      <StepBlock last>
        <StepHeader index={8} state={s6} icon={<FileCheck2 className="w-4 h-4" />}
          title="File your tax return"
          subtitle="The last step: you confirm everything is right and we send your return to HMRC."
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
                  Tax year <strong>{filed.tax_year}</strong>. You don&apos;t need to do anything else for this year
                  on this page. Keep the reference below for your records.
                </p>
                {filed.calculation_id && (
                  <p className="text-xs text-green-700">
                    HMRC calculation reference: <span className="font-mono">{filed.calculation_id}</span>
                  </p>
                )}
                {filed.sandbox && (
                  <p className="flex items-start gap-1.5 text-xs text-green-700">
                    <AlertCircle className="w-3.5 h-3.5 mt-0.5 shrink-0" />
                    This was a test using HMRC&apos;s test service — no real return was filed.
                  </p>
                )}
              </div>
            ) : (
              <>
                <div className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900 flex items-start gap-2">
                  <AlertTriangle className="w-4 h-4 mt-0.5 shrink-0" />
                  <span>
                    This <strong>files your tax return</strong> for tax year <strong>{taxYear}</strong> with HMRC.
                    It can&apos;t be undone here, so please check your figures above first.
                  </span>
                </div>

                <label className="flex cursor-pointer items-start gap-3 rounded-lg border border-secondary-200 p-3 text-sm text-secondary-700 hover:bg-secondary-50">
                  <input
                    type="checkbox"
                    checked={declarationAccepted}
                    onChange={(e) => setDeclarationAccepted(e.target.checked)}
                    className="mt-0.5 h-5 w-5 shrink-0"
                  />
                  <span>
                    I declare that the information I have given is correct and complete to the best of my
                    knowledge and belief, and I want to submit this as my final declaration to HMRC.
                  </span>
                </label>

                <button
                  onClick={submitFinalDeclaration}
                  disabled={filing || !declarationAccepted}
                  className="flex w-full items-center justify-center gap-2 rounded-lg bg-primary-600 px-5 py-3 text-base font-semibold text-white hover:bg-primary-700 disabled:opacity-50 sm:w-auto"
                >
                  {filing ? <Loader2 className="w-5 h-5 animate-spin" /> : <FileCheck2 className="w-5 h-5" />}
                  {filing ? 'Sending your return to HMRC…' : 'File my tax return now'}
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
      </StepBlock>
      </Card>)}
        </div>
      </div>

      <Modal
        isOpen={confirmRemoveNino}
        onClose={() => setConfirmRemoveNino(false)}
        title="Remove your National Insurance number?"
        size="sm"
        footer={(
          <div className="flex justify-end gap-2">
            <button
              type="button"
              onClick={() => setConfirmRemoveNino(false)}
              className="rounded-lg border border-secondary-300 px-4 py-2 text-sm font-medium text-secondary-700 hover:bg-secondary-50"
            >
              Keep it
            </button>
            <button
              type="button"
              onClick={removeNino}
              disabled={removingNino}
              className="flex items-center gap-2 rounded-lg bg-red-600 px-4 py-2 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-50"
            >
              {removingNino && <Loader2 className="w-4 h-4 animate-spin" />}
              Remove
            </button>
          </div>
        )}
      >
        <p className="text-sm text-secondary-600">
          We&apos;ll delete the encrypted copy we hold. You&apos;ll need to enter it again before your return can be filed.
        </p>
      </Modal>
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

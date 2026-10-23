'use client';

import React, { Suspense, useCallback, useEffect, useRef, useState } from 'react';
import { useParams, useRouter, useSearchParams } from 'next/navigation';
import Link from 'next/link';
import {
  ArrowLeft,
  BarChart3,
  Calendar,
  Check,
  CheckCircle,
  ChevronDown,
  Copy,
  FileText,
  FlaskConical,
  Pause,
  Pencil,
  Play,
  Radar,
  Send,
  Shield,
  ShieldCheck,
  ThumbsDown,
  Users,
  X,
  XCircle,
} from 'lucide-react';
import { Button, ConfirmDialog, Modal } from '@/components/ui';
import { marketingService } from '@/services/opsapi-marketing.service';
import {
  type AudiencePreview,
  type Campaign,
  type CampaignStatus,
  type MktList,
  AB_EDITABLE_STATUSES,
  EDITABLE_STATUSES,
  INPUT_CLASS,
  LIVE_STATUSES,
  Notice,
  StatusBadge,
  apiErrorCode,
  apiErrorMessage,
  fmtDateTime,
  fmtInt,
  normaliseCampaign,
  toLocalInput,
  unwrap,
  unwrapArray,
} from '../_components/shared';
import PerformanceTab from '../_components/PerformanceTab';
import ContentTab from '../_components/ContentTab';
import AudienceTab from '../_components/AudienceTab';
import TrackingTab from '../_components/TrackingTab';
import AbTestTab from '../_components/AbTestTab';
import { HelpLink } from '@/components/opsapi-marketing/GettingStarted';
import { TestModeBanner, useTestMode } from '@/components/opsapi-marketing/TestMode';

type TabKey = 'performance' | 'content' | 'audience' | 'tracking' | 'ab';

const TABS: { key: TabKey; label: string; icon: React.ReactNode }[] = [
  { key: 'performance', label: 'Performance', icon: <BarChart3 className="h-4 w-4" aria-hidden="true" /> },
  { key: 'content', label: 'Content', icon: <FileText className="h-4 w-4" aria-hidden="true" /> },
  { key: 'audience', label: 'Audience', icon: <Users className="h-4 w-4" aria-hidden="true" /> },
  { key: 'tracking', label: 'Tracking', icon: <Radar className="h-4 w-4" aria-hidden="true" /> },
  { key: 'ab', label: 'A/B test', icon: <FlaskConical className="h-4 w-4" aria-hidden="true" /> },
];

const POLL_MS = 15_000;

type Dialog = null | 'schedule' | 'reject' | 'approval' | 'duplicate' | 'cancel' | 'send';

type Flash = { tone: 'success' | 'error' | 'warn'; text: string };

function isTabKey(v: string | null): v is TabKey {
  return !!v && TABS.some((t) => t.key === v);
}

export default function CampaignWorkspacePage() {
  const params = useParams();
  const id = String(params?.id || '');
  return (
    <Suspense fallback={<p className="p-6 text-sm text-secondary-500">Loading…</p>}>
      <CampaignWorkspace key={id} id={id} />
    </Suspense>
  );
}

function CampaignWorkspace({ id }: { id: string }) {
  const router = useRouter();
  const searchParams = useSearchParams();
  const queryTab = searchParams.get('tab');

  const [campaign, setCampaign] = useState<Campaign | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [lists, setLists] = useState<MktList[]>([]);
  // ?list= comes from the lists page ("Write an email to these people").
  const [listUuid, setListUuid] = useState(searchParams.get('list') || '');
  const [tab, setTab] = useState<TabKey | null>(isTabKey(queryTab) ? queryTab : null);
  const [busy, setBusy] = useState<string | null>(null);
  const [flash, setFlash] = useState<Flash | null>(null);
  const [validation, setValidation] = useState<{ preview: AudiencePreview | null; warnings: string[] } | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const [dialog, setDialog] = useState<Dialog>(null);
  const [scheduleAt, setScheduleAt] = useState('');
  const [moreOpen, setMoreOpen] = useState(false);
  const testMode = useTestMode();
  const moreRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!moreOpen) return;
    const close = (e: MouseEvent) => {
      if (moreRef.current && !moreRef.current.contains(e.target as Node)) setMoreOpen(false);
    };
    document.addEventListener('mousedown', close);
    return () => document.removeEventListener('mousedown', close);
  }, [moreOpen]);
  const [rejectReason, setRejectReason] = useState('');
  const [approvalNotes, setApprovalNotes] = useState('');
  const [dupName, setDupName] = useState('');
  const [renaming, setRenaming] = useState(false);
  const [nameDraft, setNameDraft] = useState('');

  const loadCampaign = useCallback(async () => {
    const res = await marketingService.getCampaign(id);
    const c = normaliseCampaign(unwrap<Campaign>(res));
    setCampaign(c);
    return c;
  }, [id]);

  const load = useCallback(async () => {
    try {
      const [c, lRes] = await Promise.all([
        loadCampaign(),
        marketingService.listLists({ per_page: 100 }).catch(() => null),
      ]);
      const ls = lRes ? unwrapArray<MktList>(lRes) : [];
      setLists(ls);
      const current = ls.find((l) => l.id === c.list_id);
      // Came from a list's "Write an email to them": save that list on the email now.
      const wanted = searchParams.get('list');
      const fromLink = wanted ? ls.find((l) => l.uuid === wanted) : undefined;
      if (fromLink && fromLink.id !== c.list_id && EDITABLE_STATUSES.includes(c.status)) {
        marketingService
          .updateCampaign(id, { list_uuid: fromLink.uuid })
          .then((res) => setCampaign(normaliseCampaign(unwrap<Campaign>(res))))
          .catch(() => {
            /* still chosen on screen; saved on Check it / send */
          });
      }
      if (current) setListUuid((prev) => prev || current.uuid);
      setLoadError(null);
    } catch (e: unknown) {
      setLoadError(apiErrorMessage(e, 'Failed to load campaign'));
    }
  }, [loadCampaign, searchParams, id]);

  useEffect(() => {
    void load();
  }, [load]);

  const status = campaign?.status;

  // Live campaigns: refresh status + analytics every 15s.
  useEffect(() => {
    if (status !== 'sending') return;
    const t = window.setInterval(() => {
      loadCampaign()
        .then(() => setRefreshKey((k) => k + 1))
        .catch(() => {
          /* transient — next tick retries */
        });
    }, POLL_MS);
    return () => window.clearInterval(t);
  }, [status, loadCampaign]);

  const onSaved = useCallback((c: Campaign, message: string) => {
    setCampaign(normaliseCampaign(c));
    setFlash({ tone: message.includes('back to draft') ? 'warn' : 'success', text: message });
  }, []);

  /** Choosing who gets it saves straight away, so it's still chosen next time. */
  const chooseList = async (uuid: string) => {
    setListUuid(uuid);
    if (!uuid) return;
    try {
      const res = await marketingService.updateCampaign(id, { list_uuid: uuid });
      setCampaign(normaliseCampaign(unwrap<Campaign>(res)));
    } catch (e: unknown) {
      setFlash({ tone: 'error', text: apiErrorMessage(e, 'Could not save who gets this email') });
    }
  };

  const run = async (label: string, fn: () => Promise<unknown>, success: string) => {
    setBusy(label);
    setFlash(null);
    try {
      await fn();
      await loadCampaign();
      setRefreshKey((k) => k + 1);
      setFlash({ tone: 'success', text: success });
      return true;
    } catch (e: unknown) {
      const code = apiErrorCode(e);
      const msg = apiErrorMessage(e, `${label} failed`);
      setFlash({
        tone: 'error',
        text: code === 'not_editable' ? `${msg} (Refresh to see the latest status.)` : msg,
      });
      // The campaign may have moved on (e.g. finished sending) — resync.
      await loadCampaign().catch(() => undefined);
      return false;
    } finally {
      setBusy(null);
    }
  };

  const listBody = listUuid ? { list_uuid: listUuid } : {};

  const doValidate = () =>
    run(
      'Validate',
      async () => {
        const res = await marketingService.validateCampaign(id, listBody);
        const out = unwrap<{ preview?: AudiencePreview; warnings?: string[] }>(res);
        setValidation({ preview: out.preview ?? null, warnings: out.warnings ?? [] });
      },
      'All good — it’s ready. Press “Send now”, or “Schedule…” to pick a time.',
    );

  const doSendNow = async () => {
    const ok = await run(
      'Send',
      () => marketingService.scheduleCampaign(id, { ...listBody, send_now: true }),
      'Sending started. Performance updates every 15 seconds.',
    );
    setDialog(null);
    if (ok) setTab('performance');
  };

  const doSchedule = async () => {
    const when = new Date(scheduleAt);
    if (Number.isNaN(when.getTime())) {
      setFlash({ tone: 'error', text: 'Pick a valid date and time.' });
      return;
    }
    if (when.getTime() < Date.now()) {
      setFlash({ tone: 'error', text: 'Scheduled time is in the past — use Send now instead.' });
      return;
    }
    const ok = await run(
      'Schedule',
      () => marketingService.scheduleCampaign(id, { ...listBody, scheduled_at: when.toISOString() }),
      `Scheduled for ${fmtDateTime(when.toISOString())}.`,
    );
    if (ok) setDialog(null);
  };

  const doReject = async () => {
    const ok = await run(
      'Reject',
      () => marketingService.rejectCampaign(id, { reason: rejectReason.trim() || 'Needs changes' }),
      'Campaign rejected and returned to draft.',
    );
    if (ok) setDialog(null);
  };

  const doRequestApproval = async () => {
    const ok = await run(
      'Request approval',
      () => marketingService.requestApproval(id, { notes: approvalNotes.trim() || undefined }),
      'Approval requested.',
    );
    if (ok) setDialog(null);
  };

  const doDuplicate = async () => {
    setBusy('Duplicate');
    try {
      const res = await marketingService.duplicateCampaign(id, dupName.trim() ? { name: dupName.trim() } : {});
      const row = unwrap<Campaign>(res);
      setDialog(null);
      router.push(`/dashboard/opsapi-marketing/campaigns/${row.uuid}?tab=content`);
    } catch (e: unknown) {
      setFlash({ tone: 'error', text: apiErrorMessage(e, 'Duplicate failed') });
    } finally {
      setBusy(null);
    }
  };

  const doCancel = async () => {
    await run('Cancel', () => marketingService.cancelCampaign(id), 'Campaign cancelled. Queued messages were skipped.');
    setDialog(null);
  };

  const saveName = async () => {
    const name = nameDraft.trim();
    if (!campaign || !name || name === campaign.name) {
      setRenaming(false);
      return;
    }
    setBusy('Rename');
    try {
      const res = await marketingService.updateCampaign(id, { name });
      setCampaign(normaliseCampaign(unwrap<Campaign>(res)));
      setRenaming(false);
    } catch (e: unknown) {
      setFlash({ tone: 'error', text: apiErrorMessage(e, 'Rename failed') });
    } finally {
      setBusy(null);
    }
  };

  if (!campaign) {
    return (
      <div className="space-y-3 p-6">
        <Link
          href="/dashboard/opsapi-marketing/campaigns"
          className="inline-flex items-center gap-1 text-sm text-secondary-500 hover:underline"
        >
          <ArrowLeft className="h-4 w-4" aria-hidden="true" /> All campaigns
        </Link>
        {loadError ? <Notice tone="error">{loadError}</Notice> : <p className="text-sm text-secondary-500">Loading…</p>}
      </div>
    );
  }

  const s: CampaignStatus = campaign.status;
  const editable = EDITABLE_STATUSES.includes(s);
  const abEditable = AB_EDITABLE_STATUSES.includes(s);
  const defaultTab: TabKey = LIVE_STATUSES.includes(s) ? 'performance' : 'content';
  const activeTab: TabKey = tab ?? defaultTab;
  const isBusy = busy !== null;

  const hasContent =
    campaign.channel === 'email'
      ? !!(campaign.subject?.trim() && (campaign.body_html?.trim() || campaign.body_text?.trim()))
      : !!campaign.body_text?.trim();
  const hasAudience = !!listUuid || !!campaign.list_id;
  const steps: { key: TabKey; label: string; done: boolean; hint: string }[] = [
    { key: 'content', label: 'Content', done: hasContent, hint: hasContent ? 'Ready' : 'Add a subject and body' },
    { key: 'audience', label: 'Audience', done: hasAudience, hint: hasAudience ? 'List selected' : 'Pick a list' },
    {
      key: 'tracking',
      label: 'Tracking',
      done: true,
      hint: campaign.tracking && Object.keys(campaign.tracking).length > 0 ? 'Customised' : 'Defaults (all on)',
    },
    {
      key: 'audience',
      label: 'Check',
      done: s === 'validated',
      hint: s === 'validated' ? 'All good' : 'Press “Check it”',
    },
  ];

  const canSend = s === 'draft' || s === 'validated' || s === 'scheduled';

  return (
    <div className="space-y-5 p-6">
      <Link
        href="/dashboard/opsapi-marketing/campaigns"
        className="inline-flex items-center gap-1 text-sm text-secondary-500 hover:underline"
      >
        <ArrowLeft className="h-4 w-4" aria-hidden="true" /> All campaigns
      </Link>
      <div className="flex flex-wrap gap-2">
        <HelpLink topic="write-email">How do I write this email?</HelpLink>
        <HelpLink topic="send">How do I send it?</HelpLink>
      </div>

      {/* Header */}
      <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
        <div className="min-w-0 space-y-1">
          {renaming ? (
            <form
              className="flex items-center gap-2"
              onSubmit={(e) => {
                e.preventDefault();
                void saveName();
              }}
            >
              <label htmlFor="campaign-name" className="sr-only">
                Campaign name
              </label>
              <input
                id="campaign-name"
                className={`${INPUT_CLASS} w-full max-w-md text-lg font-semibold`}
                value={nameDraft}
                onChange={(e) => setNameDraft(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === 'Escape') setRenaming(false);
                }}
                maxLength={255}
                autoFocus
              />
              <Button type="submit" size="sm" isLoading={busy === 'Rename'} aria-label="Save name">
                <Check className="h-4 w-4" aria-hidden="true" />
              </Button>
              <Button
                type="button"
                size="sm"
                variant="ghost"
                onClick={() => setRenaming(false)}
                aria-label="Cancel rename"
              >
                <X className="h-4 w-4" aria-hidden="true" />
              </Button>
            </form>
          ) : (
            <div className="flex flex-wrap items-center gap-2">
              <h1 className="truncate text-2xl font-bold tracking-tight text-secondary-900">{campaign.name}</h1>
              {editable && (
                <button
                  type="button"
                  className="rounded p-1 text-secondary-500 hover:bg-secondary-100"
                  onClick={() => {
                    setNameDraft(campaign.name);
                    setRenaming(true);
                  }}
                  aria-label="Rename campaign"
                  title="Rename"
                >
                  <Pencil className="h-4 w-4" aria-hidden="true" />
                </button>
              )}
              <StatusBadge status={s} />
            </div>
          )}
          <p className="text-sm text-secondary-500">
            {campaign.channel.toUpperCase()}
            {campaign.message_type ? ` · ${campaign.message_type}` : ''}
            {s === 'scheduled' && campaign.scheduled_at ? ` · sends ${fmtDateTime(campaign.scheduled_at)}` : ''}
            {campaign.started_at ? ` · started ${fmtDateTime(campaign.started_at)}` : ''}
            {campaign.completed_at ? ` · completed ${fmtDateTime(campaign.completed_at)}` : ''}
            {campaign.max_deliveries ? ` · budget ${fmtInt(campaign.max_deliveries)}` : ''}
          </p>
        </div>

        <div className="flex flex-wrap gap-2" role="toolbar" aria-label="Campaign actions">
          {(s === 'draft' || s === 'validated') && (
            <Button
              size="sm"
              variant="outline"
              leftIcon={<CheckCircle className="h-4 w-4" />}
              isLoading={busy === 'Validate'}
              disabled={isBusy}
              onClick={() => void doValidate()}
            >
              {s === 'validated' ? 'Check again' : 'Check it'}
            </Button>
          )}
          {s === 'awaiting_approval' && (
            <>
              <Button
                size="sm"
                leftIcon={<ShieldCheck className="h-4 w-4" />}
                isLoading={busy === 'Approve'}
                disabled={isBusy}
                onClick={() =>
                  void run('Approve', () => marketingService.approveCampaign(id), 'Approved — ready to send.')
                }
              >
                Approve
              </Button>
              <Button
                size="sm"
                variant="outline"
                leftIcon={<ThumbsDown className="h-4 w-4" />}
                disabled={isBusy}
                onClick={() => {
                  setRejectReason('');
                  setDialog('reject');
                }}
              >
                Reject
              </Button>
            </>
          )}
          {canSend && (
            <>
              <Button
                size="sm"
                variant="outline"
                leftIcon={<Calendar className="h-4 w-4" />}
                disabled={isBusy}
                onClick={() => {
                  setScheduleAt(toLocalInput(s === 'scheduled' ? campaign.scheduled_at : null));
                  setDialog('schedule');
                }}
              >
                {s === 'scheduled' ? 'Reschedule…' : 'Schedule…'}
              </Button>
              <Button
                size="sm"
                leftIcon={<Send className="h-4 w-4" />}
                disabled={isBusy}
                onClick={() => setDialog('send')}
              >
                Send now
              </Button>
            </>
          )}
          {(s === 'sending' || s === 'scheduled') && (
            <Button
              size="sm"
              variant="outline"
              leftIcon={<Pause className="h-4 w-4" />}
              isLoading={busy === 'Pause'}
              disabled={isBusy}
              onClick={() =>
                void run('Pause', () => marketingService.pauseCampaign(id), 'Paused. Queued messages are held.')
              }
            >
              Pause
            </Button>
          )}
          {s === 'paused' && (
            <Button
              size="sm"
              leftIcon={<Play className="h-4 w-4" />}
              isLoading={busy === 'Resume'}
              disabled={isBusy}
              onClick={() => void run('Resume', () => marketingService.resumeCampaign(id), 'Resumed.')}
            >
              Resume
            </Button>
          )}
          <div className="relative" ref={moreRef}>
            <Button
              size="sm"
              variant="outline"
              rightIcon={<ChevronDown className="h-4 w-4" />}
              aria-haspopup="menu"
              aria-expanded={moreOpen}
              disabled={isBusy}
              onClick={() => setMoreOpen((o) => !o)}
            >
              More
            </Button>
            {moreOpen && (
              <div
                role="menu"
                className="absolute right-0 z-20 mt-1 w-56 overflow-hidden rounded-xl border border-secondary-200 bg-surface py-1 shadow-lg"
                onKeyDown={(e) => e.key === 'Escape' && setMoreOpen(false)}
              >
                {(s === 'draft' || s === 'validated') && (
                  <button
                    type="button"
                    role="menuitem"
                    className="flex w-full items-center gap-2 px-3 py-2 text-left text-sm hover:bg-secondary-50 dark:hover:bg-secondary-800"
                    onClick={() => {
                      setMoreOpen(false);
                      setApprovalNotes('');
                      setDialog('approval');
                    }}
                  >
                    <Shield className="h-4 w-4" aria-hidden="true" /> Ask someone to approve it
                  </button>
                )}
                <button
                  type="button"
                  role="menuitem"
                  className="flex w-full items-center gap-2 px-3 py-2 text-left text-sm hover:bg-secondary-50 dark:hover:bg-secondary-800"
                  onClick={() => {
                    setMoreOpen(false);
                    setDupName(`${campaign.name} (copy)`);
                    setDialog('duplicate');
                  }}
                >
                  <Copy className="h-4 w-4" aria-hidden="true" /> Make a copy
                </button>
                {s !== 'completed' && s !== 'cancelled' && (
                  <button
                    type="button"
                    role="menuitem"
                    className="flex w-full items-center gap-2 px-3 py-2 text-left text-sm text-error-600 hover:bg-error-500/10"
                    onClick={() => {
                      setMoreOpen(false);
                      setDialog('cancel');
                    }}
                  >
                    <XCircle className="h-4 w-4" aria-hidden="true" /> Cancel this email
                  </button>
                )}
              </div>
            )}
          </div>
        </div>
      </div>

      {/* Status context */}
      {s === 'draft' && campaign.rejected_reason && (
        <Notice tone="warn">
          <span className="font-medium">Rejected:</span> {campaign.rejected_reason}
        </Notice>
      )}
      {s === 'awaiting_approval' && (
        <Notice tone="info">
          Waiting for approval.{campaign.approval_notes ? ` Notes: ${campaign.approval_notes}` : ''}
        </Notice>
      )}
      {s === 'failed' && <Notice tone="error">This campaign failed. Duplicate it to fix and resend.</Notice>}
      <TestModeBanner on={testMode} />
      {flash && (
        <div className="flex items-start gap-2">
          <div className="flex-1">
            <Notice tone={flash.tone}>{flash.text}</Notice>
          </div>
          <button
            type="button"
            className="mt-1.5 rounded p-1 text-secondary-500 hover:bg-secondary-100"
            onClick={() => setFlash(null)}
            aria-label="Dismiss message"
          >
            <X className="h-4 w-4" aria-hidden="true" />
          </button>
        </div>
      )}
      {validation && validation.warnings.length > 0 && (
        <Notice tone="warn">
          <span className="font-medium">Validation warnings:</span>{' '}
          {validation.warnings.map((w) => w.replace(/_/g, ' ')).join(', ')}
        </Notice>
      )}

      {/* Draft checklist */}
      {(s === 'draft' || s === 'validated') && (
        <nav aria-label="Campaign setup steps">
          <ol className="grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
            {steps.map((st, i) => (
              <li key={st.label}>
                <button
                  type="button"
                  onClick={() => setTab(st.key)}
                  className="flex w-full items-center gap-3 rounded-lg border border-secondary-200 p-3 text-left hover:bg-secondary-100/60"
                >
                  <span
                    className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-xs font-semibold ${
                      st.done
                        ? 'bg-green-600 text-white dark:bg-green-500'
                        : 'border border-secondary-200 text-secondary-500'
                    }`}
                    aria-hidden="true"
                  >
                    {st.done ? <Check className="h-3.5 w-3.5" /> : i + 1}
                  </span>
                  <span className="min-w-0">
                    <span className="block text-sm font-medium">
                      {st.label}
                      <span className="sr-only">{st.done ? ' (done)' : ' (to do)'}</span>
                    </span>
                    <span className="block truncate text-xs text-secondary-500">{st.hint}</span>
                  </span>
                </button>
              </li>
            ))}
          </ol>
        </nav>
      )}

      {/* Tabs */}
      <div
        role="tablist"
        aria-label="Campaign workspace"
        className="flex gap-1 overflow-x-auto border-b border-secondary-200"
      >
        {TABS.map((t) => (
          <button
            key={t.key}
            type="button"
            role="tab"
            id={`tab-${t.key}`}
            aria-selected={activeTab === t.key}
            aria-controls={`panel-${t.key}`}
            onClick={() => setTab(t.key)}
            className={`-mb-px inline-flex items-center gap-1.5 whitespace-nowrap border-b-2 px-3 py-2 text-sm ${
              activeTab === t.key
                ? 'border-primary-500 font-medium text-secondary-900'
                : 'border-transparent text-secondary-500 hover:text-secondary-900'
            }`}
          >
            {t.icon}
            {t.label}
            {t.key === 'ab' && campaign.ab_config?.enabled && (
              <span className="rounded bg-secondary-100 px-1 text-[10px] font-medium">ON</span>
            )}
          </button>
        ))}
      </div>

      {activeTab === 'performance' && (
        <div role="tabpanel" id="panel-performance" aria-labelledby="tab-performance">
          {s === 'draft' || s === 'validated' || s === 'awaiting_approval' ? (
            <p className="text-sm text-secondary-500">
              No sends yet. Performance appears here once the campaign starts sending.
            </p>
          ) : (
            <PerformanceTab campaignUuid={campaign.uuid} refreshKey={refreshKey} live={s === 'sending'} />
          )}
        </div>
      )}
      {/* Editing tabs stay mounted so unsaved edits survive switching tabs. */}
      <div role="tabpanel" id="panel-content" aria-labelledby="tab-content" hidden={activeTab !== 'content'}>
        <ContentTab campaign={campaign} editable={editable} onSaved={onSaved} />
      </div>
      <div role="tabpanel" id="panel-audience" aria-labelledby="tab-audience" hidden={activeTab !== 'audience'}>
        <AudienceTab
          campaign={campaign}
          lists={lists}
          listUuid={listUuid}
          onListChange={(uuid) => void chooseList(uuid)}
          editable={editable}
          onSaved={onSaved}
          initialPreview={validation?.preview ?? null}
        />
      </div>
      <div role="tabpanel" id="panel-tracking" aria-labelledby="tab-tracking" hidden={activeTab !== 'tracking'}>
        <TrackingTab campaign={campaign} editable={editable} onSaved={onSaved} />
      </div>
      <div role="tabpanel" id="panel-ab" aria-labelledby="tab-ab" hidden={activeTab !== 'ab'}>
        <AbTestTab campaign={campaign} editable={abEditable} onSaved={onSaved} />
      </div>

      {/* Dialogs */}
      <Modal
        isOpen={dialog === 'schedule'}
        onClose={() => setDialog(null)}
        title={s === 'scheduled' ? 'Reschedule campaign' : 'Schedule campaign'}
        description={
          s === 'draft' ? 'The campaign is validated first; sending starts automatically at this time.' : undefined
        }
        footer={
          <>
            <Button variant="ghost" onClick={() => setDialog(null)}>
              Close
            </Button>
            <Button
              leftIcon={<Calendar className="h-4 w-4" />}
              onClick={() => void doSchedule()}
              isLoading={busy === 'Schedule'}
              disabled={!scheduleAt}
            >
              Schedule
            </Button>
          </>
        }
      >
        <label className="block text-sm">
          <span className="font-medium">Send at (your local time)</span>
          <input
            type="datetime-local"
            className={`${INPUT_CLASS} mt-1 block w-full`}
            value={scheduleAt}
            onChange={(e) => setScheduleAt(e.target.value)}
          />
        </label>
        {!hasAudience && (
          <p className="mt-2 text-xs text-amber-700 dark:text-amber-300">
            No audience list selected — choose one on the Audience tab first.
          </p>
        )}
      </Modal>

      <Modal
        isOpen={dialog === 'reject'}
        onClose={() => setDialog(null)}
        title="Reject campaign"
        description="The campaign returns to draft with your reason shown to its author."
        footer={
          <>
            <Button variant="ghost" onClick={() => setDialog(null)}>
              Close
            </Button>
            <Button variant="danger" onClick={() => void doReject()} isLoading={busy === 'Reject'}>
              Reject
            </Button>
          </>
        }
      >
        <label className="block text-sm">
          <span className="font-medium">Reason</span>
          <textarea
            className={`${INPUT_CLASS} mt-1 block h-24 w-full`}
            value={rejectReason}
            onChange={(e) => setRejectReason(e.target.value)}
            placeholder="What needs to change?"
          />
        </label>
      </Modal>

      <Modal
        isOpen={dialog === 'approval'}
        onClose={() => setDialog(null)}
        title="Request approval"
        description="An approver must approve before this campaign can be sent."
        footer={
          <>
            <Button variant="ghost" onClick={() => setDialog(null)}>
              Close
            </Button>
            <Button
              leftIcon={<Shield className="h-4 w-4" />}
              onClick={() => void doRequestApproval()}
              isLoading={busy === 'Request approval'}
            >
              Request approval
            </Button>
          </>
        }
      >
        <label className="block text-sm">
          <span className="font-medium">Notes for the approver (optional)</span>
          <textarea
            className={`${INPUT_CLASS} mt-1 block h-24 w-full`}
            value={approvalNotes}
            onChange={(e) => setApprovalNotes(e.target.value)}
          />
        </label>
      </Modal>

      <Modal
        isOpen={dialog === 'duplicate'}
        onClose={() => setDialog(null)}
        title="Duplicate campaign"
        description="Creates a new draft with the same content, list, tracking and A/B settings."
        footer={
          <>
            <Button variant="ghost" onClick={() => setDialog(null)}>
              Close
            </Button>
            <Button
              leftIcon={<Copy className="h-4 w-4" />}
              onClick={() => void doDuplicate()}
              isLoading={busy === 'Duplicate'}
            >
              Duplicate
            </Button>
          </>
        }
      >
        <label className="block text-sm">
          <span className="font-medium">New campaign name</span>
          <input
            className={`${INPUT_CLASS} mt-1 block w-full`}
            value={dupName}
            onChange={(e) => setDupName(e.target.value)}
            maxLength={255}
          />
        </label>
      </Modal>

      <ConfirmDialog
        isOpen={dialog === 'send'}
        onClose={() => setDialog(null)}
        onConfirm={() => void doSendNow()}
        title="Send now?"
        message={
          (testMode ? 'Test mode is on, so nobody will really receive it — switch test mode off to send for real. ' : '') +
          (validation?.preview
            ? `This sends to about ${fmtInt(validation.preview.eligible)} eligible contacts immediately. Consent and suppressions are re-checked per contact.`
            : 'This validates the campaign (if needed) and starts sending to every eligible contact immediately.')
        }
        confirmText="Send now"
        variant="warning"
        isLoading={busy === 'Send'}
      />

      <ConfirmDialog
        isOpen={dialog === 'cancel'}
        onClose={() => setDialog(null)}
        onConfirm={() => void doCancel()}
        title="Cancel campaign?"
        message="Cancelling is permanent. Messages not yet sent are skipped. Already-sent messages are not recalled."
        confirmText="Cancel campaign"
        cancelText="Keep campaign"
        variant="danger"
        isLoading={busy === 'Cancel'}
      />
    </div>
  );
}

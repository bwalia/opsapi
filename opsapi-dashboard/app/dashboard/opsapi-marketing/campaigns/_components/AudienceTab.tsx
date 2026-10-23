'use client';

import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import { Users, Eye, Send, Save } from 'lucide-react';
import { useAuthStore } from '@/store/auth.store';
import { Button } from '@/components/ui';
import { marketingService } from '@/services/opsapi-marketing.service';
import {
  type AudiencePreview,
  type Campaign,
  type MktList,
  INPUT_CLASS,
  KpiTile,
  Notice,
  apiErrorMessage,
  fmtInt,
  unwrap,
} from './shared';

const REASONS: { key: keyof AudiencePreview | 'other'; label: string; explain: string }[] = [
  {
    key: 'suppressed',
    label: 'Unsubscribed or blocked',
    explain: 'On a global or channel suppression list (hard bounce, complaint, manual block). Suppressions always win.',
  },
  {
    key: 'no_consent',
    label: 'No permission',
    explain:
      'They were added without saying they may get marketing (add them again and answer “Who are these people?”).',
  },
  {
    key: 'missing_address',
    label: 'No email address',
    explain: 'No usable email address (or phone number for SMS) on the CRM contact.',
  },
  {
    key: 'other',
    label: 'Other',
    explain: 'Deleted contacts, or people who already got several emails recently.',
  },
];

export default function AudienceTab({
  campaign,
  lists,
  listUuid,
  onListChange,
  editable,
  onSaved,
  initialPreview,
}: {
  campaign: Campaign;
  lists: MktList[];
  listUuid: string;
  onListChange: (uuid: string) => void;
  editable: boolean;
  onSaved: (c: Campaign, message: string) => void;
  /** Preview returned by the last Validate call, if any. */
  initialPreview: AudiencePreview | null;
}) {
  const [preview, setPreview] = useState<AudiencePreview | null>(initialPreview);
  const [previewFor, setPreviewFor] = useState(listUuid);
  const [previewing, setPreviewing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [budget, setBudget] = useState(campaign.max_deliveries ? String(campaign.max_deliveries) : '');
  const [savingBudget, setSavingBudget] = useState(false);
  const [batchSize, setBatchSize] = useState(campaign.batch_size ? String(campaign.batch_size) : '');
  const [batchEvery, setBatchEvery] = useState(
    campaign.batch_interval_minutes ? String(campaign.batch_interval_minutes) : '60',
  );
  const [savingBatches, setSavingBatches] = useState(false);
  const myEmail = useAuthStore((st) => st.user?.email ?? '');
  const [testEmail, setTestEmail] = useState(myEmail);
  const [dryRun, setDryRun] = useState(false);
  const [testing, setTesting] = useState(false);
  const [testResult, setTestResult] = useState<string | null>(null);

  // A newer validate preview from the parent replaces ours.
  const [seenInitial, setSeenInitial] = useState(initialPreview);
  if (initialPreview !== seenInitial) {
    setSeenInitial(initialPreview);
    setPreview(initialPreview);
    setPreviewFor(listUuid);
  }
  // Counts belong to one list; drop them when the selection changes.
  if (previewFor !== listUuid && preview) {
    setPreview(null);
  }

  const selected = lists.find((l) => l.uuid === listUuid);

  // Test mode (dry run) sends nothing, test emails included: say so next to "Send test".
  useEffect(() => {
    let cancelled = false;
    marketingService
      .sendingInfo()
      .then((res) => {
        if (!cancelled) setDryRun(!!(res.data?.data ?? res.data)?.dry_run);
      })
      .catch(() => {
        /* no settings access: no warning */
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const runPreview = async () => {
    setPreviewing(true);
    setError(null);
    try {
      const res = await marketingService.audiencePreview(campaign.uuid, listUuid ? { list_uuid: listUuid } : {});
      setPreview(unwrap<AudiencePreview>(res));
      setPreviewFor(listUuid);
    } catch (e: unknown) {
      setError(apiErrorMessage(e, 'Could not preview audience'));
    } finally {
      setPreviewing(false);
    }
  };

  const saveBudget = async () => {
    const n = budget.trim() === '' ? null : Number(budget);
    if (n !== null && (!Number.isInteger(n) || n < 1)) {
      setError('Max deliveries must be a whole number of at least 1, or empty for no limit.');
      return;
    }
    setSavingBudget(true);
    setError(null);
    try {
      const res = await marketingService.updateCampaign(campaign.uuid, { max_deliveries: n });
      onSaved(unwrap<Campaign>(res), n ? `Delivery budget set to ${fmtInt(n)}.` : 'Delivery budget removed.');
    } catch (e: unknown) {
      setError(apiErrorMessage(e, 'Could not save budget'));
    } finally {
      setSavingBudget(false);
    }
  };

  const saveBatches = async () => {
    const size = batchSize.trim() === '' ? null : Number(batchSize);
    const every = Number(batchEvery);
    if (size !== null && (!Number.isInteger(size) || size < 1)) {
      setError('Batch size must be a whole number of at least 1, or empty to send all at once.');
      return;
    }
    if (size !== null && (!Number.isInteger(every) || every < 1)) {
      setError('Minutes between batches must be a whole number of at least 1.');
      return;
    }
    setSavingBatches(true);
    setError(null);
    try {
      const res = await marketingService.updateCampaign(campaign.uuid, {
        batch_size: size,
        batch_interval_minutes: size === null ? null : every,
      });
      onSaved(
        unwrap<Campaign>(res),
        size ? `Sends ${fmtInt(size)} at a time, every ${every} minutes.` : 'Batches off: sends as fast as allowed.',
      );
    } catch (e: unknown) {
      setError(apiErrorMessage(e, 'Could not save batches'));
    } finally {
      setSavingBatches(false);
    }
  };

  const testSend = async () => {
    const to = testEmail.trim();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(to)) {
      setError('Type the email address to send the test to, e.g. you@yourbusiness.co.uk');
      return;
    }
    setTesting(true);
    setError(null);
    setTestResult(null);
    try {
      const res = await marketingService.testSend(campaign.uuid, { email: to });
      const row = unwrap<{ state?: string; reason?: string | null }>(res);
      if (row?.reason === 'dry_run') {
        setTestResult(`Test mode is on, so nothing was really sent to ${to}. Switch test mode off to receive it.`);
      } else if (row?.state === 'accepted' || row?.state === 'delivered') {
        setTestResult(`Sent to ${to}. Check that inbox (and the spam folder) in a minute.`);
      } else if (row?.state === 'skipped' && String(row.reason || '').startsWith('suppressed')) {
        setError(`${to} unsubscribed before, so they can’t be emailed — not even a test.`);
      } else {
        setError(
          `The test didn’t go out${row?.reason ? ` (${row.reason})` : ''}. Check your email settings and try again.`,
        );
      }
    } catch (e: unknown) {
      setError(apiErrorMessage(e, 'Test send failed'));
    } finally {
      setTesting(false);
    }
  };

  const other = preview ? (preview.other ?? preview.other_excluded ?? 0) : 0;
  const budgetDirty = budget !== (campaign.max_deliveries ? String(campaign.max_deliveries) : '');
  const batchesDirty =
    batchSize !== (campaign.batch_size ? String(campaign.batch_size) : '') ||
    (batchSize !== '' && batchEvery !== String(campaign.batch_interval_minutes ?? ''));

  return (
    <div className="space-y-4">
      {error && <Notice tone="error">{error}</Notice>}

      <section aria-labelledby="aud-list" className="space-y-3 rounded-lg border border-secondary-200 p-4">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <h2 id="aud-list" className="flex items-center gap-1.5 text-sm font-medium">
            <Users className="h-4 w-4 text-secondary-500" aria-hidden="true" /> Who gets this email
          </h2>
          <Link href="/dashboard/opsapi-marketing/lists" className="text-xs text-secondary-500 underline">
            Manage lists
          </Link>
        </div>
        <div className="flex flex-wrap items-end gap-2">
          <label className="block min-w-64 flex-1 text-sm">
            <span className="sr-only">List</span>
            <select
              className={`${INPUT_CLASS} w-full`}
              value={listUuid}
              onChange={(e) => onListChange(e.target.value)}
              disabled={!editable && campaign.status !== 'scheduled'}
            >
              <option value="">— Choose a list —</option>
              {lists.map((l) => (
                <option key={l.uuid} value={l.uuid}>
                  {l.name}
                  {l.list_type === 'dynamic' ? ' (smart list)' : ''}
                  {l.channel && l.channel !== campaign.channel ? ` · ${l.channel}` : ''}
                </option>
              ))}
            </select>
          </label>
          <Button
            variant="outline"
            leftIcon={<Eye className="h-4 w-4" />}
            onClick={() => void runPreview()}
            isLoading={previewing}
            disabled={!listUuid && !campaign.list_id}
          >
            Who will get it?
          </Button>
        </div>
        {lists.length === 0 && (
          <p className="text-sm text-secondary-500">
            No lists yet.{' '}
            <Link href="/dashboard/opsapi-marketing/lists" className="underline">
              Create one
            </Link>{' '}
            from your CRM contacts.
          </p>
        )}
        {selected?.list_type === 'dynamic' && (
          <p className="text-xs text-amber-700 dark:text-amber-300">
            Smart list — it fills itself from its rules just before sending.
          </p>
        )}
        {selected && selected.channel && selected.channel !== campaign.channel && (
          <p className="text-xs text-amber-700 dark:text-amber-300">
            This list is for {selected.channel}; the campaign sends via {campaign.channel}.
          </p>
        )}
        <p className="text-xs text-secondary-500">
          If you change the list after pressing “Check it”, press it again before sending.
        </p>

        {preview && (
          <div className="space-y-3 pt-2">
            <div className="grid grid-cols-2 gap-3 md:grid-cols-3 lg:grid-cols-6">
              <KpiTile label="In the list" value={fmtInt(preview.audience_total)} />
              <KpiTile label="Will get it" value={fmtInt(preview.eligible)} tone="good" />
              <KpiTile label="Unsubscribed" value={fmtInt(preview.suppressed)} />
              <KpiTile label="No permission" value={fmtInt(preview.no_consent)} />
              <KpiTile label="No email address" value={fmtInt(preview.missing_address)} />
              <KpiTile label="Other" value={fmtInt(other)} />
            </div>
            {preview.exact === false && (
              <p className="text-xs text-secondary-500">
                Large list — counts are extrapolated from a sample of {fmtInt(preview.sampled)} contacts. Eligibility is
                re-checked per contact at send time.
              </p>
            )}
            <dl className="grid gap-2 text-xs sm:grid-cols-2">
              {REASONS.map((r) => (
                <div key={r.key}>
                  <dt className="font-medium">{r.label}</dt>
                  <dd className="text-secondary-500">{r.explain}</dd>
                </div>
              ))}
            </dl>
          </div>
        )}
      </section>

      <section aria-labelledby="aud-test" className="space-y-3 rounded-lg border border-secondary-200 p-4">
        <h2 id="aud-test" className="flex items-center gap-1.5 text-sm font-medium">
          <Send className="h-4 w-4 text-secondary-500" aria-hidden="true" /> Send yourself a test
        </h2>
        <p className="text-xs text-secondary-500">
          See exactly what people will get. It sends the <strong>saved</strong> email to one address — yours, or
          anyone’s — and doesn’t add them to the list.
        </p>
        {dryRun && (
          <Notice tone="warn">
            Test mode is on, so nothing is really sent — not even this test. Switch it off in{' '}
            <Link href="/dashboard/namespace/plugins#plugin-opsapi_marketing" className="underline">
              Marketing Cloud settings
            </Link>{' '}
            when you’re ready.
          </Notice>
        )}
        <form
          className="flex flex-col gap-2 sm:flex-row sm:items-end"
          onSubmit={(e) => {
            e.preventDefault();
            void testSend();
          }}
        >
          <label className="block min-w-0 flex-1 text-sm">
            <span className="text-xs text-secondary-500">Send the test to</span>
            <input
              type="email"
              className={`${INPUT_CLASS} mt-1 w-full`}
              value={testEmail}
              onChange={(e) => setTestEmail(e.target.value)}
              placeholder="you@yourbusiness.co.uk"
              autoComplete="email"
            />
          </label>
          <Button
            type="submit"
            leftIcon={<Send className="h-4 w-4" />}
            isLoading={testing}
            disabled={!testEmail.trim()}
          >
            Send test
          </Button>
        </form>
        {testResult && <Notice tone="success">{testResult}</Notice>}
      </section>

      <details className="rounded-lg border border-secondary-200 p-4">
        <summary className="cursor-pointer select-none text-sm font-medium">
          More options{' '}
          <span className="font-normal text-secondary-500">(optional — send in batches, limit how many)</span>
        </summary>
        <div className="mt-3">
          <section aria-labelledby="aud-budget" className="space-y-3">
            <h2 id="aud-budget" className="text-sm font-medium">
              Send to at most…
            </h2>
            <p className="text-xs text-secondary-500">
              Stop after this many emails. Leave empty to send to everyone on the list.
            </p>
            <div className="flex items-end gap-2">
              <label className="block text-sm">
                <span className="sr-only">Max deliveries</span>
                <input
                  type="number"
                  min={1}
                  step={1}
                  inputMode="numeric"
                  className={`${INPUT_CLASS} w-40`}
                  value={budget}
                  onChange={(e) => setBudget(e.target.value)}
                  placeholder="No limit"
                  disabled={!editable}
                  aria-label="Max deliveries"
                />
              </label>
              <Button
                size="sm"
                variant="outline"
                leftIcon={<Save className="h-4 w-4" />}
                onClick={() => void saveBudget()}
                isLoading={savingBudget}
                disabled={!editable || !budgetDirty}
              >
                Save
              </Button>
            </div>

            <h2 id="aud-batches" className="pt-2 text-sm font-medium">
              Send in batches
            </h2>
            <p className="text-xs text-secondary-500">
              For large lists: send this many at once, then the next batch after a pause. Leave empty to send everything
              as fast as the workspace rate allows.
            </p>
            <div className="flex flex-wrap items-end gap-2" aria-labelledby="aud-batches">
              <label className="block text-sm">
                <span className="text-xs text-secondary-500">Per batch</span>
                <input
                  type="number"
                  min={1}
                  step={1}
                  inputMode="numeric"
                  className={`${INPUT_CLASS} w-32`}
                  value={batchSize}
                  onChange={(e) => setBatchSize(e.target.value)}
                  placeholder="All at once"
                  disabled={!editable}
                  aria-label="Emails per batch"
                />
              </label>
              <label className="block text-sm">
                <span className="text-xs text-secondary-500">Minutes between batches</span>
                <input
                  type="number"
                  min={1}
                  step={1}
                  inputMode="numeric"
                  className={`${INPUT_CLASS} w-32`}
                  value={batchEvery}
                  onChange={(e) => setBatchEvery(e.target.value)}
                  disabled={!editable || batchSize.trim() === ''}
                  aria-label="Minutes between batches"
                />
              </label>
              <Button
                size="sm"
                variant="outline"
                leftIcon={<Save className="h-4 w-4" />}
                onClick={() => void saveBatches()}
                isLoading={savingBatches}
                disabled={!editable || !batchesDirty}
              >
                Save
              </Button>
            </div>
            {preview && Number(batchSize) > 0 && preview.eligible > Number(batchSize) && (
              <p className="text-xs text-secondary-500">
                About {fmtInt(Math.ceil(preview.eligible / Number(batchSize)))} batches; the last starts roughly{' '}
                {fmtInt(Math.ceil((Math.ceil(preview.eligible / Number(batchSize)) - 1) * Number(batchEvery)))} minutes
                after sending begins.
              </p>
            )}
          </section>
        </div>
      </details>
    </div>
  );
}

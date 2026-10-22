'use client';

import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import { Users, Eye, Send, Save } from 'lucide-react';
import { Button } from '@/components/ui';
import { marketingService } from '@/services/opsapi-marketing.service';
import {
  type AudiencePreview,
  type Campaign,
  type ListMember,
  type MktList,
  INPUT_CLASS,
  KpiTile,
  Notice,
  apiErrorMessage,
  contactLabel,
  fmtInt,
  unwrap,
  unwrapArray,
} from './shared';

const REASONS: { key: keyof AudiencePreview | 'other'; label: string; explain: string }[] = [
  {
    key: 'suppressed',
    label: 'Suppressed',
    explain: 'On a global or channel suppression list (hard bounce, complaint, manual block). Suppressions always win.',
  },
  {
    key: 'no_consent',
    label: 'No consent',
    explain: 'No marketing opt-in recorded for this channel, or the contact has unsubscribed.',
  },
  {
    key: 'missing_address',
    label: 'Missing / invalid address',
    explain: 'No usable email address (or phone number for SMS) on the CRM contact.',
  },
  {
    key: 'other',
    label: 'Other',
    explain: 'Deleted or inactive contacts, frequency caps and other policy checks.',
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
  const [members, setMembers] = useState<ListMember[]>([]);
  const [membersFor, setMembersFor] = useState('');
  const [contactUuid, setContactUuid] = useState('');
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

  useEffect(() => {
    if (!listUuid) return;
    let cancelled = false;
    marketingService
      .listMembers(listUuid)
      .then((res) => {
        if (cancelled) return;
        setMembers(unwrapArray<ListMember>(res));
        setMembersFor(listUuid);
      })
      .catch(() => {
        if (cancelled) return;
        setMembers([]);
        setMembersFor(listUuid);
      });
    return () => {
      cancelled = true;
    };
  }, [listUuid]);

  const visibleMembers = membersFor === listUuid ? members : [];

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

  const testSend = async () => {
    if (!contactUuid) return;
    setTesting(true);
    setError(null);
    setTestResult(null);
    try {
      const res = await marketingService.testSend(campaign.uuid, { contact_uuid: contactUuid });
      const row = unwrap<{ state?: string; reason?: string | null }>(res);
      const who = visibleMembers.find((m) => m.contact_uuid === contactUuid);
      setTestResult(
        `Test sent to ${who ? contactLabel(who) : 'contact'}${row?.state ? ` — delivery ${row.state}` : ''}${
          row?.reason ? ` (${row.reason})` : ''
        }.`,
      );
    } catch (e: unknown) {
      setError(apiErrorMessage(e, 'Test send failed'));
    } finally {
      setTesting(false);
    }
  };

  const other = preview ? (preview.other ?? preview.other_excluded ?? 0) : 0;
  const budgetDirty = budget !== (campaign.max_deliveries ? String(campaign.max_deliveries) : '');

  return (
    <div className="space-y-4">
      {error && <Notice tone="error">{error}</Notice>}

      <section aria-labelledby="aud-list" className="space-y-3 rounded-lg border border-secondary-200 p-4">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <h2 id="aud-list" className="flex items-center gap-1.5 text-sm font-medium">
            <Users className="h-4 w-4 text-secondary-500" aria-hidden="true" /> Audience list
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
              <option value="">— Select a list —</option>
              {lists.map((l) => (
                <option key={l.uuid} value={l.uuid}>
                  {l.name} · {l.list_type || 'static'}
                  {l.channel ? ` · ${l.channel}` : ''}
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
            Preview eligibility
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
            Dynamic list — membership is re-synced from its segment rule on preview, validate and send.
          </p>
        )}
        {selected && selected.channel && selected.channel !== campaign.channel && (
          <p className="text-xs text-amber-700 dark:text-amber-300">
            This list is for {selected.channel}; the campaign sends via {campaign.channel}.
          </p>
        )}
        <p className="text-xs text-secondary-500">
          The selected list is attached to the campaign when you validate or send. Choosing a different list after
          validating means validating (and approval) again.
        </p>

        {preview && (
          <div className="space-y-3 pt-2">
            <div className="grid grid-cols-2 gap-3 md:grid-cols-3 lg:grid-cols-6">
              <KpiTile label="In list" value={fmtInt(preview.audience_total)} />
              <KpiTile label="Eligible" value={fmtInt(preview.eligible)} tone="good" />
              <KpiTile label="Suppressed" value={fmtInt(preview.suppressed)} />
              <KpiTile label="No consent" value={fmtInt(preview.no_consent)} />
              <KpiTile label="Missing address" value={fmtInt(preview.missing_address)} />
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

      <div className="grid gap-4 md:grid-cols-2">
        <section aria-labelledby="aud-budget" className="space-y-3 rounded-lg border border-secondary-200 p-4">
          <h2 id="aud-budget" className="text-sm font-medium">
            Delivery budget
          </h2>
          <p className="text-xs text-secondary-500">
            Cap the number of messages this campaign may send. Leave empty for no limit.
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
        </section>

        <section aria-labelledby="aud-test" className="space-y-3 rounded-lg border border-secondary-200 p-4">
          <h2 id="aud-test" className="text-sm font-medium">
            Send a test
          </h2>
          <p className="text-xs text-secondary-500">
            Sends the <strong>saved</strong> content to one contact from the selected list, bypassing quiet hours.
            Consent and suppression still apply.
          </p>
          <div className="flex flex-wrap items-end gap-2">
            <label className="block min-w-56 flex-1 text-sm">
              <span className="sr-only">Test recipient</span>
              <select
                className={`${INPUT_CLASS} w-full`}
                value={contactUuid}
                onChange={(e) => setContactUuid(e.target.value)}
                disabled={!listUuid || visibleMembers.length === 0}
                aria-label="Test recipient"
              >
                <option value="">
                  {!listUuid
                    ? 'Select a list first'
                    : visibleMembers.length === 0
                      ? 'No members in this list'
                      : '— Choose a contact —'}
                </option>
                {visibleMembers.map((m) => (
                  <option key={m.contact_uuid} value={m.contact_uuid}>
                    {contactLabel(m)}
                  </option>
                ))}
              </select>
            </label>
            <Button
              size="sm"
              leftIcon={<Send className="h-4 w-4" />}
              onClick={() => void testSend()}
              isLoading={testing}
              disabled={!contactUuid}
            >
              Send test
            </Button>
          </div>
          {testResult && <Notice tone="success">{testResult}</Notice>}
        </section>
      </div>
    </div>
  );
}

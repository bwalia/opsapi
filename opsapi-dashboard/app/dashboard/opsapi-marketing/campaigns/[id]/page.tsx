'use client';

import React, { useCallback, useEffect, useState } from 'react';
import { useParams } from 'next/navigation';
import Link from 'next/link';
import { isAxiosError } from 'axios';
import { Send, CheckCircle, Pause, Play, XCircle, Copy, Shield } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button } from '@/components/ui';
import { marketingService } from '@/services/opsapi-marketing.service';

type Campaign = {
  uuid: string;
  name: string;
  channel: string;
  status: string;
  subject?: string;
  message_type?: string;
  approval_required?: boolean;
  max_deliveries?: number;
  scheduled_at?: string;
  list_id?: number | null;
  ab_config?: { enabled?: boolean; variants?: { key: string }[] };
};

type Preview = {
  audience_total: number;
  eligible: number;
  suppressed: number;
  no_consent: number;
  missing_address: number;
  other_excluded: number;
  exact?: boolean;
};

type Stats = {
  total?: number;
  by_state?: Record<string, number>;
  by_variant?: Record<string, Record<string, number>>;
  opened_estimated?: number;
  clicked?: number;
  accepted?: number;
  delivered?: number;
  bounced?: number;
  failed?: number;
  skipped?: number;
  queued?: number;
};

type ListRow = { uuid: string; name: string; list_type?: string };

function apiErrorMessage(e: unknown, fallback: string): string {
  if (isAxiosError(e)) {
    const data = e.response?.data as { error?: string; message?: string; details?: { code?: string } } | undefined;
    if (data?.error) return String(data.error);
    if (data?.message) return String(data.message);
    if (e.message) return e.message;
  }
  if (e instanceof Error) return e.message;
  return fallback;
}

export default function CampaignDetailPage() {
  const params = useParams();
  const id = String(params?.id || '');
  const [campaign, setCampaign] = useState<Campaign | null>(null);
  const [preview, setPreview] = useState<Preview | null>(null);
  const [stats, setStats] = useState<Stats | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [lists, setLists] = useState<ListRow[]>([]);
  const [listUuid, setListUuid] = useState('');

  const load = useCallback(async () => {
    if (!id) return;
    setError(null);
    try {
      const [cRes, sRes, aRes, lRes] = await Promise.all([
        marketingService.getCampaign(id),
        marketingService.campaignStats(id).catch(() => null),
        marketingService.campaignAnalytics(id).catch(() => null),
        marketingService.listLists({ per_page: 50 }),
      ]);
      const c = (cRes.data?.data ?? cRes.data) as Campaign;
      setCampaign(c);
      if (sRes) setStats((sRes.data?.data ?? sRes.data) as Stats);
      if (aRes) {
        const a = (aRes.data?.data ?? aRes.data) as {
          deliveries?: Stats & { opened_estimated?: number; clicked?: number };
        };
        if (a?.deliveries) {
          const d = a.deliveries;
          setStats((prev) => ({
            ...(prev || {}),
            ...d,
            opened_estimated: d.opened_estimated,
            clicked: d.clicked,
          }));
        }
      }
      const ld = lRes.data?.data ?? lRes.data ?? [];
      setLists(Array.isArray(ld) ? ld : (ld as { items?: ListRow[] }).items || []);
    } catch (e: unknown) {
      setError(apiErrorMessage(e, 'Failed to load'));
    }
  }, [id]);

  useEffect(() => {
    void load();
  }, [load]);

  const act = async (fn: () => Promise<unknown>) => {
    setBusy(true);
    setError(null);
    try {
      await fn();
      await load();
    } catch (e: unknown) {
      setError(apiErrorMessage(e, 'Action failed'));
    } finally {
      setBusy(false);
    }
  };

  if (!campaign) {
    return (
      <div className="p-6">
        {error ? <p className="text-sm text-destructive">{error}</p> : <p className="text-sm text-muted-foreground">Loading…</p>}
      </div>
    );
  }

  const selectedList = lists.find((l) => l.uuid === listUuid);

  return (
    <div className="space-y-6 p-6">
      <PageHeader
        title={campaign.name}
        description={`${campaign.channel} · ${campaign.status}${campaign.message_type ? ` · ${campaign.message_type}` : ''}`}
        icon={<Send className="h-6 w-6" />}
        actions={
          <Link href="/dashboard/opsapi-marketing/campaigns" className="text-sm text-muted-foreground underline">
            All campaigns
          </Link>
        }
      />
      {error && <p className="text-sm text-destructive">{error}</p>}
      <p className="text-xs text-muted-foreground">
        This page has no draft Save — use Validate, then Send now. The audience list must have contacts (static
        members, or a dynamic list with a segment rule).
      </p>

      <div className="flex flex-wrap gap-2">
        {(campaign.status === 'draft' || campaign.status === 'validated') && (
          <Button
            size="sm"
            leftIcon={<CheckCircle className="h-4 w-4" />}
            disabled={busy}
            onClick={() =>
              void act(async () => {
                const res = await marketingService.validateCampaign(id, listUuid ? { list_uuid: listUuid } : {});
                const data = res.data?.data ?? res.data;
                if (data?.preview) setPreview(data.preview as Preview);
              })
            }
          >
            Validate
          </Button>
        )}
        {campaign.status === 'awaiting_approval' && (
          <>
            <Button
              size="sm"
              leftIcon={<Shield className="h-4 w-4" />}
              disabled={busy}
              onClick={() => void act(() => marketingService.approveCampaign(id))}
            >
              Approve
            </Button>
            <Button
              size="sm"
              variant="outline"
              disabled={busy}
              onClick={() => void act(() => marketingService.rejectCampaign(id, { reason: 'Needs changes' }))}
            >
              Reject
            </Button>
          </>
        )}
        {(campaign.status === 'validated' || campaign.status === 'draft') && (
          <Button
            size="sm"
            disabled={busy}
            onClick={() =>
              void act(() =>
                marketingService.scheduleCampaign(id, {
                  list_uuid: listUuid || undefined,
                  send_now: true,
                }),
              )
            }
          >
            Send now
          </Button>
        )}
        {(campaign.status === 'sending' || campaign.status === 'scheduled') && (
          <Button
            size="sm"
            variant="outline"
            leftIcon={<Pause className="h-4 w-4" />}
            disabled={busy}
            onClick={() => void act(() => marketingService.pauseCampaign(id))}
          >
            Pause
          </Button>
        )}
        {campaign.status === 'paused' && (
          <Button
            size="sm"
            leftIcon={<Play className="h-4 w-4" />}
            disabled={busy}
            onClick={() => void act(() => marketingService.resumeCampaign(id))}
          >
            Resume
          </Button>
        )}
        {campaign.status !== 'completed' && campaign.status !== 'cancelled' && (
          <Button
            size="sm"
            variant="danger"
            leftIcon={<XCircle className="h-4 w-4" />}
            disabled={busy}
            onClick={() => void act(() => marketingService.cancelCampaign(id))}
          >
            Cancel
          </Button>
        )}
        <Button
          size="sm"
          variant="outline"
          leftIcon={<Copy className="h-4 w-4" />}
          disabled={busy}
          onClick={() => void act(() => marketingService.duplicateCampaign(id))}
        >
          Duplicate
        </Button>
      </div>

      <div className="grid gap-4 md:grid-cols-2">
        <div className="space-y-3 rounded-lg border border-border p-4">
          <h2 className="text-sm font-medium">Audience</h2>
          <label className="block text-sm">
            List
            <select
              className="mt-1 w-full rounded border border-border bg-background px-2 py-1.5"
              value={listUuid}
              onChange={(e) => setListUuid(e.target.value)}
            >
              <option value="">— select —</option>
              {lists.map((l) => (
                <option key={l.uuid} value={l.uuid}>
                  {l.name}
                  {l.list_type ? ` (${l.list_type})` : ''}
                </option>
              ))}
            </select>
          </label>
          {selectedList?.list_type === 'dynamic' && (
            <p className="text-xs text-amber-800 dark:text-amber-200">
              Dynamic lists need a segment rule, then Validate will sync members automatically.
            </p>
          )}
          <Button
            size="sm"
            variant="outline"
            disabled={busy}
            onClick={() =>
              void act(async () => {
                const res = await marketingService.audiencePreview(id, listUuid ? { list_uuid: listUuid } : {});
                setPreview((res.data?.data ?? res.data) as Preview);
              })
            }
          >
            Preview eligibility
          </Button>
          {preview && (
            <dl className="grid grid-cols-2 gap-2 text-sm">
              <div>
                <dt className="text-muted-foreground">Audience</dt>
                <dd className="font-medium">{preview.audience_total}</dd>
              </div>
              <div>
                <dt className="text-muted-foreground">Eligible</dt>
                <dd className="font-medium text-green-700 dark:text-green-400">{preview.eligible}</dd>
              </div>
              <div>
                <dt className="text-muted-foreground">Suppressed</dt>
                <dd>{preview.suppressed}</dd>
              </div>
              <div>
                <dt className="text-muted-foreground">No consent</dt>
                <dd>{preview.no_consent}</dd>
              </div>
              {!preview.exact && (
                <p className="col-span-2 text-xs text-muted-foreground">Counts extrapolated from a sample.</p>
              )}
            </dl>
          )}
        </div>

        <div className="space-y-3 rounded-lg border border-border p-4">
          <h2 className="text-sm font-medium">Delivery</h2>
          <p className="text-sm">
            Subject: <span className="font-medium">{campaign.subject || '—'}</span>
          </p>
          {campaign.max_deliveries && (
            <p className="text-sm text-muted-foreground">Budget: max {campaign.max_deliveries} deliveries</p>
          )}
          {stats && (
            <dl className="grid grid-cols-2 gap-2 text-sm">
              <div>
                <dt className="text-muted-foreground">Total rows</dt>
                <dd className="font-medium">{stats.total}</dd>
              </div>
              {Object.entries(stats.by_state || {}).map(([k, v]) => (
                <div key={k}>
                  <dt className="text-muted-foreground">{k}</dt>
                  <dd>{v}</dd>
                </div>
              ))}
            </dl>
          )}
          {stats?.by_variant && Object.keys(stats.by_variant).length > 0 && (
            <div className="text-sm">
              <p className="mb-1 font-medium">A/B variants</p>
              {Object.entries(stats.by_variant).map(([k, v]) => (
                <p key={k} className="text-muted-foreground">
                  {k}: {v.total ?? 0} ({v.accepted || 0} accepted)
                </p>
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

'use client';

import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import { Megaphone, Send, Users, ShieldOff, MessageSquare } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { marketingService } from '@/services/opsapi-marketing.service';

type Overview = {
  campaigns?: { drafts?: number; active?: number; completed?: number; paused?: number };
  deliveries?: {
    queued?: number; accepted?: number; delivered?: number; bounced?: number;
    failed?: number; skipped?: number; opened_est?: number; clicked?: number;
  };
  replies_30d?: number;
  notes?: { opens_are_estimated?: boolean };
};

export default function MarketingOverviewPage() {
  const [stats, setStats] = useState<Overview | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    marketingService
      .analyticsOverview()
      .then((res) => setStats(res.data?.data ?? res.data ?? null))
      .catch((e: unknown) =>
        setError(e instanceof Error ? e.message : 'Could not load analytics (enable the plugin?)'),
      );
  }, []);

  const d = stats?.deliveries;
  const c = stats?.campaigns;

  return (
    <div className="space-y-6 p-6">
      <PageHeader
        title="Marketing Cloud"
        description="Multi-channel campaigns with consent-first delivery on your CRM audience."
        icon={<Megaphone className="h-6 w-6" />}
      />

      {error && <p className="text-sm text-muted-foreground">{error}</p>}

      {stats && (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4 text-sm">
          <Stat label="Active campaigns" value={c?.active} />
          <Stat label="Drafts" value={c?.drafts} />
          <Stat label="Accepted" value={d?.accepted} />
          <Stat label="Opened (estimated)" value={d?.opened_est} />
          <Stat label="Clicked" value={d?.clicked} />
          <Stat label="Bounced" value={d?.bounced} />
          <Stat label="Skipped" value={d?.skipped} />
          <Stat label="Replies (30d)" value={stats.replies_30d} />
        </div>
      )}
      <p className="text-xs text-muted-foreground">
        Opens are estimated — scanners and proxies inflate counts. Accepted is not delivered.
      </p>

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <NavCard href="/dashboard/opsapi-marketing/studio" icon={<Send className="h-5 w-5 mb-2 text-muted-foreground" />}
          title="Studio" desc="Design email and SMS with merge fields and previews." />
        <NavCard href="/dashboard/opsapi-marketing/campaigns" icon={<Send className="h-5 w-5 mb-2 text-muted-foreground" />}
          title="Campaigns" desc="Draft, schedule and send across email and SMS." />
        <NavCard href="/dashboard/opsapi-marketing/conversations" icon={<MessageSquare className="h-5 w-5 mb-2 text-muted-foreground" />}
          title="Conversations" desc="Inbound replies — classified, never auto-sent." />
        <NavCard href="/dashboard/plugins/opsapi_marketing/lists" icon={<Users className="h-5 w-5 mb-2 text-muted-foreground" />}
          title="Lists & segments" desc="Build audiences from CRM contacts with consent." />
        <NavCard href="/dashboard/plugins/opsapi_marketing/suppressions" icon={<ShieldOff className="h-5 w-5 mb-2 text-muted-foreground" />}
          title="Suppressions" desc="Global and per-channel blocks that always win." />
      </div>
    </div>
  );
}

function Stat({ label, value }: { label: string; value?: number }) {
  return (
    <div className="rounded-lg border border-border p-3">
      <div className="text-muted-foreground">{label}</div>
      <div className="text-2xl font-semibold tabular-nums mt-1">{value ?? 0}</div>
    </div>
  );
}

function NavCard({
  href, icon, title, desc,
}: { href: string; icon: React.ReactNode; title: string; desc: string }) {
  return (
    <Link href={href} className="rounded-lg border border-border p-5 hover:bg-muted/40 transition-colors">
      {icon}
      <h2 className="font-medium">{title}</h2>
      <p className="text-sm text-muted-foreground mt-1">{desc}</p>
    </Link>
  );
}

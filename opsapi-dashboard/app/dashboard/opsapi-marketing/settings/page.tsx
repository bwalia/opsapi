'use client';

import React, { useEffect, useState } from 'react';
import { ExternalLink, Mail, Radar, Settings } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import Link from 'next/link';
import { buttonClass } from '@/components/ui';
import { marketingService } from '@/services/opsapi-marketing.service';
import { HelpLink } from '@/components/opsapi-marketing/GettingStarted';

// Settings live on the shared workspace Plugins page; deep-link to this plugin's card.
const PLUGIN_SETTINGS_HREF = '/dashboard/namespace/plugins#plugin-opsapi_marketing';

const GROUPS: { title: string; items: string[] }[] = [
  {
    title: 'Sending',
    items: [
      'Default from name and email (SMTP comes from workspace mail unless overridden)',
      'Dry-run mode — accept sends without calling SMTP/SMS (use outside production)',
      'Email and SMS sends per minute, emails per day and emails sent at once',
      'SMS gateway URL, username and password',
    ],
  },
  {
    title: 'Compliance',
    items: [
      'Marketing jurisdiction (UK, EU, US) and workspace time zone',
      'Quiet hours and the per-contact frequency cap',
      'How long raw tracking events are kept',
    ],
  },
  {
    title: 'Tracking & attribution',
    items: [
      'Public tracking base URL for open/click/unsubscribe links (defaults to the API address)',
      'Meta Conversions API: dataset ID, access token and test event code',
      'GA4 Measurement Protocol: measurement ID and API secret',
      'Whether page views are forwarded too (off by default: conversions only)',
    ],
  },
];

type Sending = {
  via: 'workspace' | 'deployment' | 'none';
  workspace_smtp_saved: boolean;
  workspace_smtp_enabled: boolean;
  host?: string;
  from_email?: string;
  from_name?: string;
  dry_run: boolean;
  env_tag?: string;
  daily_limit: number;
  sent_last_24h: number;
  parallel: number;
  rate_per_min: number;
  public_url: string;
  sender_address_set: boolean;
};

const WORKSPACE_EMAIL_HREF = '/dashboard/namespace/email';

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-0.5 sm:flex-row sm:gap-4">
      <dt className="w-40 shrink-0 text-secondary-500">{label}</dt>
      <dd className="text-secondary-900">{children}</dd>
    </div>
  );
}

/** Which SMTP and From this workspace's email will use, and what will hold it back. */
function SendingCard() {
  const [info, setInfo] = useState<Sending | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    marketingService
      .sendingInfo()
      .then((res) => setInfo((res.data?.data ?? res.data) as Sending))
      .catch(() => setFailed(true));
  }, []);

  if (failed) return null;
  if (!info) return <div className="h-40 animate-pulse rounded-lg border border-secondary-200" />;

  const via =
    info.via === 'workspace'
      ? 'This workspace’s own SMTP'
      : info.via === 'deployment'
        ? 'The platform’s shared SMTP (no workspace SMTP is switched on)'
        : 'No SMTP is set up';
  const gmail = /gmail\.com$/i.test(info.host || '');
  const warnings: React.ReactNode[] = [];
  if (info.dry_run) warnings.push('Test mode (dry run) is on: nothing is really sent. Turn it off in the plugin settings to send.');
  if (info.via !== 'workspace')
    warnings.push(
      <>
        Set up this workspace’s own SMTP under{' '}
        <Link href={WORKSPACE_EMAIL_HREF} className="underline underline-offset-2">
          Workspace → Email
        </Link>{' '}
        so emails come from your own address{info.workspace_smtp_saved && !info.workspace_smtp_enabled ? ' (it is saved but switched off)' : ''}.
      </>,
    );
  if (gmail) warnings.push('Gmail sends at most about 500 emails a day and shows its own address as the sender. Set “Emails per day” to match.');
  if (info.env_tag) warnings.push(`This is a test environment: subjects start with ${info.env_tag} and a test banner is added.`);
  if (!info.sender_address_set) warnings.push('Add your business name and postal address: promotional emails must show it.');
  if (!info.public_url) warnings.push('Set the public tracking/unsubscribe URL: unsubscribe links and images need it.');

  return (
    <section className="rounded-lg border border-secondary-200 p-4">
      <h2 className="flex items-center gap-2 text-sm font-medium text-secondary-900">
        <Mail className="h-4 w-4" aria-hidden />
        How your emails are sent
      </h2>
      <dl className="mt-3 space-y-2 text-sm">
        <Row label="Sent through">
          {via}
          {info.host ? <span className="text-secondary-500"> · {info.host}</span> : null}
        </Row>
        <Row label="From">
          {info.from_email ? `${info.from_name ? `${info.from_name} ` : ''}<${info.from_email}>` : 'Not set'}
          <span className="text-secondary-500"> (a campaign can set its own)</span>
        </Row>
        <Row label="Daily limit">
          {info.daily_limit > 0
            ? `${info.sent_last_24h.toLocaleString()} of ${info.daily_limit.toLocaleString()} used in the last 24 hours`
            : `No limit · ${info.sent_last_24h.toLocaleString()} sent in the last 24 hours`}
        </Row>
        <Row label="Speed">
          {info.rate_per_min.toLocaleString()} per minute, {info.parallel} at once
        </Row>
      </dl>
      {warnings.length > 0 && (
        <ul className="mt-3 list-disc space-y-1 pl-4 text-sm text-amber-700">
          {warnings.map((w, i) => (
            <li key={i}>{w}</li>
          ))}
        </ul>
      )}
    </section>
  );
}

export default function MarketingSettingsPage() {
  return (
    <div className="space-y-6 p-6">
      <PageHeader
        title="Marketing settings"
        description="Channel providers, compliance rules and ad-platform forwarding are configured per workspace."
        icon={<Settings className="h-6 w-6" />}
        actions={
          <Link href={PLUGIN_SETTINGS_HREF} className={buttonClass('primary', 'md')}>
            <ExternalLink className="mr-1.5 h-4 w-4" aria-hidden />
            Open Marketing Cloud settings
          </Link>
        }
      />
      <p className="max-w-2xl text-sm text-secondary-500">
        These are edited under{' '}
        <Link href={PLUGIN_SETTINGS_HREF} className="underline underline-offset-2">
          Workspace → Plugins → Marketing Cloud
        </Link>
        . Secrets (SMS password, Meta token, GA4 secret) are encrypted at rest and never shown again after saving.
      </p>
      <SendingCard />
      <HelpLink topic="connect-email">How do I connect my email and switch off test mode?</HelpLink>
      <div className="grid gap-4 md:grid-cols-3">
        {GROUPS.map((g) => (
          <div key={g.title} className="rounded-lg border border-secondary-200 p-4">
            <h2 className="text-sm font-medium text-secondary-900">{g.title}</h2>
            <ul className="mt-2 list-disc space-y-1 pl-4 text-sm text-secondary-500">
              {g.items.map((i) => (
                <li key={i}>{i}</li>
              ))}
            </ul>
          </div>
        ))}
      </div>
      <section className="rounded-lg border border-secondary-200 p-4">
        <h2 className="flex items-center gap-2 text-sm font-medium text-secondary-900">
          <Radar className="h-4 w-4" aria-hidden />
          Track sales on your website <span className="font-normal text-secondary-500">(advanced)</span>
        </h2>
        <p className="mt-1 max-w-2xl text-sm text-secondary-500">
          See which emails lead to visits, sign-ups and sales on your website. You add a small piece of code to your
          site, and your web developer adds one line where a sale or sign-up happens. You don’t need it to send emails.
        </p>
        <div className="mt-3">
          <Link href="/dashboard/opsapi-marketing/pixels" className={buttonClass('outline', 'sm')}>
            Set up website tracking
          </Link>
        </div>
      </section>
    </div>
  );
}

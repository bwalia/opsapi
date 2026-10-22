'use client';

import React from 'react';
import { ExternalLink, Settings } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import Link from 'next/link';
import { buttonClass } from '@/components/ui';

// Settings live on the shared workspace Plugins page; deep-link to this plugin's card.
const PLUGIN_SETTINGS_HREF = '/dashboard/namespace/plugins#plugin-opsapi_marketing';

const GROUPS: { title: string; items: string[] }[] = [
  {
    title: 'Sending',
    items: [
      'Default from name and email (SMTP comes from workspace mail unless overridden)',
      'Dry-run mode — accept sends without calling SMTP/SMS (use outside production)',
      'Email and SMS sends per minute',
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
      <p className="text-xs text-secondary-500">
        Pixels themselves (install snippet, allowed domains, attribution window) are managed on{' '}
        <Link href="/dashboard/opsapi-marketing/pixels" className="underline underline-offset-2">
          Pixels &amp; attribution
        </Link>
        .
      </p>
    </div>
  );
}

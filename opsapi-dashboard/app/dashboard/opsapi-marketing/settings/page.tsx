'use client';

import React from 'react';
import { Settings } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import Link from 'next/link';

export default function MarketingSettingsPage() {
  return (
    <div className="space-y-6 p-6">
      <PageHeader
        title="Marketing settings"
        description="Channel providers, rates and quiet hours are configured per workspace."
        icon={<Settings className="h-6 w-6" />}
      />
      <p className="text-sm text-secondary-500 max-w-xl">
        Open{' '}
        <Link href="/dashboard/settings/plugins" className="underline underline-offset-2">
          Workspace → Plugins → Marketing Cloud
        </Link>{' '}
        to set SMTP (or rely on workspace mail), SMS gateway credentials, dry-run mode,
        frequency caps and quiet hours. Secrets are encrypted at rest.
      </p>
    </div>
  );
}

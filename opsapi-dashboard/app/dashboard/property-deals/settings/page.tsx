'use client';

/** Property Deals — Settings (SPEC §3.8 #9): templates, SLA & urgency, AI, connectors, mailboxes, my notifications. */
import React, { useState } from 'react';
import { Settings } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { PdPage, Tabs } from '@/components/property-deals/ui';
import { usePdMe } from '@/components/property-deals/usePd';
import { useIsNamespaceOwner } from '@/contexts/NamespaceContext';
import TemplateEditor from '@/components/property-deals/settings/TemplateEditor';
import PluginSettings from '@/components/property-deals/settings/PluginSettings';
import AiSettings from '@/components/property-deals/settings/AiSettings';
import { DataConnectors, Mailboxes, MyNotifications } from '@/components/property-deals/settings/Connections';

type Tab = 'templates' | 'rules' | 'ai' | 'data' | 'mail' | 'me';

export default function SettingsPage() {
  return (
    <PdPage>
      <SettingsBody />
    </PdPage>
  );
}

function SettingsBody() {
  const { can } = usePdMe();
  const owner = useIsNamespaceOwner();
  const [tab, setTab] = useState<Tab>(can('settings', 'read') ? 'templates' : 'me');
  const canEdit = can('settings', 'update');
  return (
    <div className="space-y-6">
      <PageHeader title="Deals settings" description="Workflow templates, deadlines and urgency, AI and data sources." icon={<Settings className="h-6 w-6" />} />
      <div data-tour="settings-tabs">
        <Tabs<Tab>
          value={tab}
          onChange={setTab}
          tabs={[
            ...(can('settings', 'read')
              ? ([
                  { key: 'templates', label: 'Workflow templates' },
                  { key: 'rules', label: 'SLA, urgency & more' },
                  { key: 'ai', label: 'AI & JobShout' },
                  { key: 'data', label: 'Data connectors' },
                  { key: 'mail', label: 'Mailboxes' },
                ] as { key: Tab; label: string }[])
              : []),
            { key: 'me', label: 'My notifications' },
          ]}
        />
      </div>
      {tab === 'templates' && <TemplateEditor canEdit={canEdit} />}
      {tab === 'rules' && <PluginSettings canEdit={owner || can('settings', 'manage')} />}
      {tab === 'ai' && <AiSettings canEditProviders={owner || can('settings', 'manage')} canEditPlugin={canEdit} />}
      {tab === 'data' && <DataConnectors canEdit={canEdit} />}
      {tab === 'mail' && <Mailboxes canEdit={canEdit} />}
      {tab === 'me' && <MyNotifications />}
    </div>
  );
}

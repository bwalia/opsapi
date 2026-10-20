'use client';

import React, { useEffect, useState } from 'react';
import { Send, Plus, RefreshCw } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button } from '@/components/ui';
import { marketingService } from '@/services/opsapi-marketing.service';

type Campaign = {
  uuid: string;
  name: string;
  channel: string;
  status: string;
  message_type?: string;
  scheduled_at?: string;
};

export default function MarketingCampaignsPage() {
  const [items, setItems] = useState<Campaign[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [creating, setCreating] = useState(false);

  const load = async () => {
    setLoading(true);
    setError(null);
    try {
      const res = await marketingService.listCampaigns({ per_page: 50 });
      const data = res.data?.data ?? res.data ?? [];
      setItems(Array.isArray(data) ? data : data.items || []);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Failed to load campaigns');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    void load();
  }, []);

  const createDraft = async () => {
    setCreating(true);
    try {
      await marketingService.createCampaign({
        name: 'Untitled campaign',
        channel: 'email',
        message_type: 'marketing',
        status: 'draft',
        subject: 'Hello {{contact.first_name}}',
        body_html: '<p>Hi {{contact.first_name}},</p><p>Your update is ready.</p>',
        body_text: 'Hi {{contact.first_name}}, your update is ready.',
      });
      await load();
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Create failed');
    } finally {
      setCreating(false);
    }
  };

  return (
    <div className="space-y-6 p-6">
      <PageHeader
        title="Campaigns"
        description="Consent-gated multi-channel sends. Eligibility is re-checked at send time."
        icon={<Send className="h-6 w-6" />}
        actions={
          <>
            <Button variant="outline" leftIcon={<RefreshCw className="h-4 w-4" />} onClick={() => void load()}>
              Refresh
            </Button>
            <Button leftIcon={<Plus className="h-4 w-4" />} onClick={() => void createDraft()} disabled={creating}>
              New campaign
            </Button>
          </>
        }
      />
      {error && <p className="text-sm text-destructive">{error}</p>}
      {loading ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : items.length === 0 ? (
        <p className="text-sm text-muted-foreground">No campaigns yet. Create a draft to get started.</p>
      ) : (
        <div className="overflow-x-auto rounded-lg border border-border">
          <table className="w-full text-sm">
            <thead className="bg-muted/40 text-left">
              <tr>
                <th className="p-3 font-medium">Name</th>
                <th className="p-3 font-medium">Channel</th>
                <th className="p-3 font-medium">Status</th>
                <th className="p-3 font-medium">Type</th>
              </tr>
            </thead>
            <tbody>
              {items.map((c) => (
                <tr key={c.uuid} className="border-t border-border">
                  <td className="p-3">
                    <a href={`/dashboard/opsapi-marketing/campaigns/${c.uuid}`} className="underline-offset-2 hover:underline">
                      {c.name}
                    </a>
                  </td>
                  <td className="p-3">{c.channel}</td>
                  <td className="p-3">{c.status}</td>
                  <td className="p-3">{c.message_type || '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

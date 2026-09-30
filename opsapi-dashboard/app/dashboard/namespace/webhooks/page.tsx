'use client';

/**
 * Webhooks — /dashboard/namespace/webhooks
 *
 * Send this workspace's events (invoice paid, lead created, …) to your own
 * URLs: signed, retried, and logged. Configuration only — no code — so it is
 * safe to offer every tenant (see PLUGINS.md for code-level plugins).
 */

import React, { useCallback, useEffect, useState } from 'react';
import toast from 'react-hot-toast';
import { History, KeyRound, Pencil, Plus, Send, Trash2, Webhook as WebhookIcon } from 'lucide-react';
import { Button, Card, ConfirmDialog, Table } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { usePermissions } from '@/contexts/PermissionsContext';
import { Pill, apiError } from '@/components/field-service/shared';
import WebhookFormModal from '@/components/webhooks/WebhookFormModal';
import WebhookSecretModal from '@/components/webhooks/WebhookSecretModal';
import WebhookDeliveriesModal, { STATUS_STYLE, when } from '@/components/webhooks/WebhookDeliveriesModal';
import { webhooksService, type DeliveryStatus, type Webhook } from '@/services/webhooks.service';
import type { TableColumn } from '@/types';

function Health({ webhook, onFailures }: { webhook: Webhook; onFailures: () => void }) {
  const last = webhook.last_delivery;
  return (
    <div className="space-y-1">
      <div className="flex flex-wrap items-center gap-1.5">
        <Pill className={webhook.is_active ? 'bg-green-50 text-green-700' : 'bg-secondary-100 text-secondary-500'}>
          {webhook.is_active ? 'Active' : 'Paused'}
        </Pill>
        {!!webhook.dead_count && (
          <button
            type="button"
            onClick={onFailures}
            className="focus:outline-none focus:ring-2 focus:ring-error-500/30 rounded-md"
          >
            <Pill className="bg-error-50 text-error-700">{webhook.dead_count} failed</Pill>
          </button>
        )}
      </div>
      <p className="text-xs text-secondary-500">
        {last
          ? `${STATUS_STYLE[last.status].label}${last.response_status ? ` · HTTP ${last.response_status}` : ''} · ${when(last.updated_at)}`
          : 'No deliveries yet'}
      </p>
    </div>
  );
}

function WebhooksPageContent() {
  const { canCreate, canUpdate, canDelete } = usePermissions();
  const [webhooks, setWebhooks] = useState<Webhook[]>([]);
  const [loading, setLoading] = useState(true);
  const [editing, setEditing] = useState<{ webhook: Webhook | null } | null>(null);
  const [secret, setSecret] = useState<string | null>(null);
  const [deliveries, setDeliveries] = useState<{ webhook: Webhook; status: DeliveryStatus | '' } | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<Webhook | null>(null);
  const [rotateTarget, setRotateTarget] = useState<Webhook | null>(null);
  const [working, setWorking] = useState(false);
  const [testing, setTesting] = useState<string | null>(null);

  const allowEdit = canUpdate('webhooks');
  const allowDelete = canDelete('webhooks');

  const load = useCallback(async () => {
    try {
      setWebhooks(await webhooksService.list());
    } catch (err) {
      toast.error(apiError(err, 'Could not load webhooks'));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const sendTest = async (w: Webhook) => {
    setTesting(w.uuid);
    try {
      const r = await webhooksService.test(w.uuid);
      if (r.delivered) toast.success(`Delivered — HTTP ${r.response_status} in ${r.duration_ms} ms`);
      else toast.error(`Not delivered: ${r.error}`);
    } catch (err) {
      toast.error(apiError(err, 'Could not send the test'));
    } finally {
      setTesting(null);
    }
  };

  const remove = async () => {
    if (!deleteTarget) return;
    setWorking(true);
    try {
      await webhooksService.remove(deleteTarget.uuid);
      toast.success('Webhook deleted');
      setDeleteTarget(null);
      load();
    } catch (err) {
      toast.error(apiError(err, 'Could not delete the webhook'));
    } finally {
      setWorking(false);
    }
  };

  const rotate = async () => {
    if (!rotateTarget) return;
    setWorking(true);
    try {
      setSecret(await webhooksService.rotateSecret(rotateTarget.uuid));
      setRotateTarget(null);
    } catch (err) {
      toast.error(apiError(err, 'Could not rotate the secret'));
    } finally {
      setWorking(false);
    }
  };

  const columns: TableColumn<Webhook>[] = [
    {
      key: 'url',
      header: 'Endpoint',
      render: (w) => (
        <div className="min-w-0 max-w-md">
          <p className="font-mono text-sm text-secondary-900 truncate" title={w.url}>
            {w.url}
          </p>
          {w.description && <p className="text-xs text-secondary-500 truncate">{w.description}</p>}
        </div>
      ),
    },
    {
      key: 'events',
      header: 'Events',
      render: (w) => (
        <div className="flex flex-wrap gap-1 max-w-xs">
          {w.events.slice(0, 3).map((e) => (
            <span key={e} className="px-2 py-0.5 rounded-md bg-secondary-100 text-secondary-700 font-mono text-xs">
              {e}
            </span>
          ))}
          {w.events.length > 3 && <span className="text-xs text-secondary-500">+{w.events.length - 3}</span>}
        </div>
      ),
    },
    {
      key: 'health',
      header: 'Status',
      render: (w) => <Health webhook={w} onFailures={() => setDeliveries({ webhook: w, status: 'dead' })} />,
    },
    {
      key: 'actions',
      header: '',
      width: 'w-48',
      render: (w) => (
        <div className="flex items-center gap-1" onClick={(e) => e.stopPropagation()}>
          {allowEdit && (
            <button
              type="button"
              onClick={() => sendTest(w)}
              disabled={testing === w.uuid}
              className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg disabled:opacity-50"
              aria-label="Send a test event"
              title="Send a test event"
            >
              <Send className="w-4 h-4" />
            </button>
          )}
          <button
            type="button"
            onClick={() => setDeliveries({ webhook: w, status: '' })}
            className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg"
            aria-label="Delivery log"
            title="Delivery log"
          >
            <History className="w-4 h-4" />
          </button>
          {allowEdit && (
            <>
              <button
                type="button"
                onClick={() => setEditing({ webhook: w })}
                className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg"
                aria-label="Edit webhook"
                title="Edit webhook"
              >
                <Pencil className="w-4 h-4" />
              </button>
              <button
                type="button"
                onClick={() => setRotateTarget(w)}
                className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg"
                aria-label="Rotate signing secret"
                title="Rotate signing secret"
              >
                <KeyRound className="w-4 h-4" />
              </button>
            </>
          )}
          {allowDelete && (
            <button
              type="button"
              onClick={() => setDeleteTarget(w)}
              className="p-1.5 text-secondary-500 hover:text-error-500 hover:bg-error-50 rounded-lg"
              aria-label="Delete webhook"
              title="Delete webhook"
            >
              <Trash2 className="w-4 h-4" />
            </button>
          )}
        </div>
      ),
    },
  ];

  return (
    <div className="space-y-6">
      <PageHeader
        title="Webhooks"
        description="Send this workspace's events to your own URLs: signed, retried and logged."
        icon={<WebhookIcon className="w-5 h-5" />}
        actions={
          canCreate('webhooks') ? (
            <Button onClick={() => setEditing({ webhook: null })}>
              <Plus className="w-4 h-4 mr-1.5" /> Add webhook
            </Button>
          ) : undefined
        }
      />

      {!loading && webhooks.length === 0 ? (
        <Card padding="lg">
          <div className="flex flex-col items-center text-center py-8 gap-3">
            <div className="w-12 h-12 rounded-xl bg-primary-50 text-primary-600 flex items-center justify-center">
              <WebhookIcon className="w-6 h-6" />
            </div>
            <h2 className="text-lg font-semibold text-secondary-900">No webhooks yet</h2>
            <p className="text-sm text-secondary-500 max-w-md">
              Get a signed HTTPS request when things happen here — an invoice is paid, a lead comes in, a task moves —
              and connect OpsAPI to your ERP, Zapier, Slack or your own code.
            </p>
            {canCreate('webhooks') && (
              <Button onClick={() => setEditing({ webhook: null })}>
                <Plus className="w-4 h-4 mr-1.5" /> Add your first webhook
              </Button>
            )}
          </div>
        </Card>
      ) : (
        <Table
          columns={columns}
          data={webhooks}
          keyExtractor={(w) => w.uuid}
          onRowClick={allowEdit ? (w) => setEditing({ webhook: w }) : undefined}
          isLoading={loading}
          caption="Webhooks"
        />
      )}

      <WebhookFormModal
        isOpen={!!editing}
        webhook={editing?.webhook ?? null}
        onClose={() => setEditing(null)}
        onSaved={(_, newSecret) => {
          if (newSecret) setSecret(newSecret);
          load();
        }}
      />
      <WebhookSecretModal secret={secret} onClose={() => setSecret(null)} />
      <WebhookDeliveriesModal
        webhook={deliveries?.webhook ?? null}
        initialStatus={deliveries?.status}
        canRedeliver={allowEdit}
        onClose={() => {
          setDeliveries(null);
          load();
        }}
      />
      <ConfirmDialog
        isOpen={!!deleteTarget}
        onClose={() => setDeleteTarget(null)}
        onConfirm={remove}
        title="Delete webhook"
        message={`Stop sending events to ${deleteTarget?.url ?? ''}? Its queued and logged deliveries are removed too.`}
        confirmText="Delete"
        variant="danger"
        isLoading={working}
      />
      <ConfirmDialog
        isOpen={!!rotateTarget}
        onClose={() => setRotateTarget(null)}
        onConfirm={rotate}
        title="Rotate signing secret"
        message="The current secret stops working immediately. Update your receiver with the new one."
        confirmText="Rotate"
        variant="warning"
        isLoading={working}
      />
    </div>
  );
}

export default function WebhooksPage() {
  return (
    <ProtectedPage module="webhooks" title="Webhooks">
      <WebhooksPageContent />
    </ProtectedPage>
  );
}

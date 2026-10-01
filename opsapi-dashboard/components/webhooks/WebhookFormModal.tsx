'use client';

/**
 * Create / edit a workspace webhook: URL, description, and the events it
 * receives (grouped by entity; entities the user can't read are locked).
 */

import React, { useEffect, useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { Lock, Search } from 'lucide-react';
import { Modal, Button, Input } from '@/components/ui';
import { CheckboxField, apiError } from '@/components/field-service/shared';
import { webhooksService, type Webhook, type WebhookEventGroup } from '@/services/webhooks.service';


interface WebhookFormModalProps {
  isOpen: boolean;
  /** null = create. */
  webhook: Webhook | null;
  onClose: () => void;
  /** Called with the saved webhook, plus its secret when it was just created. */
  onSaved: (webhook: Webhook, secret?: string) => void;
}

export default function WebhookFormModal(props: WebhookFormModalProps) {
  return (
    <Modal
      isOpen={props.isOpen}
      onClose={props.onClose}
      title={props.webhook ? 'Edit webhook' : 'Add webhook'}
      description="We POST a signed JSON payload to your URL when these events happen in this workspace."
      size="2xl"
    >
      {props.isOpen && <WebhookForm key={props.webhook?.uuid ?? 'new'} {...props} />}
    </Modal>
  );
}

function WebhookForm({ webhook, onClose, onSaved }: WebhookFormModalProps) {
  const [url, setUrl] = useState(webhook?.url ?? '');
  const [description, setDescription] = useState(webhook?.description ?? '');
  const [active, setActive] = useState(webhook?.is_active ?? true);
  const [selected, setSelected] = useState<Set<string>>(() => new Set(webhook?.events ?? []));
  const [groups, setGroups] = useState<WebhookEventGroup[] | null>(null);
  const [filter, setFilter] = useState('');
  const [errors, setErrors] = useState<{ url?: string; events?: string }>({});
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    webhooksService
      .events()
      .then(setGroups)
      .catch((err) => {
        setGroups([]);
        toast.error(apiError(err, 'Could not load the event list'));
      });
  }, []);

  const visible = useMemo(() => {
    const f = filter.trim().toLowerCase();
    return (groups ?? []).filter((g) => !f || g.entity.includes(f) || g.owner.includes(f));
  }, [groups, filter]);

  const toggle = (event: string, on: boolean) =>
    setSelected((s) => {
      const next = new Set(s);
      if (on) next.add(event);
      else next.delete(event);
      // "all" replaces the individual events of that entity
      if (on && event.endsWith('.*')) {
        const group = groups?.find((g) => `${g.entity}.*` === event);
        group?.events.forEach((name) => next.delete(name));
      }
      return next;
    });

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    const problems: typeof errors = {};
    if (!/^https?:\/\/\S+$/i.test(url.trim())) problems.url = 'Enter the full URL, starting with https://';
    if (selected.size === 0) problems.events = 'Choose at least one event';
    setErrors(problems);
    if (Object.keys(problems).length) {
      // Bring the first problem into view (the form scrolls inside the modal).
      if (problems.url) document.getElementById('webhook-url')?.focus();
      else document.getElementById('webhook-events')?.scrollIntoView({ block: 'center', behavior: 'smooth' });
      return;
    }

    setSaving(true);
    const input = {
      url: url.trim(),
      description: description.trim() || null,
      events: Array.from(selected).sort(),
      ...(webhook ? { is_active: active } : {}),
    };
    try {
      if (webhook) {
        onSaved(await webhooksService.update(webhook.uuid, input));
        toast.success('Webhook saved');
      } else {
        const { webhook: created, secret } = await webhooksService.create(input);
        onSaved(created, secret);
      }
      onClose();
    } catch (err) {
      const message = apiError(err, 'Could not save the webhook');
      if (/^url /i.test(message)) {
        setErrors({ url: 'The URL ' + message.slice(4) });
        document.getElementById('webhook-url')?.focus();
      } else toast.error(message);
    } finally {
      setSaving(false);
    }
  };

  return (
    <form onSubmit={submit} noValidate className="space-y-5">
      <Input
        id="webhook-url"
        label="Endpoint URL *"
        placeholder="https://example.com/opsapi/webhooks"
        value={url}
        onChange={(e) => setUrl(e.target.value)}
        error={errors.url}
        helperText={errors.url ? undefined : 'Must be https and publicly reachable.'}
        autoComplete="off"
      />
      <Input
        id="webhook-description"
        label="Description"
        placeholder="e.g. Sync paid invoices to our ERP"
        value={description}
        maxLength={255}
        onChange={(e) => setDescription(e.target.value)}
      />

      <fieldset id="webhook-events">
        <div className="flex items-center justify-between gap-3 mb-2">
          <legend className="text-sm font-medium text-secondary-700">Events *</legend>
          <span className="text-xs text-secondary-500">{selected.size} selected</span>
        </div>
        <Input
          aria-label="Filter events"
          placeholder="Filter, e.g. invoice or crm"
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
          leftIcon={<Search className="w-4 h-4" />}
        />
        <div className="mt-2 max-h-72 overflow-y-auto rounded-lg border border-secondary-200 divide-y divide-secondary-100">
          {groups === null && <p className="p-4 text-sm text-secondary-500">Loading events…</p>}
          {groups !== null && visible.length === 0 && (
            <p className="p-4 text-sm text-secondary-500">No matching events.</p>
          )}
          {visible.map((g) => {
            const all = selected.has(`${g.entity}.*`);
            return (
              <div
                key={g.entity}
                className={`flex flex-wrap items-center gap-x-5 gap-y-2 px-3 py-2.5 ${g.allowed ? '' : 'opacity-60'}`}
              >
                <div className="w-44 shrink-0">
                  <p className="font-mono text-sm text-secondary-900">{g.entity}</p>
                  <p className="text-xs text-secondary-500">{g.owner === 'core' ? 'OpsAPI' : `Plugin: ${g.owner}`}</p>
                </div>
                {g.allowed ? (
                  <>
                    {g.events.map((name) => (
                      <label key={name} className="flex items-center gap-1.5 text-sm text-secondary-700 cursor-pointer">
                        <input
                          type="checkbox"
                          className="h-4 w-4 rounded border-secondary-300 text-primary-600 focus:ring-primary-500"
                          checked={all || selected.has(name)}
                          disabled={all}
                          onChange={(e) => toggle(name, e.target.checked)}
                        />
                        {name.slice(g.entity.length + 1).replace(/_/g, ' ')}
                      </label>
                    ))}
                    <label className="flex items-center gap-1.5 text-sm text-secondary-700 cursor-pointer ml-auto">
                      <input
                        type="checkbox"
                        className="h-4 w-4 rounded border-secondary-300 text-primary-600 focus:ring-primary-500"
                        checked={all}
                        onChange={(e) => toggle(`${g.entity}.*`, e.target.checked)}
                      />
                      all
                    </label>
                  </>
                ) : (
                  <span className="flex items-center gap-1.5 text-xs text-secondary-500">
                    <Lock className="w-3.5 h-3.5" /> Your role can&apos;t read this data
                  </span>
                )}
              </div>
            );
          })}
        </div>
        {errors.events && (
          <p className="mt-1.5 text-sm text-error-600" role="alert">
            {errors.events}
          </p>
        )}
      </fieldset>

      {webhook && (
        <CheckboxField
          label="Active"
          hint="Paused webhooks receive nothing; events that happen meanwhile aren't sent later."
          checked={active}
          onChange={setActive}
        />
      )}

      <div className="flex justify-end gap-3 pt-1">
        <Button type="button" variant="outline" onClick={onClose} disabled={saving}>
          Cancel
        </Button>
        <Button type="submit" isLoading={saving}>
          {webhook ? 'Save changes' : 'Add webhook'}
        </Button>
      </div>
    </form>
  );
}

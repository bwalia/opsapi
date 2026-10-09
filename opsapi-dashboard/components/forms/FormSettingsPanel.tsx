'use client';

/** The Settings tab: after-submit behaviour, limits, emails and retention. Saved explicitly. */

import React, { useEffect, useState } from 'react';
import toast from 'react-hot-toast';
import { Button, Card, Input, Switch, Textarea } from '@/components/ui';
import { apiError } from '@/components/field-service/shared';
import type { Form, FormSettings } from '@/services/forms.service';

function Section({ title, description, children }: { title: string; description?: string; children: React.ReactNode }) {
  return (
    <Card padding="md" className="space-y-4">
      <div>
        <h2 className="text-base font-semibold text-secondary-900">{title}</h2>
        {description && <p className="mt-0.5 text-sm text-secondary-500">{description}</p>}
      </div>
      {children}
    </Card>
  );
}

/** "2026-12-31T17:00:00Z" <-> the local value of <input type="datetime-local">. */
function toLocalInput(iso?: string) {
  if (!iso) return '';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export default function FormSettingsPanel({ form, onSave, readOnly }: {
  form: Form; onSave: (settings: FormSettings) => Promise<void>; readOnly?: boolean;
}) {
  const [s, setS] = useState<FormSettings>(form.settings || {});
  const [emails, setEmails] = useState((form.settings?.notify_emails || []).join(', '));
  const [closeAt, setCloseAt] = useState(toLocalInput(form.settings?.close_at));
  const [saving, setSaving] = useState(false);
  const [errors, setErrors] = useState<Record<string, string>>({});

  useEffect(() => {
    setS(form.settings || {});
    setEmails((form.settings?.notify_emails || []).join(', '));
    setCloseAt(toLocalInput(form.settings?.close_at));
  }, [form.uuid, form.settings]);

  const save = async () => {
    const errs: Record<string, string> = {};
    if (s.redirect_url && !/^https:\/\//.test(s.redirect_url)) errs.redirect_url = 'Use an https:// address.';
    const list = emails.split(/[,\s]+/).map((e) => e.trim()).filter(Boolean);
    if (list.some((e) => !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e))) errs.notify_emails = 'One of these is not an email address.';
    if (s.auto_reply?.enabled && (!s.auto_reply.subject?.trim() || !s.auto_reply.body?.trim())) {
      errs.auto_reply = 'An auto-reply needs a subject and a message.';
    }
    setErrors(errs);
    if (Object.keys(errs).length) return;
    setSaving(true);
    try {
      // null clears a setting on the server ("" too); absent keys keep it.
      const clear = <T,>(v: T | undefined | '') => (v === undefined || v === '' ? null : v);
      await onSave({
        success_message: clear(s.success_message),
        closed_message: clear(s.closed_message),
        redirect_url: clear(s.redirect_url),
        max_submissions: clear(s.max_submissions),
        retention_days: clear(s.retention_days),
        close_at: closeAt ? new Date(closeAt).toISOString() : null,
        notify_emails: list.length ? list : null,
        auto_reply: s.auto_reply?.enabled || s.auto_reply?.subject || s.auto_reply?.body ? s.auto_reply : null,
      } as unknown as FormSettings);
      toast.success('Settings saved');
    } catch (e) {
      toast.error(apiError(e, 'Could not save the settings'));
    } finally {
      setSaving(false);
    }
  };

  const reply = s.auto_reply || { enabled: false };
  return (
    <fieldset disabled={readOnly} className="mx-auto max-w-3xl space-y-5">
      <Section title="After someone submits">
        <Textarea label="Thank-you message" rows={3} maxLength={1000} value={s.success_message || ''}
          placeholder="Thanks — your response has been received."
          onChange={(e) => setS({ ...s, success_message: e.target.value })} />
        <Input label="Or send them to a page (optional)" placeholder="https://example.com/thank-you" value={s.redirect_url || ''}
          error={errors.redirect_url} onChange={(e) => setS({ ...s, redirect_url: e.target.value })} />
      </Section>

      <Section title="Close the form automatically" description="People see the closed message instead of the form.">
        <div className="grid gap-4 sm:grid-cols-2">
          <Input label="Close on" type="datetime-local" value={closeAt} onChange={(e) => setCloseAt(e.target.value)} />
          <Input label="After this many responses" inputMode="numeric" value={s.max_submissions ?? ''}
            onChange={(e) => setS({ ...s, max_submissions: e.target.value ? Number(e.target.value.replace(/\D/g, '')) : undefined })} />
        </div>
        <Textarea label="Closed message" rows={2} maxLength={500} value={s.closed_message || ''}
          placeholder="This form is no longer accepting responses."
          onChange={(e) => setS({ ...s, closed_message: e.target.value })} />
      </Section>

      <Section title="Emails">
        <Input label="Tell these people about each new response" value={emails} error={errors.notify_emails}
          helperText="Comma-separated, up to 10. Empty = the person who created the form."
          placeholder="sales@example.com, owner@example.com" onChange={(e) => setEmails(e.target.value)} />
        <div className="flex items-center justify-between gap-3 border-t border-secondary-100 pt-4">
          <div>
            <p className="text-sm font-medium text-secondary-800">Reply to the person who answered</p>
            <p className="text-xs text-secondary-500">Sent to the email they gave. Use {'{{answer_key}}'} to include an answer.</p>
          </div>
          <Switch checked={!!reply.enabled} aria-label="Send an auto-reply"
            onChange={(b) => setS({ ...s, auto_reply: { ...reply, enabled: b } })} />
        </div>
        {reply.enabled && (
          <div className="space-y-3">
            <Input label="Subject" maxLength={200} value={reply.subject || ''} placeholder="Thanks, {{name}}"
              onChange={(e) => setS({ ...s, auto_reply: { ...reply, subject: e.target.value } })} />
            <Textarea label="Message" rows={5} maxLength={5000} value={reply.body || ''}
              placeholder={'Hi {{name}},\nthanks for getting in touch. We will reply within one working day.'}
              error={errors.auto_reply} onChange={(e) => setS({ ...s, auto_reply: { ...reply, body: e.target.value } })} />
            <p className="text-xs text-secondary-500">
              Answer keys: {form.schema.fields.filter((f) => f.key && !['heading', 'paragraph'].includes(f.type))
                .map((f) => `{{${f.key}}}`).join('  ')}
            </p>
          </div>
        )}
      </Section>

      <Section title="Keep responses" description="Responses older than this are deleted automatically. Leave empty to keep them.">
        <Input label="Days" inputMode="numeric" value={s.retention_days ?? ''} placeholder="e.g. 365"
          onChange={(e) => setS({ ...s, retention_days: e.target.value ? Number(e.target.value.replace(/\D/g, '')) : undefined })} />
      </Section>

      {!readOnly && (
        <div className="flex justify-end">
          <Button onClick={save} isLoading={saving}>Save settings</Button>
        </div>
      )}
    </fieldset>
  );
}

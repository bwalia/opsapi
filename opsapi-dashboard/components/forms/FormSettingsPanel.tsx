'use client';

/** The Settings tab: after-submit behaviour, limits, emails and retention. Saved explicitly. */

import React, { useEffect, useState } from 'react';
import Link from 'next/link';
import toast from 'react-hot-toast';
import { AlertTriangle, MailCheck } from 'lucide-react';
import { chatService, type ChatChannel } from '@/services/chat.service';
import SpamProtectionModal from './SpamProtectionModal';
import { Button, Card, Input, Select, Switch, Textarea } from '@/components/ui';
import { apiError } from '@/components/field-service/shared';
import { formsService, type Form, type FormSettings } from '@/services/forms.service';

/** Where this workspace's emails go out from, with the way to set up its own server. */
function EmailVia({ via }: { via?: Form['email_via'] }) {
  if (!via) return null;
  const none = via === 'none';
  return (
    <div className={`flex items-start gap-2.5 rounded-lg p-3 text-sm ${none ? 'bg-warning-500/10 text-warning-600' : 'bg-secondary-50 text-secondary-600'}`}>
      {none ? <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
        : <MailCheck className="mt-0.5 h-4 w-4 shrink-0 text-success-600" aria-hidden="true" />}
      <p>
        {via === 'workspace' && 'Emails go out from your workspace\'s own email server. '}
        {via === 'platform' && 'Emails go out from the platform\'s email server. Set up your own to send from your domain. '}
        {none && 'No email server is set up, so none of these emails will be sent (responses are still saved). '}
        <Link href="/dashboard/namespace/email" className="font-medium underline">
          {via === 'workspace' ? 'Email settings' : 'Set up your email server'}
        </Link>
      </p>
    </div>
  );
}

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
  const [channels, setChannels] = useState<ChatChannel[] | null>(null);
  const [spamOpen, setSpamOpen] = useState(false);
  const [spamReady, setSpamReady] = useState<boolean | null>(null);

  // Chat channels (if chat is on here) and whether Turnstile keys exist.
  useEffect(() => {
    chatService.listChannels().then(setChannels).catch(() => setChannels(null));
    formsService.workspaceSettings()
      .then((w) => setSpamReady(!!w.turnstile.site_key && w.turnstile.has_secret)).catch(() => setSpamReady(null));
  }, []);

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
    if (s.theme?.logo_url && !/^https:\/\//.test(s.theme.logo_url)) errs.logo_url = 'Use an https:// address.';
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
        theme: s.theme && Object.values(s.theme).some(Boolean) ? s.theme : null,
        captcha: !!s.captcha,
        notify_in_app: s.notify_in_app !== false,
        chat_channel_uuid: clear(s.chat_channel_uuid),
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
        <EmailVia via={form.email_via} />
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

      <Section title="Alerts" description="Besides email: tell the team in the app and in chat.">
        <div className="flex items-center justify-between gap-3">
          <div>
            <p className="text-sm font-medium text-secondary-800">In-app notification</p>
            <p className="text-xs text-secondary-500">To you and the notify addresses that are members of this workspace.</p>
          </div>
          <Switch checked={s.notify_in_app !== false} aria-label="In-app notification"
            onChange={(b) => setS({ ...s, notify_in_app: b })} />
        </div>
        {channels !== null && (
          <Select label="Post each new response to a chat channel" value={s.chat_channel_uuid || ''}
            onChange={(e) => setS({ ...s, chat_channel_uuid: e.target.value || undefined })}>
            <option value="">Don&apos;t post</option>
            {channels.filter((c) => (c.type || c.channel_type) !== 'direct').map((c) => (
              <option key={c.uuid} value={c.uuid}>#{c.name}</option>
            ))}
          </Select>
        )}
      </Section>

      <Section title="Branding" description="How the public page looks.">
        <div className="grid gap-4 sm:grid-cols-2">
          <ColorInput label="Main colour (buttons, highlights)" value={s.theme?.primary_color}
            onChange={(v) => setS({ ...s, theme: { ...s.theme, primary_color: v } })} />
          <ColorInput label="Page background" value={s.theme?.background} fallback="#f8fafc"
            onChange={(v) => setS({ ...s, theme: { ...s.theme, background: v } })} />
        </div>
        <Input label="Logo (image address)" placeholder="https://example.com/logo.png" value={s.theme?.logo_url || ''}
          error={errors.logo_url} helperText="Empty = your workspace's logo."
          onChange={(e) => setS({ ...s, theme: { ...s.theme, logo_url: e.target.value || undefined } })} />
        <Input label="Submit button text" placeholder="Submit" maxLength={40} value={s.theme?.submit_label || ''}
          onChange={(e) => setS({ ...s, theme: { ...s.theme, submit_label: e.target.value || undefined } })} />
        <div className="flex items-center justify-between gap-3">
          <span className="text-sm font-medium text-secondary-800">Hide &ldquo;Powered by OpsAPI&rdquo;</span>
          <Switch checked={!!s.theme?.hide_branding} aria-label="Hide Powered by"
            onChange={(b) => setS({ ...s, theme: { ...s.theme, hide_branding: b || undefined } })} />
        </div>
      </Section>

      <Section title="Spam protection" description="Bots are already filtered (a hidden trap field, a minimum time, rate limits).">
        <div className="flex items-center justify-between gap-3">
          <div>
            <p className="text-sm font-medium text-secondary-800">&ldquo;I&apos;m not a robot&rdquo; check (Cloudflare Turnstile)</p>
            <p className="text-xs text-secondary-500">
              {spamReady === false ? 'Add your workspace’s Turnstile keys first. ' : 'For forms that attract spam. '}
              <button type="button" className="font-medium text-primary-600 hover:underline" onClick={() => setSpamOpen(true)}>
                {spamReady ? 'Workspace keys' : 'Set up Turnstile'}
              </button>
            </p>
          </div>
          <Switch checked={!!s.captcha} aria-label="Turnstile check" disabled={spamReady === false && !s.captcha}
            onChange={(b) => setS({ ...s, captcha: b })} />
        </div>
      </Section>
      <SpamProtectionModal open={spamOpen} onClose={() => setSpamOpen(false)}
        onSaved={(w) => setSpamReady(!!w.turnstile.site_key && w.turnstile.has_secret)} />

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

function ColorInput({ label, value, onChange, fallback = '#ff004e' }: {
  label: string; value?: string; onChange: (v?: string) => void; fallback?: string;
}) {
  return (
    <div>
      <label className="mb-1.5 block text-sm font-medium text-secondary-700">{label}</label>
      <div className="flex items-center gap-2">
        <input type="color" aria-label={label} value={value || fallback} onChange={(e) => onChange(e.target.value)}
          className="h-10 w-12 cursor-pointer rounded-lg border border-secondary-300 bg-surface p-1" />
        <input aria-label={`${label} (hex)`} value={value || ''} placeholder="Default" maxLength={7}
          onChange={(e) => onChange(/^#[0-9a-fA-F]{6}$/.test(e.target.value) ? e.target.value : e.target.value || undefined)}
          className="h-10 w-28 rounded-lg border border-secondary-300 bg-surface px-3 font-mono text-sm" />
        {value && <button type="button" onClick={() => onChange(undefined)} className="text-xs text-secondary-500 hover:underline">Reset</button>}
      </div>
    </div>
  );
}

'use client';

/**
 * Workspace → Email — /dashboard/namespace/email
 *
 * The workspace's own SMTP server (falls back to the platform's) and its
 * versions of the built-in emails. Templates use {{placeholders}}; every email
 * has a default that "Reset" brings back.
 */

import React, { useCallback, useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import toast from 'react-hot-toast';
import { ArrowLeft, Mail, RotateCcw, Send } from 'lucide-react';
import { Button, Card, ConfirmDialog, Input, Modal, Select, Switch, Textarea } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { usePermissions } from '@/contexts/PermissionsContext';
import { apiError, Pill } from '@/components/field-service/shared';
import { formatRelativeTime } from '@/lib/utils';
import { namespaceMailService, type EmailTemplate, type MailSettings } from '@/services/namespace-mail.service';

function SmtpCard({ editable }: { editable: boolean }) {
  const [current, setCurrent] = useState<MailSettings | null>(null);
  const [host, setHost] = useState('');
  const [port, setPort] = useState('587');
  const [security, setSecurity] = useState<'starttls' | 'ssl' | 'none'>('starttls');
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [fromEmail, setFromEmail] = useState('');
  const [fromName, setFromName] = useState('');
  const [replyTo, setReplyTo] = useState('');
  const [enabled, setEnabled] = useState(true);
  const [saving, setSaving] = useState(false);
  const [testTo, setTestTo] = useState('');
  const [testing, setTesting] = useState(false);
  const [removeOpen, setRemoveOpen] = useState(false);

  const fill = (m: MailSettings) => {
    setCurrent(m);
    setHost(m.host || '');
    setPort(String(m.port || 587));
    setSecurity(m.security || 'starttls');
    setUsername(m.username || '');
    setPassword('');
    setFromEmail(m.from_email || '');
    setFromName(m.from_name || '');
    setReplyTo(m.reply_to || '');
    setEnabled(m.enabled ?? true);
  };

  useEffect(() => {
    namespaceMailService.getSettings().then(fill).catch((err) => toast.error(apiError(err, 'Failed to load email settings')));
  }, []);

  const save = async (e: React.FormEvent) => {
    e.preventDefault();
    setSaving(true);
    try {
      fill(
        await namespaceMailService.saveSettings({
          host: host.trim(),
          port: Number(port),
          security,
          username: username.trim(),
          ...(password ? { password } : {}),
          from_email: fromEmail.trim(),
          from_name: fromName.trim(),
          reply_to: replyTo.trim(),
          enabled,
        })
      );
      toast.success('Email settings saved');
    } catch (err) {
      toast.error(apiError(err, 'Could not save'));
    } finally {
      setSaving(false);
    }
  };

  const test = async () => {
    setTesting(true);
    try {
      await namespaceMailService.test(testTo.trim());
      toast.success(`Test email sent to ${testTo.trim()}`);
    } catch (err) {
      toast.error(apiError(err, 'The test email failed'));
    } finally {
      setTesting(false);
      namespaceMailService.getSettings().then(fill).catch(() => undefined);
    }
  };

  const remove = async () => {
    try {
      await namespaceMailService.removeSettings();
      fill({ configured: false });
      setRemoveOpen(false);
      toast.success('Back to the platform email server');
    } catch (err) {
      toast.error(apiError(err, 'Could not remove'));
    }
  };

  return (
    <Card className="shadow-sm">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 className="text-base font-semibold text-secondary-900">Email server (SMTP)</h2>
          <p className="text-sm text-secondary-500">
            Emails from this workspace (account links, licence keys) are sent through this server. Without one, the
            platform&apos;s server is used.
          </p>
        </div>
        {current?.configured && (
          <Pill className={current.last_error ? 'bg-red-50 text-red-700' : current.last_tested_at ? 'bg-green-50 text-green-700' : 'bg-secondary-100 text-secondary-600'}>
            {current.last_error ? 'Last test failed' : current.last_tested_at ? `Tested ${formatRelativeTime(current.last_tested_at)}` : 'Not tested'}
          </Pill>
        )}
      </div>
      {current?.last_error && (
        <p className="mt-2 rounded-lg bg-red-50 p-2 text-sm text-red-700" role="alert">
          {current.last_error}
        </p>
      )}
      <form onSubmit={save} className="mt-4 space-y-4">
        <fieldset disabled={!editable} className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <Input label="Server" value={host} onChange={(e) => setHost(e.target.value)} placeholder="smtp.example.com" required />
          <div className="grid grid-cols-2 gap-3">
            <Input label="Port" type="number" min={1} max={65535} value={port} onChange={(e) => setPort(e.target.value)} required />
            <Select label="Security" value={security} onChange={(e) => setSecurity(e.target.value as typeof security)}>
              <option value="starttls">STARTTLS</option>
              <option value="ssl">SSL/TLS</option>
              <option value="none">None</option>
            </Select>
          </div>
          <Input label="Username" value={username} onChange={(e) => setUsername(e.target.value)} autoComplete="off" />
          <Input
            label="Password"
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            autoComplete="new-password"
            placeholder={current?.has_password ? 'Saved — leave blank to keep' : ''}
          />
          <Input label="From address" type="email" value={fromEmail} onChange={(e) => setFromEmail(e.target.value)} placeholder="billing@example.com" required />
          <Input label="From name" value={fromName} onChange={(e) => setFromName(e.target.value)} placeholder="Example Ltd" helperText="Billing emails use the app's display name." />
          <Input label="Reply-to (optional)" type="email" value={replyTo} onChange={(e) => setReplyTo(e.target.value)} />
          <div className="flex items-center justify-between rounded-lg border border-secondary-200 px-3 py-2">
            <div>
              <p className="text-sm font-medium text-secondary-800">Use this server</p>
              <p className="text-xs text-secondary-500">Turn off to fall back to the platform&apos;s server.</p>
            </div>
            <Switch checked={enabled} onChange={setEnabled} aria-label="Use this server" />
          </div>
        </fieldset>
        {editable && (
          <div className="flex flex-wrap items-center justify-between gap-2">
            {current?.configured ? (
              <Button type="button" variant="ghost" className="text-error-600" onClick={() => setRemoveOpen(true)}>
                Remove
              </Button>
            ) : (
              <span />
            )}
            <Button type="submit" isLoading={saving}>
              Save
            </Button>
          </div>
        )}
      </form>
      {editable && current?.configured && (
        <div className="mt-4 flex flex-wrap items-end gap-2 border-t border-secondary-100 pt-4">
          <div className="flex-1 min-w-[220px]">
            <Input label="Send a test email to" type="email" value={testTo} onChange={(e) => setTestTo(e.target.value)} />
          </div>
          <Button type="button" variant="outline" onClick={test} isLoading={testing} disabled={!testTo.trim()}>
            <Send className="w-4 h-4 mr-1.5" /> Send test
          </Button>
        </div>
      )}
      <ConfirmDialog
        isOpen={removeOpen}
        onClose={() => setRemoveOpen(false)}
        onConfirm={remove}
        title="Remove this email server?"
        message="This workspace's emails will be sent through the platform's server again."
        confirmText="Remove"
        variant="warning"
      />
    </Card>
  );
}

function TemplateEditor({ template, onClose, onSaved }: { template: EmailTemplate | null; onClose: () => void; onSaved: () => void }) {
  const [subject, setSubject] = useState('');
  const [html, setHtml] = useState('');
  const [preview, setPreview] = useState<{ subject: string; html: string } | null>(null);
  const [saving, setSaving] = useState(false);
  const textRef = useRef<HTMLTextAreaElement | null>(null);

  useEffect(() => {
    if (!template) return;
    namespaceMailService
      .preview(template.key)
      .then((p) => {
        setPreview(p);
        setSubject(template.subject);
        // No custom body yet: start from the default's text so it's easy to edit.
        setHtml(template.html || '');
      })
      .catch(() => setPreview(null));
  }, [template]);

  useEffect(() => {
    if (!template || !html) return;
    const t = setTimeout(() => {
      namespaceMailService.preview(template.key, { subject, html }).then(setPreview).catch(() => undefined);
    }, 400);
    return () => clearTimeout(t);
  }, [template, subject, html]);

  const insert = (v: string) => {
    const el = textRef.current;
    const token = `{{${v}}}`;
    if (!el) return setHtml((h) => h + token);
    const { selectionStart: a, selectionEnd: b } = el;
    setHtml((h) => h.slice(0, a) + token + h.slice(b));
  };

  const save = async () => {
    if (!template) return;
    setSaving(true);
    try {
      await namespaceMailService.saveTemplate(template.key, subject, html);
      toast.success('Template saved');
      onSaved();
    } catch (err) {
      toast.error(apiError(err, 'Could not save the template'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal isOpen={!!template} onClose={onClose} title={template ? `Edit: ${template.name}` : ''} size="3xl">
      {template && (
        <div className="grid gap-5 lg:grid-cols-2">
          <div className="space-y-4">
            <Input label="Subject" value={subject} onChange={(e) => setSubject(e.target.value)} />
            <div>
              <p className="text-sm font-medium text-secondary-700 mb-1">Variables (click to insert)</p>
              <div className="flex flex-wrap gap-1.5">
                {template.variables.map((v) => (
                  <button
                    key={v}
                    type="button"
                    onClick={() => insert(v)}
                    className="rounded-md border border-secondary-200 bg-secondary-50 px-2 py-1 font-mono text-xs text-secondary-700 hover:border-primary-300"
                  >
                    {`{{${v}}}`}
                  </button>
                ))}
              </div>
            </div>
            <Textarea
              ref={textRef}
              label="Body (HTML)"
              value={html}
              onChange={(e) => setHtml(e.target.value)}
              rows={14}
              placeholder={'<h2>Your {{app_name}} account</h2>\n<p><a href="{{link}}">Open my account</a></p>'}
              className="font-mono text-xs"
              helperText="Leave empty and save to keep the built-in design. Values are escaped; no scripts run."
            />
            <div className="flex justify-end gap-2">
              <Button type="button" variant="outline" onClick={onClose}>
                Cancel
              </Button>
              <Button type="button" onClick={save} isLoading={saving} disabled={!subject.trim() || !html.trim()}>
                Save template
              </Button>
            </div>
          </div>
          <div>
            <p className="text-sm font-medium text-secondary-700 mb-1">Preview (sample data)</p>
            <p className="text-sm text-secondary-900 mb-2">
              <span className="text-secondary-500">Subject:</span> {preview?.subject}
            </p>
            <iframe
              title="Email preview"
              sandbox=""
              srcDoc={preview?.html || ''}
              className="h-[480px] w-full rounded-lg border border-secondary-200 bg-white"
            />
          </div>
        </div>
      )}
    </Modal>
  );
}

function EmailContent() {
  const { hasPermission } = usePermissions();
  const editable = hasPermission('namespace', 'update');
  const [templates, setTemplates] = useState<EmailTemplate[]>([]);
  const [editing, setEditing] = useState<EmailTemplate | null>(null);
  const [resetTarget, setResetTarget] = useState<EmailTemplate | null>(null);

  const load = useCallback(() => {
    namespaceMailService.listTemplates().then(setTemplates).catch((err) => toast.error(apiError(err, 'Failed to load templates')));
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const reset = async () => {
    if (!resetTarget) return;
    try {
      await namespaceMailService.resetTemplate(resetTarget.key);
      toast.success('Back to the built-in template');
      setResetTarget(null);
      load();
    } catch (err) {
      toast.error(apiError(err, 'Could not reset'));
    }
  };

  return (
    <div className="space-y-6">
      <Link href="/dashboard/namespace" className="inline-flex items-center text-sm text-secondary-500 hover:text-secondary-800">
        <ArrowLeft className="w-4 h-4 mr-1" /> My workspace
      </Link>
      <PageHeader title="Email" description="Your own email server and the emails this workspace sends." icon={<Mail className="w-5 h-5" />} />
      <SmtpCard editable={editable} />
      <Card className="shadow-sm">
        <h2 className="text-base font-semibold text-secondary-900">Templates</h2>
        <p className="text-sm text-secondary-500">Every email has a built-in design. Change the subject or body to make it yours.</p>
        <ul className="mt-4 divide-y divide-secondary-100 rounded-lg border border-secondary-200">
          {templates.map((t) => (
            <li key={t.key} className="flex flex-wrap items-center justify-between gap-3 px-4 py-3">
              <div className="min-w-0">
                <p className="font-medium text-secondary-900">
                  {t.name}{' '}
                  {t.customised ? (
                    <Pill className="bg-primary-50 text-primary-700">Customised</Pill>
                  ) : (
                    <Pill className="bg-secondary-100 text-secondary-600">Built-in</Pill>
                  )}
                </p>
                <p className="text-xs text-secondary-500 truncate">Subject: {t.subject}</p>
              </div>
              <div className="flex gap-2">
                {t.customised && editable && (
                  <Button size="sm" variant="ghost" onClick={() => setResetTarget(t)}>
                    <RotateCcw className="w-4 h-4 mr-1" /> Reset
                  </Button>
                )}
                <Button size="sm" variant="outline" onClick={() => setEditing(t)} disabled={!editable}>
                  {t.customised ? 'Edit' : 'Customise'}
                </Button>
              </div>
            </li>
          ))}
        </ul>
      </Card>
      <TemplateEditor
        template={editing}
        onClose={() => setEditing(null)}
        onSaved={() => {
          setEditing(null);
          load();
        }}
      />
      <ConfirmDialog
        isOpen={!!resetTarget}
        onClose={() => setResetTarget(null)}
        onConfirm={reset}
        title="Reset to the built-in template?"
        message="Your subject and body for this email are removed."
        confirmText="Reset"
        variant="warning"
      />
    </div>
  );
}

export default function NamespaceEmailPage() {
  return (
    <ProtectedPage module="namespace" title="Email">
      <EmailContent />
    </ProtectedPage>
  );
}

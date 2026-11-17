'use client';

/**
 * Workspace → Email — /dashboard/namespace/email
 *
 * The workspace's own SMTP accounts, which account sends which kind of email
 * (leads, follow-ups, shop, invoices…; falls back to the default account, then
 * the platform's server), and its versions of the built-in emails. Templates use {{placeholders}}; every email
 * has a default that "Reset" brings back.
 */

import React, { useCallback, useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import toast from 'react-hot-toast';
import { ArrowLeft, Mail, Pencil, Plus, RotateCcw, Send, Star, Trash2 } from 'lucide-react';
import { Button, Card, ConfirmDialog, Input, Modal, Select, Switch, Textarea } from '@/components/ui';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { usePermissions } from '@/contexts/PermissionsContext';
import { apiError, Pill } from '@/components/field-service/shared';
import { formatRelativeTime } from '@/lib/utils';
import {
  namespaceMailService,
  type EmailTemplate,
  type MailAccount,
  type MailAccountInput,
  type MailAccountsOverview,
  type MailRoute,
  type MailSecurity,
} from '@/services/namespace-mail.service';

type AccountForm = {
  name: string; host: string; port: string; security: MailSecurity; username: string; password: string;
  fromEmail: string; fromName: string; replyTo: string; enabled: boolean; isDefault: boolean;
};

const blankForm = (first: boolean): AccountForm => ({
  name: first ? 'Main' : '', host: '', port: '587', security: 'starttls', username: '', password: '',
  fromEmail: '', fromName: '', replyTo: '', enabled: true, isDefault: first,
});

function AccountDialog({ account, first, othersOn, onClose, onSaved }: {
  account: MailAccount | 'new' | null; first: boolean;
  /** Other accounts that are switched on (the default can't be switched off while there are any). */
  othersOn: number;
  onClose: () => void; onSaved: () => void;
}) {
  const [form, setForm] = useState<AccountForm>(blankForm(first));
  const [saving, setSaving] = useState(false);
  const editing = account && account !== 'new' ? account : null;

  useEffect(() => {
    if (!account) return;
    if (account === 'new') return setForm(blankForm(first));
    setForm({
      name: account.name, host: account.host, port: String(account.port), security: account.security,
      username: account.username || '', password: '', fromEmail: account.from_email, fromName: account.from_name || '',
      replyTo: account.reply_to || '', enabled: account.enabled, isDefault: account.is_default,
    });
  }, [account, first]);

  const set = <K extends keyof AccountForm>(k: K, v: AccountForm[K]) => setForm((f) => ({ ...f, [k]: v }));

  const save = async (e: React.FormEvent) => {
    e.preventDefault();
    setSaving(true);
    const input: MailAccountInput = {
      name: form.name.trim(), host: form.host.trim(), port: Number(form.port), security: form.security,
      username: form.username.trim(), ...(form.password ? { password: form.password } : {}),
      from_email: form.fromEmail.trim(), from_name: form.fromName.trim(), reply_to: form.replyTo.trim(),
      enabled: form.enabled, ...(form.isDefault ? { is_default: true } : {}),
    };
    try {
      if (editing) await namespaceMailService.updateAccount(editing.uuid, input);
      else await namespaceMailService.createAccount(input);
      toast.success(editing ? 'Email account saved' : 'Email account added');
      onSaved();
    } catch (err) {
      toast.error(apiError(err, 'Could not save the email account'));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal isOpen={!!account} onClose={onClose} title={editing ? `Edit ${editing.name}` : 'Add an email account'} size="2xl">
      <form onSubmit={save} className="space-y-4">
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <Input label="Name" value={form.name} onChange={(e) => set('name', e.target.value)} placeholder="Sales, Support, Shop…"
            helperText="Only you see this; it's how you pick the account below." required maxLength={80} />
          <Input label="Server" value={form.host} onChange={(e) => set('host', e.target.value)} placeholder="smtp.example.com" required />
          <div className="grid grid-cols-2 gap-3">
            <Input label="Port" type="number" min={1} max={65535} value={form.port} onChange={(e) => set('port', e.target.value)} required />
            <Select label="Security" value={form.security} onChange={(e) => set('security', e.target.value as MailSecurity)}>
              <option value="starttls">STARTTLS</option>
              <option value="ssl">SSL/TLS</option>
              <option value="none">None</option>
            </Select>
          </div>
          <Input label="Username" value={form.username} onChange={(e) => set('username', e.target.value)} autoComplete="off" />
          <Input label="Password" type="password" value={form.password} onChange={(e) => set('password', e.target.value)}
            autoComplete="new-password" placeholder={editing?.has_password ? 'Saved — leave blank to keep' : ''} />
          <Input label="From address" type="email" value={form.fromEmail} onChange={(e) => set('fromEmail', e.target.value)}
            placeholder="sales@example.com" required />
          <Input label="From name" value={form.fromName} onChange={(e) => set('fromName', e.target.value)} placeholder="Example Ltd Sales" />
          <Input label="Reply-to (optional)" type="email" value={form.replyTo} onChange={(e) => set('replyTo', e.target.value)} />
        </div>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <div className="flex items-center justify-between rounded-lg border border-secondary-200 px-3 py-2">
            <div>
              <p className="text-sm font-medium text-secondary-800">Use this account</p>
              <p className="text-xs text-secondary-500">
                {editing?.is_default && othersOn > 0
                  ? 'The default stays on. To switch it off, make another account the default first.'
                  : 'Off: its emails go through the default instead.'}
              </p>
            </div>
            <Switch checked={form.enabled} onChange={(v) => set('enabled', v)} aria-label="Use this account"
              disabled={!!editing?.is_default && othersOn > 0 && form.enabled} />
          </div>
          <div className="flex items-center justify-between rounded-lg border border-secondary-200 px-3 py-2">
            <div>
              <p className="text-sm font-medium text-secondary-800">Default account</p>
              <p className="text-xs text-secondary-500">Sends every email not given another account.</p>
            </div>
            <Switch checked={form.isDefault} onChange={(v) => set('isDefault', v)} aria-label="Default account"
              disabled={!!editing?.is_default} />
          </div>
        </div>
        <div className="flex justify-end gap-2">
          <Button type="button" variant="outline" onClick={onClose}>Cancel</Button>
          <Button type="submit" isLoading={saving}>{editing ? 'Save' : 'Add account'}</Button>
        </div>
      </form>
    </Modal>
  );
}

function accountStatus(a: MailAccount) {
  if (!a.enabled) return { text: 'Off', cls: 'bg-secondary-100 text-secondary-600' };
  if (a.last_error) return { text: 'Last test failed', cls: 'bg-red-50 text-red-700' };
  if (a.last_tested_at) return { text: `Tested ${formatRelativeTime(a.last_tested_at)}`, cls: 'bg-green-50 text-green-700' };
  return { text: 'Not tested', cls: 'bg-secondary-100 text-secondary-600' };
}

function MailAccounts({ editable }: { editable: boolean }) {
  const [overview, setOverview] = useState<MailAccountsOverview | null>(null);
  const [editing, setEditing] = useState<MailAccount | 'new' | null>(null);
  const [testing, setTesting] = useState<MailAccount | null>(null);
  const [testTo, setTestTo] = useState('');
  const [sending, setSending] = useState(false);
  const [removing, setRemoving] = useState<MailAccount | null>(null);
  const [savingRoute, setSavingRoute] = useState<string | null>(null);

  const load = useCallback(() => {
    namespaceMailService.overview().then(setOverview).catch((err) => toast.error(apiError(err, 'Failed to load email accounts')));
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const accounts = overview?.accounts ?? [];
  const byUuid = new Map(accounts.map((a) => [a.uuid, a]));
  const defaultAccount = accounts.find((a) => a.is_default);
  const platform = overview?.platform;
  const platformLabel = platform?.configured ? `Platform server (${platform.from_email})` : 'Platform server (not set up)';

  const sendTest = async () => {
    if (!testing) return;
    setSending(true);
    try {
      await namespaceMailService.testAccount(testing.uuid, testTo.trim());
      toast.success(`Test email sent to ${testTo.trim()} from ${testing.name}`);
      setTesting(null);
    } catch (err) {
      toast.error(apiError(err, 'The test email failed'));
    } finally {
      setSending(false);
      load();
    }
  };

  const remove = async () => {
    if (!removing) return;
    try {
      const res = await namespaceMailService.deleteAccount(removing.uuid);
      toast.success(
        res.new_default ? `${removing.name} removed. ${res.new_default} is now the default.` : `${removing.name} removed`,
      );
      setRemoving(null);
      load();
    } catch (err) {
      toast.error(apiError(err, 'Could not remove'));
    }
  };

  const makeDefault = async (a: MailAccount) => {
    try {
      await namespaceMailService.makeDefault(a.uuid);
      toast.success(`${a.name} is now the default`);
      load();
    } catch (err) {
      toast.error(apiError(err, 'Could not change the default'));
    }
  };

  const route = async (key: string, uuid: string) => {
    setSavingRoute(key);
    try {
      const routing = await namespaceMailService.saveRouting({ [key]: uuid || null });
      setOverview((o) => (o ? { ...o, routing } : o));
      load();
    } catch (err) {
      toast.error(apiError(err, 'Could not change the account'));
    } finally {
      setSavingRoute(null);
    }
  };

  // What actually sends a purpose's email, for the hint under each row.
  const effective = (key: string, uuid: string | null) => {
    const chosen = uuid ? byUuid.get(uuid) : undefined;
    if (chosen && chosen.enabled) return chosen.from_email;
    if (key !== 'default' && defaultAccount?.enabled) return `${defaultAccount.from_email} (default)`;
    return platform?.configured ? `${platform.from_email} (platform)` : 'nothing — no server is set up';
  };

  return (
    <>
      <Card className="shadow-sm">
        <div className="flex flex-wrap items-start justify-between gap-2">
          <div>
            <h2 className="text-base font-semibold text-secondary-900">Email accounts (SMTP)</h2>
            <p className="text-sm text-secondary-500">
              Add a server for each address you send from — e.g. sales@ for new enquiries, support@ for questions to
              customers. Without any, the platform&apos;s server is used.
            </p>
          </div>
          {editable && (
            <Button size="sm" onClick={() => setEditing('new')}>
              <Plus className="w-4 h-4 mr-1" /> Add account
            </Button>
          )}
        </div>
        {overview && accounts.some((a) => a.enabled) && !(defaultAccount && defaultAccount.enabled) && (
          <p role="status" className="mt-4 rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-900">
            {defaultAccount
              ? `The default account, ${defaultAccount.name}, is switched off`
              : 'There is no default account'}
            , so emails without an account of their own go through the{' '}
            {platformLabel.charAt(0).toLowerCase() + platformLabel.slice(1)}. To send them from your own address, pick a
            default under &ldquo;Which account sends what&rdquo;.
          </p>
        )}
        {!overview ? null : accounts.length === 0 ? (
          <p className="mt-4 rounded-lg border border-dashed border-secondary-300 p-4 text-sm text-secondary-500">
            No email accounts yet. Every email goes through the {platformLabel.charAt(0).toLowerCase() + platformLabel.slice(1)}.
          </p>
        ) : (
          <ul className="mt-4 divide-y divide-secondary-100 rounded-lg border border-secondary-200">
            {accounts.map((a) => {
              const st = accountStatus(a);
              return (
                <li key={a.uuid} className="px-4 py-3">
                  <div className="flex flex-wrap items-center justify-between gap-3">
                    <div className="min-w-0">
                      <p className="flex flex-wrap items-center gap-2 font-medium text-secondary-900">
                        {a.name}
                        {a.is_default && <Pill className="bg-primary-50 text-primary-700">Default</Pill>}
                        <Pill className={st.cls}>{st.text}</Pill>
                      </p>
                      <p className="truncate text-xs text-secondary-500">
                        {a.from_name ? `${a.from_name} <${a.from_email}>` : a.from_email} · {a.host}:{a.port}
                      </p>
                    </div>
                    {editable && (
                      <div className="flex flex-wrap gap-2">
                        {!a.is_default && a.enabled && (
                          <Button size="sm" variant="ghost" onClick={() => makeDefault(a)}>
                            <Star className="w-4 h-4 mr-1" /> Make default
                          </Button>
                        )}
                        <Button size="sm" variant="ghost" onClick={() => { setTestTo(''); setTesting(a); }}>
                          <Send className="w-4 h-4 mr-1" /> Test
                        </Button>
                        <Button size="sm" variant="outline" onClick={() => setEditing(a)}>
                          <Pencil className="w-4 h-4 mr-1" /> Edit
                        </Button>
                        <Button size="sm" variant="ghost" className="text-error-600" onClick={() => setRemoving(a)} aria-label={`Remove ${a.name}`}>
                          <Trash2 className="w-4 h-4" />
                        </Button>
                      </div>
                    )}
                  </div>
                  {a.last_error && (
                    <p className="mt-2 rounded-lg bg-red-50 p-2 text-xs text-red-700" role="alert">
                      {a.last_error}
                    </p>
                  )}
                </li>
              );
            })}
          </ul>
        )}
      </Card>

      {overview && (
        <Card className="shadow-sm">
          <h2 className="text-base font-semibold text-secondary-900">Which account sends what</h2>
          <p className="text-sm text-secondary-500">
            Every kind of email this workspace sends is listed here. Pick the account for each one.
            &ldquo;Use the default&rdquo; sends it through the default account; an account that&apos;s switched off
            falls back to the default too.
          </p>
          {accounts.length < 2 && (
            <p className="mt-2 rounded-lg bg-primary-50 px-3 py-2 text-sm text-primary-800">
              To send some emails from a different address (e.g. marketing from news@, quotations from sales@), add
              another account above. It then appears in every list below.
            </p>
          )}
          {groupRoutes(overview.routing).map(([group, rows]) => (
          <div key={group} className="mt-5">
          <h3 className="mb-2 text-xs font-semibold uppercase tracking-wide text-secondary-500">{group}</h3>
          <ul className="divide-y divide-secondary-100 rounded-lg border border-secondary-200">
            {rows.map((r) => (
              <li key={r.key} className="grid grid-cols-1 gap-2 px-4 py-3 sm:grid-cols-[1fr_260px] sm:items-center">
                <div className="min-w-0">
                  <p className="font-medium text-secondary-900">{r.name}</p>
                  <p className="text-xs text-secondary-500">{r.description}</p>
                  <p className="mt-0.5 text-xs text-secondary-400">Sent from {effective(r.key, r.account_uuid)}</p>
                </div>
                <Select
                  aria-label={`Account for ${r.name}`}
                  value={r.account_uuid || ''}
                  disabled={!editable || savingRoute === r.key || (r.key === 'default' ? false : accounts.length === 0)}
                  onChange={(e) => route(r.key, e.target.value)}
                >
                  <option value="">{r.key === 'default' ? platformLabel : 'Use the default'}</option>
                  {accounts.map((a) => (
                    <option key={a.uuid} value={a.uuid}
                      disabled={r.key === 'default' && !a.enabled && accounts.some((x) => x.enabled && x.uuid !== a.uuid)}>
                      {a.name}{a.enabled ? '' : ' (off)'}
                    </option>
                  ))}
                </Select>
              </li>
            ))}
          </ul>
          </div>
          ))}
          {!!overview.platform_only?.length && (
            <p className="mt-5 text-xs text-secondary-500">
              Always sent by the platform, so they arrive even if an account here stops working:{' '}
              {overview.platform_only.join('; ')}.
            </p>
          )}
        </Card>
      )}

      <AccountDialog
        account={editing}
        first={accounts.length === 0}
        othersOn={accounts.filter((a) => a.enabled && !(editing && editing !== 'new' && a.uuid === editing.uuid)).length}
        onClose={() => setEditing(null)}
        onSaved={() => {
          setEditing(null);
          load();
        }}
      />
      <Modal isOpen={!!testing} onClose={() => setTesting(null)} title={testing ? `Send a test from ${testing.name}` : ''} size="md">
        <div className="space-y-4">
          <Input label="Send a test email to" type="email" value={testTo} onChange={(e) => setTestTo(e.target.value)} />
          <div className="flex justify-end gap-2">
            <Button type="button" variant="outline" onClick={() => setTesting(null)}>Cancel</Button>
            <Button type="button" onClick={sendTest} isLoading={sending} disabled={!testTo.trim()}>
              <Send className="w-4 h-4 mr-1.5" /> Send test
            </Button>
          </div>
        </div>
      </Modal>
      <ConfirmDialog
        isOpen={!!removing}
        onClose={() => setRemoving(null)}
        onConfirm={remove}
        title={removing ? `Remove ${removing.name}?` : ''}
        message={
          removing?.is_default
            ? (() => {
                const next = accounts.filter((a) => a.uuid !== removing.uuid && a.enabled)
                  .sort((x, y) => (x.created_at || '').localeCompare(y.created_at || ''))[0];
                return next
                  ? `This is the default account. ${next.name} becomes the default instead (you can change that).`
                  : 'This is the default account. With no other account switched on, emails will go through the platform’s server.';
              })()
            : 'Emails sent through this account will go through the default account instead.'
        }
        confirmText="Remove"
        variant="warning"
      />
    </>
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
      <PageHeader title="Email" description="Your own email accounts, which one sends what, and the emails this workspace sends." icon={<Mail className="w-5 h-5" />} />
      <MailAccounts editable={editable} />
      {templates.length > 0 && (
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
      )}
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

/** Rows grouped by `group`, in the order the API lists them (groups appear where their first row does). */
function groupRoutes(routes: MailRoute[]): [string, MailRoute[]][] {
  const groups = new Map<string, MailRoute[]>();
  for (const r of routes) {
    const g = r.group || 'Other';
    if (!groups.has(g)) groups.set(g, []);
    groups.get(g)!.push(r);
  }
  return [...groups.entries()];
}

export default function NamespaceEmailPage() {
  return (
    <ProtectedPage module="namespace" title="Email">
      <EmailContent />
    </ProtectedPage>
  );
}

'use client';

/**
 * Forms — /dashboard/forms
 *
 * Build a form, publish it and share its link; responses can create customers,
 * leads or workspace invitations. The page assistant can build forms too
 * ("create a contact form that makes each person a lead").
 */

import React, { useCallback, useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import toast from 'react-hot-toast';
import { formatDistanceToNow } from 'date-fns';
import {
  ClipboardList, Copy, ExternalLink, FilePlus2, Globe, Link2, Loader2, Lock, MoreHorizontal, Pencil, Search, ShieldCheck, Sparkles,
  Trash2, Unlock,
} from 'lucide-react';
import { Badge, Button, ConfirmDialog, Input, Modal, Select, Textarea } from '@/components/ui';
import SpamProtectionModal from '@/components/forms/SpamProtectionModal';
import CustomDomainModal from '@/components/forms/CustomDomainModal';
import { ProtectedPage } from '@/components/permissions';
import { PageHeader } from '@/components/layout/PageHeader';
import { usePermissions } from '@/contexts/PermissionsContext';
import { apiError } from '@/components/field-service/shared';
import { formsService, parseTs, shareUrl, type FormSummary, type FormTemplate, type GeneratedForm } from '@/services/forms.service';

const STATUS: Record<string, { label: string; variant: 'success' | 'warning' | 'secondary' }> = {
  draft: { label: 'Draft', variant: 'secondary' },
  published: { label: 'Live', variant: 'success' },
  closed: { label: 'Closed', variant: 'warning' },
  archived: { label: 'Archived', variant: 'secondary' },
};

function ago(iso?: string) {
  const d = parseTs(iso);
  return d ? formatDistanceToNow(d, { addSuffix: true }) : '—';
}

function NewFormModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  const router = useRouter();
  const [templates, setTemplates] = useState<FormTemplate[]>([]);
  const [title, setTitle] = useState('');
  const [template, setTemplate] = useState<string>('');
  const [busy, setBusy] = useState(false);
  const [mode, setMode] = useState<'start' | 'ai'>('start');
  const [prompt, setPrompt] = useState('');
  const [draft, setDraft] = useState<GeneratedForm | null>(null);
  const [drafting, setDrafting] = useState(false);

  const generate = async () => {
    setDrafting(true);
    setDraft(null);
    try {
      setDraft(await formsService.generate(prompt.trim()));
    } catch (e) {
      toast.error(apiError(e, 'The AI could not draft a form'));
    } finally {
      setDrafting(false);
    }
  };

  const createFromDraft = async () => {
    if (!draft) return;
    setBusy(true);
    try {
      const form = await formsService.create({ title: title.trim() || draft.title, description: draft.description,
        fields: draft.schema.fields, targets: draft.targets });
      router.push(`/dashboard/forms/${form.uuid}`);
    } catch (e) {
      toast.error(apiError(e, 'Could not create the form'));
      setBusy(false);
    }
  };

  useEffect(() => {
    if (open && templates.length === 0) formsService.templates().then(setTemplates).catch(() => undefined);
  }, [open, templates.length]);

  const create = async () => {
    setBusy(true);
    try {
      const chosen = templates.find((t) => t.key === template);
      const form = await formsService.create({ title: title.trim() || chosen?.title || 'Untitled form', template: template || undefined });
      router.push(`/dashboard/forms/${form.uuid}`);
    } catch (e) {
      toast.error(apiError(e, 'Could not create the form'));
      setBusy(false);
    }
  };

  const option = (key: string, name: string, desc: string, extra?: string) => (
    <button key={key} type="button" onClick={() => setTemplate(key)} aria-pressed={template === key}
      className={`rounded-xl border p-3.5 text-left transition-colors ${template === key
        ? 'border-primary-500 bg-primary-500/5 ring-2 ring-primary-500/15' : 'border-secondary-200 hover:border-secondary-300'}`}>
      <p className="text-sm font-semibold text-secondary-900">{name}</p>
      <p className="mt-0.5 text-xs text-secondary-500">{desc}</p>
      {extra && <p className="mt-1.5 text-xs font-medium text-primary-600">{extra}</p>}
    </button>
  );

  return (
    <Modal isOpen={open} onClose={onClose} title="New form" size="2xl"
      footer={
        <div className="flex w-full justify-end gap-2">
          <Button variant="ghost" onClick={onClose}>Cancel</Button>
          {mode === 'start'
            ? <Button onClick={create} isLoading={busy}>Create and edit</Button>
            : <Button onClick={createFromDraft} isLoading={busy} disabled={!draft}>Create this form</Button>}
        </div>
      }>
      <div className="mb-5 inline-flex rounded-lg border border-secondary-300 p-0.5" role="tablist">
        {(['start', 'ai'] as const).map((m) => (
          <button key={m} type="button" role="tab" aria-selected={mode === m} onClick={() => setMode(m)}
            className={`inline-flex h-9 items-center gap-1.5 rounded-md px-3 text-sm ${mode === m ? 'bg-secondary-900 text-white' : 'text-secondary-600 hover:bg-secondary-100'}`}>
            {m === 'ai' && <Sparkles className="h-4 w-4" />}{m === 'start' ? 'Blank or template' : 'Describe it, AI drafts it'}
          </button>
        ))}
      </div>
      {mode === 'ai' ? (
        <div className="space-y-4">
          <Textarea label="What should the form ask, and what should happen with each response?" rows={4} maxLength={2000}
            value={prompt} onChange={(e) => setPrompt(e.target.value)}
            placeholder="A job application form: name, email, phone, a link to their CV, years of experience, and when they can start. Make each applicant a lead." />
          <Button variant="outline" leftIcon={<Sparkles className="h-4 w-4" />} onClick={generate} isLoading={drafting}
            disabled={prompt.trim().length < 5}>
            {draft ? 'Draft again' : 'Draft the form'}
          </Button>
          {draft && (
            <div className="rounded-xl border border-secondary-200 p-4">
              <Input label="Title" value={title || draft.title} onChange={(e) => setTitle(e.target.value)} />
              {draft.description && <p className="mt-2 text-sm text-secondary-600">{draft.description}</p>}
              <ol className="mt-3 list-decimal space-y-1 pl-5 text-sm text-secondary-800">
                {draft.schema.fields.map((f, i) => (
                  <li key={f.key || i}>{f.label || f.type}{f.required ? ' *' : ''}
                    <span className="text-secondary-500"> · {f.type.replace('_', ' ')}{f.system ? ' · locked' : ''}</span></li>
                ))}
              </ol>
              {draft.targets.length > 0 && (
                <p className="mt-3 text-sm text-secondary-700">Creates: {draft.targets.map((t) => (t.type === 'user' ? 'invitation' : t.type)).join(', ')}</p>
              )}
              {draft.dropped > 0 && <p className="mt-2 text-xs text-warning-600">{draft.dropped} suggested question(s) were left out because they weren&apos;t valid.</p>}
              <p className="mt-2 text-xs text-secondary-500">It is created as a draft: you can change anything before publishing.</p>
            </div>
          )}
        </div>
      ) : (
      <div className="space-y-5">
        <Input label="Title" placeholder="e.g. Get a quote" value={title} maxLength={200}
          onChange={(e) => setTitle(e.target.value)} autoFocus />
        <div>
          <p className="mb-2 text-sm font-medium text-secondary-700">Start from</p>
          <div className="grid grid-cols-1 gap-2.5 sm:grid-cols-2">
            {option('', 'Blank form', 'Add your own questions.')}
            {templates.map((t) => option(t.key, t.title, t.description,
              t.targets.length ? `Creates: ${t.targets.join(', ')}` : undefined))}
          </div>
        </div>
        <p className="flex items-start gap-2 rounded-lg bg-secondary-50 p-3 text-xs text-secondary-600">
          <Sparkles className="mt-0.5 h-4 w-4 shrink-0 text-primary-500" aria-hidden="true" />
          Or ask the assistant on this page, e.g. “Create a job application form with name, email, CV link and years of
          experience, and make each applicant a lead.”
        </p>
      </div>
      )}
    </Modal>
  );
}

function FormsPageContent() {
  const { canCreate, canUpdate, canDelete, canManage } = usePermissions();
  const [spamOpen, setSpamOpen] = useState(false);
  const [domainOpen, setDomainOpen] = useState(false);
  const [forms, setForms] = useState<FormSummary[]>([]);
  const [cursor, setCursor] = useState<string | undefined>();
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [query, setQuery] = useState('');
  const [q, setQ] = useState('');
  const [status, setStatus] = useState('');
  const [newOpen, setNewOpen] = useState(false);
  const [menu, setMenu] = useState<string | null>(null);
  const [toDelete, setToDelete] = useState<FormSummary | null>(null);
  const [deleting, setDeleting] = useState(false);
  const fetchId = useRef(0);

  useEffect(() => {
    const t = setTimeout(() => setQ(query.trim()), 300);
    return () => clearTimeout(t);
  }, [query]);

  const load = useCallback(async (more?: string) => {
    const id = ++fetchId.current;
    if (more) setLoadingMore(true); else setLoading(true);
    try {
      const res = await formsService.list({ q: q || undefined, status: status || undefined, cursor: more, limit: 50 });
      if (id !== fetchId.current) return;
      setForms((prev) => (more ? [...prev, ...res.items] : res.items));
      setCursor(res.nextCursor);
    } catch (e) {
      toast.error(apiError(e, 'Could not load forms'));
    } finally {
      if (id === fetchId.current) {
        setLoading(false);
        setLoadingMore(false);
      }
    }
  }, [q, status]);

  useEffect(() => { load(); }, [load]);

  const replace = (f: FormSummary) => setForms((prev) => prev.map((x) => (x.uuid === f.uuid ? f : x)));

  const copyLink = async (f: FormSummary) => {
    await navigator.clipboard.writeText(shareUrl(f));
    toast.success(f.status === 'published' ? 'Link copied' : 'Link copied — publish the form to make it work');
  };

  const run = async (label: string, fn: () => Promise<void>) => {
    setMenu(null);
    try {
      await fn();
    } catch (e) {
      toast.error(apiError(e, `Could not ${label}`));
    }
  };

  return (
    <div className="space-y-6">
      <PageHeader title="Forms" icon={<ClipboardList className="h-5 w-5" />}
        description="Build a form, share its link, and turn every response into a customer, lead or teammate."
        actions={(
          <>
            {canManage('forms') && (
              <>
                <Button variant="ghost" leftIcon={<Globe className="h-4 w-4" />} onClick={() => setDomainOpen(true)}>Custom domain</Button>
                <Button variant="ghost" leftIcon={<ShieldCheck className="h-4 w-4" />} onClick={() => setSpamOpen(true)}>Spam protection</Button>
              </>
            )}
            {canCreate('forms') && (
              <Button leftIcon={<FilePlus2 className="h-4 w-4" />} onClick={() => setNewOpen(true)}>New form</Button>
            )}
          </>
        )} />

      <div className="flex flex-col gap-3 sm:flex-row">
        <div className="flex-1">
          <Input aria-label="Search forms" placeholder="Search forms" value={query} leftIcon={<Search className="h-4 w-4" />}
            onChange={(e) => setQuery(e.target.value)} />
        </div>
        <div className="sm:w-48">
          <Select aria-label="Status" value={status} onChange={(e) => setStatus(e.target.value)}>
            <option value="">All forms</option>
            <option value="published">Live</option>
            <option value="draft">Drafts</option>
            <option value="closed">Closed</option>
          </Select>
        </div>
      </div>

      {loading ? (
        <div className="grid h-48 place-items-center" aria-busy="true"><Loader2 className="h-6 w-6 animate-spin text-secondary-400" /></div>
      ) : forms.length === 0 ? (
        <div className="flex flex-col items-center gap-3 rounded-2xl border-2 border-dashed border-secondary-200 px-6 py-14 text-center">
          <ClipboardList className="h-10 w-10 text-secondary-300" aria-hidden="true" />
          <div>
            <p className="font-semibold text-secondary-900">{q || status ? 'No forms match.' : 'No forms yet'}</p>
            {!q && !status && (
              <p className="mt-1 max-w-md text-sm text-secondary-500">
                Contact forms, quote requests, sign-ups, applications — share the link and responses arrive here.
              </p>
            )}
          </div>
          {canCreate('forms') && !q && !status && (
            <Button leftIcon={<FilePlus2 className="h-4 w-4" />} onClick={() => setNewOpen(true)}>Create your first form</Button>
          )}
        </div>
      ) : (
        <ul className="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-3">
          {forms.map((f) => (
            <li key={f.uuid} className="relative flex flex-col rounded-xl border border-secondary-200 bg-surface p-4 shadow-sm transition-shadow hover:shadow-md">
              <div className="flex items-start gap-2">
                <Link href={`/dashboard/forms/${f.uuid}`} className="min-w-0 flex-1 after:absolute after:inset-0 focus:outline-none">
                  <h2 className="truncate font-semibold text-secondary-900">{f.title}</h2>
                </Link>
                <Badge size="sm" variant={STATUS[f.status]?.variant}>{STATUS[f.status]?.label || f.status}</Badge>
                <div className="relative z-10">
                  <button type="button" aria-label={`Actions for ${f.title}`} aria-expanded={menu === f.uuid}
                    onClick={() => setMenu(menu === f.uuid ? null : f.uuid)}
                    className="inline-flex h-8 w-8 items-center justify-center rounded-md text-secondary-500 hover:bg-secondary-100">
                    <MoreHorizontal className="h-4 w-4" />
                  </button>
                  {menu === f.uuid && (
                    <div role="menu" className="absolute right-0 top-9 z-20 w-48 rounded-lg border border-secondary-200 bg-surface py-1 shadow-lg"
                      onMouseLeave={() => setMenu(null)}>
                      <MenuItem icon={Pencil} label="Edit" href={`/dashboard/forms/${f.uuid}`} />
                      <MenuItem icon={Link2} label="Copy link" onClick={() => run('copy the link', () => copyLink(f))} />
                      {f.status === 'published' && (
                        <MenuItem icon={ExternalLink} label="Open form" href={shareUrl(f)} external />
                      )}
                      {canCreate('forms') && (
                        <MenuItem icon={Copy} label="Duplicate" onClick={() => run('duplicate', async () => {
                          const copy = await formsService.duplicate(f.uuid);
                          setForms((prev) => [copy, ...prev]);
                          toast.success('Duplicated as a draft');
                        })} />
                      )}
                      {canUpdate('forms') && f.status === 'published' && (
                        <MenuItem icon={Lock} label="Close" onClick={() => run('close', async () => replace(await formsService.setOpen(f.uuid, false)))} />
                      )}
                      {canUpdate('forms') && f.status === 'closed' && (
                        <MenuItem icon={Unlock} label="Reopen" onClick={() => run('reopen', async () => replace(await formsService.setOpen(f.uuid, true)))} />
                      )}
                      {canDelete('forms') && (
                        <MenuItem icon={Trash2} label="Delete" danger onClick={() => { setMenu(null); setToDelete(f); }} />
                      )}
                    </div>
                  )}
                </div>
              </div>
              {f.description && <p className="mt-1 line-clamp-2 text-sm text-secondary-500">{f.description}</p>}
              <dl className="mt-4 grid grid-cols-3 gap-2 text-xs">
                <div><dt className="text-secondary-400">Responses</dt><dd className="text-base font-semibold text-secondary-900">{f.submission_count}</dd></div>
                <div><dt className="text-secondary-400">Questions</dt><dd className="text-base font-semibold text-secondary-900">{f.question_count}</dd></div>
                <div><dt className="text-secondary-400">Last response</dt><dd className="mt-1 text-secondary-700">{ago(f.last_submission_at)}</dd></div>
              </dl>
              {(f.targets.length > 0 || f.has_unpublished_changes) && (
                <div className="mt-3 flex flex-wrap gap-1.5">
                  {f.targets.map((t) => (
                    <span key={t.type} className="rounded-full bg-primary-500/10 px-2 py-0.5 text-xs font-medium text-primary-600">
                      → {t.type === 'user' ? 'invitation' : t.type}
                    </span>
                  ))}
                  {f.has_unpublished_changes && (
                    <span className="rounded-full bg-warning-500/10 px-2 py-0.5 text-xs font-medium text-warning-600">Unpublished changes</span>
                  )}
                </div>
              )}
            </li>
          ))}
        </ul>
      )}
      {cursor && !loading && (
        <div className="flex justify-center"><Button variant="ghost" onClick={() => load(cursor)} isLoading={loadingMore}>Load more</Button></div>
      )}

      <NewFormModal open={newOpen} onClose={() => setNewOpen(false)} />
      <SpamProtectionModal open={spamOpen} onClose={() => setSpamOpen(false)} />
      <CustomDomainModal open={domainOpen} onClose={() => setDomainOpen(false)} onChanged={() => load()} />
      <ConfirmDialog isOpen={!!toDelete} onClose={() => setToDelete(null)} variant="danger" title="Delete form"
        confirmText="Delete" isLoading={deleting}
        message={`Delete "${toDelete?.title}"? Its link stops working at once; its responses are removed after 30 days.`}
        onConfirm={async () => {
          if (!toDelete) return;
          setDeleting(true);
          try {
            await formsService.remove(toDelete.uuid);
            setForms((prev) => prev.filter((x) => x.uuid !== toDelete.uuid));
            toast.success('Form deleted');
          } catch (e) {
            toast.error(apiError(e, 'Could not delete the form'));
          } finally {
            setDeleting(false);
            setToDelete(null);
          }
        }} />
    </div>
  );
}

function MenuItem({ icon: Icon, label, onClick, href, external, danger }: {
  icon: React.ComponentType<{ className?: string }>; label: string; onClick?: () => void; href?: string;
  external?: boolean; danger?: boolean;
}) {
  const cls = `flex w-full items-center gap-2 px-3 py-2 text-left text-sm ${danger ? 'text-error-600' : 'text-secondary-700'} hover:bg-secondary-50`;
  if (href) {
    return external
      ? <a role="menuitem" href={href} target="_blank" rel="noopener noreferrer" className={cls}><Icon className="h-4 w-4" />{label}</a>
      : <Link role="menuitem" href={href} className={cls}><Icon className="h-4 w-4" />{label}</Link>;
  }
  return <button role="menuitem" type="button" onClick={onClick} className={cls}><Icon className="h-4 w-4" />{label}</button>;
}

export default function FormsPage() {
  return (
    <ProtectedPage module="forms" title="Forms">
      <FormsPageContent />
    </ProtectedPage>
  );
}

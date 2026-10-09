'use client';

/**
 * The Responses tab: newest first ("Load more" pages by cursor), filters,
 * CSV export, and a detail view with the records each response created or
 * matched, plus Retry / Spam / Delete.
 */

import React, { useCallback, useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import toast from 'react-hot-toast';
import { formatDistanceToNow } from 'date-fns';
import {
  AlertTriangle, Download, Inbox, Loader2, RefreshCw, Search, ShieldAlert, ShieldCheck, Trash2,
} from 'lucide-react';
import { Badge, Button, ConfirmDialog, Input, Modal, Select } from '@/components/ui';
import { apiError } from '@/components/field-service/shared';
import { usePermissions } from '@/contexts/PermissionsContext';
import {
  formsService, parseTs, type Column, type FormField, type Submission, type SubmissionLink,
} from '@/services/forms.service';
import { TARGET_LABEL } from './field-types';

/** A human-readable answer (mirrors Fields.show on the server). */
export function showAnswer(field: Pick<FormField, 'type' | 'options' | 'scale'> | Column | undefined, v: unknown): string {
  if (v === undefined || v === null || v === '') return '';
  const label = (val: unknown) => field?.options?.find((o) => o.value === val)?.label ?? String(val);
  switch (field?.type) {
    case 'name': {
      const n = v as { first?: string; last?: string };
      return `${n.first || ''} ${n.last || ''}`.trim();
    }
    case 'address':
      return ['line1', 'line2', 'city', 'postcode', 'country']
        .map((k) => (v as Record<string, string>)[k]).filter(Boolean).join(', ');
    case 'multi_select':
      return (Array.isArray(v) ? v : [v]).map(label).join(', ');
    case 'single_select':
    case 'radio':
      return label(v);
    case 'boolean':
      return v === true ? 'Yes' : 'No';
    case 'consent':
      return v === true ? 'Agreed' : 'Not agreed';
    case 'rating':
      return `${v}/${field.scale || 5}`;
    default:
      return typeof v === 'object' ? JSON.stringify(v) : String(v);
  }
}

const STATUS_BADGE: Record<string, { label: string; variant: 'success' | 'warning' | 'error' }> = {
  complete: { label: 'Complete', variant: 'success' },
  needs_attention: { label: 'Needs attention', variant: 'warning' },
  spam: { label: 'Spam', variant: 'error' },
};

const OUTCOME: Record<string, string> = { created: 'created', matched: 'linked', invited: 'invited', failed: 'failed' };

const ERROR_TEXT: Record<string, string> = {
  workspace_full: 'The workspace has no free seats. Raise the limit or remove someone, then retry.',
  email_in_use: 'Another record already uses this email.',
  invalid_email: "The email can't be used for this record.",
  role_missing: "The role this form invites people as doesn't exist any more.",
  publisher_missing: 'The person who published the form no longer exists. Publish it again, then retry.',
  error: 'Something went wrong. Retry, and contact support if it keeps failing.',
};

function recordHref(l: SubmissionLink): string | null {
  if (!l.entity_uuid || l.missing) return null;
  if (l.entity_type === 'customer') return `/dashboard/customers/${l.entity_uuid}`;
  if (l.entity_type === 'lead') return `/dashboard/leads?lead=${l.entity_uuid}`;
  if (l.entity_type === 'invitation') return '/dashboard/namespace/members';
  return null;
}

function LinkChip({ l }: { l: SubmissionLink }) {
  const failed = l.outcome === 'failed';
  const href = recordHref(l);
  const text = `${TARGET_LABEL[l.target] || l.target} ${OUTCOME[l.outcome] || l.outcome}`;
  const cls = `inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium ${failed
    ? 'bg-warning-500/10 text-warning-600' : 'bg-secondary-100 text-secondary-700'}`;
  return href ? <Link href={href} className={`${cls} hover:bg-secondary-200`}>{text}</Link> : <span className={cls}>{text}</span>;
}

function when(iso: string) {
  const d = parseTs(iso);
  return d ? formatDistanceToNow(d, { addSuffix: true }) : iso;
}

export default function FormResponses({ formUuid, initialResponse }: { formUuid: string; initialResponse?: string }) {
  const { canUpdate, canDelete } = usePermissions();
  const [items, setItems] = useState<Submission[]>([]);
  const [columns, setColumns] = useState<Column[]>([]);
  const [cursor, setCursor] = useState<string | undefined>();
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [status, setStatus] = useState('');
  const [query, setQuery] = useState('');
  const [q, setQ] = useState('');
  const [openId, setOpenId] = useState<string | null>(initialResponse || null);
  const [exporting, setExporting] = useState(false);
  const fetchId = useRef(0);

  useEffect(() => {
    const t = setTimeout(() => setQ(query.trim()), 300);
    return () => clearTimeout(t);
  }, [query]);

  const load = useCallback(async (more?: string) => {
    const id = ++fetchId.current;
    if (more) setLoadingMore(true); else setLoading(true);
    try {
      const res = await formsService.submissions(formUuid, { status: status || undefined, q: q || undefined, cursor: more, limit: 50 });
      if (id !== fetchId.current) return;
      setItems((prev) => (more ? [...prev, ...res.items] : res.items));
      setColumns(res.columns);
      setCursor(res.nextCursor);
    } catch (e) {
      toast.error(apiError(e, 'Could not load the responses'));
    } finally {
      if (id === fetchId.current) {
        setLoading(false);
        setLoadingMore(false);
      }
    }
  }, [formUuid, status, q]);

  useEffect(() => { load(); }, [load]);

  const exportCsv = async () => {
    setExporting(true);
    try {
      const { blob, filename } = await formsService.exportCsv(formUuid, { status: status || undefined, q: q || undefined });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = filename;
      a.click();
      URL.revokeObjectURL(url);
    } catch (e) {
      toast.error(apiError(e, 'Could not export'));
    } finally {
      setExporting(false);
    }
  };

  const shown = columns.slice(0, 3);
  const replace = (s: Submission) => setItems((prev) => prev.map((x) => (x.uuid === s.uuid ? { ...x, ...s } : x)));

  return (
    <div className="space-y-4">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-end">
        <div className="flex-1">
          <Input aria-label="Search responses" placeholder="Search answers or email" value={query}
            leftIcon={<Search className="h-4 w-4" />} onChange={(e) => setQuery(e.target.value)} />
        </div>
        <div className="sm:w-56">
          <Select aria-label="Status" value={status} onChange={(e) => setStatus(e.target.value)}>
            <option value="">All responses</option>
            <option value="needs_attention">Needs attention</option>
            <option value="complete">Complete</option>
            <option value="spam">Spam</option>
          </Select>
        </div>
        <Button variant="ghost" onClick={() => load()} leftIcon={<RefreshCw className="h-4 w-4" />}>Refresh</Button>
        <Button variant="outline" onClick={exportCsv} isLoading={exporting} leftIcon={<Download className="h-4 w-4" />}>
          Export CSV
        </Button>
      </div>

      <div className="overflow-x-auto rounded-xl border border-secondary-200 bg-surface">
        {loading ? (
          <div className="grid h-40 place-items-center" aria-busy="true"><Loader2 className="h-5 w-5 animate-spin text-secondary-400" /></div>
        ) : items.length === 0 ? (
          <div className="flex flex-col items-center gap-2 p-10 text-center text-sm text-secondary-500">
            <Inbox className="h-8 w-8 text-secondary-300" aria-hidden="true" />
            {q || status ? 'No responses match.' : 'No responses yet. Share the link to start collecting them.'}
          </div>
        ) : (
          <table className="min-w-full text-sm">
            <thead>
              <tr className="border-b border-secondary-200 text-left text-xs uppercase tracking-wide text-secondary-500">
                <th scope="col" className="px-4 py-3 font-medium">Received</th>
                {shown.map((c) => <th key={c.key} scope="col" className="px-4 py-3 font-medium">{c.label}</th>)}
                <th scope="col" className="px-4 py-3 font-medium">Records</th>
                <th scope="col" className="px-4 py-3 font-medium">Status</th>
              </tr>
            </thead>
            <tbody>
              {items.map((s) => (
                <tr key={s.uuid} tabIndex={0} onClick={() => setOpenId(s.uuid)}
                  onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); setOpenId(s.uuid); } }}
                  className="cursor-pointer border-b border-secondary-100 last:border-0 hover:bg-secondary-50 focus:bg-secondary-50 focus:outline-none">
                  <td className="whitespace-nowrap px-4 py-3 text-secondary-600">{when(s.created_at)}</td>
                  {shown.map((c) => (
                    <td key={c.key} className="max-w-[16rem] truncate px-4 py-3 text-secondary-800">{showAnswer(c, s.answers[c.key])}</td>
                  ))}
                  <td className="px-4 py-3"><div className="flex flex-wrap gap-1">{s.links.map((l) => <LinkChip key={l.target} l={l} />)}</div></td>
                  <td className="px-4 py-3">
                    <Badge size="sm" variant={STATUS_BADGE[s.status]?.variant}>{STATUS_BADGE[s.status]?.label || s.status}</Badge>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
      {cursor && !loading && (
        <div className="flex justify-center">
          <Button variant="ghost" onClick={() => load(cursor)} isLoading={loadingMore}>Load more</Button>
        </div>
      )}

      {openId && (
        <ResponseDetail formUuid={formUuid} sid={openId} onClose={() => setOpenId(null)}
          canUpdate={canUpdate('forms')} canDelete={canDelete('forms')}
          onChanged={replace} onDeleted={(sid) => { setItems((p) => p.filter((x) => x.uuid !== sid)); setOpenId(null); }} />
      )}
    </div>
  );
}

function ResponseDetail({ formUuid, sid, onClose, onChanged, onDeleted, canUpdate, canDelete }: {
  formUuid: string; sid: string; onClose: () => void; onChanged: (s: Submission) => void;
  onDeleted: (sid: string) => void; canUpdate: boolean; canDelete: boolean;
}) {
  const [s, setS] = useState<Submission | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);

  useEffect(() => {
    formsService.submission(formUuid, sid).then(setS).catch((e) => {
      toast.error(apiError(e, 'Could not open the response'));
      onClose();
    });
  }, [formUuid, sid, onClose]);

  const act = async (name: string, fn: () => Promise<Submission>, done: string) => {
    setBusy(name);
    try {
      const next = await fn();
      setS(next);
      onChanged(next);
      toast.success(done);
    } catch (e) {
      toast.error(apiError(e, 'That did not work'));
    } finally {
      setBusy(null);
    }
  };

  const failed = s?.links.filter((l) => l.outcome === 'failed') || [];
  return (
    <>
      <Modal isOpen onClose={onClose} title="Response" size="xl"
        description={s ? `Received ${parseTs(s.created_at)?.toLocaleString() || s.created_at}${s.respondent_email ? ` from ${s.respondent_email}` : ''}` : undefined}
        footer={s && (canUpdate || canDelete) ? (
          <div className="flex w-full flex-wrap items-center gap-2">
            {canDelete && (
              <Button variant="ghost" className="text-error-600" leftIcon={<Trash2 className="h-4 w-4" />}
                onClick={() => setConfirmDelete(true)}>Delete</Button>
            )}
            <div className="ml-auto flex flex-wrap gap-2">
              {canUpdate && s.status === 'spam' && (
                <Button variant="outline" isLoading={busy === 'ham'} leftIcon={<ShieldCheck className="h-4 w-4" />}
                  onClick={() => act('ham', () => formsService.setSubmissionStatus(formUuid, sid, 'complete'), 'Marked as not spam')}>
                  Not spam
                </Button>
              )}
              {canUpdate && s.status !== 'spam' && (
                <Button variant="ghost" isLoading={busy === 'spam'} leftIcon={<ShieldAlert className="h-4 w-4" />}
                  onClick={() => act('spam', () => formsService.setSubmissionStatus(formUuid, sid, 'spam'), 'Marked as spam')}>
                  Spam
                </Button>
              )}
              {canUpdate && failed.length > 0 && s.status !== 'spam' && (
                <Button isLoading={busy === 'retry'} leftIcon={<RefreshCw className="h-4 w-4" />}
                  onClick={() => act('retry', () => formsService.retry(formUuid, sid), 'Retried')}>
                  Retry
                </Button>
              )}
            </div>
          </div>
        ) : undefined}>
        {!s ? (
          <div className="grid h-40 place-items-center"><Loader2 className="h-5 w-5 animate-spin text-secondary-400" /></div>
        ) : (
          <div className="space-y-6">
            {s.status === 'spam' && (
              <p className="flex items-start gap-2 rounded-lg bg-error-500/10 p-3 text-sm text-error-600">
                <ShieldAlert className="mt-0.5 h-4 w-4 shrink-0" />
                Marked as spam{s.spam_reason ? ` (${s.spam_reason.replace(/_/g, ' ')})` : ''}: no records were created and no emails sent.
              </p>
            )}
            {failed.map((l) => (
              <p key={l.target} className="flex items-start gap-2 rounded-lg bg-warning-500/10 p-3 text-sm text-warning-600">
                <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
                {TARGET_LABEL[l.target]} not created: {ERROR_TEXT[l.error_code || 'error'] || l.error_code}
              </p>
            ))}
            <dl className="divide-y divide-secondary-100">
              {(s.fields || []).filter((f) => f.key && !['heading', 'paragraph'].includes(f.type)).map((f) => (
                <div key={f.key} className="grid gap-1 py-3 sm:grid-cols-3 sm:gap-4">
                  <dt className="text-sm text-secondary-500">{f.label}</dt>
                  <dd className="whitespace-pre-wrap break-words text-sm text-secondary-900 sm:col-span-2">
                    {showAnswer(f, s.answers[f.key || '']) || <span className="text-secondary-400">—</span>}
                  </dd>
                </div>
              ))}
            </dl>
            {s.links.length > 0 && (
              <div>
                <h3 className="mb-2 text-sm font-semibold text-secondary-900">Records</h3>
                <ul className="space-y-2">
                  {s.links.map((l) => {
                    const href = recordHref(l);
                    return (
                      <li key={l.target} className="flex flex-wrap items-center gap-2 text-sm">
                        <LinkChip l={l} />
                        <span className="text-secondary-700">
                          {l.record?.name || l.record?.email || (l.missing ? 'deleted since' : '')}
                          {l.entity_type === 'invitation' && l.record?.status ? ` · invitation ${l.record.status}` : ''}
                        </span>
                        {href && <Link href={href} className="text-primary-600 hover:underline">Open</Link>}
                      </li>
                    );
                  })}
                </ul>
              </div>
            )}
            <div className="grid gap-2 rounded-lg bg-secondary-50 p-3 text-xs text-secondary-600 sm:grid-cols-2">
              {s.page_url && <p className="truncate">Page: {s.page_url}</p>}
              {s.referrer && <p className="truncate">Came from: {s.referrer}</p>}
              {s.utm && Object.keys(s.utm).length > 0 && (
                <p>Campaign: {Object.entries(s.utm).map(([k, v]) => `${k}=${v}`).join(', ')}</p>
              )}
              {s.duration_ms !== undefined && <p>Time to fill in: {Math.round(s.duration_ms / 1000)} s</p>}
              <p>Form version {s.version}</p>
            </div>
          </div>
        )}
      </Modal>
      <ConfirmDialog isOpen={confirmDelete} onClose={() => setConfirmDelete(false)} variant="danger"
        title="Delete this response?" confirmText="Delete" isLoading={busy === 'delete'}
        message="The answers are deleted for good. Customers, leads or invitations it created stay."
        onConfirm={async () => {
          setBusy('delete');
          try {
            await formsService.removeSubmission(formUuid, sid);
            toast.success('Response deleted');
            onDeleted(sid);
          } catch (e) {
            toast.error(apiError(e, 'Could not delete'));
          } finally {
            setBusy(null);
            setConfirmDelete(false);
          }
        }} />
    </>
  );
}

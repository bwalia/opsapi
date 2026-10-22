'use client';

import React, { useCallback, useEffect, useState } from 'react';
import { isAxiosError } from 'axios';
import { FileUp, Plus, RefreshCw, Trash2, Upload, Users, X } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button } from '@/components/ui';
import { marketingService } from '@/services/opsapi-marketing.service';

type MktList = {
  id: number;
  uuid: string;
  name: string;
  list_type?: string;
  channel?: string;
  segment_rule?: unknown;
};

type Member = {
  contact_uuid: string;
  first_name?: string;
  last_name?: string;
  email?: string;
  phone?: string;
  company?: string;
  source?: string;
};

type LegalBasis = 'legitimate_interest' | 'consent';

/** What a contacts file holds (preview), or what was imported from it. */
type FileScan = {
  file_type: string;
  found: number;
  importable: number;
  new_contacts: number;
  existing_contacts: number;
  skipped: { duplicates: number; personal: number; unsubscribed: number };
  personal_rule: boolean;
  sample?: { email: string; first_name?: string; last_name?: string; company?: string }[];
  imported?: number;
  created_contacts?: number;
};

const ACCEPT_FILES = '.csv,.txt,.xlsx,.pdf';
const MAX_FILE_BYTES = 7 * 1024 * 1024;

/** File → base64 (without the data: prefix). */
function readBase64(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).replace(/^data:[^,]*,/, ''));
    reader.onerror = () => reject(new Error('Could not read the file'));
    reader.readAsDataURL(file);
  });
}

type Condition = { field: string; op: string; value: string };

const NO_VALUE_OPS = ['is_empty', 'not_empty'];
const OP_LABELS: Record<string, string> = {
  eq: 'equals',
  neq: 'does not equal',
  contains: 'contains',
  not_contains: 'does not contain',
  starts_with: 'starts with',
  is_empty: 'is empty',
  not_empty: 'is not empty',
};

function apiErrorMessage(e: unknown, fallback: string): string {
  if (isAxiosError(e)) {
    const data = e.response?.data as { error?: string; message?: string } | undefined;
    if (data?.error) return String(data.error);
    if (data?.message) return String(data.message);
    if (e.message) return e.message;
  }
  if (e instanceof Error) return e.message;
  return fallback;
}

/** Split a stored rule into flat conditions + match mode; nested groups aren't editable here. */
function parseRule(raw: unknown): { match: 'and' | 'or'; conditions: Condition[] } {
  const rule = typeof raw === 'string' ? safeJson(raw) : raw;
  const leaf = (n: unknown): Condition | null => {
    const r = n as { field?: string; op?: string; value?: unknown };
    return r && r.field && r.op ? { field: r.field, op: r.op, value: r.value == null ? '' : String(r.value) } : null;
  };
  if (rule && typeof rule === 'object' && !Array.isArray(rule)) {
    const r = rule as { and?: unknown[]; or?: unknown[] };
    const group = r.and ?? r.or;
    if (Array.isArray(group)) {
      return {
        match: r.or ? 'or' : 'and',
        conditions: group.map(leaf).filter((c): c is Condition => c !== null),
      };
    }
    const single = leaf(rule);
    if (single) return { match: 'and', conditions: [single] };
  }
  return { match: 'and', conditions: [] };
}

function safeJson(s: string): unknown {
  try {
    return JSON.parse(s);
  } catch {
    return null;
  }
}

function buildRule(match: 'and' | 'or', conditions: Condition[]) {
  return {
    [match]: conditions.map((c) =>
      NO_VALUE_OPS.includes(c.op) ? { field: c.field, op: c.op } : { field: c.field, op: c.op, value: c.value },
    ),
  };
}

/** Accept a CSV with a header row, or a bare list of emails (one per line / comma separated). */
function toCsv(text: string): string {
  const trimmed = text.trim();
  const firstLine = trimmed.split(/\r?\n/)[0].toLowerCase();
  if (firstLine.split(',').map((h) => h.trim()).includes('email')) return trimmed;
  const emails = trimmed
    .split(/[\s,;]+/)
    .map((s) => s.trim())
    .filter(Boolean);
  return ['email', ...emails].join('\n');
}

export default function MarketingListsPage() {
  const [lists, setLists] = useState<MktList[]>([]);
  const [selected, setSelected] = useState<MktList | null>(null);
  const [members, setMembers] = useState<Member[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const [newName, setNewName] = useState('');
  const [newType, setNewType] = useState<'static' | 'dynamic'>('static');
  const [newChannel, setNewChannel] = useState('email');

  const [csvText, setCsvText] = useState('');
  const [grantConsent, setGrantConsent] = useState(false);
  const [memberTotal, setMemberTotal] = useState<number | null>(null);

  const [upload, setUpload] = useState<{ name: string; base64: string } | null>(null);
  const [basis, setBasis] = useState<LegalBasis>('legitimate_interest');
  const [sourceNote, setSourceNote] = useState('');
  const [scan, setScan] = useState<FileScan | null>(null);
  const [lawful, setLawful] = useState(false);

  const [fields, setFields] = useState<string[]>([]);
  const [ops, setOps] = useState<string[]>([]);
  const [match, setMatch] = useState<'and' | 'or'>('and');
  const [conditions, setConditions] = useState<Condition[]>([]);
  const [segmentCount, setSegmentCount] = useState<number | null>(null);

  const loadLists = useCallback(async () => {
    const res = await marketingService.listLists({ per_page: 100 });
    const data = res.data?.data ?? res.data ?? [];
    const rows: MktList[] = Array.isArray(data) ? data : data.items || [];
    setLists(rows);
    return rows;
  }, []);

  const loadMembers = useCallback(async (list: MktList) => {
    const res = await marketingService.listMembers(list.uuid);
    const data = res.data?.data ?? res.data ?? [];
    setMembers(Array.isArray(data) ? data : []);
    setMemberTotal(typeof res.data?.meta?.total === 'number' ? res.data.meta.total : null);
  }, []);

  useEffect(() => {
    void (async () => {
      try {
        await loadLists();
        const f = await marketingService.segmentFields();
        const d = f.data?.data ?? f.data ?? {};
        setFields((d.fields || []).map((x: { field: string }) => x.field));
        setOps(d.ops || []);
      } catch (e: unknown) {
        setError(apiErrorMessage(e, 'Failed to load lists'));
      }
    })();
  }, [loadLists]);

  const select = async (list: MktList) => {
    setSelected(list);
    setError(null);
    setNotice(null);
    setSegmentCount(null);
    setCsvText('');
    setUpload(null);
    setScan(null);
    setLawful(false);
    const parsed = parseRule(list.segment_rule);
    setMatch(parsed.match);
    setConditions(parsed.conditions);
    try {
      await loadMembers(list);
    } catch (e: unknown) {
      setError(apiErrorMessage(e, 'Failed to load members'));
    }
  };

  const act = async (fn: () => Promise<string | void>) => {
    setBusy(true);
    setError(null);
    setNotice(null);
    try {
      const msg = await fn();
      if (msg) setNotice(msg);
    } catch (e: unknown) {
      setError(apiErrorMessage(e, 'Action failed'));
    } finally {
      setBusy(false);
    }
  };

  const createList = () =>
    act(async () => {
      if (!newName.trim()) throw new Error('List name is required');
      const res = await marketingService.createList({ name: newName.trim(), list_type: newType, channel: newChannel });
      const created = (res.data?.data ?? res.data) as MktList;
      setNewName('');
      await loadLists();
      await select(created);
      return newType === 'dynamic'
        ? 'List created — add a segment rule below.'
        : 'List created — add contacts below.';
    });

  const importContacts = () =>
    act(async () => {
      if (!selected) return;
      if (!csvText.trim()) throw new Error('Paste emails or CSV first');
      const res = await marketingService.importListCsv(selected.uuid, {
        csv: toCsv(csvText),
        grant_consent: grantConsent,
      });
      const r = (res.data?.data ?? res.data) as { added?: number; created?: number; skipped?: number };
      setCsvText('');
      await loadMembers(selected);
      return `Added ${r.added ?? 0} (new contacts: ${r.created ?? 0}, skipped: ${r.skipped ?? 0}).`;
    });

  const previewFile = (file: { name: string; base64: string }, legalBasis: LegalBasis) =>
    act(async () => {
      if (!selected) return;
      setScan(null);
      setLawful(false);
      const res = await marketingService.importContactsFile(selected.uuid, {
        file_name: file.name,
        content_base64: file.base64,
        legal_basis: legalBasis,
      });
      setScan((res.data?.data ?? res.data) as FileScan);
    });

  const chooseFile = async (file: File | undefined) => {
    if (!file) return;
    if (file.size > MAX_FILE_BYTES) {
      setError('That file is over 7 MB. Split it, or save it as CSV (much smaller than Excel or PDF).');
      return;
    }
    try {
      const picked = { name: file.name, base64: await readBase64(file) };
      setUpload(picked);
      await previewFile(picked, basis);
    } catch (e: unknown) {
      setError(apiErrorMessage(e, 'Could not read the file'));
    }
  };

  const importFile = () =>
    act(async () => {
      if (!selected || !upload) return;
      const res = await marketingService.importContactsFile(selected.uuid, {
        file_name: upload.name,
        content_base64: upload.base64,
        legal_basis: basis,
        source_note: sourceNote.trim() || undefined,
        commit: true,
        confirm: true,
      });
      const r = (res.data?.data ?? res.data) as FileScan;
      setUpload(null);
      setScan(null);
      setLawful(false);
      setSourceNote('');
      await loadMembers(selected);
      return `Imported ${r.imported ?? 0} contacts from ${upload.name} (${r.created_contacts ?? 0} new to the CRM).`;
    });

  const removeMember = (contactUuid: string) =>
    act(async () => {
      if (!selected) return;
      await marketingService.removeListMember(selected.uuid, contactUuid);
      await loadMembers(selected);
    });

  const deleteList = () =>
    act(async () => {
      if (!selected || !window.confirm(`Delete list "${selected.name}"?`)) return;
      await marketingService.deleteList(selected.uuid);
      setSelected(null);
      setMembers([]);
      await loadLists();
      return 'List deleted.';
    });

  const previewSegment = () =>
    act(async () => {
      if (conditions.length === 0) throw new Error('Add at least one condition');
      const res = await marketingService.previewSegment({ rule: buildRule(match, conditions), limit: 1 });
      const d = res.data?.data ?? res.data;
      setSegmentCount(d?.total ?? 0);
    });

  const saveSegment = () =>
    act(async () => {
      if (!selected) return;
      if (conditions.length === 0) throw new Error('Add at least one condition');
      const res = await marketingService.setListSegment(selected.uuid, {
        rule: buildRule(match, conditions),
        sync: true,
      });
      const d = res.data?.data ?? res.data;
      const rows = await loadLists();
      const fresh = rows.find((l) => l.uuid === selected.uuid);
      if (fresh) setSelected(fresh);
      await loadMembers(selected);
      return `Segment saved — ${d?.sync?.synced ?? 0} contact(s) now in the list.`;
    });

  const syncNow = () =>
    act(async () => {
      if (!selected) return;
      const res = await marketingService.syncList(selected.uuid);
      const d = res.data?.data ?? res.data;
      await loadMembers(selected);
      return `Synced ${d?.synced ?? 0} contact(s).`;
    });

  const updateCondition = (i: number, patch: Partial<Condition>) =>
    setConditions((cs) => cs.map((c, j) => (j === i ? { ...c, ...patch } : c)));

  const isDynamic = selected?.list_type === 'dynamic';

  return (
    <div className="space-y-6 p-6">
      <PageHeader
        title="Lists & segments"
        description="Build campaign audiences: add contacts to a static list, or define a dynamic segment over CRM contacts."
        icon={<Users className="h-5 w-5" />}
      />
      {error && <p className="text-sm text-error-600">{error}</p>}
      {notice && <p className="text-sm text-green-700 dark:text-green-400">{notice}</p>}

      <div className="grid gap-6 lg:grid-cols-[320px_1fr]">
        <div className="space-y-4">
          <div className="space-y-2 rounded-lg border border-secondary-200 p-4">
            <h2 className="text-sm font-medium">New list</h2>
            <input
              className="w-full rounded border border-secondary-200 bg-surface px-2 py-1.5 text-sm"
              placeholder="List name"
              aria-label="List name"
              value={newName}
              onChange={(e) => setNewName(e.target.value)}
            />
            <div className="flex gap-2">
              <select
                className="flex-1 rounded border border-secondary-200 bg-surface px-2 py-1.5 text-sm"
                aria-label="List type"
                value={newType}
                onChange={(e) => setNewType(e.target.value as 'static' | 'dynamic')}
              >
                <option value="static">Static (pick contacts)</option>
                <option value="dynamic">Dynamic (segment rule)</option>
              </select>
              <select
                className="rounded border border-secondary-200 bg-surface px-2 py-1.5 text-sm"
                aria-label="Channel"
                value={newChannel}
                onChange={(e) => setNewChannel(e.target.value)}
              >
                <option value="email">email</option>
                <option value="sms">sms</option>
              </select>
            </div>
            <Button size="sm" leftIcon={<Plus className="h-4 w-4" />} disabled={busy} onClick={() => void createList()}>
              Create list
            </Button>
          </div>

          <ul className="divide-y divide-secondary-200 rounded-lg border border-secondary-200">
            {lists.length === 0 && <li className="p-4 text-sm text-secondary-500">No lists yet.</li>}
            {lists.map((l) => (
              <li key={l.uuid}>
                <button
                  type="button"
                  className={`w-full p-3 text-left text-sm hover:bg-secondary-50 ${
                    selected?.uuid === l.uuid ? 'bg-secondary-100' : ''
                  }`}
                  onClick={() => void select(l)}
                >
                  <div className="font-medium">{l.name}</div>
                  <div className="text-xs text-secondary-500">
                    {l.list_type || 'static'} · {l.channel || 'email'}
                  </div>
                </button>
              </li>
            ))}
          </ul>
        </div>

        {!selected ? (
          <p className="text-sm text-secondary-500">Select a list to manage its contacts.</p>
        ) : (
          <div className="space-y-6">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <h2 className="text-lg font-semibold">
                {selected.name}{' '}
                <span className="text-sm font-normal text-secondary-500">
                  ({selected.list_type || 'static'}, {(memberTotal ?? members.length).toLocaleString('en-GB')} member
                  {(memberTotal ?? members.length) === 1 ? '' : 's'})
                </span>
              </h2>
              <Button
                size="sm"
                variant="danger"
                leftIcon={<Trash2 className="h-4 w-4" />}
                disabled={busy}
                onClick={() => void deleteList()}
              >
                Delete list
              </Button>
            </div>

            {isDynamic && (
              <div className="space-y-3 rounded-lg border border-secondary-200 p-4">
                <h3 className="text-sm font-medium">Segment rule</h3>
                <p className="text-xs text-secondary-500">
                  Members are CRM contacts matching this rule. Campaign Validate and Send re-sync automatically.
                </p>
                <label className="flex items-center gap-2 text-sm">
                  Match
                  <select
                    className="rounded border border-secondary-200 bg-surface px-2 py-1"
                    value={match}
                    onChange={(e) => setMatch(e.target.value as 'and' | 'or')}
                  >
                    <option value="and">all conditions</option>
                    <option value="or">any condition</option>
                  </select>
                </label>
                {conditions.map((c, i) => (
                  <div key={i} className="flex flex-wrap items-center gap-2">
                    <select
                      className="rounded border border-secondary-200 bg-surface px-2 py-1 text-sm"
                      aria-label="Field"
                      value={c.field}
                      onChange={(e) => updateCondition(i, { field: e.target.value })}
                    >
                      {fields.map((f) => (
                        <option key={f} value={f}>
                          {f}
                        </option>
                      ))}
                    </select>
                    <select
                      className="rounded border border-secondary-200 bg-surface px-2 py-1 text-sm"
                      aria-label="Operator"
                      value={c.op}
                      onChange={(e) => updateCondition(i, { op: e.target.value })}
                    >
                      {ops.map((o) => (
                        <option key={o} value={o}>
                          {OP_LABELS[o] || o}
                        </option>
                      ))}
                    </select>
                    {!NO_VALUE_OPS.includes(c.op) && (
                      <input
                        className="flex-1 rounded border border-secondary-200 bg-surface px-2 py-1 text-sm"
                        aria-label="Value"
                        value={c.value}
                        onChange={(e) => updateCondition(i, { value: e.target.value })}
                      />
                    )}
                    <button
                      type="button"
                      className="p-1 text-secondary-500 hover:text-error-600"
                      aria-label="Remove condition"
                      onClick={() => setConditions((cs) => cs.filter((_, j) => j !== i))}
                    >
                      <X className="h-4 w-4" />
                    </button>
                  </div>
                ))}
                <div className="flex flex-wrap items-center gap-2">
                  <Button
                    size="sm"
                    variant="outline"
                    leftIcon={<Plus className="h-4 w-4" />}
                    onClick={() =>
                      setConditions((cs) => [...cs, { field: fields[0] || 'email', op: 'contains', value: '' }])
                    }
                  >
                    Add condition
                  </Button>
                  <Button size="sm" variant="outline" disabled={busy} onClick={() => void previewSegment()}>
                    Preview
                  </Button>
                  <Button size="sm" disabled={busy} onClick={() => void saveSegment()}>
                    Save &amp; sync
                  </Button>
                  <Button
                    size="sm"
                    variant="ghost"
                    leftIcon={<RefreshCw className="h-4 w-4" />}
                    disabled={busy}
                    onClick={() => void syncNow()}
                  >
                    Re-sync
                  </Button>
                  {segmentCount !== null && (
                    <span className="text-sm text-secondary-500">{segmentCount} matching contact(s)</span>
                  )}
                </div>
              </div>
            )}

            {!isDynamic && (selected.channel || 'email') === 'email' && (
              <div className="space-y-3 rounded-lg border border-secondary-200 p-4">
                <h3 className="flex items-center gap-1.5 text-sm font-medium">
                  <FileUp className="h-4 w-4 text-secondary-500" aria-hidden="true" /> Import from a file
                </h3>
                <p className="text-xs text-secondary-500">
                  A CSV, Excel (.xlsx) or PDF of contacts, up to 7 MB. Every email in it is found, in any column, along
                  with name, company, phone and website when the file has those columns. You see what will be imported
                  before anything is added.
                </p>
                <div className="flex flex-wrap gap-4 text-sm" role="radiogroup" aria-label="Why you may email them">
                  {(
                    [
                      ['legitimate_interest', 'Business contacts (B2B, legitimate interest)'],
                      ['consent', 'They opted in to hear from us'],
                    ] as [LegalBasis, string][]
                  ).map(([value, label]) => (
                    <label key={value} className="flex items-center gap-1.5">
                      <input
                        type="radio"
                        name="legal-basis"
                        checked={basis === value}
                        onChange={() => {
                          setBasis(value);
                          if (upload) void previewFile(upload, value);
                        }}
                      />
                      {label}
                    </label>
                  ))}
                </div>
                <label className="block text-sm">
                  <span className="sr-only">Contacts file</span>
                  <input
                    type="file"
                    accept={ACCEPT_FILES}
                    disabled={busy}
                    className="block w-full text-sm file:mr-3 file:rounded file:border-0 file:bg-secondary-100 file:px-3 file:py-1.5 file:text-sm"
                    onChange={(e) => {
                      void chooseFile(e.target.files?.[0]);
                      e.target.value = '';
                    }}
                  />
                </label>
                {busy && upload && !scan && <p className="text-sm text-secondary-500">Reading {upload.name}…</p>}

                {scan && upload && (
                  <div className="space-y-3 rounded-md bg-secondary-50 p-3 text-sm dark:bg-secondary-900/40">
                    <p>
                      <strong>{upload.name}</strong> ({scan.file_type.toUpperCase()}): {scan.found.toLocaleString('en-GB')}{' '}
                      email{scan.found === 1 ? '' : 's'} found.
                    </p>
                    <ul className="grid gap-1 sm:grid-cols-2">
                      <li className="text-success-700 dark:text-success-400">
                        Will import: <strong>{scan.importable.toLocaleString('en-GB')}</strong> (
                        {scan.new_contacts.toLocaleString('en-GB')} new, {scan.existing_contacts.toLocaleString('en-GB')}{' '}
                        already in your CRM)
                      </li>
                      <li>Duplicates in the file: {scan.skipped.duplicates.toLocaleString('en-GB')}</li>
                      <li>
                        Already unsubscribed (never emailed again):{' '}
                        {scan.skipped.unsubscribed.toLocaleString('en-GB')}
                      </li>
                      {scan.personal_rule && (
                        <li>
                          Personal addresses skipped (gmail, hotmail…):{' '}
                          {scan.skipped.personal.toLocaleString('en-GB')}
                        </li>
                      )}
                    </ul>
                    {scan.personal_rule && scan.skipped.personal > 0 && (
                      <p className="text-xs text-secondary-500">
                        UK and EU law (PECR) treats personal mailboxes as private individuals: they must opt in before you
                        send them marketing, so business-contact imports leave them out.
                      </p>
                    )}
                    {scan.sample && scan.sample.length > 0 && (
                      <table className="w-full text-xs">
                        <thead className="text-left text-secondary-500">
                          <tr>
                            <th className="py-1 pr-2">Email</th>
                            <th className="py-1 pr-2">Name</th>
                            <th className="py-1">Company</th>
                          </tr>
                        </thead>
                        <tbody>
                          {scan.sample.slice(0, 8).map((r) => (
                            <tr key={r.email} className="border-t border-secondary-200">
                              <td className="py-1 pr-2">{r.email}</td>
                              <td className="py-1 pr-2">{[r.first_name, r.last_name].filter(Boolean).join(' ') || '—'}</td>
                              <td className="py-1">{r.company || '—'}</td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    )}
                    {scan.importable > 0 && (
                      <>
                        <label className="block text-sm">
                          <span className="text-xs text-secondary-500">
                            Where did this data come from? (optional, kept as a record)
                          </span>
                          <input
                            className="mt-1 w-full rounded border border-secondary-200 bg-surface px-2 py-1 text-sm"
                            value={sourceNote}
                            onChange={(e) => setSourceNote(e.target.value)}
                            placeholder="e.g. Bought from ExampleData Ltd, October 2026"
                            maxLength={1000}
                          />
                        </label>
                        <label className="flex items-start gap-2 text-sm">
                          <input
                            type="checkbox"
                            className="mt-1"
                            checked={lawful}
                            onChange={(e) => setLawful(e.target.checked)}
                          />
                          <span>
                            {basis === 'consent'
                              ? 'These people opted in to marketing from us.'
                              : 'These are business contacts I have a legitimate reason to email about our products.'}{' '}
                            Every email will say who we are and include an unsubscribe link, and anyone who unsubscribes
                            is never emailed again.
                          </span>
                        </label>
                        <Button
                          size="sm"
                          leftIcon={<Upload className="h-4 w-4" />}
                          disabled={busy || !lawful}
                          onClick={() => void importFile()}
                        >
                          Import {scan.importable.toLocaleString('en-GB')} contacts
                        </Button>
                      </>
                    )}
                  </div>
                )}
              </div>
            )}

            {!isDynamic && (
              <div className="space-y-3 rounded-lg border border-secondary-200 p-4">
                <h3 className="text-sm font-medium">Add contacts</h3>
                <p className="text-xs text-secondary-500">
                  Paste emails (one per line) or a CSV with a header row: email,first_name,last_name,phone. Existing
                  CRM contacts are matched by email; others are created.
                </p>
                <textarea
                  className="h-32 w-full rounded border border-secondary-200 bg-surface px-2 py-1.5 font-mono text-sm"
                  aria-label="Emails or CSV"
                  value={csvText}
                  onChange={(e) => setCsvText(e.target.value)}
                />
                <label className="flex items-start gap-2 text-sm">
                  <input
                    type="checkbox"
                    className="mt-1"
                    checked={grantConsent}
                    onChange={(e) => setGrantConsent(e.target.checked)}
                  />
                  <span>
                    These contacts have given consent to receive marketing on this channel. Without recorded consent,
                    contacts are counted as ineligible for marketing sends. Earlier opt-outs are never overridden.
                  </span>
                </label>
                <Button
                  size="sm"
                  leftIcon={<Upload className="h-4 w-4" />}
                  disabled={busy}
                  onClick={() => void importContacts()}
                >
                  Add to list
                </Button>
              </div>
            )}

            <div className="rounded-lg border border-secondary-200">
              <table className="w-full text-sm">
                <thead className="text-left text-secondary-500">
                  <tr>
                    <th className="p-2">Name</th>
                    <th className="p-2">Email</th>
                    <th className="p-2">Company</th>
                    <th className="p-2">Source</th>
                    <th className="p-2" />
                  </tr>
                </thead>
                <tbody>
                  {members.length === 0 && (
                    <tr>
                      <td colSpan={5} className="p-4 text-secondary-500">
                        No members yet — campaigns using this list will fail Validate until it has contacts.
                      </td>
                    </tr>
                  )}
                  {members.map((m) => (
                    <tr key={m.contact_uuid} className="border-t border-secondary-200">
                      <td className="p-2">{[m.first_name, m.last_name].filter(Boolean).join(' ') || '—'}</td>
                      <td className="p-2">{m.email || m.phone || '—'}</td>
                      <td className="p-2 text-secondary-500">{m.company || '—'}</td>
                      <td className="p-2 text-secondary-500">{m.source}</td>
                      <td className="p-2 text-right">
                        {m.source !== 'segment' && (
                          <button
                            type="button"
                            className="p-1 text-secondary-500 hover:text-error-600"
                            aria-label="Remove from list"
                            disabled={busy}
                            onClick={() => void removeMember(m.contact_uuid)}
                          >
                            <X className="h-4 w-4" />
                          </button>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

'use client';

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { isAxiosError } from 'axios';
import {
  ArrowLeft,
  Check,
  ContactRound,
  FileUp,
  Keyboard,
  Mail,
  Plus,
  RefreshCw,
  Search,
  Trash2,
  Users,
  X,
} from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button } from '@/components/ui';
import { marketingService } from '@/services/opsapi-marketing.service';
import { crmService, type CrmContact } from '@/services/crm.service';
import { STARTER } from '../campaigns/_components/shared';
import { HelpLink, downloadExampleCsv } from '@/components/opsapi-marketing/GettingStarted';

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

/** What a batch of people holds (the check step), or what was added from it. */
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

/** People waiting for the check step: typed, from a file, or picked from contacts. */
type Pending = { name: string; base64: string; how: AddMode; label: string };

type AddMode = 'type' | 'file' | 'contacts';

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

/** Text → base64 (UTF-8), in chunks so a long paste can't overflow the stack. */
function textBase64(text: string): string {
  const bytes = new TextEncoder().encode(text);
  let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

type Condition = { field: string; op: string; value: string };

const NO_VALUE_OPS = ['is_empty', 'not_empty'];
const OP_LABELS: Record<string, string> = {
  eq: 'is',
  neq: 'is not',
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

const people = (n: number) => `${n.toLocaleString('en-GB')} ${n === 1 ? 'person' : 'people'}`;

const CARD = 'rounded-xl border border-secondary-200 bg-surface p-5';
const FIELD = 'w-full rounded-lg border border-secondary-300 bg-surface px-3 py-2.5 text-base';

/** The three steps, with the ones already done ticked. */
function Steps({ done }: { done: [boolean, boolean, boolean] }) {
  const labels = ['Make a list', 'Add people to it', 'Send them an email'];
  const current = done.indexOf(false);
  return (
    <ol className="grid gap-2 sm:grid-cols-3" aria-label="How it works">
      {labels.map((label, i) => (
        <li
          key={label}
          aria-current={i === current ? 'step' : undefined}
          className={`flex items-center gap-3 rounded-xl border p-3 text-base ${
            i === current
              ? 'border-primary-500 bg-primary-50 font-medium text-primary-900 dark:bg-primary-900/30 dark:text-primary-100'
              : 'border-secondary-200 text-secondary-600'
          }`}
        >
          <span
            className={`flex h-8 w-8 shrink-0 items-center justify-center rounded-full text-sm font-semibold ${
              done[i] ? 'bg-success-600 text-white' : i === current ? 'bg-primary-600 text-white' : 'bg-secondary-200'
            }`}
            aria-hidden="true"
          >
            {done[i] ? <Check className="h-4 w-4" /> : i + 1}
          </span>
          {label}
          {done[i] && <span className="sr-only">(done)</span>}
        </li>
      ))}
    </ol>
  );
}

/** A big, clearly labelled choice button. */
function Choice({
  icon,
  title,
  hint,
  active,
  onClick,
}: {
  icon: React.ReactNode;
  title: string;
  hint: string;
  active: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      aria-pressed={active}
      onClick={onClick}
      className={`flex min-h-24 flex-col items-start gap-1 rounded-xl border-2 p-4 text-left transition-colors ${
        active
          ? 'border-primary-600 bg-primary-50 dark:bg-primary-900/30'
          : 'border-secondary-200 hover:border-primary-400 hover:bg-secondary-50 dark:hover:bg-secondary-900/40'
      }`}
    >
      <span className="flex items-center gap-2 text-base font-semibold">
        {icon}
        {title}
      </span>
      <span className="text-sm text-secondary-600">{hint}</span>
    </button>
  );
}

export default function MarketingListsPage() {
  const router = useRouter();
  const [lists, setLists] = useState<MktList[]>([]);
  const [counts, setCounts] = useState<Record<string, number>>({});
  const [loaded, setLoaded] = useState(false);
  const [selected, setSelected] = useState<MktList | null>(null);
  const [members, setMembers] = useState<Member[]>([]);
  const [memberTotal, setMemberTotal] = useState<number | null>(null);
  const [memberFilter, setMemberFilter] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const [showNew, setShowNew] = useState(false);
  const [newName, setNewName] = useState('');
  const [newType, setNewType] = useState<'static' | 'dynamic'>('static');
  const [newChannel, setNewChannel] = useState('email');

  // Adding people: pick how, collect them, then one check-and-confirm step for all three ways.
  const [mode, setMode] = useState<AddMode | null>(null);
  const [typed, setTyped] = useState('');
  const [contactQuery, setContactQuery] = useState('');
  const [contacts, setContacts] = useState<CrmContact[]>([]);
  const [contactsError, setContactsError] = useState<string | null>(null);
  const [picked, setPicked] = useState<Record<string, string>>({}); // contact uuid -> email
  const [pending, setPending] = useState<Pending | null>(null);
  const [basis, setBasis] = useState<LegalBasis>('legitimate_interest');
  const [sourceNote, setSourceNote] = useState('');
  const [scan, setScan] = useState<FileScan | null>(null);
  const [lawful, setLawful] = useState(false);

  // Text-message lists: phone numbers pasted, consent required.
  const [smsText, setSmsText] = useState('');
  const [smsConsent, setSmsConsent] = useState(false);

  const [fields, setFields] = useState<string[]>([]);
  const [ops, setOps] = useState<string[]>([]);
  const [match, setMatch] = useState<'and' | 'or'>('and');
  const [conditions, setConditions] = useState<Condition[]>([]);
  const [segmentCount, setSegmentCount] = useState<number | null>(null);

  const loadLists = useCallback(async () => {
    const [res, cRes] = await Promise.all([
      marketingService.listLists({ per_page: 100 }),
      marketingService.listCounts().catch(() => null),
    ]);
    const data = res.data?.data ?? res.data ?? [];
    const rows: MktList[] = Array.isArray(data) ? data : data.items || [];
    const c = cRes?.data?.data ?? cRes?.data;
    setLists(rows);
    setCounts(c && typeof c === 'object' && !Array.isArray(c) ? c : {});
    setLoaded(true);
    return rows;
  }, []);

  const loadMembers = useCallback(async (list: MktList) => {
    const res = await marketingService.listMembers(list.uuid);
    const data = res.data?.data ?? res.data ?? [];
    const rows: Member[] = Array.isArray(data) ? data : [];
    const total = typeof res.data?.meta?.total === 'number' ? res.data.meta.total : rows.length;
    setMembers(rows);
    setMemberTotal(total);
    setCounts((c) => ({ ...c, [list.uuid]: total }));
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
        setError(apiErrorMessage(e, 'Could not load your lists'));
      }
    })();
  }, [loadLists]);

  // Contacts to pick from, searched as you type.
  useEffect(() => {
    if (mode !== 'contacts') return;
    let cancelled = false;
    const handle = window.setTimeout(() => {
      crmService
        .getContacts({ search: contactQuery.trim() || undefined, perPage: 50 })
        .then((r) => {
          if (cancelled) return;
          setContacts(r.data);
          setContactsError(null);
        })
        .catch((e: unknown) => {
          if (cancelled) return;
          setContacts([]);
          setContactsError(
            isAxiosError(e) && e.response?.status === 403
              ? 'Your access doesn’t include Contacts. Ask the workspace owner, or type the email addresses instead.'
              : apiErrorMessage(e, 'Could not load your contacts'),
          );
        });
    }, 300);
    return () => {
      cancelled = true;
      window.clearTimeout(handle);
    };
  }, [mode, contactQuery]);

  const resetAdd = () => {
    setMode(null);
    setTyped('');
    setPicked({});
    setPending(null);
    setScan(null);
    setLawful(false);
    setSourceNote('');
    setSmsText('');
    setSmsConsent(false);
  };

  const select = async (list: MktList) => {
    setSelected(list);
    setError(null);
    setNotice(null);
    setSegmentCount(null);
    setMemberFilter('');
    resetAdd();
    const parsed = parseRule(list.segment_rule);
    setMatch(parsed.match);
    setConditions(parsed.conditions);
    try {
      await loadMembers(list);
    } catch (e: unknown) {
      setError(apiErrorMessage(e, 'Could not load the people in this list'));
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
      setError(apiErrorMessage(e, 'That didn’t work. Please try again.'));
    } finally {
      setBusy(false);
    }
  };

  const createList = (e?: React.FormEvent) => {
    e?.preventDefault();
    return act(async () => {
      if (!newName.trim()) throw new Error('Type a name for your list first, e.g. “Customers”.');
      const res = await marketingService.createList({ name: newName.trim(), list_type: newType, channel: newChannel });
      const created = (res.data?.data ?? res.data) as MktList;
      setNewName('');
      setNewType('static');
      setNewChannel('email');
      setShowNew(false);
      await loadLists();
      await select(created);
      return newType === 'dynamic'
        ? `“${created.name}” is ready. Now choose who belongs in it.`
        : `“${created.name}” is ready. Now add the people you want to email.`;
    });
  };

  /** Show what a batch holds and what will be added (nothing is added yet). */
  const check = (p: Pending, legalBasis: LegalBasis) =>
    act(async () => {
      if (!selected) return;
      setScan(null);
      setLawful(false);
      const res = await marketingService.importContactsFile(selected.uuid, {
        file_name: p.name,
        content_base64: p.base64,
        legal_basis: legalBasis,
      });
      setScan((res.data?.data ?? res.data) as FileScan);
    });

  const startCheck = (p: Pending) => {
    setPending(p);
    void check(p, basis);
  };

  const checkTyped = () => {
    if (!typed.trim()) {
      setError('Type or paste at least one email address.');
      return;
    }
    startCheck({ name: 'typed-in.csv', base64: textBase64(toCsv(typed)), how: 'type', label: 'Typed in by hand' });
  };

  const checkPicked = () => {
    const emails = Object.values(picked);
    if (emails.length === 0) {
      setError('Tick at least one person.');
      return;
    }
    startCheck({
      name: 'from-contacts.csv',
      base64: textBase64(['email', ...emails].join('\n')),
      how: 'contacts',
      label: 'Chosen from contacts',
    });
  };

  const chooseFile = async (file: File | undefined) => {
    if (!file) return;
    setError(null);
    if (file.size > MAX_FILE_BYTES) {
      setError('That file is too big (over 7 MB). Save it as CSV, or split it into smaller files.');
      return;
    }
    try {
      startCheck({ name: file.name, base64: await readBase64(file), how: 'file', label: '' });
    } catch (e: unknown) {
      setError(apiErrorMessage(e, 'Could not read the file'));
    }
  };

  const confirmAdd = () =>
    act(async () => {
      if (!selected || !pending) return;
      const res = await marketingService.importContactsFile(selected.uuid, {
        file_name: pending.name,
        content_base64: pending.base64,
        legal_basis: basis,
        source_note: sourceNote.trim() || pending.label || undefined,
        commit: true,
        confirm: true,
      });
      const r = (res.data?.data ?? res.data) as FileScan;
      resetAdd();
      await loadMembers(selected);
      return `Done! ${people(r.imported ?? 0)} added to “${selected.name}”.`;
    });

  const addSms = () =>
    act(async () => {
      if (!selected) return;
      if (!smsText.trim()) throw new Error('Paste the phone numbers first.');
      const res = await marketingService.importListCsv(selected.uuid, { csv: smsText.trim(), grant_consent: true });
      const r = (res.data?.data ?? res.data) as { added?: number; skipped?: number };
      resetAdd();
      await loadMembers(selected);
      return `Done! ${people(r.added ?? 0)} added${r.skipped ? ` (${r.skipped} skipped)` : ''}.`;
    });

  const removeMember = (m: Member) =>
    act(async () => {
      if (!selected) return;
      await marketingService.removeListMember(selected.uuid, m.contact_uuid);
      await loadMembers(selected);
      return `${m.email || m.phone || 'That person'} was taken off this list (still in your contacts).`;
    });

  const deleteList = () =>
    act(async () => {
      if (
        !selected ||
        !window.confirm(`Delete the list “${selected.name}”?\n\nThe people stay in your contacts — only the list goes.`)
      )
        return;
      await marketingService.deleteList(selected.uuid);
      setSelected(null);
      setMembers([]);
      await loadLists();
      return 'List deleted.';
    });

  const writeEmail = () =>
    act(async () => {
      if (!selected) return;
      const res = await marketingService.createCampaign({ name: `Email to ${selected.name}`, ...STARTER });
      const row = (res.data?.data ?? res.data) as { uuid: string };
      router.push(`/dashboard/opsapi-marketing/campaigns/${row.uuid}?tab=content&list=${selected.uuid}`);
    });

  const previewSegment = () =>
    act(async () => {
      if (conditions.length === 0) throw new Error('Add at least one rule');
      const res = await marketingService.previewSegment({ rule: buildRule(match, conditions), limit: 1 });
      const d = res.data?.data ?? res.data;
      setSegmentCount(d?.total ?? 0);
    });

  const saveSegment = () =>
    act(async () => {
      if (!selected) return;
      if (conditions.length === 0) throw new Error('Add at least one rule');
      const res = await marketingService.setListSegment(selected.uuid, {
        rule: buildRule(match, conditions),
        sync: true,
      });
      const d = res.data?.data ?? res.data;
      const rows = await loadLists();
      const fresh = rows.find((l) => l.uuid === selected.uuid);
      if (fresh) setSelected(fresh);
      await loadMembers(selected);
      return `Saved — ${people(d?.sync?.synced ?? 0)} now in the list.`;
    });

  const syncNow = () =>
    act(async () => {
      if (!selected) return;
      const res = await marketingService.syncList(selected.uuid);
      const d = res.data?.data ?? res.data;
      await loadMembers(selected);
      return `Updated — ${people(d?.synced ?? 0)} in the list.`;
    });

  const updateCondition = (i: number, patch: Partial<Condition>) =>
    setConditions((cs) => cs.map((c, j) => (j === i ? { ...c, ...patch } : c)));

  const isDynamic = selected?.list_type === 'dynamic';
  const isSms = (selected?.channel || 'email') === 'sms';
  const total = memberTotal ?? members.length;
  const memberUuids = useMemo(() => new Set(members.map((m) => m.contact_uuid)), [members]);
  const shownMembers = useMemo(() => {
    const q = memberFilter.trim().toLowerCase();
    if (!q) return members;
    return members.filter((m) =>
      [m.first_name, m.last_name, m.email, m.phone, m.company].some((v) => v && v.toLowerCase().includes(q)),
    );
  }, [members, memberFilter]);
  const pickable = contacts.filter((c) => c.email && !memberUuids.has(c.uuid));
  const pickedCount = Object.keys(picked).length;

  const newListForm = (
    <form onSubmit={(e) => void createList(e)} className="space-y-3">
      <label className="block">
        <span className="text-base font-medium">What do you want to call this list?</span>
        <input
          className={`${FIELD} mt-1`}
          placeholder="e.g. Customers, Local businesses, Newsletter"
          value={newName}
          onChange={(e) => setNewName(e.target.value)}
          maxLength={255}
          autoFocus
        />
      </label>
      <details className="text-sm text-secondary-600">
        <summary className="cursor-pointer select-none py-1">More options (most people don’t need these)</summary>
        <div className="mt-2 space-y-2 pl-1">
          <label className="flex items-start gap-2">
            <input
              type="checkbox"
              className="mt-1"
              checked={newChannel === 'sms'}
              onChange={(e) => setNewChannel(e.target.checked ? 'sms' : 'email')}
            />
            <span>For text messages (SMS) instead of email</span>
          </label>
          <label className="flex items-start gap-2">
            <input
              type="checkbox"
              className="mt-1"
              checked={newType === 'dynamic'}
              onChange={(e) => setNewType(e.target.checked ? 'dynamic' : 'static')}
            />
            <span>Smart list: fills itself with contacts that match rules you set (e.g. everyone in London)</span>
          </label>
        </div>
      </details>
      <div className="flex flex-wrap gap-2">
        <Button type="submit" size="lg" leftIcon={<Plus className="h-5 w-5" />} disabled={busy}>
          Create list
        </Button>
        {lists.length > 0 && (
          <Button type="button" size="lg" variant="ghost" onClick={() => setShowNew(false)}>
            Cancel
          </Button>
        )}
      </div>
    </form>
  );

  return (
    <div className="mx-auto max-w-6xl space-y-6 p-4 sm:p-6">
      <PageHeader
        title="Mailing lists"
        description="A list is a group of people you send emails to. Make a list, add people, then write them an email."
        icon={<Users className="h-5 w-5" />}
        actions={<HelpLink topic="make-list">How do lists work?</HelpLink>}
      />

      <Steps done={[lists.length > 0, !!selected && total > 0, false]} />

      {error && (
        <div role="alert" className="rounded-xl border border-error-500 bg-error-500/10 p-4 text-base text-error-600">
          {error}
        </div>
      )}
      {notice && (
        <div role="status" className="rounded-xl border border-success-500 bg-success-500/10 p-4 text-base text-success-600">
          {notice}
        </div>
      )}

      {loaded && lists.length === 0 ? (
        <div className={`${CARD} mx-auto max-w-xl`}>
          <h2 className="mb-1 text-xl font-semibold">Make your first list</h2>
          <p className="mb-4 text-base text-secondary-600">
            Give it a name you’ll recognise. You’ll add people to it in the next step.
          </p>
          {newListForm}
        </div>
      ) : (
        <div className="grid gap-6 lg:grid-cols-[300px_1fr]">
          <div className="space-y-3">
            {showNew ? (
              <div className={CARD}>{newListForm}</div>
            ) : (
              <Button
                size="lg"
                className="w-full"
                leftIcon={<Plus className="h-5 w-5" />}
                onClick={() => setShowNew(true)}
              >
                Make a new list
              </Button>
            )}
            <h2 className="pt-2 text-sm font-medium uppercase tracking-wide text-secondary-500">Your lists</h2>
            <ul className="space-y-2">
              {lists.map((l) => {
                const n = counts[l.uuid];
                return (
                  <li key={l.uuid}>
                    <button
                      type="button"
                      aria-current={selected?.uuid === l.uuid ? 'true' : undefined}
                      className={`w-full rounded-xl border-2 p-3 text-left ${
                        selected?.uuid === l.uuid
                          ? 'border-primary-600 bg-primary-50 dark:bg-primary-900/30'
                          : 'border-secondary-200 hover:border-primary-400'
                      }`}
                      onClick={() => void select(l)}
                    >
                      <div className="text-base font-medium">{l.name}</div>
                      <div className="text-sm text-secondary-600">
                        {n === undefined ? '…' : n === 0 ? 'Empty — add people' : people(n)}
                        {l.channel === 'sms' ? ' · text messages' : ''}
                        {l.list_type === 'dynamic' ? ' · smart list' : ''}
                      </div>
                    </button>
                  </li>
                );
              })}
            </ul>
          </div>

          {!selected ? (
            <div className={`${CARD} flex min-h-48 flex-col items-center justify-center text-center`}>
              <ArrowLeft className="mb-2 hidden h-6 w-6 text-secondary-400 lg:block" aria-hidden="true" />
              <p className="text-lg">Click a list to see who’s in it and add people.</p>
            </div>
          ) : (
            <div className="space-y-6">
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <h2 className="text-2xl font-semibold">{selected.name}</h2>
                  <p className="text-base text-secondary-600">
                    {total === 0 ? 'Nobody in this list yet.' : `${people(total)} in this list.`}
                  </p>
                </div>
                <Button
                  variant="ghost"
                  leftIcon={<Trash2 className="h-4 w-4" />}
                  disabled={busy}
                  onClick={() => void deleteList()}
                >
                  Delete this list
                </Button>
              </div>

              {isDynamic && (
                <section className={`${CARD} space-y-3`}>
                  <h3 className="text-lg font-semibold">Who belongs in this smart list</h3>
                  <p className="text-sm text-secondary-600">
                    Contacts that match these rules are put in the list for you, and it updates itself before every
                    email.
                  </p>
                  <label className="flex items-center gap-2 text-base">
                    Include contacts that match
                    <select
                      className="rounded-lg border border-secondary-300 bg-surface px-2 py-1.5"
                      value={match}
                      onChange={(e) => setMatch(e.target.value as 'and' | 'or')}
                    >
                      <option value="and">all of the rules</option>
                      <option value="or">any rule</option>
                    </select>
                  </label>
                  {conditions.map((c, i) => (
                    <div key={i} className="flex flex-wrap items-center gap-2">
                      <select
                        className="rounded-lg border border-secondary-300 bg-surface px-2 py-1.5 text-base"
                        aria-label="Field"
                        value={c.field}
                        onChange={(e) => updateCondition(i, { field: e.target.value })}
                      >
                        {fields.map((f) => (
                          <option key={f} value={f}>
                            {f.replace(/[._]/g, ' ')}
                          </option>
                        ))}
                      </select>
                      <select
                        className="rounded-lg border border-secondary-300 bg-surface px-2 py-1.5 text-base"
                        aria-label="Rule"
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
                          className="flex-1 rounded-lg border border-secondary-300 bg-surface px-2 py-1.5 text-base"
                          aria-label="Value"
                          value={c.value}
                          onChange={(e) => updateCondition(i, { value: e.target.value })}
                        />
                      )}
                      <button
                        type="button"
                        className="p-2 text-secondary-500 hover:text-error-600"
                        aria-label="Remove this rule"
                        onClick={() => setConditions((cs) => cs.filter((_, j) => j !== i))}
                      >
                        <X className="h-5 w-5" />
                      </button>
                    </div>
                  ))}
                  <div className="flex flex-wrap items-center gap-2">
                    <Button
                      variant="outline"
                      leftIcon={<Plus className="h-4 w-4" />}
                      onClick={() =>
                        setConditions((cs) => [...cs, { field: fields[0] || 'email', op: 'contains', value: '' }])
                      }
                    >
                      Add a rule
                    </Button>
                    <Button variant="outline" disabled={busy} onClick={() => void previewSegment()}>
                      How many match?
                    </Button>
                    <Button disabled={busy} onClick={() => void saveSegment()}>
                      Save
                    </Button>
                    <Button
                      variant="ghost"
                      leftIcon={<RefreshCw className="h-4 w-4" />}
                      disabled={busy}
                      onClick={() => void syncNow()}
                    >
                      Update now
                    </Button>
                    {segmentCount !== null && <span className="text-base">{people(segmentCount)} match</span>}
                  </div>
                </section>
              )}

              {!isDynamic && isSms && (
                <section className={`${CARD} space-y-3`}>
                  <h3 className="text-lg font-semibold">Add people to this list</h3>
                  <p className="text-base text-secondary-600">
                    Paste one person per line: <code>email,first_name,phone</code> as the first line, then each person
                    (e.g. <code>jane@shop.co.uk,Jane,+44 7700 900123</code>).
                  </p>
                  <textarea
                    className={`${FIELD} h-36 font-mono text-sm`}
                    aria-label="People to add"
                    value={smsText}
                    onChange={(e) => setSmsText(e.target.value)}
                  />
                  <label className="flex items-start gap-2 text-base">
                    <input
                      type="checkbox"
                      className="mt-1.5 h-4 w-4"
                      checked={smsConsent}
                      onChange={(e) => setSmsConsent(e.target.checked)}
                    />
                    <span>These people agreed to get text messages from me.</span>
                  </label>
                  <Button size="lg" disabled={busy || !smsConsent} onClick={() => void addSms()}>
                    Add to list
                  </Button>
                </section>
              )}

              {!isDynamic && !isSms && (
                <section className={`${CARD} space-y-4`}>
                  <h3 className="text-lg font-semibold">Add people to this list</h3>

                  {!pending && (
                    <>
                      <p className="text-base text-secondary-600">How would you like to add them?</p>
                      <div className="grid gap-3 md:grid-cols-3">
                        <Choice
                          icon={<Keyboard className="h-5 w-5" />}
                          title="Type email addresses"
                          hint="Type or paste them in, one per line."
                          active={mode === 'type'}
                          onClick={() => setMode('type')}
                        />
                        <Choice
                          icon={<FileUp className="h-5 w-5" />}
                          title="Upload a file"
                          hint="An Excel, CSV or PDF file. We find the email addresses in it."
                          active={mode === 'file'}
                          onClick={() => setMode('file')}
                        />
                        <Choice
                          icon={<ContactRound className="h-5 w-5" />}
                          title="Choose from my contacts"
                          hint="Tick people already saved in your contacts."
                          active={mode === 'contacts'}
                          onClick={() => setMode('contacts')}
                        />
                      </div>

                      {mode === 'type' && (
                        <div className="space-y-3">
                          <label className="block">
                            <span className="text-base font-medium">Email addresses</span>
                            <textarea
                              className={`${FIELD} mt-1 h-40 font-mono`}
                              placeholder={'jane@company.co.uk\njohn@business.com'}
                              value={typed}
                              onChange={(e) => setTyped(e.target.value)}
                              autoFocus
                            />
                          </label>
                          <Button size="lg" disabled={busy} onClick={checkTyped}>
                            Next
                          </Button>
                        </div>
                      )}

                      {mode === 'file' && (
                        <label className="flex cursor-pointer flex-col items-center justify-center gap-2 rounded-xl border-2 border-dashed border-secondary-300 p-8 text-center hover:border-primary-500">
                          <FileUp className="h-8 w-8 text-secondary-500" aria-hidden="true" />
                          <span className="text-base font-medium">Click here to choose your file</span>
                          <span className="text-sm text-secondary-600">Excel (.xlsx), CSV or PDF, up to 7 MB</span>
                          <span className="text-sm text-secondary-600">
                            Only an email column is needed; names and company are used if they’re there.
                          </span>
                          <input
                            type="file"
                            accept={ACCEPT_FILES}
                            disabled={busy}
                            className="sr-only"
                            onChange={(e) => {
                              void chooseFile(e.target.files?.[0]);
                              e.target.value = '';
                            }}
                          />
                        </label>
                      )}
                      {mode === 'file' && (
                        <div className="flex flex-wrap items-center gap-2">
                          <Button variant="ghost" onClick={downloadExampleCsv}>
                            Download an example file
                          </Button>
                          <HelpLink topic="import-file">How to get your file ready</HelpLink>
                        </div>
                      )}

                      {mode === 'contacts' && (
                        <div className="space-y-3">
                          <label className="relative block">
                            <span className="sr-only">Search your contacts</span>
                            <Search
                              className="pointer-events-none absolute left-3 top-1/2 h-5 w-5 -translate-y-1/2 text-secondary-400"
                              aria-hidden="true"
                            />
                            <input
                              className={`${FIELD} pl-10`}
                              placeholder="Search by name, email or company"
                              value={contactQuery}
                              onChange={(e) => setContactQuery(e.target.value)}
                              autoFocus
                            />
                          </label>
                          {contactsError ? (
                            <p className="text-base text-error-600">{contactsError}</p>
                          ) : (
                            <>
                              {pickable.length > 0 && (
                                <button
                                  type="button"
                                  className="text-sm font-medium text-primary-700 underline underline-offset-2 dark:text-primary-300"
                                  onClick={() =>
                                    setPicked((p) => {
                                      const next = { ...p };
                                      for (const c of pickable) next[c.uuid] = c.email as string;
                                      return next;
                                    })
                                  }
                                >
                                  Tick everyone shown ({pickable.length})
                                </button>
                              )}
                              <ul className="max-h-80 divide-y divide-secondary-200 overflow-y-auto rounded-xl border border-secondary-200">
                                {contacts.length === 0 && (
                                  <li className="p-4 text-base text-secondary-600">
                                    {contactQuery ? 'Nobody matches that search.' : 'No contacts yet.'}
                                  </li>
                                )}
                                {contacts.map((c) => {
                                  const inList = memberUuids.has(c.uuid);
                                  const name = [c.first_name, c.last_name].filter(Boolean).join(' ') || c.email || '—';
                                  return (
                                    <li key={c.uuid}>
                                      <label
                                        className={`flex items-center gap-3 px-4 py-3 ${
                                          !c.email || inList ? 'opacity-60' : 'cursor-pointer hover:bg-secondary-50 dark:hover:bg-secondary-900/40'
                                        }`}
                                      >
                                        <input
                                          type="checkbox"
                                          className="h-5 w-5"
                                          disabled={!c.email || inList}
                                          checked={inList || !!picked[c.uuid]}
                                          onChange={(e) =>
                                            setPicked((p) => {
                                              const next = { ...p };
                                              if (e.target.checked && c.email) next[c.uuid] = c.email;
                                              else delete next[c.uuid];
                                              return next;
                                            })
                                          }
                                        />
                                        <span className="min-w-0 flex-1">
                                          <span className="block truncate text-base">{name}</span>
                                          <span className="block truncate text-sm text-secondary-600">
                                            {c.email || 'No email address'}
                                            {c.account_name ? ` · ${c.account_name}` : ''}
                                          </span>
                                        </span>
                                        {inList && <span className="text-sm text-secondary-600">Already in list</span>}
                                      </label>
                                    </li>
                                  );
                                })}
                              </ul>
                              <Button size="lg" disabled={busy || pickedCount === 0} onClick={checkPicked}>
                                {pickedCount === 0 ? 'Tick the people to add' : `Next: add ${people(pickedCount)}`}
                              </Button>
                            </>
                          )}
                        </div>
                      )}
                    </>
                  )}

                  {pending && !scan && (
                    <p className="text-base text-secondary-600" role="status">
                      {busy ? 'Checking the email addresses…' : 'Something went wrong — go back and try again.'}
                    </p>
                  )}

                  {pending && scan && (
                    <div className="space-y-4">
                      <div className="rounded-xl bg-secondary-50 p-4 text-base dark:bg-secondary-900/40">
                        <p className="text-lg font-semibold">
                          {scan.importable > 0
                            ? `${people(scan.importable)} will be added.`
                            : 'Nobody new to add from these.'}
                        </p>
                        <p className="text-secondary-600">
                          We found {scan.found.toLocaleString('en-GB')} email address{scan.found === 1 ? '' : 'es'}
                          {pending.how === 'file' ? ` in ${pending.name}` : ''}.
                        </p>
                        <ul className="mt-2 list-disc space-y-1 pl-5 text-secondary-700 dark:text-secondary-300">
                          {scan.skipped.duplicates > 0 && (
                            <li>{scan.skipped.duplicates.toLocaleString('en-GB')} were listed twice (added once).</li>
                          )}
                          {scan.skipped.unsubscribed > 0 && (
                            <li>
                              {scan.skipped.unsubscribed.toLocaleString('en-GB')} asked not to get emails, so they are
                              left out.
                            </li>
                          )}
                          {scan.personal_rule && scan.skipped.personal > 0 && (
                            <li>
                              {scan.skipped.personal.toLocaleString('en-GB')} personal address
                              {scan.skipped.personal === 1 ? '' : 'es'} (like Gmail or Hotmail) left out: the law only
                              lets you email these people if they asked to hear from you. If they did, choose “People who
                              asked to get my emails” below.
                            </li>
                          )}
                        </ul>
                      </div>

                      <fieldset className="space-y-2">
                        <legend className="mb-1 text-base font-medium">Who are these people?</legend>
                        {(
                          [
                            [
                              'legitimate_interest',
                              'Businesses I want to tell about my products',
                              'Company email addresses, e.g. from a business directory or a list you bought.',
                            ],
                            [
                              'consent',
                              'People who asked to get my emails',
                              'They signed up on my website, in my shop, or told me yes.',
                            ],
                          ] as [LegalBasis, string, string][]
                        ).map(([value, title, hint]) => (
                          <label
                            key={value}
                            className={`flex cursor-pointer items-start gap-3 rounded-xl border-2 p-3 ${
                              basis === value ? 'border-primary-600 bg-primary-50 dark:bg-primary-900/30' : 'border-secondary-200'
                            }`}
                          >
                            <input
                              type="radio"
                              name="who"
                              className="mt-1 h-4 w-4"
                              checked={basis === value}
                              onChange={() => {
                                setBasis(value);
                                void check(pending, value);
                              }}
                            />
                            <span>
                              <span className="block text-base font-medium">{title}</span>
                              <span className="block text-sm text-secondary-600">{hint}</span>
                            </span>
                          </label>
                        ))}
                      </fieldset>

                      {scan.importable > 0 && (
                        <>
                          {pending.how === 'file' && (
                            <label className="block">
                              <span className="text-base">Where did you get this list? (optional, saved as a note)</span>
                              <input
                                className={`${FIELD} mt-1`}
                                value={sourceNote}
                                onChange={(e) => setSourceNote(e.target.value)}
                                placeholder="e.g. Bought from ExampleData Ltd, October 2026"
                                maxLength={1000}
                              />
                            </label>
                          )}
                          <label className="flex items-start gap-3 rounded-xl border border-secondary-200 p-3 text-base">
                            <input
                              type="checkbox"
                              className="mt-1 h-5 w-5"
                              checked={lawful}
                              onChange={(e) => setLawful(e.target.checked)}
                            />
                            <span>
                              I’m allowed to email these people. Every email will show my business name and address,
                              and anyone can unsubscribe with one click — they are never emailed again.
                            </span>
                          </label>
                        </>
                      )}

                      <div className="flex flex-wrap gap-2">
                        {scan.importable > 0 && (
                          <Button
                            size="lg"
                            leftIcon={<Check className="h-5 w-5" />}
                            disabled={busy || !lawful}
                            onClick={() => void confirmAdd()}
                          >
                            {lawful ? `Add ${people(scan.importable)}` : 'Tick the box above to continue'}
                          </Button>
                        )}
                        <Button
                          size="lg"
                          variant="outline"
                          leftIcon={<ArrowLeft className="h-5 w-5" />}
                          disabled={busy}
                          onClick={() => {
                            setPending(null);
                            setScan(null);
                            setLawful(false);
                          }}
                        >
                          Back
                        </Button>
                      </div>
                    </div>
                  )}
                </section>
              )}

              {total > 0 && (
                <section className={`${CARD} flex flex-wrap items-center justify-between gap-4 border-primary-500`}>
                  <div>
                    <h3 className="text-lg font-semibold">Ready to send?</h3>
                    <p className="text-base text-secondary-600">
                      Write an email and send it to the {people(total)} in “{selected.name}”.
                    </p>
                  </div>
                  <Button size="lg" leftIcon={<Mail className="h-5 w-5" />} disabled={busy} onClick={() => void writeEmail()}>
                    Write an email to them
                  </Button>
                </section>
              )}

              <section className={`${CARD} space-y-3`}>
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <h3 className="text-lg font-semibold">People in this list ({total.toLocaleString('en-GB')})</h3>
                  {members.length > 10 && (
                    <label className="relative block w-full sm:w-64">
                      <span className="sr-only">Find someone in this list</span>
                      <Search
                        className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-secondary-400"
                        aria-hidden="true"
                      />
                      <input
                        className="w-full rounded-lg border border-secondary-300 bg-surface py-2 pl-9 pr-3 text-base"
                        placeholder="Find someone"
                        value={memberFilter}
                        onChange={(e) => setMemberFilter(e.target.value)}
                      />
                    </label>
                  )}
                </div>
                {members.length === 0 ? (
                  <p className="text-base text-secondary-600">
                    {isDynamic
                      ? 'Nobody matches the rules yet.'
                      : 'Nobody here yet. Use “Add people to this list” above.'}
                  </p>
                ) : (
                  <div className="overflow-x-auto">
                    <table className="w-full text-base">
                      <thead className="text-left text-sm text-secondary-600">
                        <tr>
                          <th className="py-2 pr-3 font-medium">Name</th>
                          <th className="py-2 pr-3 font-medium">{isSms ? 'Phone' : 'Email'}</th>
                          <th className="hidden py-2 pr-3 font-medium sm:table-cell">Company</th>
                          <th className="py-2">
                            <span className="sr-only">Remove</span>
                          </th>
                        </tr>
                      </thead>
                      <tbody>
                        {shownMembers.map((m) => (
                          <tr key={m.contact_uuid} className="border-t border-secondary-200">
                            <td className="py-2 pr-3">{[m.first_name, m.last_name].filter(Boolean).join(' ') || '—'}</td>
                            <td className="break-all py-2 pr-3">{(isSms ? m.phone : m.email) || m.email || m.phone || '—'}</td>
                            <td className="hidden py-2 pr-3 text-secondary-600 sm:table-cell">{m.company || '—'}</td>
                            <td className="py-2 text-right">
                              {m.source !== 'segment' && (
                                <button
                                  type="button"
                                  className="rounded-lg px-2 py-1 text-sm text-secondary-600 hover:bg-error-500/10 hover:text-error-600"
                                  disabled={busy}
                                  onClick={() => void removeMember(m)}
                                >
                                  Remove
                                </button>
                              )}
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                    {total > members.length && (
                      <p className="mt-2 text-sm text-secondary-600">
                        Showing the newest {members.length.toLocaleString('en-GB')} of {total.toLocaleString('en-GB')}.
                      </p>
                    )}
                  </div>
                )}
              </section>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

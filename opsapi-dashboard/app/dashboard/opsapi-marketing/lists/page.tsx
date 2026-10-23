'use client';

import React, { Suspense, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { usePathname, useRouter, useSearchParams } from 'next/navigation';
import toast from 'react-hot-toast';
import { Check, Mail, MessageSquare, Pencil, Plus, Search, Sparkles, Trash2, Users, X } from 'lucide-react';
import { PageHeader } from '@/components/layout/PageHeader';
import { Button, ConfirmDialog } from '@/components/ui';
import { marketingService } from '@/services/opsapi-marketing.service';
import { HelpLink } from '@/components/opsapi-marketing/GettingStarted';
import { STARTER } from '../campaigns/_components/shared';
import { AddPeople } from './_components/AddPeople';
import { AddSmsPeople, SmartListRules } from './_components/OtherLists';
import {
  Alert,
  CARD,
  FIELD,
  type Member,
  type MktList,
  SOURCE_LABELS,
  Skeleton,
  fmtDate,
  friendlyError,
  people,
} from './_components/shared';

type Load = 'loading' | 'ready' | 'error';

/** The three steps, with the ones already done ticked. */
function Steps({ done }: { done: [boolean, boolean, boolean] }) {
  const labels = ['Make a list', 'Add people to it', 'Send them an email'];
  const current = done.indexOf(false);
  return (
    <ol className="grid grid-cols-3 gap-2 sm:gap-3" aria-label="How it works">
      {labels.map((label, i) => (
        <li
          key={label}
          aria-current={i === current ? 'step' : undefined}
          className={`flex flex-col items-center gap-1.5 rounded-2xl border px-2 py-2.5 text-center text-sm leading-tight transition sm:flex-row sm:gap-3 sm:px-4 sm:py-3 sm:text-left sm:text-base ${
            i === current
              ? 'border-primary-500 bg-primary-50 font-semibold text-primary-900 shadow-sm dark:bg-primary-900/30 dark:text-primary-100'
              : 'border-secondary-200 bg-surface text-secondary-600'
          }`}
        >
          <span
            className={`flex h-7 w-7 shrink-0 items-center justify-center rounded-full text-sm font-bold sm:h-8 sm:w-8 ${
              done[i]
                ? 'bg-success-600 text-white'
                : i === current
                  ? 'bg-primary-600 text-white'
                  : 'bg-secondary-100 dark:bg-secondary-800'
            }`}
            aria-hidden="true"
          >
            {done[i] ? <Check className="h-4 w-4" /> : i + 1}
          </span>
          <span>
            <span className="sr-only">Step {i + 1}: </span>
            {label}
            {done[i] && <span className="sr-only"> (done)</span>}
          </span>
        </li>
      ))}
    </ol>
  );
}

function ListsPage() {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const wanted = searchParams.get('list');

  const [lists, setLists] = useState<MktList[]>([]);
  const [counts, setCounts] = useState<Record<string, number>>({});
  const [listsLoad, setListsLoad] = useState<Load>('loading');
  const [listsError, setListsError] = useState<string | null>(null);
  const [listFilter, setListFilter] = useState('');

  const [members, setMembers] = useState<Member[]>([]);
  const [memberTotal, setMemberTotal] = useState(0);
  const [membersLoad, setMembersLoad] = useState<Load>('loading');
  const [membersError, setMembersError] = useState<string | null>(null);
  const [memberFilter, setMemberFilter] = useState('');
  const [removing, setRemoving] = useState<string | null>(null);
  const membersSeq = useRef(0);

  const [showNew, setShowNew] = useState(false);
  const [newName, setNewName] = useState('');
  const [newType, setNewType] = useState<'static' | 'dynamic'>('static');
  const [newChannel, setNewChannel] = useState('email');
  const [creating, setCreating] = useState(false);
  const [createError, setCreateError] = useState<string | null>(null);

  const [renaming, setRenaming] = useState(false);
  const [rename, setRename] = useState('');
  const [savingName, setSavingName] = useState(false);
  const [headerError, setHeaderError] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [writing, setWriting] = useState(false);

  // The list in the address bar, else the first one: there is always a list open.
  const selected = useMemo(() => lists.find((l) => l.uuid === wanted) ?? lists[0] ?? null, [lists, wanted]);

  /** Open a list (kept in the address bar so refresh, back and sharing keep it). */
  const open = useCallback(
    (uuid: string | null) => {
      const q = new URLSearchParams(searchParams.toString());
      if (uuid) q.set('list', uuid);
      else q.delete('list');
      const qs = q.toString();
      router.replace(`${pathname}${qs ? `?${qs}` : ''}`, { scroll: false });
    },
    [pathname, router, searchParams],
  );

  const loadLists = useCallback(async () => {
    setListsError(null);
    try {
      const [res, cRes] = await Promise.all([
        marketingService.listLists({ per_page: 200 }),
        marketingService.listCounts().catch(() => null), // counts are a nicety; the lists still show
      ]);
      const data = res.data?.data ?? res.data ?? [];
      const rows: MktList[] = Array.isArray(data) ? data : data.items || [];
      const c = cRes?.data?.data ?? cRes?.data;
      setLists(rows);
      setCounts(c && typeof c === 'object' && !Array.isArray(c) ? c : {});
      setListsLoad('ready');
      return rows;
    } catch (e: unknown) {
      setListsError(friendlyError(e, 'Could not load your lists'));
      setListsLoad((s) => (s === 'ready' ? 'ready' : 'error'));
      return null;
    }
  }, []);

  const loadMembers = useCallback(async (list: MktList) => {
    const seq = ++membersSeq.current;
    setMembersError(null);
    try {
      const res = await marketingService.listMembers(list.uuid);
      if (seq !== membersSeq.current) return; // another list was opened meanwhile
      const data = res.data?.data ?? res.data ?? [];
      const rows: Member[] = Array.isArray(data) ? data : [];
      const total = typeof res.data?.meta?.total === 'number' ? res.data.meta.total : rows.length;
      setMembers(rows);
      setMemberTotal(total);
      setCounts((c) => ({ ...c, [list.uuid]: total }));
      setMembersLoad('ready');
    } catch (e: unknown) {
      if (seq !== membersSeq.current) return;
      setMembersError(friendlyError(e, 'Could not load the people in this list'));
      setMembersLoad('error');
    }
  }, []);

  useEffect(() => {
    void loadLists();
  }, [loadLists]);

  // Another list opened: show its people.
  const [shownFor, setShownFor] = useState<string | null>(null);
  if (selected && shownFor !== selected.uuid) {
    setShownFor(selected.uuid);
    setMembers([]);
    setMemberTotal(0);
    setMemberFilter('');
    setMembersLoad('loading');
    setRenaming(false);
    setHeaderError(null);
  }
  const selectedUuid = selected?.uuid;
  useEffect(() => {
    if (selected) void loadMembers(selected);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- reload only when another list is opened
  }, [selectedUuid, loadMembers]);

  const refreshSelected = useCallback(async () => {
    if (selected) await loadMembers(selected);
  }, [selected, loadMembers]);

  const createList = async (e: React.FormEvent) => {
    e.preventDefault();
    if (creating) return;
    const name = newName.trim();
    if (!name) {
      setCreateError('Type a name for your list first, e.g. “Customers”.');
      return;
    }
    if (lists.some((l) => l.name.trim().toLowerCase() === name.toLowerCase())) {
      setCreateError(`You already have a list called “${name}”. Pick another name.`);
      return;
    }
    setCreating(true);
    setCreateError(null);
    try {
      const res = await marketingService.createList({
        name,
        list_type: newType,
        channel: newChannel,
      });
      const created = (res.data?.data ?? res.data) as MktList;
      setNewName('');
      setNewType('static');
      setNewChannel('email');
      setShowNew(false);
      await loadLists();
      open(created.uuid);
      toast.success(`“${created.name}” is ready — now add people to it`);
    } catch (err: unknown) {
      setCreateError(friendlyError(err, 'Could not create the list'));
    } finally {
      setCreating(false);
    }
  };

  const saveName = async () => {
    if (!selected || savingName) return;
    const name = rename.trim();
    if (!name) {
      setHeaderError('The list needs a name.');
      return;
    }
    if (name === selected.name) {
      setRenaming(false);
      return;
    }
    setSavingName(true);
    setHeaderError(null);
    try {
      await marketingService.updateList(selected.uuid, { name });
      setLists((ls) => ls.map((l) => (l.uuid === selected.uuid ? { ...l, name } : l)));
      setRenaming(false);
      toast.success('List renamed');
    } catch (err: unknown) {
      setHeaderError(friendlyError(err, 'Could not rename the list'));
    } finally {
      setSavingName(false);
    }
  };

  const deleteList = async () => {
    if (!selected) return;
    setDeleting(true);
    try {
      await marketingService.deleteList(selected.uuid);
      toast.success(`“${selected.name}” deleted`);
      setConfirmDelete(false);
      const rows = await loadLists();
      open(rows?.[0]?.uuid ?? null);
    } catch (err: unknown) {
      setConfirmDelete(false);
      setHeaderError(friendlyError(err, 'Could not delete the list'));
    } finally {
      setDeleting(false);
    }
  };

  const writeEmail = async () => {
    if (!selected || writing) return;
    setWriting(true);
    setHeaderError(null);
    try {
      const res = await marketingService.createCampaign({
        name: `Email to ${selected.name}`,
        ...STARTER,
      });
      const row = (res.data?.data ?? res.data) as { uuid?: string };
      if (!row?.uuid) throw new Error('Could not start a new email');
      router.push(`/dashboard/opsapi-marketing/campaigns/${row.uuid}?tab=content&list=${selected.uuid}`);
    } catch (err: unknown) {
      setHeaderError(friendlyError(err, 'Could not start a new email'));
      setWriting(false);
    }
  };

  const removeMember = async (m: Member) => {
    if (!selected || removing) return;
    setRemoving(m.contact_uuid);
    try {
      await marketingService.removeListMember(selected.uuid, m.contact_uuid);
      setMembers((ms) => ms.filter((x) => x.contact_uuid !== m.contact_uuid));
      setMemberTotal((n) => Math.max(0, n - 1));
      setCounts((c) => ({
        ...c,
        [selected.uuid]: Math.max(0, (c[selected.uuid] ?? 1) - 1),
      }));
      toast.success(`${m.email || m.phone || 'That person'} taken off this list (still in your contacts)`);
    } catch (err: unknown) {
      toast.error(friendlyError(err, 'Could not take them off the list'));
    } finally {
      setRemoving(null);
    }
  };

  const isDynamic = selected?.list_type === 'dynamic';
  const isSms = selected?.channel === 'sms';
  const memberUuids = useMemo(() => new Set(members.map((m) => m.contact_uuid)), [members]);
  const shownMembers = useMemo(() => {
    const q = memberFilter.trim().toLowerCase();
    if (!q) return members;
    return members.filter((m) =>
      [m.first_name, m.last_name, m.email, m.phone, m.company].some((v) => v && v.toLowerCase().includes(q)),
    );
  }, [members, memberFilter]);
  const shownLists = useMemo(() => {
    const q = listFilter.trim().toLowerCase();
    return q ? lists.filter((l) => l.name.toLowerCase().includes(q)) : lists;
  }, [lists, listFilter]);
  const selectedCount = selected ? (counts[selected.uuid] ?? memberTotal) : 0;

  const newListForm = (
    <form onSubmit={(e) => void createList(e)} className="space-y-3" noValidate>
      <label className="block">
        <span className="text-base font-medium text-secondary-900">What do you want to call this list?</span>
        <input
          className={`${FIELD} mt-1.5`}
          placeholder="e.g. Customers, Local businesses"
          value={newName}
          onChange={(e) => {
            setNewName(e.target.value);
            setCreateError(null);
          }}
          maxLength={255}
          autoFocus
          aria-invalid={!!createError}
        />
      </label>
      {createError && <Alert onDismiss={() => setCreateError(null)}>{createError}</Alert>}
      <details className="text-sm text-secondary-600">
        <summary className="cursor-pointer select-none py-1 hover:text-secondary-900">
          More options (most people don’t need these)
        </summary>
        <div className="mt-2 space-y-2">
          <label className="flex cursor-pointer items-start gap-2">
            <input
              type="checkbox"
              className="mt-0.5 h-4 w-4 accent-primary-600"
              checked={newChannel === 'sms'}
              onChange={(e) => setNewChannel(e.target.checked ? 'sms' : 'email')}
            />
            <span>For text messages (SMS) instead of email</span>
          </label>
          <label className="flex cursor-pointer items-start gap-2">
            <input
              type="checkbox"
              className="mt-0.5 h-4 w-4 accent-primary-600"
              checked={newType === 'dynamic'}
              onChange={(e) => setNewType(e.target.checked ? 'dynamic' : 'static')}
            />
            <span>Smart list: fills itself with contacts that match rules you set (e.g. everyone in London)</span>
          </label>
        </div>
      </details>
      <div className="flex flex-wrap gap-2">
        <Button type="submit" size="lg" leftIcon={<Plus className="h-5 w-5" />} isLoading={creating}>
          Create list
        </Button>
        {lists.length > 0 && (
          <Button
            type="button"
            size="lg"
            variant="ghost"
            onClick={() => {
              setShowNew(false);
              setCreateError(null);
            }}
          >
            Cancel
          </Button>
        )}
      </div>
    </form>
  );

  return (
    <div className="space-y-6 p-4 sm:p-6 lg:p-8">
      <PageHeader
        title="Mailing lists"
        description="A list is a group of people you send emails to. Make a list, add people, then write them an email."
        icon={<Users className="h-6 w-6" />}
        actions={<HelpLink topic="make-list">How do lists work?</HelpLink>}
      />

      <Steps done={[lists.length > 0, selectedCount > 0, false]} />

      {listsLoad === 'loading' && (
        <div className="grid gap-6 lg:grid-cols-[280px_minmax(0,1fr)] xl:grid-cols-[320px_minmax(0,1fr)] 2xl:grid-cols-[360px_minmax(0,1fr)]">
          <div className="space-y-3">
            <Skeleton className="h-12" />
            {[0, 1, 2, 3].map((i) => (
              <Skeleton key={i} className="h-18" />
            ))}
          </div>
          <div className="space-y-4">
            <Skeleton className="h-28" />
            <Skeleton className="h-80" />
          </div>
        </div>
      )}

      {listsLoad === 'error' && (
        <Alert
          onRetry={() => {
            setListsLoad('loading');
            void loadLists();
          }}
        >
          {listsError}
        </Alert>
      )}

      {listsLoad === 'ready' && lists.length === 0 && (
        <div className="grid gap-6 lg:grid-cols-2">
          <div className={`${CARD} p-6 sm:p-8`}>
            <h2 className="text-2xl font-semibold text-secondary-900">Make your first list</h2>
            <p className="mb-5 mt-1 text-base text-secondary-600">
              Give it a name you’ll recognise. You’ll add people to it in the next step.
            </p>
            {newListForm}
          </div>
          <div
            className={`${CARD} space-y-4 bg-linear-to-br from-primary-50 to-transparent p-6 sm:p-8 dark:from-primary-900/20`}
          >
            <h2 className="text-lg font-semibold text-secondary-900">What happens next</h2>
            <ol className="space-y-4">
              {[
                ['Add people', 'Type their email addresses, upload a spreadsheet, or tick people in your contacts.'],
                ['Write your email', 'Start from a ready-made design and change the words.'],
                ['Send it', 'Send yourself a test first, then press Send — or pick a time.'],
              ].map(([t, d], i) => (
                <li key={t} className="flex gap-3">
                  <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-primary-600 text-sm font-bold text-white">
                    {i + 2}
                  </span>
                  <span>
                    <span className="block text-base font-semibold text-secondary-900">{t}</span>
                    <span className="block text-base text-secondary-600">{d}</span>
                  </span>
                </li>
              ))}
            </ol>
            <HelpLink topic="top">Read the full getting-started guide</HelpLink>
          </div>
        </div>
      )}

      {listsLoad === 'ready' && selected && (
        <div className="grid items-start gap-6 lg:grid-cols-[280px_minmax(0,1fr)] xl:grid-cols-[320px_minmax(0,1fr)] 2xl:grid-cols-[360px_minmax(0,1fr)]">
          <aside className="space-y-3 lg:sticky lg:top-6" aria-label="Your lists">
            {listsError && <Alert onRetry={() => void loadLists()}>{listsError}</Alert>}
            {showNew ? (
              <div className={`${CARD} p-4`}>{newListForm}</div>
            ) : (
              <div className="flex flex-col gap-3 sm:flex-row sm:items-end lg:flex-col lg:items-stretch">
                {/* Phones and tablets: a dropdown instead of a long stack of cards. */}
                <label className="block min-w-0 flex-1 lg:hidden">
                  <span className="text-sm font-medium text-secondary-700 dark:text-secondary-300">
                    Your list ({lists.length})
                  </span>
                  <select
                    className={`${FIELD} mt-1`}
                    value={selected.uuid}
                    onChange={(e) => open(e.target.value)}
                    aria-label="Choose a list"
                  >
                    {lists.map((l) => (
                      <option key={l.uuid} value={l.uuid}>
                        {l.name}
                        {counts[l.uuid] === undefined
                          ? ''
                          : ` — ${counts[l.uuid] === 0 ? 'empty' : people(counts[l.uuid])}`}
                      </option>
                    ))}
                  </select>
                </label>
                <Button
                  size="lg"
                  className="w-full sm:w-auto lg:w-full"
                  leftIcon={<Plus className="h-5 w-5" />}
                  onClick={() => setShowNew(true)}
                >
                  Make a new list
                </Button>
              </div>
            )}
            <div className="hidden space-y-3 lg:block">
              <h2 className="pt-2 text-xs font-semibold uppercase tracking-wider text-secondary-500">
                Your lists ({lists.length})
              </h2>
              {lists.length > 6 && (
                <label className="relative block">
                  <span className="sr-only">Find a list</span>
                  <Search
                    className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-secondary-400"
                    aria-hidden="true"
                  />
                  <input
                    className={`${FIELD} py-2 pl-9 text-sm`}
                    placeholder="Find a list"
                    value={listFilter}
                    onChange={(e) => setListFilter(e.target.value)}
                  />
                </label>
              )}
              <ul className="space-y-2 lg:max-h-[calc(100vh-22rem)] lg:overflow-y-auto lg:pr-1">
                {shownLists.length === 0 && (
                  <li className="p-2 text-sm text-secondary-600">No list matches “{listFilter}”.</li>
                )}
                {shownLists.map((l) => {
                  const n = counts[l.uuid];
                  const active = selected.uuid === l.uuid;
                  return (
                    <li key={l.uuid}>
                      <button
                        type="button"
                        aria-current={active ? 'true' : undefined}
                        className={`relative w-full rounded-xl border p-3.5 text-left transition ${
                          active
                            ? 'border-primary-500 bg-primary-50 shadow-sm dark:bg-primary-900/30'
                            : 'border-secondary-200 bg-surface hover:border-primary-300 hover:shadow-sm'
                        }`}
                        onClick={() => open(l.uuid)}
                      >
                        {active && (
                          <span className="absolute inset-y-3 left-0 w-1 rounded-r bg-primary-600" aria-hidden="true" />
                        )}
                        <span className="flex items-start justify-between gap-2">
                          <span className="min-w-0 truncate text-base font-semibold text-secondary-900">{l.name}</span>
                          {l.channel === 'sms' && (
                            <MessageSquare
                              className="mt-1 h-4 w-4 shrink-0 text-secondary-400"
                              aria-label="Text messages"
                            />
                          )}
                          {l.list_type === 'dynamic' && (
                            <Sparkles className="mt-1 h-4 w-4 shrink-0 text-secondary-400" aria-label="Smart list" />
                          )}
                        </span>
                        <span className="mt-1 block text-sm">
                          {n === undefined ? (
                            <span className="text-secondary-500">—</span>
                          ) : n === 0 ? (
                            <span className="rounded-full bg-warning-500/15 px-2 py-0.5 font-medium text-warning-600">
                              Empty — add people
                            </span>
                          ) : (
                            <span className="text-secondary-600">{people(n)}</span>
                          )}
                        </span>
                      </button>
                    </li>
                  );
                })}
              </ul>
            </div>
          </aside>

          <div className="min-w-0 space-y-6">
            <section className={`${CARD} @container space-y-3 p-5 sm:p-6`} aria-label="This list">
              <div className="flex flex-col gap-4 @2xl:flex-row @2xl:items-start @2xl:justify-between">
                <div className="min-w-0 flex-1">
                  {renaming ? (
                    <form
                      className="flex flex-wrap items-center gap-2"
                      onSubmit={(e) => {
                        e.preventDefault();
                        void saveName();
                      }}
                    >
                      <input
                        className={`${FIELD} min-w-0 max-w-md flex-1 basis-48 text-lg font-semibold sm:text-xl`}
                        aria-label="List name"
                        value={rename}
                        onChange={(e) => setRename(e.target.value)}
                        onKeyDown={(e) => e.key === 'Escape' && setRenaming(false)}
                        maxLength={255}
                        autoFocus
                      />
                      <Button type="submit" isLoading={savingName}>
                        Save
                      </Button>
                      <Button type="button" variant="ghost" onClick={() => setRenaming(false)}>
                        Cancel
                      </Button>
                    </form>
                  ) : (
                    <div className="flex min-w-0 items-start gap-2">
                      <h2 className="line-clamp-2 wrap-break-word text-xl font-bold tracking-tight text-secondary-900 sm:text-2xl">
                        {selected.name}
                      </h2>
                      <button
                        type="button"
                        className="shrink-0 rounded-lg p-1.5 text-secondary-500 hover:bg-secondary-100 hover:text-secondary-900 dark:hover:bg-secondary-800"
                        aria-label="Rename this list"
                        title="Rename"
                        onClick={() => {
                          setRename(selected.name);
                          setRenaming(true);
                        }}
                      >
                        <Pencil className="h-4 w-4" />
                      </button>
                    </div>
                  )}
                  <p className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-base text-secondary-600">
                    <span className="font-semibold text-secondary-900">
                      {membersLoad === 'loading' && counts[selected.uuid] === undefined ? '…' : people(selectedCount)}
                    </span>
                    <span aria-hidden="true">·</span>
                    <span>{isSms ? 'Text messages' : 'Email'}</span>
                    {isDynamic && (
                      <>
                        <span aria-hidden="true">·</span>
                        <span>Smart list — fills itself</span>
                      </>
                    )}
                  </p>
                </div>
                <div className="flex w-full flex-wrap items-center gap-2 @2xl:w-auto @2xl:shrink-0">
                  {!isSms && (
                    <Button
                      size="lg"
                      className="flex-1 @md:flex-none"
                      leftIcon={<Mail className="h-5 w-5" />}
                      isLoading={writing}
                      disabled={selectedCount === 0}
                      title={selectedCount === 0 ? 'Add people to the list first' : undefined}
                      onClick={() => void writeEmail()}
                    >
                      <span className="whitespace-nowrap">
                        Write an email<span className="hidden @sm:inline"> to them</span>
                      </span>
                    </Button>
                  )}
                  <Button
                    size="lg"
                    variant="ghost"
                    leftIcon={<Trash2 className="h-4 w-4" />}
                    onClick={() => setConfirmDelete(true)}
                    className="text-secondary-600 hover:text-error-600"
                  >
                    Delete
                  </Button>
                </div>
              </div>
              {headerError && <Alert onDismiss={() => setHeaderError(null)}>{headerError}</Alert>}
              {selectedCount === 0 && membersLoad === 'ready' && !isSms && (
                <p className="text-sm text-secondary-600">Add people below, then you can write them an email.</p>
              )}
            </section>

            <div className="@container">
              <div className="grid items-start gap-6 @5xl:grid-cols-[minmax(0,5fr)_minmax(0,6fr)]">
                {isDynamic ? (
                  <SmartListRules key={selected.uuid} list={selected} onSaved={refreshSelected} />
                ) : isSms ? (
                  <AddSmsPeople key={selected.uuid} list={selected} onAdded={refreshSelected} />
                ) : (
                  <AddPeople key={selected.uuid} list={selected} memberUuids={memberUuids} onAdded={refreshSelected} />
                )}

                <section className={`${CARD} @container min-w-0 space-y-4 p-5 sm:p-6`} aria-labelledby="people-title">
                  <div className="flex flex-wrap items-center justify-between gap-3">
                    <h3 id="people-title" className="flex items-center gap-2 text-lg font-semibold text-secondary-900">
                      People in this list
                      <span className="rounded-full bg-secondary-100 px-2.5 py-0.5 text-sm font-semibold text-secondary-700 dark:bg-secondary-800 dark:text-secondary-200">
                        {selectedCount.toLocaleString('en-GB')}
                      </span>
                    </h3>
                    {members.length > 8 && (
                      <label className="relative block w-full @md:w-64">
                        <span className="sr-only">Find someone in this list</span>
                        <Search
                          className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-secondary-400"
                          aria-hidden="true"
                        />
                        <input
                          className={`${FIELD} py-2 pl-9 pr-8 text-sm`}
                          placeholder="Find someone"
                          value={memberFilter}
                          onChange={(e) => setMemberFilter(e.target.value)}
                        />
                        {memberFilter && (
                          <button
                            type="button"
                            className="absolute right-2 top-1/2 -translate-y-1/2 rounded p-1 text-secondary-400 hover:text-secondary-700"
                            aria-label="Clear search"
                            onClick={() => setMemberFilter('')}
                          >
                            <X className="h-4 w-4" />
                          </button>
                        )}
                      </label>
                    )}
                  </div>

                  {membersLoad === 'loading' && (
                    <div className="space-y-2" aria-label="Loading">
                      {[0, 1, 2, 3, 4].map((i) => (
                        <Skeleton key={i} className="h-11" />
                      ))}
                    </div>
                  )}

                  {membersLoad === 'error' && (
                    <Alert
                      onRetry={() => {
                        setMembersLoad('loading');
                        void refreshSelected();
                      }}
                    >
                      {membersError}
                    </Alert>
                  )}

                  {membersLoad === 'ready' && members.length === 0 && (
                    <div className="flex flex-col items-center justify-center gap-2 rounded-xl border-2 border-dashed border-secondary-200 px-6 py-12 text-center">
                      <Users className="h-10 w-10 text-secondary-300" aria-hidden="true" />
                      <p className="text-lg font-semibold text-secondary-900">Nobody here yet</p>
                      <p className="max-w-sm text-base text-secondary-600">
                        {isDynamic
                          ? 'Nobody matches the rules yet. Change the rules, then press Save rules.'
                          : 'Use “Add people to this list” to type email addresses, upload a file, or pick from your contacts.'}
                      </p>
                    </div>
                  )}

                  {membersLoad === 'ready' && members.length > 0 && (
                    <>
                      {shownMembers.length === 0 ? (
                        <p className="py-6 text-center text-base text-secondary-600">
                          Nobody matches “{memberFilter}”.
                        </p>
                      ) : (
                        <div className="-mx-5 sm:-mx-6">
                          <table className="w-full text-left text-base">
                            <thead className="border-y border-secondary-200 bg-secondary-50 text-sm text-secondary-600 dark:bg-secondary-900/40">
                              <tr>
                                <th scope="col" className="px-5 py-2.5 font-medium sm:px-6">
                                  Person
                                </th>
                                <th scope="col" className="hidden px-3 py-2.5 font-medium @xl:table-cell">
                                  Company
                                </th>
                                <th scope="col" className="hidden px-3 py-2.5 font-medium @3xl:table-cell">
                                  Added
                                </th>
                                <th scope="col" className="w-px px-5 py-2.5 sm:px-6">
                                  <span className="sr-only">Remove</span>
                                </th>
                              </tr>
                            </thead>
                            <tbody className="divide-y divide-secondary-200">
                              {shownMembers.map((m) => {
                                const name = [m.first_name, m.last_name].filter(Boolean).join(' ');
                                const address = (isSms ? m.phone : m.email) || m.email || m.phone || '';
                                const initials =
                                  (name || address)
                                    .split(/[\s@.]+/)
                                    .filter(Boolean)
                                    .slice(0, 2)
                                    .map((w) => w[0]?.toUpperCase())
                                    .join('') || '?';
                                return (
                                  <tr
                                    key={m.contact_uuid}
                                    className="hover:bg-secondary-50 dark:hover:bg-secondary-900/30"
                                  >
                                    <td className="w-full max-w-0 px-5 py-3 sm:px-6">
                                      <div className="flex min-w-0 items-center gap-3">
                                        <span
                                          className="hidden h-9 w-9 shrink-0 items-center justify-center rounded-full bg-primary-500/10 text-sm font-semibold text-primary-700 @md:flex dark:text-primary-300"
                                          aria-hidden="true"
                                        >
                                          {initials}
                                        </span>
                                        <div className="min-w-0">
                                          <p className="truncate font-medium text-secondary-900">
                                            {name || address || '—'}
                                          </p>
                                          {name && address && (
                                            <p className="text-sm text-secondary-600 [overflow-wrap:anywhere]">
                                              {address}
                                            </p>
                                          )}
                                          {m.company && (
                                            <p className="truncate text-sm text-secondary-500 @xl:hidden">
                                              {m.company}
                                            </p>
                                          )}
                                        </div>
                                      </div>
                                    </td>
                                    <td className="hidden max-w-56 truncate px-3 py-3 text-secondary-600 @xl:table-cell">
                                      {m.company || '—'}
                                    </td>
                                    <td className="hidden whitespace-nowrap px-3 py-3 text-secondary-600 @3xl:table-cell">
                                      <span className="block">{fmtDate(m.added_at)}</span>
                                      {m.source && SOURCE_LABELS[m.source] && (
                                        <span className="block text-xs text-secondary-500">
                                          {SOURCE_LABELS[m.source]}
                                        </span>
                                      )}
                                    </td>
                                    <td className="px-5 py-3 text-right sm:px-6">
                                      {m.source !== 'segment' && (
                                        <Button
                                          size="sm"
                                          variant="ghost"
                                          isLoading={removing === m.contact_uuid}
                                          disabled={!!removing && removing !== m.contact_uuid}
                                          className="text-secondary-600 hover:text-error-600"
                                          aria-label={`Remove ${address || name || 'this person'} from the list`}
                                          onClick={() => void removeMember(m)}
                                        >
                                          <X className="h-4 w-4 @md:hidden" aria-hidden="true" />
                                          <span className="hidden @md:inline">Remove</span>
                                        </Button>
                                      )}
                                    </td>
                                  </tr>
                                );
                              })}
                            </tbody>
                          </table>
                        </div>
                      )}
                      {memberTotal > members.length && (
                        <p className="text-sm text-secondary-600">
                          Showing the newest {members.length.toLocaleString('en-GB')} of{' '}
                          {memberTotal.toLocaleString('en-GB')}.
                        </p>
                      )}
                    </>
                  )}
                </section>
              </div>
            </div>
          </div>
        </div>
      )}

      <ConfirmDialog
        isOpen={confirmDelete}
        onClose={() => !deleting && setConfirmDelete(false)}
        onConfirm={() => void deleteList()}
        title={`Delete “${selected?.name ?? ''}”?`}
        message="The people stay in your contacts — only this list is removed. Emails already sent are not affected."
        confirmText="Delete list"
        isLoading={deleting}
      />
    </div>
  );
}

export default function MarketingListsPage() {
  return (
    <Suspense
      fallback={
        <div className="space-y-6 p-4 sm:p-6 lg:p-8">
          <Skeleton className="h-16" />
          <Skeleton className="h-96" />
        </div>
      }
    >
      <ListsPage />
    </Suspense>
  );
}

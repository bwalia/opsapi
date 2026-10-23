'use client';

import React, { useEffect, useRef, useState } from 'react';
import { isAxiosError } from 'axios';
import toast from 'react-hot-toast';
import { ArrowLeft, Check, ContactRound, FileUp, Keyboard, Search, UploadCloud } from 'lucide-react';
import { Button } from '@/components/ui';
import { marketingService } from '@/services/opsapi-marketing.service';
import { crmService, type CrmContact } from '@/services/crm.service';
import { HelpLink, downloadExampleCsv } from '@/components/opsapi-marketing/GettingStarted';
import {
  Alert,
  CARD,
  FIELD,
  type MktList,
  Skeleton,
  findEmails,
  friendlyError,
  people,
  readBase64,
  textBase64,
} from './shared';

type Mode = 'type' | 'file' | 'contacts';
type LegalBasis = 'legitimate_interest' | 'consent';

/** What a batch of people holds (the check step), or what was added from it. */
type Scan = {
  file_type: string;
  found: number;
  importable: number;
  new_contacts: number;
  existing_contacts: number;
  skipped: { duplicates: number; personal: number; unsubscribed: number };
  personal_rule: boolean;
  imported?: number;
};

/** People waiting for the check step: typed, from a file, or picked from contacts. */
type Pending = { name: string; base64: string; how: Mode; note: string };

const ACCEPT = '.csv,.txt,.xlsx,.pdf';
const ACCEPT_RE = /\.(csv|txt|xlsx|pdf)$/i;
const MAX_FILE_BYTES = 7 * 1024 * 1024;

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
      className={`group flex w-full items-center gap-3 rounded-xl border-2 p-3.5 text-left transition @xl:flex-col @xl:items-start @xl:gap-2 @xl:p-4 ${
        active
          ? 'border-primary-600 bg-primary-50 shadow-sm dark:bg-primary-900/30'
          : 'border-secondary-200 hover:border-primary-400 hover:shadow-sm'
      }`}
    >
      <span
        className={`flex h-10 w-10 shrink-0 items-center justify-center rounded-lg ${
          active
            ? 'bg-primary-600 text-white'
            : 'bg-secondary-100 text-secondary-600 group-hover:text-primary-600 dark:bg-secondary-800'
        }`}
      >
        {icon}
      </span>
      <span className="min-w-0">
        <span className="block text-base font-semibold text-secondary-900">{title}</span>
        <span className="block text-sm text-secondary-600">{hint}</span>
      </span>
    </button>
  );
}

/** "Add people to this list": three ways in, one check-and-confirm step out.
 * Render with key={list.uuid} so opening another list starts afresh. */
export function AddPeople({
  list,
  memberUuids,
  onAdded,
}: {
  list: MktList;
  memberUuids: Set<string>;
  onAdded: () => Promise<void> | void;
}) {
  const [mode, setMode] = useState<Mode | null>(null);
  const [error, setError] = useState<string | null>(null);

  const [typed, setTyped] = useState('');
  const [dragging, setDragging] = useState(false);
  const [reading, setReading] = useState(false);

  const [query, setQuery] = useState('');
  const [contacts, setContacts] = useState<CrmContact[] | null>(null);
  const [contactsError, setContactsError] = useState<string | null>(null);
  const [contactsTry, setContactsTry] = useState(0);
  const [picked, setPicked] = useState<Record<string, string>>({}); // contact uuid -> email

  const [pending, setPending] = useState<Pending | null>(null);
  const [basis, setBasis] = useState<LegalBasis>('legitimate_interest');
  const [scan, setScan] = useState<Scan | null>(null);
  const [checking, setChecking] = useState(false);
  const [checkError, setCheckError] = useState<string | null>(null);
  const [lawful, setLawful] = useState(false);
  const [note, setNote] = useState('');
  const [adding, setAdding] = useState(false);
  const checkSeq = useRef(0);

  // Contacts to pick from, searched as you type.
  useEffect(() => {
    if (mode !== 'contacts') return;
    let cancelled = false;
    const handle = window.setTimeout(() => {
      crmService
        .getContacts({ search: query.trim() || undefined, perPage: 50 })
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
              : friendlyError(e, 'Could not load your contacts'),
          );
        });
    }, 300);
    return () => {
      cancelled = true;
      window.clearTimeout(handle);
    };
  }, [mode, query, contactsTry]);

  /** Ask the server what this batch holds and what would be added (nothing is added yet). */
  const check = async (p: Pending, legalBasis: LegalBasis) => {
    const seq = ++checkSeq.current;
    setChecking(true);
    setCheckError(null);
    setScan(null);
    setLawful(false);
    try {
      const res = await marketingService.importContactsFile(list.uuid, {
        file_name: p.name,
        content_base64: p.base64,
        legal_basis: legalBasis,
      });
      if (seq === checkSeq.current) setScan((res.data?.data ?? res.data) as Scan);
    } catch (e: unknown) {
      if (seq === checkSeq.current) setCheckError(friendlyError(e, 'Could not check these email addresses'));
    } finally {
      if (seq === checkSeq.current) setChecking(false);
    }
  };

  const startCheck = (p: Pending) => {
    setError(null);
    setPending(p);
    void check(p, basis);
  };

  const typedEmails = findEmails(typed);

  const checkTyped = () => {
    if (typedEmails.length === 0) {
      setError('We couldn’t find any email addresses. Type them like jane@company.co.uk, one per line.');
      return;
    }
    startCheck({
      name: 'typed-in.csv',
      base64: textBase64(['email', ...typedEmails].join('\n')),
      how: 'type',
      note: 'Typed in by hand',
    });
  };

  const checkPicked = () => {
    const emails = Object.values(picked);
    if (emails.length === 0) return;
    startCheck({
      name: 'from-contacts.csv',
      base64: textBase64(['email', ...emails].join('\n')),
      how: 'contacts',
      note: 'Chosen from contacts',
    });
  };

  const chooseFile = async (file: File | undefined) => {
    if (!file) return;
    setError(null);
    if (!ACCEPT_RE.test(file.name)) {
      setError(
        /\.xls$/i.test(file.name)
          ? 'That’s an old Excel file (.xls). Open it in Excel and use Save As → Excel Workbook (.xlsx), then try again.'
          : 'Please choose an Excel (.xlsx), CSV or PDF file.',
      );
      return;
    }
    if (file.size === 0) {
      setError('That file is empty.');
      return;
    }
    if (file.size > MAX_FILE_BYTES) {
      setError('That file is too big (over 7 MB). Save it as CSV, or split it into smaller files.');
      return;
    }
    setReading(true);
    try {
      startCheck({
        name: file.name,
        base64: await readBase64(file),
        how: 'file',
        note: '',
      });
    } catch (e: unknown) {
      setError(friendlyError(e, 'Could not read that file'));
    } finally {
      setReading(false);
    }
  };

  const confirmAdd = async () => {
    if (!pending || adding) return;
    setAdding(true);
    setCheckError(null);
    try {
      const res = await marketingService.importContactsFile(list.uuid, {
        file_name: pending.name,
        content_base64: pending.base64,
        legal_basis: basis,
        source_note: note.trim() || pending.note || undefined,
        commit: true,
        confirm: true,
      });
      const r = (res.data?.data ?? res.data) as Scan;
      toast.success(`${people(r.imported ?? 0)} added to “${list.name}”`);
      setMode(null);
      setTyped('');
      setPicked({});
      setPending(null);
      setScan(null);
      setNote('');
      await onAdded();
    } catch (e: unknown) {
      setCheckError(friendlyError(e, 'Could not add these people'));
    } finally {
      setAdding(false);
    }
  };

  const back = () => {
    checkSeq.current++;
    setPending(null);
    setScan(null);
    setChecking(false);
    setCheckError(null);
    setLawful(false);
  };

  const pickable = (contacts || []).filter((c) => c.email && !memberUuids.has(c.uuid));
  const pickedCount = Object.keys(picked).length;

  return (
    <section className={`${CARD} @container space-y-5 p-5 sm:p-6`} aria-labelledby="add-people-title">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h3 id="add-people-title" className="text-lg font-semibold text-secondary-900">
            Add people to this list
          </h3>
          <p className="text-base text-secondary-600">
            {pending ? 'Check who will be added, then confirm.' : 'How would you like to add them?'}
          </p>
        </div>
        <HelpLink topic="add-people">Help</HelpLink>
      </div>

      {error && <Alert onDismiss={() => setError(null)}>{error}</Alert>}

      {!pending && (
        <>
          <div className="grid gap-2.5 @xl:grid-cols-3 @xl:gap-3">
            <Choice
              icon={<Keyboard className="h-5 w-5" />}
              title="Type emails"
              hint="Type or paste them in."
              active={mode === 'type'}
              onClick={() => setMode('type')}
            />
            <Choice
              icon={<FileUp className="h-5 w-5" />}
              title="Upload a file"
              hint="Excel, CSV or PDF."
              active={mode === 'file'}
              onClick={() => setMode('file')}
            />
            <Choice
              icon={<ContactRound className="h-5 w-5" />}
              title="From my contacts"
              hint="Tick people you already have."
              active={mode === 'contacts'}
              onClick={() => setMode('contacts')}
            />
          </div>

          {mode === 'type' && (
            <div className="space-y-3">
              <label className="block">
                <span className="text-base font-medium text-secondary-900">Email addresses</span>
                <span className="block text-sm text-secondary-600">
                  One per line, or separated by commas. Have names too? Upload a file instead.
                </span>
                <textarea
                  className={`${FIELD} mt-2 h-44 font-mono text-sm`}
                  placeholder={'jane@company.co.uk\njohn@business.com'}
                  value={typed}
                  onChange={(e) => setTyped(e.target.value)}
                  autoFocus
                />
              </label>
              <div className="flex flex-wrap items-center gap-3">
                <Button
                  size="lg"
                  className="w-full @md:w-auto"
                  onClick={checkTyped}
                  disabled={typedEmails.length === 0}
                >
                  {typedEmails.length === 0
                    ? 'Next'
                    : `Next: check ${typedEmails.length} address${typedEmails.length === 1 ? '' : 'es'}`}
                </Button>
                {typed.trim() !== '' && typedEmails.length === 0 && (
                  <span className="text-sm text-secondary-600">No email addresses found yet.</span>
                )}
              </div>
            </div>
          )}

          {mode === 'file' && (
            <div className="space-y-3">
              <label
                onDragOver={(e) => {
                  e.preventDefault();
                  setDragging(true);
                }}
                onDragLeave={() => setDragging(false)}
                onDrop={(e) => {
                  e.preventDefault();
                  setDragging(false);
                  void chooseFile(e.dataTransfer.files?.[0]);
                }}
                className={`flex cursor-pointer flex-col items-center justify-center gap-2 rounded-xl border-2 border-dashed p-5 text-center transition @md:p-8 ${
                  dragging
                    ? 'border-primary-500 bg-primary-50 dark:bg-primary-900/30'
                    : 'border-secondary-300 hover:border-primary-500'
                }`}
              >
                <UploadCloud className="h-9 w-9 text-primary-500" aria-hidden="true" />
                <span className="text-base font-semibold text-secondary-900">
                  {reading ? 'Reading your file…' : 'Click to choose a file, or drag it here'}
                </span>
                <span className="text-sm text-secondary-600">Excel (.xlsx), CSV or PDF, up to 7 MB</span>
                <span className="text-sm text-secondary-600">
                  Only an email column is needed — names and companies are used if they’re there.
                </span>
                <input
                  type="file"
                  accept={ACCEPT}
                  disabled={reading}
                  className="sr-only"
                  onChange={(e) => {
                    void chooseFile(e.target.files?.[0]);
                    e.target.value = '';
                  }}
                />
              </label>
              <div className="flex flex-wrap items-center gap-2">
                <Button variant="ghost" onClick={downloadExampleCsv}>
                  Download an example file
                </Button>
                <HelpLink topic="import-file">How to get your file ready</HelpLink>
              </div>
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
                  value={query}
                  onChange={(e) => setQuery(e.target.value)}
                  autoFocus
                />
              </label>
              {contactsError ? (
                <Alert onRetry={() => setContactsTry((n) => n + 1)}>{contactsError}</Alert>
              ) : contacts === null ? (
                <div className="space-y-2">
                  {[0, 1, 2, 3].map((i) => (
                    <Skeleton key={i} className="h-14" />
                  ))}
                </div>
              ) : (
                <>
                  {pickable.length > 0 && (
                    <div className="flex flex-wrap items-center justify-between gap-2 text-sm">
                      <button
                        type="button"
                        className="font-medium text-primary-700 underline underline-offset-2 dark:text-primary-300"
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
                      {pickedCount > 0 && (
                        <button
                          type="button"
                          className="text-secondary-600 underline underline-offset-2"
                          onClick={() => setPicked({})}
                        >
                          Untick all
                        </button>
                      )}
                    </div>
                  )}
                  <ul className="max-h-96 divide-y divide-secondary-200 overflow-y-auto rounded-xl border border-secondary-200">
                    {contacts.length === 0 && (
                      <li className="p-4 text-base text-secondary-600">
                        {query
                          ? 'Nobody matches that search.'
                          : 'You have no contacts yet. Type or upload email addresses instead.'}
                      </li>
                    )}
                    {contacts.map((c) => {
                      const inList = memberUuids.has(c.uuid);
                      const disabled = !c.email || inList;
                      const name = [c.first_name, c.last_name].filter(Boolean).join(' ') || c.email || '—';
                      return (
                        <li key={c.uuid}>
                          <label
                            className={`flex items-center gap-3 px-4 py-3 ${
                              disabled
                                ? 'opacity-60'
                                : 'cursor-pointer hover:bg-secondary-50 dark:hover:bg-secondary-900/40'
                            }`}
                          >
                            <input
                              type="checkbox"
                              className="h-5 w-5 accent-primary-600"
                              disabled={disabled}
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
                              <span className="block truncate text-base text-secondary-900">{name}</span>
                              <span className="block truncate text-sm text-secondary-600">
                                {c.email || 'No email address'}
                                {c.account_name ? ` · ${c.account_name}` : ''}
                              </span>
                            </span>
                            {inList && <span className="shrink-0 text-sm text-secondary-600">Already in list</span>}
                          </label>
                        </li>
                      );
                    })}
                  </ul>
                  <Button size="lg" className="w-full @md:w-auto" disabled={pickedCount === 0} onClick={checkPicked}>
                    {pickedCount === 0 ? 'Tick the people to add' : `Next: add ${people(pickedCount)}`}
                  </Button>
                </>
              )}
            </div>
          )}
        </>
      )}

      {pending && (
        <div className="space-y-4">
          {checking && (
            <div className="space-y-2" role="status" aria-live="polite">
              <p className="text-base text-secondary-600">
                {pending.how === 'file'
                  ? `Reading ${pending.name} and checking the addresses…`
                  : 'Checking the addresses…'}
              </p>
              <Skeleton className="h-24" />
              <Skeleton className="h-32" />
            </div>
          )}

          {checkError && <Alert onRetry={scan ? undefined : () => void check(pending, basis)}>{checkError}</Alert>}

          {scan && !checking && (
            <>
              <div className="rounded-xl bg-secondary-50 p-4 text-base dark:bg-secondary-900/40">
                <p className="text-xl font-semibold text-secondary-900">
                  {scan.importable > 0 ? `${people(scan.importable)} will be added` : 'Nobody new to add'}
                </p>
                <p className="text-secondary-600">
                  We found {scan.found.toLocaleString('en-GB')} email address
                  {scan.found === 1 ? '' : 'es'}
                  {pending.how === 'file' ? ` in ${pending.name}` : ''}.
                  {scan.importable > 0 && scan.new_contacts > 0
                    ? ` ${scan.new_contacts.toLocaleString('en-GB')} will also be saved to your contacts.`
                    : ''}
                </p>
                {(scan.skipped.duplicates > 0 ||
                  scan.skipped.unsubscribed > 0 ||
                  (scan.personal_rule && scan.skipped.personal > 0)) && (
                  <ul className="mt-2 list-disc space-y-1 pl-5 text-secondary-700 dark:text-secondary-300">
                    {scan.skipped.duplicates > 0 && (
                      <li>{scan.skipped.duplicates.toLocaleString('en-GB')} were listed twice (added once).</li>
                    )}
                    {scan.skipped.unsubscribed > 0 && (
                      <li>
                        {scan.skipped.unsubscribed.toLocaleString('en-GB')} asked not to get emails, so they are left
                        out.
                      </li>
                    )}
                    {scan.personal_rule && scan.skipped.personal > 0 && (
                      <li>
                        {scan.skipped.personal.toLocaleString('en-GB')} personal address
                        {scan.skipped.personal === 1 ? '' : 'es'} (like Gmail or Hotmail) left out: the law only lets
                        you email these people if they asked to hear from you. If they did, choose “People who asked to
                        get my emails” below.
                      </li>
                    )}
                  </ul>
                )}
                {scan.found === 0 && (
                  <p className="mt-2 text-secondary-700 dark:text-secondary-300">
                    Check that the file has email addresses in it, then go back and try again.
                  </p>
                )}
              </div>

              <fieldset className="space-y-2">
                <legend className="mb-1 text-base font-medium text-secondary-900">Who are these people?</legend>
                <div className="grid gap-2 @3xl:grid-cols-2">
                  {(
                    [
                      [
                        'legitimate_interest',
                        'Businesses I want to tell about my products',
                        'Company addresses, e.g. from a directory or a list you bought.',
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
                      className={`flex cursor-pointer items-start gap-3 rounded-xl border-2 p-3 transition ${
                        basis === value
                          ? 'border-primary-600 bg-primary-50 dark:bg-primary-900/30'
                          : 'border-secondary-200 hover:border-primary-400'
                      }`}
                    >
                      <input
                        type="radio"
                        name={`who-${list.uuid}`}
                        className="mt-1 h-4 w-4 accent-primary-600"
                        checked={basis === value}
                        onChange={() => {
                          setBasis(value);
                          void check(pending, value);
                        }}
                      />
                      <span>
                        <span className="block text-base font-medium text-secondary-900">{title}</span>
                        <span className="block text-sm text-secondary-600">{hint}</span>
                      </span>
                    </label>
                  ))}
                </div>
              </fieldset>

              {scan.importable > 0 && (
                <>
                  {pending.how === 'file' && (
                    <label className="block">
                      <span className="text-base text-secondary-900">
                        Where did you get this list? (optional, saved as a note)
                      </span>
                      <input
                        className={`${FIELD} mt-1`}
                        value={note}
                        onChange={(e) => setNote(e.target.value)}
                        placeholder="e.g. Bought from ExampleData Ltd, October 2026"
                        maxLength={1000}
                      />
                    </label>
                  )}
                  <label className="flex cursor-pointer items-start gap-3 rounded-xl border border-secondary-200 p-3 text-base text-secondary-900">
                    <input
                      type="checkbox"
                      className="mt-1 h-5 w-5 accent-primary-600"
                      checked={lawful}
                      onChange={(e) => setLawful(e.target.checked)}
                    />
                    <span>
                      I’m allowed to email these people. Every email will show my business name and address, and anyone
                      can unsubscribe with one click — they are never emailed again.
                    </span>
                  </label>
                </>
              )}
            </>
          )}

          <div className="flex flex-col gap-2 @md:flex-row @md:flex-wrap">
            {scan && !checking && scan.importable > 0 && (
              <Button
                size="lg"
                className="w-full @md:w-auto"
                leftIcon={<Check className="h-5 w-5" />}
                disabled={!lawful}
                isLoading={adding}
                onClick={() => void confirmAdd()}
              >
                {lawful ? `Add ${people(scan.importable)}` : 'Tick the box above to continue'}
              </Button>
            )}
            <Button
              size="lg"
              variant="outline"
              className="w-full @md:w-auto"
              leftIcon={<ArrowLeft className="h-5 w-5" />}
              disabled={adding}
              onClick={back}
            >
              Back
            </Button>
          </div>
        </div>
      )}
    </section>
  );
}

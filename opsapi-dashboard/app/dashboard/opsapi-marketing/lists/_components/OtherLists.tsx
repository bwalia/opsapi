'use client';

import React, { useEffect, useState } from 'react';
import toast from 'react-hot-toast';
import { Plus, RefreshCw, X } from 'lucide-react';
import { Button } from '@/components/ui';
import { marketingService } from '@/services/opsapi-marketing.service';
import { Alert, CARD, FIELD, type MktList, friendlyError, people } from './shared';

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
const SELECT =
  'w-full rounded-lg border border-secondary-300 bg-surface px-2.5 py-2 text-base text-secondary-900 sm:w-auto';

/** Split a stored rule into flat conditions + match mode; nested groups aren't editable here. */
function parseRule(raw: unknown): {
  match: 'and' | 'or';
  conditions: Condition[];
} {
  let rule = raw;
  if (typeof raw === 'string') {
    try {
      rule = JSON.parse(raw);
    } catch {
      rule = null;
    }
  }
  const leaf = (n: unknown): Condition | null => {
    const r = n as { field?: string; op?: string; value?: unknown };
    return r && r.field && r.op
      ? {
          field: r.field,
          op: r.op,
          value: r.value == null ? '' : String(r.value),
        }
      : null;
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

function buildRule(match: 'and' | 'or', conditions: Condition[]) {
  return {
    [match]: conditions.map((c) =>
      NO_VALUE_OPS.includes(c.op) ? { field: c.field, op: c.op } : { field: c.field, op: c.op, value: c.value },
    ),
  };
}

/** Rules for a smart list. Render with key={list.uuid}. */
export function SmartListRules({ list, onSaved }: { list: MktList; onSaved: () => Promise<void> | void }) {
  const initial = parseRule(list.segment_rule);
  const [match, setMatch] = useState<'and' | 'or'>(initial.match);
  const [conditions, setConditions] = useState<Condition[]>(initial.conditions);
  const [fields, setFields] = useState<string[]>([]);
  const [ops, setOps] = useState<string[]>([]);
  const [count, setCount] = useState<number | null>(null);
  const [busy, setBusy] = useState<'count' | 'save' | 'sync' | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [loadTry, setLoadTry] = useState(0);

  useEffect(() => {
    let cancelled = false;
    marketingService
      .segmentFields()
      .then((f) => {
        if (cancelled) return;
        const d = f.data?.data ?? f.data ?? {};
        setFields((d.fields || []).map((x: { field: string }) => x.field));
        setOps(d.ops || []);
        setLoadError(null);
      })
      .catch((e: unknown) => {
        if (!cancelled) setLoadError(friendlyError(e, 'Could not load the rule options'));
      });
    return () => {
      cancelled = true;
    };
  }, [loadTry]);

  const update = (i: number, patch: Partial<Condition>) => {
    setCount(null);
    setConditions((cs) => cs.map((c, j) => (j === i ? { ...c, ...patch } : c)));
  };

  const run = async (kind: 'count' | 'save' | 'sync') => {
    if (kind !== 'sync' && conditions.length === 0) {
      setError('Add at least one rule first.');
      return;
    }
    if (kind !== 'sync' && conditions.some((c) => !NO_VALUE_OPS.includes(c.op) && !c.value.trim())) {
      setError('Fill in a value for every rule.');
      return;
    }
    setBusy(kind);
    setError(null);
    try {
      if (kind === 'count') {
        const res = await marketingService.previewSegment({
          rule: buildRule(match, conditions),
          limit: 1,
        });
        setCount((res.data?.data ?? res.data)?.total ?? 0);
      } else if (kind === 'save') {
        const res = await marketingService.setListSegment(list.uuid, {
          rule: buildRule(match, conditions),
          sync: true,
        });
        toast.success(`Saved — ${people((res.data?.data ?? res.data)?.sync?.synced ?? 0)} in the list`);
        await onSaved();
      } else {
        const res = await marketingService.syncList(list.uuid);
        toast.success(`Updated — ${people((res.data?.data ?? res.data)?.synced ?? 0)} in the list`);
        await onSaved();
      }
    } catch (e: unknown) {
      setError(friendlyError(e, kind === 'count' ? 'Could not count the matches' : 'Could not save the rules'));
    } finally {
      setBusy(null);
    }
  };

  return (
    <section className={`${CARD} space-y-4 p-5 sm:p-6`}>
      <div>
        <h3 className="text-lg font-semibold text-secondary-900">Who belongs in this smart list</h3>
        <p className="text-base text-secondary-600">
          Contacts that match these rules are put in the list for you, and it updates itself before every email.
        </p>
      </div>
      {loadError && <Alert onRetry={() => setLoadTry((n) => n + 1)}>{loadError}</Alert>}
      {error && <Alert onDismiss={() => setError(null)}>{error}</Alert>}
      <label className="flex flex-col gap-2 text-base text-secondary-900 sm:flex-row sm:items-center">
        Include contacts that match
        <select className={SELECT} value={match} onChange={(e) => setMatch(e.target.value as 'and' | 'or')}>
          <option value="and">all of the rules</option>
          <option value="or">any rule</option>
        </select>
      </label>
      {conditions.length === 0 && <p className="text-base text-secondary-600">No rules yet — press “Add a rule”.</p>}
      {conditions.map((c, i) => (
        <div
          key={i}
          className="relative flex flex-col gap-2 rounded-xl bg-secondary-50 p-2 pr-11 sm:flex-row sm:flex-wrap sm:items-center sm:pr-2 dark:bg-secondary-900/40"
        >
          <select
            className={SELECT}
            aria-label="Field"
            value={c.field}
            onChange={(e) => update(i, { field: e.target.value })}
          >
            {!fields.includes(c.field) && <option value={c.field}>{c.field.replace(/[._]/g, ' ')}</option>}
            {fields.map((f) => (
              <option key={f} value={f}>
                {f.replace(/[._]/g, ' ')}
              </option>
            ))}
          </select>
          <select className={SELECT} aria-label="Rule" value={c.op} onChange={(e) => update(i, { op: e.target.value })}>
            {!ops.includes(c.op) && <option value={c.op}>{OP_LABELS[c.op] || c.op}</option>}
            {ops.map((o) => (
              <option key={o} value={o}>
                {OP_LABELS[o] || o}
              </option>
            ))}
          </select>
          {!NO_VALUE_OPS.includes(c.op) && (
            <input
              className={`${FIELD} py-2 sm:w-auto sm:min-w-40 sm:flex-1`}
              aria-label="Value"
              placeholder="e.g. London"
              value={c.value}
              onChange={(e) => update(i, { value: e.target.value })}
            />
          )}
          <button
            type="button"
            className="absolute right-1 top-1 rounded-lg p-2 text-secondary-500 hover:bg-error-500/10 hover:text-error-600 sm:static"
            aria-label="Remove this rule"
            onClick={() => {
              setCount(null);
              setConditions((cs) => cs.filter((_, j) => j !== i));
            }}
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
            setConditions((cs) => [
              ...cs,
              {
                field: fields[0] || 'email',
                op: ops.includes('contains') ? 'contains' : ops[0] || 'contains',
                value: '',
              },
            ])
          }
        >
          Add a rule
        </Button>
        <Button variant="outline" isLoading={busy === 'count'} disabled={!!busy} onClick={() => void run('count')}>
          How many match?
        </Button>
        <Button isLoading={busy === 'save'} disabled={!!busy} onClick={() => void run('save')}>
          Save rules
        </Button>
        <Button
          variant="ghost"
          leftIcon={<RefreshCw className="h-4 w-4" />}
          isLoading={busy === 'sync'}
          disabled={!!busy}
          onClick={() => void run('sync')}
        >
          Update now
        </Button>
        {count !== null && <span className="text-base font-medium text-secondary-900">{people(count)} match</span>}
      </div>
    </section>
  );
}

/** Text-message lists: phone numbers pasted with consent. Render with key={list.uuid}. */
export function AddSmsPeople({ list, onAdded }: { list: MktList; onAdded: () => Promise<void> | void }) {
  const [text, setText] = useState('');
  const [consent, setConsent] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const add = async () => {
    if (!text.trim()) {
      setError('Paste the people first.');
      return;
    }
    if (!/^.*email/i.test(text.trim().split(/\r?\n/)[0])) {
      setError('The first line must be the headings: email,first_name,phone');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const res = await marketingService.importListCsv(list.uuid, {
        csv: text.trim(),
        grant_consent: true,
      });
      const r = (res.data?.data ?? res.data) as {
        added?: number;
        skipped?: number;
      };
      toast.success(`${people(r.added ?? 0)} added${r.skipped ? ` (${r.skipped} skipped)` : ''}`);
      setText('');
      setConsent(false);
      await onAdded();
    } catch (e: unknown) {
      setError(friendlyError(e, 'Could not add these people'));
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className={`${CARD} space-y-4 p-5 sm:p-6`}>
      <div>
        <h3 className="text-lg font-semibold text-secondary-900">Add people to this list</h3>
        <p className="text-base text-secondary-600">
          Paste one person per line. The first line is the headings: <code>email,first_name,phone</code>
        </p>
      </div>
      {error && <Alert onDismiss={() => setError(null)}>{error}</Alert>}
      <textarea
        className={`${FIELD} h-40 font-mono text-sm`}
        aria-label="People to add"
        placeholder={'email,first_name,phone\njane@shop.co.uk,Jane,+44 7700 900123'}
        value={text}
        onChange={(e) => setText(e.target.value)}
      />
      <label className="flex cursor-pointer items-start gap-3 text-base text-secondary-900">
        <input
          type="checkbox"
          className="mt-1 h-5 w-5 accent-primary-600"
          checked={consent}
          onChange={(e) => setConsent(e.target.checked)}
        />
        <span>These people agreed to get text messages from me.</span>
      </label>
      <Button size="lg" isLoading={busy} disabled={!consent} onClick={() => void add()}>
        {consent ? 'Add to list' : 'Tick the box above to continue'}
      </Button>
    </section>
  );
}

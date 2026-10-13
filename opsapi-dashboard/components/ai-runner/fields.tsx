'use client';

/**
 * AI Runs form pieces shared by Runners & sources and AI run settings: a list-of-values input, a checklist of
 * people / projects / runners, a labelled switch, the workspace's projects and members, and a project's columns.
 */
import React, { useState } from 'react';
import { X } from 'lucide-react';
import { Input, Select, Switch } from '@/components/ui';
import { useAiData } from '@/components/ai-runner/ui';
import { kanbanService } from '@/services/kanban.service';
import namespaceService from '@/services/namespace.service';

export type Choice = { value: string; label: string; hint?: string };

// An empty Lua table arrives as {} rather than [].
export const strings = (v: unknown): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string') : []);

/** Number inputs where 0 is valid: an emptied field stays empty (NaN) rather than snapping to 0; `required` stops the save. */
export const typed = (v: string) => (v === '' ? NaN : Number(v));
export const shown = (n?: number) => (n == null || Number.isNaN(n) ? '' : n);

export function Toggle({ label, hint, checked, onChange }: { label: string; hint?: string; checked: boolean; onChange: (v: boolean) => void }) {
  return (
    <div className="flex items-start justify-between gap-4">
      <div>
        <div className="text-sm font-medium text-secondary-800">{label}</div>
        {hint && <div className="text-xs text-secondary-500">{hint}</div>}
      </div>
      <Switch checked={checked} onChange={onChange} aria-label={label} />
    </div>
  );
}

/**
 * A list of short values (globs, tool names, statuses, patterns) as removable chips. Enter (or leaving the field)
 * adds what was typed; `check` returns why a value can't be added.
 */
export function TagsInput({ id, label, values, onChange, placeholder, hint, check, mono = true }: {
  id: string; label: string; values: string[]; onChange: (v: string[]) => void; placeholder?: string; hint?: string;
  check?: (v: string) => string | null; mono?: boolean;
}) {
  const [text, setText] = useState('');
  const [error, setError] = useState<string | null>(null);
  function add() {
    const v = text.trim();
    if (!v) return;
    const why = check?.(v) ?? null;
    setError(why);
    if (why) return;
    if (!values.includes(v)) onChange([...values, v]);
    setText('');
  }
  return (
    <div className="min-w-0">
      <label htmlFor={id} className="mb-1.5 block text-sm font-medium text-secondary-700">{label}</label>
      <div className="flex min-h-10 flex-wrap items-center gap-1.5 rounded-lg border border-secondary-300 bg-surface px-2 py-1.5 focus-within:border-primary-500 focus-within:ring-2 focus-within:ring-primary-500/20">
        {values.map((v) => (
          <span key={v} data-testid={`${id}-chip`} className={`inline-flex max-w-full items-center gap-1 rounded-md bg-secondary-100 px-2 py-0.5 text-xs text-secondary-800 ${mono ? 'font-mono' : ''}`}>
            <span className="break-all">{v}</span>
            <button type="button" className="rounded text-secondary-500 hover:text-error-600" aria-label={`Remove ${v}`}
              onClick={() => onChange(values.filter((x) => x !== v))}>
              <X className="h-3 w-3" aria-hidden />
            </button>
          </span>
        ))}
        <input id={id} value={text} placeholder={values.length ? undefined : placeholder} aria-describedby={`${id}-hint`}
          aria-invalid={!!error || undefined}
          className={`min-w-[8rem] flex-1 bg-transparent py-0.5 text-sm text-secondary-900 outline-none placeholder:text-secondary-400 ${mono ? 'font-mono' : ''}`}
          onChange={(e) => { setText(e.target.value); setError(null); }}
          onBlur={add}
          onKeyDown={(e) => {
            if (e.key === 'Enter') { e.preventDefault(); add(); }
            if (e.key === 'Backspace' && !text && values.length) onChange(values.slice(0, -1));
          }} />
      </div>
      <p id={`${id}-hint`} className={`mt-1 text-xs ${error ? 'text-error-600' : 'text-secondary-500'}`} role={error ? 'alert' : undefined}>
        {error || hint || 'Press Enter to add.'}
      </p>
    </div>
  );
}

/** Checkboxes with a filter. Picked uuids the list doesn't show (no access, or gone) stay listed so they can be removed. */
export function CheckList({ legend, items, picked, onChange, loading, error, hint }: {
  legend: string; items: Choice[]; picked: string[]; onChange: (v: string[]) => void; loading: boolean; error?: string; hint?: string;
}) {
  const [q, setQ] = useState('');
  const known = new Set(items.map((i) => i.value));
  const all = [...items, ...picked.filter((v) => !known.has(v)).map((v) => ({ value: v, label: 'Not in the list', hint: v }))];
  const shownItems = all.filter((i) => !q || `${i.label} ${i.hint || ''}`.toLowerCase().includes(q.trim().toLowerCase()));
  return (
    <fieldset className="min-w-0 space-y-2">
      <legend className="text-sm font-medium text-secondary-800">
        {legend} <span className="font-normal text-secondary-500">({picked.length} selected)</span>
      </legend>
      {hint && <p className="text-xs text-secondary-500">{hint}</p>}
      <Input aria-label={`Filter ${legend.toLowerCase()}`} placeholder="Filter" value={q} onChange={(e) => setQ(e.target.value)} />
      <div className="max-h-48 space-y-1 overflow-auto rounded-lg border border-secondary-200 p-2">
        {error && <p className="text-sm text-error-600">{error}</p>}
        {!error && loading && !all.length && <p className="text-sm text-secondary-500">Loading…</p>}
        {!loading && !shownItems.length && <p className="text-sm text-secondary-500">None found.</p>}
        {shownItems.map((i) => (
          <label key={i.value} className="flex items-start gap-2 text-sm">
            <input type="checkbox" className="mt-0.5" checked={picked.includes(i.value)}
              onChange={(e) => onChange(e.target.checked ? [...picked, i.value] : picked.filter((v) => v !== i.value))} />
            <span className="min-w-0">
              {i.label}
              {i.hint && <span className="block break-all text-xs text-secondary-500">{i.hint}</span>}
            </span>
          </label>
        ))}
      </div>
    </fieldset>
  );
}

// ponytail: the first 200 members and projects; add server-side search if workspaces outgrow that.
export function useProjects() {
  const r = useAiData(async () => (await kanbanService.getProjects({ perPage: 200 })).data || [], []);
  return { ...r, choices: (r.data || []).map((p): Choice => ({ value: p.uuid, label: p.name })) };
}
export function useMembers() {
  const r = useAiData(async () => (await namespaceService.getMembers({ perPage: 200, status: 'active' })).data || [], []);
  const choices = (r.data || []).flatMap((m): Choice[] => m.user ? [{
    value: m.user.uuid,
    label: m.user.full_name || [m.user.first_name, m.user.last_name].filter(Boolean).join(' ') || m.user.email,
    hint: m.user.email,
  }] : []);
  return { ...r, choices };
}

/** A project picker that keeps a saved project the caller can't see rather than losing it on save. */
export function ProjectSelect({ id, label = 'Project', value, onChange, required, projects }: {
  id: string; label?: string; value: string | null; onChange: (uuid: string | null) => void; required?: boolean;
  projects: ReturnType<typeof useProjects>;
}) {
  const list = projects.choices;
  return (
    <Select id={id} label={label} required={required} value={value || ''} onChange={(e) => onChange(e.target.value || null)}>
      <option value="">{projects.loading && !projects.data ? 'Loading projects…' : 'Choose a project'}</option>
      {list.map((p) => <option key={p.value} value={p.value}>{p.label}</option>)}
      {projects.data && value && !list.some((p) => p.value === value) && <option value={value}>Current project</option>}
    </Select>
  );
}

/**
 * A column of the project's first board (where tracked tasks go), or free text when the columns can't be read or
 * no project is chosen. Empty = `emptyLabel`.
 */
export function ColumnField({ id, projectUuid, value, onChange, emptyLabel = 'First column', helperText }: {
  id: string; projectUuid: string | null; value: string | null; onChange: (v: string | null) => void; emptyLabel?: string; helperText?: string;
}) {
  const columns = useAiData(async () => {
    if (!projectUuid) return [];
    const [board] = await kanbanService.getBoards(projectUuid);
    return board ? ((await kanbanService.getBoard(board.uuid)).columns || []).map((c) => c.name) : [];
  }, [projectUuid]);
  const names = columns.loading ? [] : columns.data || []; // not the previous project's while the new one loads
  const column = value || '';
  return names.length ? (
    <Select id={id} label="Column" value={column} helperText={helperText} onChange={(e) => onChange(e.target.value || null)}>
      <option value="">{emptyLabel}</option>
      {names.map((n) => <option key={n} value={n}>{n}</option>)}
      {column && !names.includes(column) && <option value={column}>{column}</option>}
    </Select>
  ) : (
    <Input id={id} label="Column" value={column} placeholder={emptyLabel} helperText={helperText}
      onChange={(e) => onChange(e.target.value.trim() ? e.target.value : null)} />
  );
}

'use client';

/**
 * GlobalSearch — a ⌘K / Ctrl+K command palette that searches every page/module
 * the current user can reach (the backend-driven menu = the source of truth for
 * what's accessible, so this is automatically permission- and namespace-scoped).
 *
 * Opens on ⌘K / Ctrl+K, or via the `opsapi:open-search` window event that the
 * header search box dispatches. Keyboard: ↑/↓ to move, ↵ to open, Esc to close.
 * Hand-rolled (no cmdk dependency) — it's just a filtered list + key handling.
 *
 * It also finds records (GET /api/v2/search, lapis/lib/global-search.lua): customers, leads, accounts, contacts,
 * invoices, shop orders, quotes, deals, products and stock, suppliers, purchase orders and invoices, employees,
 * projects... each only for people allowed to see it. Records come first, grouped, then matching pages. Typing a
 * whole deal code opens its deal page.
 */

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import {
  Search, CornerDownLeft, Lock, Users, UserPlus, Building2, Contact, Briefcase, FileText, ShoppingCart, FileSignature,
  Package, Truck, ClipboardCheck, Receipt, UserRound, KanbanSquare, Loader2, type LucideIcon,
} from 'lucide-react';
import { useMenu, type MenuItemWithIcon } from '@/hooks';
import { searchService } from '@/services/search.service';

type SearchItem = MenuItemWithIcon & { subtitle?: string; section?: string };

/** An icon per kind of record (anything new falls back to the search icon). */
const GROUP_ICON: Record<string, LucideIcon> = {
  deals: Lock, customers: Users, leads: UserPlus, crm_accounts: Building2, crm_contacts: Contact, crm_deals: Briefcase,
  invoices: FileText, shop_orders: ShoppingCart, shop_quotes: FileSignature, shop_products: Package, shop_suppliers: Truck,
  purchase_orders: ClipboardCheck, purchase_invoices: Receipt, employees: UserRound, projects: KanbanSquare,
};

/** All chars of `q` appear in order in `s` (cheap fuzzy match). */
function fuzzy(q: string, s: string): boolean {
  let i = 0;
  for (let k = 0; k < s.length && i < q.length; k++) {
    if (s[k] === q[i]) i++;
  }
  return i === q.length;
}

/** Rank a menu item against the query; 0 = no match. */
function scoreMatch(q: string, it: MenuItemWithIcon): number {
  const name = (it.name || '').toLowerCase();
  const path = (it.path || '').toLowerCase();
  const mod = (it.module || '').toLowerCase();
  if (name === q) return 100;
  if (name.startsWith(q)) return 80;
  if (name.includes(q)) return 60;
  if (mod.includes(q)) return 40;
  if (path.includes(q)) return 20;
  if (fuzzy(q, name)) return 10;
  return 0;
}

export function GlobalSearch() {
  const router = useRouter();
  const { allMenu } = useMenu();
  // Records found for `searched` (never shown under a newer query); `searching` while the API answers.
  const [records, setRecords] = useState<SearchItem[]>([]);
  const [searched, setSearched] = useState('');
  const [searching, setSearching] = useState(false);
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState('');
  const [active, setActive] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLDivElement>(null);

  // Open on ⌘K / Ctrl+K (toggle), or via the header's custom event. Resets live
  // in these handlers (not an effect) so opening always starts clean.
  useEffect(() => {
    const reset = () => {
      setQuery('');
      setActive(0);
    };
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && (e.key === 'k' || e.key === 'K')) {
        e.preventDefault();
        reset();
        setOpen((o) => !o);
      }
    };
    const onOpen = () => {
      reset();
      setOpen(true);
    };
    window.addEventListener('keydown', onKey);
    window.addEventListener('opsapi:open-search', onOpen);
    return () => {
      window.removeEventListener('keydown', onKey);
      window.removeEventListener('opsapi:open-search', onOpen);
    };
  }, []);

  // Focus the input when it opens (DOM side-effect only).
  useEffect(() => {
    if (!open) return;
    const t = setTimeout(() => inputRef.current?.focus(), 20);
    return () => clearTimeout(t);
  }, [open]);

  // Records (debounced; the API checks what this person may see). A whole deal code opens the deal straight away.
  useEffect(() => {
    const term = query.trim();
    if (!open || term.length < 2) return;
    const ctrl = new AbortController();
    const t = setTimeout(() => {
      setSearching(true);
      searchService
        .search(term, ctrl.signal)
        .then((r) => {
          if (r.open) {
            setOpen(false);
            router.push(r.open);
            return;
          }
          const items: SearchItem[] = [];
          r.groups.forEach((g) =>
            g.items.forEach((hit, i) =>
              items.push({
                key: `rec:${g.key}:${i}:${hit.path}`,
                name: hit.title,
                path: hit.path,
                module: g.key,
                IconComponent: GROUP_ICON[g.key] ?? Search,
                subtitle: hit.subtitle ?? undefined,
                section: g.label,
              } as unknown as SearchItem),
            ),
          );
          setRecords(items);
          setSearched(term);
        })
        .catch(() => {
          if (ctrl.signal.aborted) return;
          setRecords([]);
          setSearched(term);
        })
        .finally(() => !ctrl.signal.aborted && setSearching(false));
    }, 250);
    return () => {
      ctrl.abort();
      clearTimeout(t);
    };
  }, [query, open, router]);

  const results = useMemo<SearchItem[]>(() => {
    const items: SearchItem[] = allMenu || [];
    const q = query.trim().toLowerCase();
    if (!q) return items;
    const pages = items
      .map((it) => ({ it, score: scoreMatch(q, it) }))
      .filter((x) => x.score > 0)
      .sort((a, b) => b.score - a.score)
      .map((x) => x.it);
    // Records only while they still match what is typed (a stale answer is dropped); pages after them.
    const live = q.length >= 2 && searched.toLowerCase() === q ? records : [];
    return [...live, ...pages.map((p) => ({ ...p, section: 'Pages' }) as SearchItem)];
  }, [query, allMenu, records, searched]);

  // Keep the highlighted row visible.
  useEffect(() => {
    listRef.current?.querySelector(`[data-idx="${active}"]`)?.scrollIntoView({ block: 'nearest' });
  }, [active]);

  const go = useCallback(
    (item?: SearchItem) => {
      const target = item || results[active];
      if (!target) return;
      setOpen(false);
      router.push(target.path);
    },
    [results, active, router]
  );

  const onKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      setActive((a) => Math.min(a + 1, results.length - 1));
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      setActive((a) => Math.max(a - 1, 0));
    } else if (e.key === 'Enter') {
      e.preventDefault();
      go();
    } else if (e.key === 'Escape') {
      setOpen(false);
    }
  };

  if (!open) return null;

  return (
    <div
      className="fixed inset-0 z-[100] flex items-start justify-center p-4 pt-[12vh]"
      role="dialog"
      aria-modal="true"
      aria-label="Search"
    >
      <div
        className="absolute inset-0 bg-secondary-900/40 backdrop-blur-sm"
        onClick={() => setOpen(false)}
        aria-hidden="true"
      />
      <div className="relative z-10 w-full max-w-xl overflow-hidden rounded-2xl border border-secondary-200/80 bg-surface shadow-2xl ring-1 ring-black/5">
        <div className="flex items-center gap-3 border-b border-secondary-100 px-5">
          <Search className="h-5 w-5 shrink-0 text-primary-500" aria-hidden="true" />
          <input
            ref={inputRef}
            value={query}
            onChange={(e) => {
              setQuery(e.target.value);
              setActive(0);
            }}
            onKeyDown={onKeyDown}
            placeholder="Search customers, orders, invoices, stock, deals, pages…"
            // The palette itself signals focus; the global input focus ring would
            // be clipped by the rounded panel (looked like a cut-off red box).
            style={{ outline: 'none', boxShadow: 'none', border: 'none' }}
            className="min-w-0 flex-1 bg-transparent py-4 text-base text-secondary-900 placeholder:text-secondary-400"
          />
          <kbd className="rounded-md border border-secondary-200 bg-secondary-50 px-1.5 py-0.5 text-[10px] font-sans font-medium text-secondary-500 shadow-sm">
            esc
          </kbd>
        </div>

        <div ref={listRef} className="scrollbar-hidden max-h-[min(60vh,24rem)] overflow-y-auto overscroll-contain p-2">
          {searching && query.trim().length >= 2 && searched.toLowerCase() !== query.trim().toLowerCase() && (
            <p className="flex items-center gap-2 px-3 py-2 text-xs text-secondary-400" role="status">
              <Loader2 className="h-3.5 w-3.5 animate-spin" aria-hidden="true" /> Searching records…
            </p>
          )}
          {results.length === 0 ? (
            <p className="px-4 py-8 text-center text-sm text-secondary-400">
              No matches{query ? ` for “${query}”` : ''}.
            </p>
          ) : (
            results.map((it, i) => {
              const Icon = it.IconComponent;
              const activeRow = i === active;
              const heading = query.trim() && it.section && (i === 0 || results[i - 1].section !== it.section) ? it.section : null;
              return (
                <React.Fragment key={it.key}>
                {heading && (
                  <p className="px-3 pb-1 pt-3 text-[11px] font-semibold uppercase tracking-wide text-secondary-400 first:pt-1">{heading}</p>
                )}
                <button
                  data-idx={i}
                  type="button"
                  onMouseMove={() => setActive(i)}
                  onClick={() => go(it)}
                  className={`flex w-full items-center gap-3 rounded-xl px-3 py-2.5 text-left transition-colors ${
                    activeRow ? 'bg-primary-50 ring-1 ring-primary-100' : ''
                  }`}
                >
                  <span
                    className={`flex h-8 w-8 shrink-0 items-center justify-center rounded-lg ${
                      activeRow ? 'bg-primary-100 text-primary-600' : 'bg-secondary-100 text-secondary-500'
                    }`}
                  >
                    {Icon ? <Icon className="h-4 w-4" /> : <Search className="h-4 w-4" />}
                  </span>
                  <span className="min-w-0 flex-1">
                    <span className="block truncate text-sm font-medium text-secondary-900">{it.name}</span>
                    <span className="block truncate text-xs text-secondary-400">{it.subtitle ?? it.path}</span>
                  </span>
                  {activeRow && <CornerDownLeft className="h-4 w-4 shrink-0 text-secondary-300" aria-hidden="true" />}
                </button>
                </React.Fragment>
              );
            })
          )}
        </div>

        <div className="flex items-center gap-3 border-t border-secondary-100 bg-secondary-50/60 px-5 py-2 text-[11px] text-secondary-400">
          <span>↑ ↓ navigate</span>
          <span>↵ open</span>
          <span className="ml-auto">
            {results.length} result{results.length === 1 ? '' : 's'}
          </span>
        </div>
      </div>
    </div>
  );
}

export default GlobalSearch;

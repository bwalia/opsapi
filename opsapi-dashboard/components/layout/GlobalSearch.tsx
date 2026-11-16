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
 * Shop staff also find deals here: a deal code, WSQ quote number, order number, supplier quote reference or
 * customer email lists the matching deals first, and typing a whole deal code opens its deal page.
 */

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { Search, CornerDownLeft, Lock } from 'lucide-react';
import { useMenu, type MenuItemWithIcon } from '@/hooks';
import { usePermissions } from '@/contexts/PermissionsContext';
import { shopService } from '@/services/shop.service';
import type { ShopDealSearchResult } from '@/types/shop';

type SearchItem = MenuItemWithIcon & { subtitle?: string };

const DEAL_MATCH: Record<ShopDealSearchResult['matched_by'], string> = {
  deal_code: 'Deal code',
  quote_number: 'Quote',
  order_number: 'Order',
  supplier_quote_ref: 'Supplier quote ref',
  customer_email: 'Customer email',
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
  const { hasPermission } = usePermissions();
  const canSeeDeals = hasPermission('shop', 'read');
  const [deals, setDeals] = useState<SearchItem[]>([]);
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

  // Deals (shop staff only): debounced; a whole deal code opens the deal page straight away.
  useEffect(() => {
    const term = query.trim();
    if (!open || !canSeeDeals || term.length < 3) return;
    let active = true;
    const t = setTimeout(() => {
      shopService
        .searchDeals(term)
        .then((r) => {
          if (!active) return;
          if (r.exact) {
            setOpen(false);
            router.push(`/dashboard/shop/deals/${encodeURIComponent(r.exact)}`);
            return;
          }
          setDeals(
            r.results.map(
              (d) =>
                ({
                  key: `deal:${d.deal_code}`,
                  name: `Deal ${d.deal_code}`,
                  path: `/dashboard/shop/deals/${encodeURIComponent(d.deal_code)}`,
                  module: 'shop',
                  IconComponent: Lock,
                  subtitle: `${DEAL_MATCH[d.matched_by] ?? d.matched_by}: ${d.match}${d.customer ? ` · ${d.customer}` : ''}`,
                }) as unknown as SearchItem,
            ),
          );
        })
        .catch(() => active && setDeals([]));
    }, 250);
    return () => {
      active = false;
      clearTimeout(t);
    };
  }, [query, open, canSeeDeals, router]);

  const results = useMemo<SearchItem[]>(() => {
    const items = allMenu || [];
    const q = query.trim().toLowerCase();
    if (!q) return items;
    const pages = items
      .map((it) => ({ it, score: scoreMatch(q, it) }))
      .filter((x) => x.score > 0)
      .sort((a, b) => b.score - a.score)
      .map((x) => x.it);
    // Deals only while they still match what is typed (a stale answer is dropped).
    const live = canSeeDeals && q.length >= 3 ? deals : [];
    return [...live, ...pages];
  }, [query, allMenu, deals, canSeeDeals]);

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
            placeholder={canSeeDeals ? 'Search pages, or find a deal (code, WSQ number, order, email)…' : 'Search pages and modules…'}
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
          {results.length === 0 ? (
            <p className="px-4 py-8 text-center text-sm text-secondary-400">
              No matches{query ? ` for “${query}”` : ''}.
            </p>
          ) : (
            results.map((it, i) => {
              const Icon = it.IconComponent;
              const activeRow = i === active;
              return (
                <button
                  key={it.key}
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

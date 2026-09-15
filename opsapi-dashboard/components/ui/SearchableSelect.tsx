'use client';

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { cn } from '@/lib/utils';
import { ChevronDown, Search, Check, X, Plus } from 'lucide-react';

type MenuPos = { left: number; width: number; top?: number; bottom?: number; maxH: number };

export interface SearchableSelectOption {
  value: string;
  label: string;
  // Optional secondary text shown beneath the label (e.g. category type).
  hint?: string;
}

export interface SearchableSelectProps {
  options: SearchableSelectOption[];
  value?: string;
  onChange: (value: string) => void;
  placeholder?: string;
  searchPlaceholder?: string;
  emptyMessage?: string;
  label?: string;
  disabled?: boolean;
  clearable?: boolean;
  // Compact styling for use inside dense table cells.
  size?: 'sm' | 'md';
  className?: string;
  // Auto-open and focus the search box on mount (handy for inline-edit cells).
  autoFocus?: boolean;
  // Called when the dropdown closes without a selection (e.g. on blur/escape).
  onClose?: () => void;
  // Allow selecting a typed value that isn't in `options` (offers a "Create …"
  // row and accepts it on Enter). Turns the select into a create-or-pick combobox.
  creatable?: boolean;
  // Optional server-side search. When provided, the typed query is forwarded
  // (debounced) so the parent can fetch matching options — letting the dropdown
  // reach records beyond a server-side result cap instead of only filtering the
  // initial page client-side. Client-side filtering of `options` still applies.
  onSearch?: (query: string) => void;
}

const SearchableSelect: React.FC<SearchableSelectProps> = ({
  options,
  value,
  onChange,
  placeholder = 'Select...',
  searchPlaceholder = 'Search...',
  emptyMessage = 'No matches',
  label,
  disabled = false,
  clearable = false,
  size = 'md',
  className,
  autoFocus = false,
  onClose,
  onSearch,
  creatable = false,
}) => {
  const [open, setOpen] = useState(autoFocus);
  const [query, setQuery] = useState('');
  const [highlight, setHighlight] = useState(0);
  const [pos, setPos] = useState<MenuPos | null>(null);
  const rootRef = useRef<HTMLDivElement>(null);
  const btnRef = useRef<HTMLButtonElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  const searchRef = useRef<HTMLInputElement>(null);

  // Position the menu in a portal (fixed) so it's never clipped by a modal's
  // overflow; flip above the trigger when there's little room below.
  const place = useCallback(() => {
    const el = btnRef.current;
    if (!el) return;
    const r = el.getBoundingClientRect();
    const spaceBelow = window.innerHeight - r.bottom;
    const spaceAbove = r.top;
    const openUp = spaceBelow < 260 && spaceAbove > spaceBelow;
    const maxH = Math.max(180, Math.min(340, (openUp ? spaceAbove : spaceBelow) - 16));
    setPos({
      left: r.left,
      width: r.width,
      maxH,
      top: openUp ? undefined : r.bottom + 4,
      bottom: openUp ? window.innerHeight - r.top + 4 : undefined,
    });
  }, []);

  const selected = useMemo(
    () => options.find((o) => o.value === value),
    [options, value]
  );

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return options;
    return options.filter(
      (o) =>
        o.label.toLowerCase().includes(q) ||
        o.hint?.toLowerCase().includes(q)
    );
  }, [options, query]);

  // Offer to create the typed value when it matches no existing option.
  const trimmedQuery = query.trim();
  const showCreate =
    creatable &&
    trimmedQuery.length > 0 &&
    !options.some((o) => o.value.toLowerCase() === trimmedQuery.toLowerCase());

  // Debounced server-side search: forward the typed query to the parent so it
  // can refetch options. Only active when an onSearch handler is supplied.
  const onSearchRef = useRef(onSearch);
  onSearchRef.current = onSearch;
  useEffect(() => {
    if (!onSearchRef.current || !open) return;
    const t = setTimeout(() => onSearchRef.current?.(query.trim()), 250);
    return () => clearTimeout(t);
  }, [query, open]);

  const close = () => {
    setOpen(false);
    setQuery('');
    onClose?.();
  };

  // Close on outside click — the menu lives in a portal, so check it too.
  useEffect(() => {
    if (!open) return;
    const handler = (e: MouseEvent) => {
      const t = e.target as Node;
      if (!rootRef.current?.contains(t) && !menuRef.current?.contains(t)) {
        close();
      }
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);

  // Keep the portal menu aligned to the trigger while open.
  useEffect(() => {
    if (!open) return;
    place();
    const onMove = () => place();
    window.addEventListener('scroll', onMove, true);
    window.addEventListener('resize', onMove);
    return () => {
      window.removeEventListener('scroll', onMove, true);
      window.removeEventListener('resize', onMove);
    };
  }, [open, place]);

  // Focus the search input whenever the menu opens.
  useEffect(() => {
    if (open) {
      setHighlight(0);
      const t = setTimeout(() => searchRef.current?.focus(), 0);
      return () => clearTimeout(t);
    }
  }, [open]);

  const pick = (val: string) => {
    onChange(val);
    setOpen(false);
    setQuery('');
  };

  const onKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Escape') {
      e.preventDefault();
      close();
    } else if (e.key === 'ArrowDown') {
      e.preventDefault();
      setHighlight((h) => Math.min(h + 1, filtered.length - 1));
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      setHighlight((h) => Math.max(h - 1, 0));
    } else if (e.key === 'Enter') {
      e.preventDefault();
      const opt = filtered[highlight];
      if (opt) pick(opt.value);
      else if (showCreate) pick(trimmedQuery);
    }
  };

  const triggerPad = size === 'sm' ? 'px-2 py-1 text-xs' : 'px-4 py-2.5 text-sm';

  return (
    <div ref={rootRef} className={cn('relative w-full', className)}>
      {label && (
        <label className="block text-sm font-medium text-secondary-700 mb-1.5">
          {label}
        </label>
      )}

      <button
        ref={btnRef}
        type="button"
        disabled={disabled}
        onClick={() => !disabled && setOpen((o) => !o)}
        className={cn(
          'flex w-full items-center justify-between gap-2 rounded-lg border border-secondary-300 bg-surface text-left text-secondary-900',
          'focus:border-primary-500 focus:outline-none focus:ring-2 focus:ring-primary-500/20',
          'disabled:cursor-not-allowed disabled:bg-secondary-50 disabled:text-secondary-500',
          'transition-colors duration-200',
          triggerPad
        )}
      >
        <span className={cn('truncate', !selected && !value && 'text-secondary-400')}>
          {selected ? selected.label : value ? value : placeholder}
        </span>
        <span className="flex items-center gap-1">
          {clearable && (selected || value) && !disabled && (
            <X
              className="h-3.5 w-3.5 text-secondary-400 hover:text-secondary-600"
              onClick={(e) => {
                e.stopPropagation();
                onChange('');
              }}
            />
          )}
          <ChevronDown className="h-4 w-4 shrink-0 text-secondary-400" />
        </span>
      </button>

      {open && pos && typeof document !== 'undefined' && createPortal(
        <div
          ref={menuRef}
          className="rounded-lg border border-secondary-200 bg-surface shadow-xl overflow-hidden"
          style={{ position: 'fixed', left: pos.left, width: pos.width, top: pos.top, bottom: pos.bottom, zIndex: 9999 }}
        >
          <div className="flex items-center gap-2 border-b border-secondary-100 px-3 py-2">
            <Search className="h-4 w-4 shrink-0 text-secondary-400" />
            <input
              ref={searchRef}
              value={query}
              onChange={(e) => {
                setQuery(e.target.value);
                setHighlight(0);
              }}
              onKeyDown={onKeyDown}
              placeholder={searchPlaceholder}
              className="w-full bg-transparent text-sm text-secondary-900 placeholder:text-secondary-400 focus:outline-none"
            />
          </div>
          <ul className="overflow-y-auto py-1" role="listbox" style={{ maxHeight: pos.maxH }}>
            {filtered.length === 0 && !showCreate ? (
              <li className="px-3 py-2 text-sm text-secondary-400">{emptyMessage}</li>
            ) : (
              filtered.map((opt, i) => {
                const isSelected = opt.value === value;
                return (
                  <li key={opt.value} role="option" aria-selected={isSelected}>
                    <button
                      type="button"
                      onClick={() => pick(opt.value)}
                      onMouseEnter={() => setHighlight(i)}
                      className={cn(
                        'flex w-full items-center justify-between gap-2 px-3 py-2 text-left text-sm',
                        i === highlight ? 'bg-primary-50' : 'hover:bg-secondary-50'
                      )}
                    >
                      <span className="min-w-0">
                        <span className="block truncate text-secondary-900">{opt.label}</span>
                        {opt.hint && (
                          <span className="block truncate text-xs text-secondary-400">{opt.hint}</span>
                        )}
                      </span>
                      {isSelected && <Check className="h-4 w-4 shrink-0 text-primary-600" />}
                    </button>
                  </li>
                );
              })
            )}
            {showCreate && (
              <li role="option" aria-selected={false}>
                <button
                  type="button"
                  onClick={() => pick(trimmedQuery)}
                  className="flex w-full items-center gap-2 px-3 py-2 text-left text-sm text-primary-600 hover:bg-primary-50"
                >
                  <Plus className="h-4 w-4 shrink-0" />
                  <span className="min-w-0 truncate">Create &ldquo;{trimmedQuery}&rdquo;</span>
                </button>
              </li>
            )}
          </ul>
        </div>,
        document.body
      )}
    </div>
  );
};

SearchableSelect.displayName = 'SearchableSelect';

export default SearchableSelect;

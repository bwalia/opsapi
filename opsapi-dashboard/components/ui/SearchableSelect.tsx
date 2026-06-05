'use client';

import React, { useEffect, useMemo, useRef, useState } from 'react';
import { cn } from '@/lib/utils';
import { ChevronDown, Search, Check, X } from 'lucide-react';

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
}) => {
  const [open, setOpen] = useState(autoFocus);
  const [query, setQuery] = useState('');
  const [highlight, setHighlight] = useState(0);
  const rootRef = useRef<HTMLDivElement>(null);
  const searchRef = useRef<HTMLInputElement>(null);

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

  const close = () => {
    setOpen(false);
    setQuery('');
    onClose?.();
  };

  // Close on outside click.
  useEffect(() => {
    if (!open) return;
    const handler = (e: MouseEvent) => {
      if (rootRef.current && !rootRef.current.contains(e.target as Node)) {
        close();
      }
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);

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
        <span className={cn('truncate', !selected && 'text-secondary-400')}>
          {selected ? selected.label : placeholder}
        </span>
        <span className="flex items-center gap-1">
          {clearable && selected && !disabled && (
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

      {open && (
        <div className="absolute z-50 mt-1 w-full min-w-[200px] rounded-lg border border-secondary-200 bg-surface shadow-lg">
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
          <ul className="max-h-60 overflow-y-auto py-1" role="listbox">
            {filtered.length === 0 ? (
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
          </ul>
        </div>
      )}
    </div>
  );
};

SearchableSelect.displayName = 'SearchableSelect';

export default SearchableSelect;

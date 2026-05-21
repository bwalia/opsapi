'use client';

/**
 * ThemePicker — header dropdown for choosing light/dark/system mode and an
 * accent preset. Drives the client-side ThemeContext (which sets data-theme
 * + inline accent vars). Keyboard-accessible and closes on outside click.
 */

import React, { useState, useRef, useEffect, useCallback } from 'react';
import { Sun, Moon, Monitor, Palette, Check } from 'lucide-react';
import { cn } from '@/lib/utils';
import { useTheme, type ThemeMode } from '@/contexts/ThemeContext';

const MODES: { id: ThemeMode; label: string; icon: React.ElementType }[] = [
  { id: 'light', label: 'Light', icon: Sun },
  { id: 'dark', label: 'Dark', icon: Moon },
  { id: 'system', label: 'System', icon: Monitor },
];

export default function ThemePicker() {
  const { mode, resolvedTheme, accent, setMode, setAccent, presets } = useTheme();
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  // Close on outside click + Escape.
  useEffect(() => {
    if (!open) return;
    const onClick = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setOpen(false);
    };
    document.addEventListener('mousedown', onClick);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('mousedown', onClick);
      document.removeEventListener('keydown', onKey);
    };
  }, [open]);

  const toggle = useCallback(() => setOpen((v) => !v), []);

  // Trigger icon mirrors the *resolved* theme so users see what's active.
  const TriggerIcon = resolvedTheme === 'dark' ? Moon : Sun;

  return (
    <div className="relative" ref={ref}>
      <button
        onClick={toggle}
        className="flex items-center justify-center w-9 h-9 rounded-lg text-secondary-500 hover:text-secondary-900 hover:bg-secondary-100 transition-colors"
        aria-label="Theme settings"
        aria-haspopup="true"
        aria-expanded={open}
      >
        <TriggerIcon className="w-[18px] h-[18px]" />
      </button>

      {open && (
        <div
          className="absolute right-0 mt-2 w-64 bg-surface rounded-xl shadow-xl border border-secondary-200 p-3 z-50 animate-in"
          role="menu"
          aria-label="Theme settings"
        >
          {/* Appearance mode */}
          <p className="px-1 pb-2 text-xs font-semibold text-secondary-400 uppercase tracking-wider">
            Appearance
          </p>
          <div className="grid grid-cols-3 gap-1.5 mb-3">
            {MODES.map(({ id, label, icon: Icon }) => {
              const active = mode === id;
              return (
                <button
                  key={id}
                  onClick={() => setMode(id)}
                  className={cn(
                    'flex flex-col items-center gap-1.5 py-2.5 rounded-lg border text-xs font-medium transition-all',
                    active
                      ? 'border-primary-500 bg-primary-500/10 text-primary-600'
                      : 'border-secondary-200 text-secondary-600 hover:bg-secondary-100 hover:border-secondary-300',
                  )}
                  aria-pressed={active}
                >
                  <Icon className="w-4 h-4" />
                  {label}
                </button>
              );
            })}
          </div>

          {/* Accent presets */}
          <div className="flex items-center gap-1.5 px-1 pb-2">
            <Palette className="w-3.5 h-3.5 text-secondary-400" />
            <p className="text-xs font-semibold text-secondary-400 uppercase tracking-wider">
              Accent
            </p>
          </div>
          <div className="flex flex-wrap gap-2 px-1">
            {presets.map((preset) => {
              const active = accent === preset.id;
              return (
                <button
                  key={preset.id}
                  onClick={() => setAccent(preset.id)}
                  title={preset.label}
                  aria-label={`Accent: ${preset.label}`}
                  aria-pressed={active}
                  className={cn(
                    'relative w-7 h-7 rounded-full transition-transform hover:scale-110',
                    active && 'ring-2 ring-offset-2 ring-offset-surface ring-secondary-400',
                  )}
                  style={{ backgroundColor: preset.swatch }}
                >
                  {active && (
                    <Check className="absolute inset-0 m-auto w-3.5 h-3.5 text-white drop-shadow" />
                  )}
                </button>
              );
            })}
          </div>
        </div>
      )}
    </div>
  );
}

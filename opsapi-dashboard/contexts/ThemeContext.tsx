'use client';

/**
 * Theme context — client-side light/dark/system + accent preset switching.
 *
 * How it composes with the rest of the theming stack:
 *   - This layer sets `data-theme="light|dark"` on <html>, which flips the
 *     CSS-variable palette defined in globals.css (the neutral ramp inverts).
 *   - The accent preset sets `--color-primary-*` overrides inline on <html>,
 *     letting the user pick a brand color without a backend round-trip.
 *   - The backend per-namespace theme (ThemeStyles.tsx) still loads on top
 *     and can set --color-primary-* via its :root rules for tenant branding.
 *     The user's explicit accent choice wins because it's set inline on
 *     <html> (inline styles beat any stylesheet rule). Light/dark wins via
 *     the html[data-theme] selector's higher specificity (see globals.css).
 *
 * Persistence: localStorage. "system" mode follows the OS preference live
 * via a matchMedia listener. A blocking inline script (ThemeScript) applies
 * the saved theme before first paint to avoid a flash of the wrong theme.
 */

import React, {
  createContext,
  useContext,
  useEffect,
  useCallback,
  useState,
  useMemo,
} from 'react';

export type ThemeMode = 'light' | 'dark' | 'system';

/** Built-in accent presets. `null` value = use the default/brand (or backend) accent. */
export interface AccentPreset {
  id: string;
  label: string;
  /** The 500-step swatch shown in the picker. */
  swatch: string;
  /** Full 50→950 scale, or null to fall back to the CSS default. */
  scale: Record<string, string> | null;
}

export const ACCENT_PRESETS: AccentPreset[] = [
  // Brand is the default accent (#ff004e). It carries an explicit scale so it
  // is applied inline on <html> and therefore wins over any active backend
  // per-namespace theme — keeping the brand color consistent across the login
  // page AND the dashboard. Picking another preset overrides it everywhere.
  {
    id: 'brand', label: 'Brand', swatch: '#ff004e',
    scale: {
      '50': '#fff0f3', '100': '#ffe0e8', '200': '#ffc6d5', '300': '#ff9fb5',
      '400': '#ff6088', '500': '#ff004e', '600': '#e6003f', '700': '#c20035',
      '800': '#a00030', '900': '#84002c', '950': '#4a0016',
    },
  },
  {
    id: 'indigo', label: 'Indigo', swatch: '#6366f1',
    scale: {
      '50': '#eef2ff', '100': '#e0e7ff', '200': '#c7d2fe', '300': '#a5b4fc',
      '400': '#818cf8', '500': '#6366f1', '600': '#4f46e5', '700': '#4338ca',
      '800': '#3730a3', '900': '#312e81', '950': '#1e1b4b',
    },
  },
  {
    id: 'emerald', label: 'Emerald', swatch: '#10b981',
    scale: {
      '50': '#ecfdf5', '100': '#d1fae5', '200': '#a7f3d0', '300': '#6ee7b7',
      '400': '#34d399', '500': '#10b981', '600': '#059669', '700': '#047857',
      '800': '#065f46', '900': '#064e3b', '950': '#022c22',
    },
  },
  {
    id: 'blue', label: 'Blue', swatch: '#3b82f6',
    scale: {
      '50': '#eff6ff', '100': '#dbeafe', '200': '#bfdbfe', '300': '#93c5fd',
      '400': '#60a5fa', '500': '#3b82f6', '600': '#2563eb', '700': '#1d4ed8',
      '800': '#1e40af', '900': '#1e3a8a', '950': '#172554',
    },
  },
  {
    id: 'amber', label: 'Amber', swatch: '#f59e0b',
    scale: {
      '50': '#fffbeb', '100': '#fef3c7', '200': '#fde68a', '300': '#fcd34d',
      '400': '#fbbf24', '500': '#f59e0b', '600': '#d97706', '700': '#b45309',
      '800': '#92400e', '900': '#78350f', '950': '#451a03',
    },
  },
  {
    id: 'violet', label: 'Violet', swatch: '#8b5cf6',
    scale: {
      '50': '#f5f3ff', '100': '#ede9fe', '200': '#ddd6fe', '300': '#c4b5fd',
      '400': '#a78bfa', '500': '#8b5cf6', '600': '#7c3aed', '700': '#6d28d9',
      '800': '#5b21b6', '900': '#4c1d95', '950': '#2e1065',
    },
  },
];

const THEME_KEY = 'ops-theme-mode';
const ACCENT_KEY = 'ops-theme-accent';

interface ThemeContextValue {
  mode: ThemeMode;
  /** The actually-applied theme after resolving "system". */
  resolvedTheme: 'light' | 'dark';
  accent: string;
  setMode: (mode: ThemeMode) => void;
  setAccent: (accentId: string) => void;
  presets: AccentPreset[];
}

const ThemeContext = createContext<ThemeContextValue | undefined>(undefined);

function systemPrefersDark(): boolean {
  if (typeof window === 'undefined') return false;
  return window.matchMedia('(prefers-color-scheme: dark)').matches;
}

function applyAccent(accentId: string) {
  if (typeof document === 'undefined') return;
  const preset = ACCENT_PRESETS.find((p) => p.id === accentId);
  const root = document.documentElement;
  const steps = ['50', '100', '200', '300', '400', '500', '600', '700', '800', '900', '950'];
  // We set --color-primary-* INLINE on <html>. Inline styles beat every
  // stylesheet — including the backend per-namespace theme <link> and the
  // @theme :root defaults — so the user's accent choice always applies.
  if (!preset || !preset.scale) {
    // Brand/default — remove inline overrides so the @theme default (or an
    // active backend theme) provides the accent.
    steps.forEach((s) => root.style.removeProperty(`--color-primary-${s}`));
    return;
  }
  steps.forEach((s) => {
    if (preset.scale![s]) root.style.setProperty(`--color-primary-${s}`, preset.scale![s]);
  });
}

function applyTheme(resolved: 'light' | 'dark') {
  if (typeof document === 'undefined') return;
  document.documentElement.setAttribute('data-theme', resolved);
}

export function ThemeProvider({ children }: { children: React.ReactNode }) {
  const [mode, setModeState] = useState<ThemeMode>('system');
  const [accent, setAccentState] = useState<string>('brand');
  const [resolvedTheme, setResolvedTheme] = useState<'light' | 'dark'>('light');

  // Hydrate from localStorage once on mount.
  useEffect(() => {
    const savedMode = (localStorage.getItem(THEME_KEY) as ThemeMode) || 'system';
    const savedAccent = localStorage.getItem(ACCENT_KEY) || 'brand';
    setModeState(savedMode);
    setAccentState(savedAccent);
    applyAccent(savedAccent);
  }, []);

  // Resolve + apply the theme whenever mode changes, and keep "system" live.
  useEffect(() => {
    const resolve = () => {
      const next: 'light' | 'dark' =
        mode === 'system' ? (systemPrefersDark() ? 'dark' : 'light') : mode;
      setResolvedTheme(next);
      applyTheme(next);
    };
    resolve();

    if (mode === 'system') {
      const mq = window.matchMedia('(prefers-color-scheme: dark)');
      mq.addEventListener('change', resolve);
      return () => mq.removeEventListener('change', resolve);
    }
  }, [mode]);

  const setMode = useCallback((next: ThemeMode) => {
    setModeState(next);
    localStorage.setItem(THEME_KEY, next);
  }, []);

  const setAccent = useCallback((accentId: string) => {
    setAccentState(accentId);
    localStorage.setItem(ACCENT_KEY, accentId);
    applyAccent(accentId);
  }, []);

  const value = useMemo<ThemeContextValue>(
    () => ({ mode, resolvedTheme, accent, setMode, setAccent, presets: ACCENT_PRESETS }),
    [mode, resolvedTheme, accent, setMode, setAccent],
  );

  return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>;
}

export function useTheme(): ThemeContextValue {
  const ctx = useContext(ThemeContext);
  if (!ctx) throw new Error('useTheme must be used within <ThemeProvider>');
  return ctx;
}

/**
 * Blocking inline script — runs before React hydration to set data-theme
 * and the accent vars from localStorage, eliminating the flash of wrong
 * theme on first paint. Rendered in <head> via the root layout.
 */
export function ThemeScript() {
  const js = `(function(){try{
    var m=localStorage.getItem('${THEME_KEY}')||'system';
    var d=m==='dark'||(m==='system'&&window.matchMedia('(prefers-color-scheme: dark)').matches);
    document.documentElement.setAttribute('data-theme', d?'dark':'light');
    var a=localStorage.getItem('${ACCENT_KEY}')||'brand';
    var P=${JSON.stringify(
      Object.fromEntries(ACCENT_PRESETS.filter((p) => p.scale).map((p) => [p.id, p.scale])),
    )};
    var s=P[a];
    if(s){Object.keys(s).forEach(function(k){document.documentElement.style.setProperty('--color-primary-'+k,s[k]);});}
  }catch(e){}})();`;
  return <script dangerouslySetInnerHTML={{ __html: js }} />;
}

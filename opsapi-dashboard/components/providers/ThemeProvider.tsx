'use client';

import React from 'react';
import { ThemeProvider as NextThemesProvider } from 'next-themes';

/**
 * App-wide theme provider (light / dark). next-themes toggles a `.dark` class on
 * <html>; globals.css remaps the design tokens under it, so the whole UI flips
 * without per-component work.
 *
 * Defaults to LIGHT and does NOT follow the OS preference (`enableSystem={false}`):
 * the tenant themes are light-only and are injected onto `:root`, which overrides
 * the dark-mode surface tokens and produces a broken half-dark/half-light hybrid
 * when the OS is dark. Defaulting to light keeps the tenant theme consistent; the
 * header toggle still lets a user opt into dark explicitly.
 */
export function ThemeProvider({ children }: { children: React.ReactNode }) {
  return (
    <NextThemesProvider attribute="class" defaultTheme="light" enableSystem={false}>
      {children}
    </NextThemesProvider>
  );
}

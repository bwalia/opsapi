'use client';

import React from 'react';
import { ThemeProvider as NextThemesProvider } from 'next-themes';

/**
 * App-wide theme provider (light / dark / system). next-themes toggles a
 * `.dark` class on <html>; globals.css remaps the design tokens under it, so the
 * whole UI flips without per-component work. Defaults to the OS preference.
 */
export function ThemeProvider({ children }: { children: React.ReactNode }) {
  return (
    <NextThemesProvider attribute="class" defaultTheme="system" enableSystem>
      {children}
    </NextThemesProvider>
  );
}

import type { Metadata } from 'next';
import { Geist } from 'next/font/google';
import { Toaster } from 'react-hot-toast';
import { ThemeProvider, ThemeScript } from '@/contexts/ThemeContext';
import './globals.css';

// Geist — Vercel's geometric sans. Clean, modern, excellent at small sizes
// and in dark mode. Exposed as --font-inter to avoid touching every
// downstream reference to that CSS variable name.
const geist = Geist({
  subsets: ['latin'],
  display: 'swap',
  variable: '--font-inter',
  weight: ['400', '500', '600', '700'],
});

export const metadata: Metadata = {
  title: 'OpsAPI Dashboard',
  description: 'Professional admin dashboard for OpsAPI',
  icons: {
    icon: '/favicon.ico',
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" className={geist.variable} suppressHydrationWarning>
      <head>
        {/* Applies saved theme + accent before first paint (no flash). */}
        <ThemeScript />
      </head>
      <body className="antialiased">
        {/* Skip to main content link for keyboard/screen reader users */}
        <a
          href="#main-content"
          className="skip-to-content"
        >
          Skip to main content
        </a>
        <ThemeProvider>{children}</ThemeProvider>
        <Toaster
          position="top-right"
          toastOptions={{
            duration: 4000,
            style: {
              background: '#0f172a',
              color: '#fff',
              borderRadius: '12px',
              padding: '16px',
              fontSize: '0.875rem',
              lineHeight: '1.5',
            },
            success: {
              iconTheme: {
                primary: '#22c55e',
                secondary: '#fff',
              },
            },
            error: {
              iconTheme: {
                primary: '#ef4444',
                secondary: '#fff',
              },
            },
            ariaProps: {
              role: 'status',
              'aria-live': 'polite',
            },
          }}
        />
      </body>
    </html>
  );
}

import type { Metadata, Viewport } from 'next';
import localFont from 'next/font/local';
import { Toaster } from 'react-hot-toast';
import { ThemeProvider } from '@/components/providers/ThemeProvider';
import PWAInstallPrompt from '@/components/pwa/PWAInstallPrompt';
import ServiceWorkerRegister from '@/components/pwa/ServiceWorkerRegister';
import RouteCacheWarmer from '@/components/pwa/RouteCacheWarmer';
import OfflineProvider from '@/components/offline/OfflineProvider';
import OfflineIndicator from '@/components/offline/OfflineIndicator';
import './globals.css';

// Plus Jakarta Sans — a modern, geometric-humanist sans with a large x-height.
// SELF-HOSTED via next/font/local (not next/font/google): the Turbopack
// production build fetches Google fonts at build time, which fails on the CI
// runner with no egress to fonts.gstatic.com ("Can't resolve
// @vercel/turbopack-next/internal/font/google/font"). The variable woff2 covers
// weights 200–800, so the same --font-jakarta token still drives 400–800.
const jakarta = localFont({
  src: './fonts/plus-jakarta-sans-latin-wght-normal.woff2',
  display: 'swap',
  variable: '--font-jakarta',
  weight: '200 800',
});

export const metadata: Metadata = {
  title: {
    default: 'OpsAPI — Operations Platform',
    template: '%s · OpsAPI',
  },
  description: 'OpsAPI — the multi-tenant operations platform. One API for your whole business, from CRM to tax filing to edge routing.',
  icons: {
    icon: [{ url: '/opsapi-logo.svg', type: 'image/svg+xml' }],
    shortcut: '/opsapi-logo.svg',
    // iOS home-screen icon must be a non-transparent PNG.
    apple: [{ url: '/icons/apple-touch-icon.png', sizes: '180x180' }],
  },
  // iOS standalone (installed) behaviour.
  appleWebApp: {
    capable: true,
    statusBarStyle: 'default',
    title: 'OpsAPI',
  },
};

export const viewport: Viewport = {
  themeColor: '#c20035',
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" className={jakarta.variable} suppressHydrationWarning>
      <body className="antialiased">
        {/* Skip to main content link for keyboard/screen reader users */}
        <a
          href="#main-content"
          className="skip-to-content"
        >
          Skip to main content
        </a>
        <OfflineProvider />
        <OfflineIndicator />
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
        <PWAInstallPrompt />
        <ServiceWorkerRegister />
        <RouteCacheWarmer />
      </body>
    </html>
  );
}

import type { Metadata } from 'next';
import { Plus_Jakarta_Sans } from 'next/font/google';
import { Toaster } from 'react-hot-toast';
import './globals.css';

// Plus Jakarta Sans — a modern, geometric-humanist sans with a large x-height,
// so it reads clearer/bigger than Inter at the same size. Loaded via next/font
// (self-hosted, zero layout shift). Exposed as --font-jakarta; globals.css maps
// it into --font-sans with a system fallback stack.
const jakarta = Plus_Jakarta_Sans({
  subsets: ['latin'],
  display: 'swap',
  variable: '--font-jakarta',
  weight: ['400', '500', '600', '700', '800'],
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
    apple: '/opsapi-logo.svg',
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" className={jakarta.variable}>
      <body className="antialiased">
        {/* Skip to main content link for keyboard/screen reader users */}
        <a
          href="#main-content"
          className="skip-to-content"
        >
          Skip to main content
        </a>
        {children}
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

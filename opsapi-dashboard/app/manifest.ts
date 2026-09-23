import type { MetadataRoute } from 'next';

// Web App Manifest — makes the dashboard installable (home-screen icon, its own
// window, splash screen). Served at /manifest.webmanifest; Next auto-links it.
//
// Note: a manifest is per-origin, so the installed app's name/icon are the
// platform's, not per-tenant. In-app theming (useBrand) still applies once the
// app is open; only the OS-level identity is fixed here.
export default function manifest(): MetadataRoute.Manifest {
  return {
    id: '/',
    name: 'OpsAPI — Operations Platform',
    short_name: 'OpsAPI',
    description:
      'The multi-tenant operations platform — CRM, invoicing, tax filing, kanban and more, in one place.',
    start_url: '/dashboard',
    scope: '/',
    display: 'standalone',
    background_color: '#ffffff',
    theme_color: '#c20035',
    icons: [
      { src: '/icons/icon-192.png', sizes: '192x192', type: 'image/png', purpose: 'any' },
      { src: '/icons/icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'any' },
      { src: '/icons/maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
    ],
  };
}

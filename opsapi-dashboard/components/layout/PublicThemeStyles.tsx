'use client';

import { useEffect } from 'react';

/**
 * PublicThemeStyles — injects the active theme CSS on UNAUTHENTICATED pages
 * (login, verify-otp) so the whole site is themed, not just the dashboard.
 *
 * Unlike <ThemeStyles/>, this does NOT depend on NamespaceContext (which only
 * exists inside DashboardLayout). It resolves the tenant from an explicit
 * `?namespace=` query param or the host subdomain; with neither it falls back
 * to the platform default theme (the pink #ff004e "OpsAPI Bright" preset).
 *
 * It targets the same <link id> as ThemeStyles, so once the dashboard mounts
 * its namespace-aware loader, that takes over seamlessly.
 */
const LINK_ID = 'ops-active-theme-css';

function apiBase(): string {
  return process.env.NEXT_PUBLIC_API_URL || 'http://127.0.0.1:4010';
}

function resolveSlug(): string | undefined {
  if (typeof window === 'undefined') return undefined;

  // 1. Explicit query param wins (?namespace=acme)
  const param = new URLSearchParams(window.location.search).get('namespace');
  if (param) return param;

  // 2. Host subdomain (acme.opsapi.com -> "acme"), skipping IPs and generic hosts
  const host = window.location.hostname;
  const isIp = /^\d{1,3}(\.\d{1,3}){3}$/.test(host);
  if (!isIp) {
    const parts = host.split('.');
    const generic = ['www', 'app', 'dashboard', 'api', 'localhost'];
    if (parts.length > 2 && parts[0] && !generic.includes(parts[0])) {
      return parts[0];
    }
  }

  // 3. No tenant context -> platform default (pink) theme
  return undefined;
}

export default function PublicThemeStyles() {
  useEffect(() => {
    if (typeof document === 'undefined') return;

    const slug = resolveSlug();
    const base = `${apiBase()}/api/v2/themes/active/styles.css`;
    const href = slug ? `${base}?namespace=${encodeURIComponent(slug)}` : base;

    let link = document.getElementById(LINK_ID) as HTMLLinkElement | null;
    if (!link) {
      link = document.createElement('link');
      link.id = LINK_ID;
      link.rel = 'stylesheet';
      document.head.appendChild(link);
    }
    if (link.href !== href) link.href = href;
  }, []);

  return null;
}

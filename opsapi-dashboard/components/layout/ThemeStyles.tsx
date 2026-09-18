'use client';

import { useCallback, useEffect, useState } from 'react';
import { useNamespace } from '@/contexts/NamespaceContext';
import { useBrand } from '@/components/brand/Logo';
import { themesService } from '@/services/themes.service';

const LINK_ID = 'ops-active-theme-css';
const ACTIVATION_EVENT = 'theme:activated';

function apiBase(): string {
  return process.env.NEXT_PUBLIC_API_URL || 'http://127.0.0.1:4010';
}

function buildHref(slug: string | undefined, version: string): string {
  const base = slug
    ? `${apiBase()}/api/v2/themes/active/styles.css?namespace=${encodeURIComponent(slug)}`
    : `${apiBase()}/api/v2/themes/active/styles.css`;
  const sep = base.includes('?') ? '&' : '?';
  return `${base}${sep}v=${encodeURIComponent(version)}`;
}

export default function ThemeStyles() {
  const { currentNamespace } = useNamespace();
  const { logoUrl } = useBrand();
  const slug = currentNamespace?.slug;
  const [version, setVersion] = useState<string>('0');

  const refreshVersion = useCallback(async () => {
    try {
      const resolved = await themesService.getActive();
      const theme = resolved?.theme;
      if (theme?.uuid) {
        setVersion(`${theme.uuid}-${theme.updated_at || theme.version || ''}`);
      } else {
        setVersion(`default-${Date.now()}`);
      }
    } catch {
      setVersion(`err-${Date.now()}`);
    }
  }, []);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const resolved = await themesService.getActive();
        if (cancelled) return;
        const theme = resolved?.theme;
        if (theme?.uuid) {
          setVersion(`${theme.uuid}-${theme.updated_at || theme.version || ''}`);
        } else {
          setVersion(`default-${Date.now()}`);
        }
      } catch {
        if (!cancelled) setVersion(`err-${Date.now()}`);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [slug]);

  useEffect(() => {
    if (typeof window === 'undefined') return;
    const handler = () => {
      refreshVersion();
    };
    window.addEventListener(ACTIVATION_EVENT, handler);
    return () => window.removeEventListener(ACTIVATION_EVENT, handler);
  }, [refreshVersion]);

  useEffect(() => {
    if (typeof document === 'undefined') return;

    const href = buildHref(slug, version);

    let link = document.getElementById(LINK_ID) as HTMLLinkElement | null;
    if (!link) {
      link = document.createElement('link');
      link.id = LINK_ID;
      link.rel = 'stylesheet';
      document.head.appendChild(link);
    }
    if (link.href !== href) {
      link.href = href;
    }
  }, [slug, version]);

  // White-labelled tenants get their own favicon; the OpsAPI one (declared in
  // app/layout.tsx metadata) stands when the namespace has no logo.
  //
  // We manage ONLY our own <link id="ops-tenant-favicon"> (created imperatively,
  // so React/Next never owns it) and update it in place. We must NOT remove the
  // favicon Next renders from metadata: deleting a React/Next-managed node out
  // from under it makes React crash on the next reconciliation with
  // "Cannot read properties of null (reading 'removeChild')", which on a
  // white-label tenant (e.g. workstation) turned every client-side navigation
  // after login into a crash/reload loop. A tenant icon appended after Next's
  // wins in the browser, so the tenant logo still takes over.
  useEffect(() => {
    if (typeof document === 'undefined') return;
    const ID = 'ops-tenant-favicon';
    let icon = document.getElementById(ID) as HTMLLinkElement | null;
    if (!logoUrl) {
      if (icon) icon.remove(); // only our own node; leave Next's default
      return;
    }
    if (!icon) {
      icon = document.createElement('link');
      icon.id = ID;
      icon.rel = 'icon';
      document.head.appendChild(icon);
    }
    if (icon.href !== logoUrl) icon.href = logoUrl;
  }, [logoUrl]);

  return null;
}

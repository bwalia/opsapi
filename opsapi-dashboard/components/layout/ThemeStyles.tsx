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

  // White-labelled tenants get their own favicon too; the OpsAPI one (declared
  // in app/layout.tsx metadata) stands when the namespace has no logo.
  useEffect(() => {
    if (typeof document === 'undefined' || !logoUrl) return;
    document.querySelectorAll<HTMLLinkElement>('link[rel~="icon"]').forEach((el) => el.remove());
    const icon = document.createElement('link');
    icon.rel = 'icon';
    icon.href = logoUrl;
    document.head.appendChild(icon);
    return () => icon.remove();
  }, [logoUrl]);

  return null;
}

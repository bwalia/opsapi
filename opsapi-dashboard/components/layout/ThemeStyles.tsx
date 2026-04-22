'use client';

import { useEffect } from 'react';
import { useNamespace } from '@/contexts/NamespaceContext';

const LINK_ID = 'ops-active-theme-css';

function apiBase(): string {
  return process.env.NEXT_PUBLIC_API_URL || 'http://127.0.0.1:4010';
}

export default function ThemeStyles() {
  const { currentNamespace } = useNamespace();
  const slug = currentNamespace?.slug;

  useEffect(() => {
    if (typeof document === 'undefined') return;

    const href = slug
      ? `${apiBase()}/api/v2/themes/active/styles.css?namespace=${encodeURIComponent(slug)}`
      : `${apiBase()}/api/v2/themes/active/styles.css`;

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
  }, [slug]);

  return null;
}

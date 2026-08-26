'use client';

import React, { useState } from 'react';
import { useNamespaceStore } from '@/store/namespace.store';

/**
 * Brand mark for the dashboard chrome.
 *
 * OpsAPI is white-labelled per tenant: a namespace that sets `logo_url` takes
 * over the mark AND the wordmark (its own `name`), so an academy instructor
 * handed off from the learner site sees Academy branding, not OpsAPI. Colors,
 * fonts and radii come from the tenant's active theme (ThemeStyles), so this
 * is the only hard-coded piece of identity left.
 *
 * No logo_url set => the OpsAPI house brand below.
 */

export interface Brand {
  name: string;
  logoUrl?: string;
}

/**
 * Current tenant's brand. Reads the namespace *store* rather than
 * NamespaceContext so it also works on pre-auth pages (login, /auth/sso), which
 * render outside the provider — the store is persisted, so a returning tenant
 * user keeps their branding on the login screen.
 */
export function useBrand(): Brand {
  const current = useNamespaceStore((s) => s.currentNamespace);
  const all = useNamespaceStore((s) => s.namespaces);
  // The namespace baked into the JWT carries only id/name/slug, so fall back to
  // the full row from the list when it's loaded.
  const logoUrl =
    current?.logo_url || all.find((n) => n.uuid === current?.uuid)?.logo_url || undefined;

  if (!logoUrl) return { name: 'OpsAPI' };
  return { name: current?.name || 'OpsAPI', logoUrl };
}

/**
 * OpsAPI house glyph — an "O" (Ops) built from an orbit ring around a core, with
 * a single API-endpoint node sitting on the ring. Pure inline SVG so it scales
 * crisply and can be animated / themed.
 */
function OpsApiMark({ size, className }: { size: number; className: string }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 48 48"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      className={className}
      role="img"
      aria-label="OpsAPI"
    >
      <defs>
        <linearGradient id="opsapi-mark-grad" x1="4" y1="4" x2="44" y2="44" gradientUnits="userSpaceOnUse">
          <stop stopColor="#ff3d74" />
          <stop offset="1" stopColor="#c20035" />
        </linearGradient>
      </defs>
      {/* squircle badge */}
      <rect x="3" y="3" width="42" height="42" rx="12.5" fill="url(#opsapi-mark-grad)" />
      {/* orbit ring (the "O" / Ops) */}
      <circle cx="24" cy="24" r="10.5" stroke="#fff" strokeWidth="3" strokeOpacity="0.95" />
      {/* core */}
      <circle cx="24" cy="24" r="3.4" fill="#fff" />
      {/* API-endpoint node on the ring (white socket with a colored center) */}
      <circle cx="31.4" cy="16.6" r="4" fill="#fff" />
      <circle cx="31.4" cy="16.6" r="1.7" fill="url(#opsapi-mark-grad)" />
    </svg>
  );
}

export function LogoMark({ size = 40, className = '' }: { size?: number; className?: string }) {
  const { name, logoUrl } = useBrand();
  // A tenant's logo_url points at an asset on THEIR site, which we don't control
  // and which may be missing (a namespace branded before its site deployed, a
  // moved file, an outage). Fall back to the house mark rather than leaving a
  // broken image in the chrome.
  // Keyed by URL, not a boolean, so switching namespace retries the new logo.
  const [failedUrl, setFailedUrl] = useState<string | null>(null);

  if (logoUrl && logoUrl !== failedUrl) {
    return (
      // eslint-disable-next-line @next/next/no-img-element
      <img
        src={logoUrl}
        alt={name}
        width={size}
        height={size}
        style={{ width: size, height: size }}
        className={`rounded-xl object-contain ${className}`}
        onError={() => setFailedUrl(logoUrl)}
      />
    );
  }
  return <OpsApiMark size={size} className={className} />;
}

/**
 * Full lockup: mark + wordmark. `tone` controls the wordmark color for
 * placement on dark ("light" text) or light ("dark" text) surfaces.
 */
export function Logo({
  size = 36,
  tone = 'dark',
  showWordmark = true,
  className = '',
}: {
  size?: number;
  tone?: 'light' | 'dark';
  showWordmark?: boolean;
  className?: string;
}) {
  const { name, logoUrl } = useBrand();
  const base = tone === 'light' ? 'text-white' : 'text-secondary-900';
  return (
    <span className={`inline-flex items-center gap-2.5 ${className}`}>
      <LogoMark size={size} />
      {showWordmark && (
        <span className={`font-semibold tracking-tight ${base}`} style={{ fontSize: size * 0.6 }}>
          {logoUrl ? name : <>Ops<span className="text-primary-500">API</span></>}
        </span>
      )}
    </span>
  );
}

export default Logo;

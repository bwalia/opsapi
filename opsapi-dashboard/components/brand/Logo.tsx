'use client';

import React from 'react';

/**
 * OpsAPI brand mark.
 *
 * The glyph reads as an "O" (Ops) built from an orbit ring around a core, with a
 * single API-endpoint node sitting on the ring — "operations orbiting an API".
 * Pure inline SVG so it scales crisply and can be animated / themed.
 */

export function LogoMark({ size = 40, className = '' }: { size?: number; className?: string }) {
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

/**
 * Full lockup: mark + "OpsAPI" wordmark. `tone` controls the wordmark color for
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
  const base = tone === 'light' ? 'text-white' : 'text-secondary-900';
  return (
    <span className={`inline-flex items-center gap-2.5 ${className}`}>
      <LogoMark size={size} />
      {showWordmark && (
        <span className={`font-semibold tracking-tight ${base}`} style={{ fontSize: size * 0.6 }}>
          Ops<span className="text-primary-500">API</span>
        </span>
      )}
    </span>
  );
}

export default Logo;

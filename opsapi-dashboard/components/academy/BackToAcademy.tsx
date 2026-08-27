'use client';

import React, { useSyncExternalStore } from 'react';
import { ArrowLeft } from 'lucide-react';
import { Button } from '@/components/ui';

/**
 * "Back to Academy" — a return link for instructors who reached the creator
 * dashboard through the academy site's SSO handoff.
 *
 * The academy origin is stashed in sessionStorage by /auth/sso ONLY on that
 * handoff (it rides in the SSO fragment as `academyUrl`). So this renders nothing
 * for a direct dashboard login, or any other way of arriving here — the button
 * appears strictly when the user came from academy. Session-scoped: it clears
 * when the tab closes.
 *
 * Read via useSyncExternalStore so the client-only value never causes a
 * hydration mismatch (server snapshot is always null → nothing rendered).
 */
const NO_SUBSCRIBE = (): (() => void) => () => {};

function readReturnUrl(): string | null {
  try {
    const v = window.sessionStorage.getItem('academy_return_url');
    return v && /^https?:\/\//i.test(v) ? v : null;
  } catch {
    // sessionStorage can be unavailable (private mode) — just hide the button.
    return null;
  }
}

export const BackToAcademy: React.FC = () => {
  const url = useSyncExternalStore(NO_SUBSCRIBE, readReturnUrl, () => null);

  if (!url) return null;

  return (
    <Button
      variant="outline"
      leftIcon={<ArrowLeft size={16} />}
      onClick={() => {
        window.location.href = url;
      }}
    >
      Back to Academy
    </Button>
  );
};

export default BackToAcademy;

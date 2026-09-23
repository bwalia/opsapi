// Current offline cache scope = `${userId}:${namespaceId}`. Every cached read
// and queued write is partitioned by this, so no tenant/user ever sees another's
// cached data. Returns null when there's no identified user (then we don't cache
// at all).
//
// Kept free of any import from api-client to avoid an import cycle. The
// localStorage key names below intentionally mirror the ones api-client owns.
const NAMESPACE_KEY = 'current_namespace';
const AUTH_USER_KEY = 'auth_user';
const ZUSTAND_AUTH_KEY = 'auth-storage';

function pickId(u: unknown): string | null {
  const user = u as { uuid?: string; id?: string | number; email?: string } | undefined;
  const v = user?.uuid ?? user?.id ?? user?.email;
  return v !== undefined && v !== null ? String(v) : null;
}

function userId(): string | null {
  try {
    const direct = localStorage.getItem(AUTH_USER_KEY);
    if (direct) {
      const id = pickId(JSON.parse(direct));
      if (id) return id;
    }
    const zustand = localStorage.getItem(ZUSTAND_AUTH_KEY);
    if (zustand) return pickId(JSON.parse(zustand)?.state?.user);
  } catch {
    /* ignore */
  }
  return null;
}

function namespaceId(): string | null {
  try {
    const n = JSON.parse(localStorage.getItem(NAMESPACE_KEY) || 'null');
    return n?.uuid ? String(n.uuid) : null;
  } catch {
    return null;
  }
}

export function currentScope(): string | null {
  if (typeof window === 'undefined') return null;
  const u = userId();
  if (!u) return null;
  return `${u}:${namespaceId() ?? 'none'}`;
}

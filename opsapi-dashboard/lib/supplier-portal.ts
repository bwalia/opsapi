/**
 * Supplier portal helpers shared by the staff dashboard and the /supplier app.
 *
 * A supplier login holds a workspace token whose role is "supplier" (the role the backend creates for
 * invited supplier contacts, landing path /supplier). The check here only decides where to send the
 * browser; the server refuses every staff route to a supplier login anyway.
 */

/** The JWT payload (base64url), unverified. null when it isn't a JWT. */
export function decodeTokenPayload(token: string | null | undefined): Record<string, unknown> | null {
  if (!token) return null;
  try {
    const parts = token.split('.');
    if (parts.length !== 3) return null;
    let b64 = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    while (b64.length % 4) b64 += '=';
    const parsed = JSON.parse(atob(b64)) as unknown;
    return parsed && typeof parsed === 'object' ? (parsed as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

/**
 * Is this token a supplier portal login? The backend puts the workspace role at
 * `userinfo.namespace.role` (helper/jwt-helper.lua); `userinfo.namespace_role` and the role's
 * landing path `/supplier` are accepted too.
 */
export function isSupplierToken(token: string | null | undefined): boolean {
  const payload = decodeTokenPayload(token);
  const info = payload?.userinfo;
  if (!info || typeof info !== 'object') return false;
  const u = info as Record<string, unknown>;
  if (u.namespace_role === 'supplier') return true;
  const ns = u.namespace;
  if (ns && typeof ns === 'object') {
    const n = ns as Record<string, unknown>;
    if (n.role === 'supplier') return true;
    if (n.landing_path === '/supplier') return true;
  }
  return false;
}

/**
 * Pure helpers for the plugin page bridge (components/plugins/PluginPageFrame).
 * Protocol and the page-side client: lapis/static/plugin-ui/opsapi-ui.js;
 * guide: PLUGINS.md §6.2.
 */

export const BRIDGE_VERSION = 1;

export const BRIDGE_METHODS = new Set(['GET', 'POST', 'PUT', 'PATCH', 'DELETE']);

/**
 * The API URL a plugin page may call, or null. Relative paths ("/tickets")
 * belong to the plugin's own API; absolute ones must start with one of the
 * allowed prefixes (the plugin's own, plus what its manifest lists for the
 * page). Encoded slashes/dots, backslashes and dot segments are refused so a
 * path can't climb out of an allowed prefix.
 */
export function resolveApiPath(path: unknown, ownPrefix: string, allowed: string[]): string | null {
  if (typeof path !== 'string' || path.length > 4000) return null;
  if (/[\\\s]/.test(path) || /%2e|%2f|%5c/i.test(path)) return null;
  const full = path.startsWith('/api/') ? path : `${ownPrefix}${path.startsWith('/') ? '' : '/'}${path}`;
  const pathname = full.split(/[?#]/)[0];
  if (pathname.split('/').some((s) => s === '.' || s === '..')) return null;
  return allowed.some((p) => pathname === p || pathname.startsWith(`${p}/`)) ? full : null;
}

/** Dashboard CSS variables sent to plugin pages as their --ops-* tokens. */
const TOKENS: Record<string, string> = {
  '--ops-primary': '--color-primary-500',
  '--ops-primary-hover': '--color-primary-600',
  '--ops-surface': '--color-surface',
  '--ops-surface-2': '--color-surface-elevated',
  '--ops-subtle': '--color-secondary-100',
  '--ops-border': '--color-secondary-200',
  '--ops-text': '--color-secondary-900',
  '--ops-text-2': '--color-secondary-600',
  '--ops-muted': '--color-secondary-500',
  '--ops-success': '--color-success-600',
  '--ops-warning': '--color-warning-600',
  '--ops-error': '--color-error-600',
  '--ops-info': '--color-info-600',
};

export interface BridgeTheme {
  mode: 'light' | 'dark';
  tokens: Record<string, string>;
}

/** The dashboard's current colours (tenant branding included) and mode. */
export function themeSnapshot(): BridgeTheme {
  const root = document.documentElement;
  const mode = root.classList.contains('dark') ? 'dark' : 'light';
  const css = getComputedStyle(root);
  const tokens: Record<string, string> = {};
  for (const [token, source] of Object.entries(TOKENS)) {
    const value = css.getPropertyValue(source).trim();
    if (value) tokens[token] = value;
  }
  if (mode === 'light') {
    const soft = css.getPropertyValue('--color-primary-50').trim();
    if (soft) tokens['--ops-primary-soft'] = soft;
  }
  return { mode, tokens };
}

/** A short, human message from an API error body. */
export function errorMessage(body: unknown): string | undefined {
  if (!body || typeof body !== 'object') return undefined;
  const b = body as { error?: unknown; message?: unknown };
  if (typeof b.error === 'string') return b.error;
  if (b.error && typeof b.error === 'object' && typeof (b.error as { message?: unknown }).message === 'string') {
    return (b.error as { message: string }).message;
  }
  return typeof b.message === 'string' ? b.message : undefined;
}

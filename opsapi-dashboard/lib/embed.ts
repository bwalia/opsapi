/**
 * The phone apps show dashboard pages inside themselves (iOS: wslcrm-app WebPageView) and set
 * this flag before the page loads. They supply the navigation, title and workspace switcher, so
 * the dashboard leaves out its own top bar, sidebar and build footer there.
 */
export const EMBED_KEY = 'opsapi-embed';

export function isEmbeddedInApp(): boolean {
  if (typeof window === 'undefined') return false;
  try {
    return window.localStorage.getItem(EMBED_KEY) === 'app';
  } catch {
    return false;
  }
}

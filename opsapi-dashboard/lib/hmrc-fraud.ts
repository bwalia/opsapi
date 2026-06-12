/**
 * HMRC anti-fraud signal collection (WEB_APP_VIA_SERVER).
 *
 * HMRC's Making Tax Digital APIs require fraud-prevention headers describing the device
 * that originated the request. For a server-side web app, several of these can ONLY be
 * gathered in the browser (screen size, window size, JS user-agent, timezone, a stable
 * per-device id). We collect them here and forward them to our backend as `X-Gov-Client-*`
 * headers; the backend maps them to the real `Gov-Client-*` headers it sends to HMRC and
 * adds the server-derived ones (public IP/port, the user→server hop).
 *
 * HMRC penalises FAKE values — so we only ever send what the browser actually reports.
 */

const DEVICE_ID_KEY = 'hmrc_device_id';

// A stable per-device UUID, persisted in localStorage so it's the same across sessions.
function deviceId(): string {
  let id = localStorage.getItem(DEVICE_ID_KEY);
  if (!id) {
    id =
      typeof crypto !== 'undefined' && crypto.randomUUID
        ? crypto.randomUUID()
        : // Fallback for older browsers without crypto.randomUUID.
          'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
            const r = (Math.random() * 16) | 0;
            return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
          });
    localStorage.setItem(DEVICE_ID_KEY, id);
  }
  return id;
}

// The browser's current UTC offset as HMRC's "UTC±HH:MM" format.
function timezone(): string {
  // getTimezoneOffset() returns minutes BEHIND UTC (e.g. UTC+1 → -60), so negate it.
  const offsetMin = -new Date().getTimezoneOffset();
  const sign = offsetMin >= 0 ? '+' : '-';
  const abs = Math.abs(offsetMin);
  const hh = String(Math.floor(abs / 60)).padStart(2, '0');
  const mm = String(abs % 60).padStart(2, '0');
  return `UTC${sign}${hh}:${mm}`;
}

// HMRC Gov-Client-Screens: one entry per screen (we have one in a browser).
function screens(): string {
  const s = window.screen;
  const scaling = window.devicePixelRatio || 1;
  return `width=${s.width}&height=${s.height}&scaling-factor=${scaling}&colour-depth=${s.colorDepth}`;
}

// HMRC Gov-Client-Window-Size: the browser viewport.
function windowSize(): string {
  return `width=${window.innerWidth}&height=${window.innerHeight}`;
}

/**
 * Build the X-Gov-Client-* headers to forward on HMRC-bound requests.
 * Returns {} during SSR (no browser APIs available).
 *
 * @param userId optional vendor user identifier → Gov-Client-User-IDs ("opsapi=<id>")
 */
export function hmrcFraudHeaders(userId?: string | number): Record<string, string> {
  if (typeof window === 'undefined') return {};
  const headers: Record<string, string> = {
    'X-Gov-Client-Device-ID': deviceId(),
    'X-Gov-Client-Browser-JS-User-Agent': navigator.userAgent,
    'X-Gov-Client-Screens': screens(),
    'X-Gov-Client-Window-Size': windowSize(),
    'X-Gov-Client-Timezone': timezone(),
  };
  if (userId !== undefined && userId !== null && `${userId}` !== '') {
    headers['X-Gov-Client-User-IDs'] = `opsapi=${encodeURIComponent(String(userId))}`;
  }
  return headers;
}

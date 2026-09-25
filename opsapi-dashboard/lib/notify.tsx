'use client';

/**
 * Browser notifications + a short chime for chat / assistant events.
 *
 * - Tab visible  → in-app toast + chime.
 * - Tab hidden   → OS notification (via the service worker when registered, so
 *                  a click focuses/opens the right page — see public/sw.js) + chime.
 *
 * Only works while an OpsAPI tab is open (the WebSocket delivers the event).
 * ponytail: closed-tab push needs Web Push (VAPID/FCM) + a server sender; add
 * when users need alerts with no tab open.
 */
import toast from 'react-hot-toast';

const PREFS_KEY = 'opsapi:notify-prefs';

export interface NotifyPrefs {
  enabled: boolean; // OS notifications when the tab is hidden
  sound: boolean;
}

export function getPrefs(): NotifyPrefs {
  try {
    const raw = localStorage.getItem(PREFS_KEY);
    if (raw) return { enabled: true, sound: true, ...(JSON.parse(raw) as Partial<NotifyPrefs>) };
  } catch {
    /* storage unavailable */
  }
  return { enabled: true, sound: true };
}

export function setPrefs(p: Partial<NotifyPrefs>): NotifyPrefs {
  const next = { ...getPrefs(), ...p };
  try {
    localStorage.setItem(PREFS_KEY, JSON.stringify(next));
  } catch {
    /* storage unavailable */
  }
  return next;
}

export const notificationsSupported = () => typeof window !== 'undefined' && 'Notification' in window;

/** Ask for OS-notification permission (must be called from a user gesture). */
export async function requestPermission(): Promise<NotificationPermission | 'unsupported'> {
  if (!notificationsSupported()) return 'unsupported';
  if (Notification.permission !== 'default') return Notification.permission;
  return Notification.requestPermission();
}

// ---- sound: a synthesized two-note chime (no audio asset to ship) ----------
// Browsers block audio until the page has had a user gesture, so the context is
// created/resumed on the first pointerdown/keydown and reused afterwards.
let audioCtx: AudioContext | null = null;

function unlockAudio() {
  try {
    audioCtx ??= new AudioContext();
    if (audioCtx.state === 'suspended') void audioCtx.resume();
  } catch {
    /* no Web Audio */
  }
}

if (typeof window !== 'undefined') {
  window.addEventListener('pointerdown', unlockAudio, { once: true, capture: true });
  window.addEventListener('keydown', unlockAudio, { once: true, capture: true });
}

export function playChime() {
  if (!audioCtx || audioCtx.state !== 'running') return;
  const now = audioCtx.currentTime;
  [880, 1318.5].forEach((freq, i) => {
    const osc = audioCtx!.createOscillator();
    const gain = audioCtx!.createGain();
    osc.type = 'sine';
    osc.frequency.value = freq;
    const t = now + i * 0.12;
    gain.gain.setValueAtTime(0.0001, t);
    gain.gain.exponentialRampToValueAtTime(0.18, t + 0.02);
    gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.35);
    osc.connect(gain).connect(audioCtx!.destination);
    osc.start(t);
    osc.stop(t + 0.4);
  });
}

export interface NotifyOptions {
  title: string;
  body?: string;
  url?: string; // where a click should take the user
  tag?: string; // same tag replaces the previous notification (one per conversation)
  onClick?: () => void; // in-app toast click
}

export async function notify({ title, body, url = '/dashboard/chat', tag, onClick }: NotifyOptions) {
  const prefs = getPrefs();
  if (prefs.sound) playChime();

  const hidden = typeof document !== 'undefined' && document.visibilityState === 'hidden';
  if (!hidden) {
    toast(
      (t) => (
        <button
          type="button"
          className="text-left text-sm"
          onClick={() => {
            toast.dismiss(t.id);
            onClick?.();
          }}
        >
          <p className="font-semibold">{title}</p>
          {body && <p className="line-clamp-2 text-secondary-500">{body}</p>}
        </button>
      ),
      { icon: '💬', id: tag }
    );
    return;
  }

  if (!prefs.enabled || !notificationsSupported() || Notification.permission !== 'granted') return;
  const options: NotificationOptions = { body, tag, icon: '/icons/icon-192.png', data: { url } };
  try {
    const reg = await navigator.serviceWorker?.getRegistration();
    if (reg) {
      await reg.showNotification(title, options);
      return;
    }
  } catch {
    /* fall through to the page-level API */
  }
  const n = new Notification(title, options);
  n.onclick = () => {
    window.focus();
    n.close();
    onClick?.();
  };
}

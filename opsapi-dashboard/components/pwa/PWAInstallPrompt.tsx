'use client';

// Unobtrusive "install this app" banner.
//  - Android / desktop Chrome/Edge: uses the `beforeinstallprompt` event to
//    trigger the native install flow on click.
//  - iOS Safari: never fires that event, so we show a short "Add to Home Screen"
//    hint instead (only when not already installed).
// Dismissal is remembered per-browser (localStorage), and the banner never shows
// once the app is running installed (display-mode: standalone).
import { useEffect, useState } from 'react';
import { Download, Share, X } from 'lucide-react';

interface BeforeInstallPromptEvent extends Event {
  prompt: () => Promise<void>;
  userChoice: Promise<{ outcome: 'accepted' | 'dismissed' }>;
}

const DISMISS_KEY = 'pwa-install-dismissed';

function isStandalone(): boolean {
  if (typeof window === 'undefined') return false;
  return (
    window.matchMedia('(display-mode: standalone)').matches ||
    // iOS Safari
    (window.navigator as Navigator & { standalone?: boolean }).standalone === true
  );
}

function dismissed(): boolean {
  try {
    return localStorage.getItem(DISMISS_KEY) === '1';
  } catch {
    return false;
  }
}

export default function PWAInstallPrompt() {
  const [deferred, setDeferred] = useState<BeforeInstallPromptEvent | null>(null);
  const [showIosHint, setShowIosHint] = useState(false);
  const [hidden, setHidden] = useState(true);

  useEffect(() => {
    if (isStandalone() || dismissed()) return;

    const onPrompt = (e: Event) => {
      e.preventDefault(); // keep it from auto-showing; we surface our own button
      setDeferred(e as BeforeInstallPromptEvent);
      setHidden(false);
    };
    window.addEventListener('beforeinstallprompt', onPrompt);

    // iOS Safari: no beforeinstallprompt — detect it and show the manual hint.
    const ua = window.navigator.userAgent;
    const isIos = /iphone|ipad|ipod/i.test(ua);
    const isSafari = /safari/i.test(ua) && !/crios|fxios|edgios/i.test(ua);
    if (isIos && isSafari) {
      setShowIosHint(true);
      setHidden(false);
    }

    return () => window.removeEventListener('beforeinstallprompt', onPrompt);
  }, []);

  const close = () => {
    setHidden(true);
    try {
      localStorage.setItem(DISMISS_KEY, '1');
    } catch {
      /* private mode / storage blocked — just hide for this session */
    }
  };

  const install = async () => {
    if (!deferred) return;
    await deferred.prompt();
    await deferred.userChoice.catch(() => undefined);
    setDeferred(null);
    close();
  };

  if (hidden || (!deferred && !showIosHint)) return null;

  return (
    <div
      role="dialog"
      aria-label="Install OpsAPI"
      className="fixed inset-x-4 bottom-4 z-[1000] mx-auto max-w-md rounded-2xl border border-secondary-200 bg-white p-4 shadow-lg sm:left-auto sm:right-4"
    >
      <div className="flex items-start gap-3">
        <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-secondary-900">
          <Download className="h-5 w-5 text-white" aria-hidden="true" />
        </div>
        <div className="min-w-0 flex-1">
          <p className="text-sm font-semibold text-secondary-900">Install OpsAPI</p>
          {deferred ? (
            <p className="mt-0.5 text-xs text-secondary-600">
              Add it to your device for faster access and a full-screen app.
            </p>
          ) : (
            <p className="mt-0.5 flex flex-wrap items-center gap-1 text-xs text-secondary-600">
              Tap <Share className="inline h-3.5 w-3.5" aria-hidden="true" /> Share, then
              &ldquo;Add to Home Screen&rdquo;.
            </p>
          )}
          {deferred && (
            <button
              type="button"
              onClick={install}
              className="mt-3 inline-flex min-h-9 items-center rounded-lg bg-secondary-900 px-4 text-xs font-medium text-white transition hover:bg-secondary-800 focus:outline-none focus-visible:ring-2 focus-visible:ring-secondary-400"
            >
              Install
            </button>
          )}
        </div>
        <button
          type="button"
          onClick={close}
          aria-label="Dismiss install prompt"
          className="-m-1 shrink-0 rounded-lg p-1 text-secondary-400 transition hover:bg-secondary-100 hover:text-secondary-600"
        >
          <X className="h-4 w-4" aria-hidden="true" />
        </button>
      </div>
    </div>
  );
}

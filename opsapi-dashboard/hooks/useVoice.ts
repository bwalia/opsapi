'use client';

/**
 * Voice for the assistant: record (speech-to-text on our own voice server) and speak replies
 * (our text-to-speech, else a voice built into this device — never a cloud voice). Exposes a 0..1
 * `level` store (read it with useVoiceLevel) so the avatar's mouth (speaking) and listening ring
 * (recording) move with the sound without re-rendering the whole pane every frame.
 */
import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { voiceService, type VoiceStatus } from '@/services/voice.service';

export type VoiceState = 'idle' | 'listening' | 'transcribing' | 'speaking';

/** Markdown reply → something pleasant to hear. */
export function speakableText(md: string, max = 1200): string {
  let t = md
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/\|.*\|/g, ' ')                      // tables: on screen only
    .replace(/!\[[^\]]*]\([^)]*\)/g, ' ')
    .replace(/\[([^\]]+)]\([^)]*\)/g, '$1')
    .replace(/[*_`#>~]/g, '')
    .replace(/^\s*[-•]\s+/gm, '')
    .replace(/^\s*(\d+)\.\s+/gm, '$1. ')
    .replace(/[^\S\n]+/g, ' ')
    .replace(/\n{2,}/g, '. ')
    .replace(/\n/g, ', ')
    .trim();
  if (t.length > max) t = t.slice(0, t.lastIndexOf('.', max) > 200 ? t.lastIndexOf('.', max) + 1 : max) + ' The rest is on screen.';
  return t;
}

function rms(analyser: AnalyserNode, buf: Uint8Array<ArrayBuffer>): number {
  analyser.getByteTimeDomainData(buf);
  let sum = 0;
  for (let i = 0; i < buf.length; i++) {
    const v = (buf[i] - 128) / 128;
    sum += v * v;
  }
  return Math.min(1, Math.sqrt(sum / buf.length) * 4);
}

/** The live 0..1 sound level, outside React state: only the face that draws it re-renders per frame. */
export interface LevelStore {
  get: () => number;
  subscribe: (cb: () => void) => () => void;
}

function levelStore(): LevelStore & { set: (v: number) => void } {
  let v = 0;
  const subs = new Set<() => void>();
  return {
    get: () => v,
    set: (n) => {
      if (n === v) return;
      v = n;
      subs.forEach((cb) => cb());
    },
    subscribe: (cb) => {
      subs.add(cb);
      return () => subs.delete(cb);
    },
  };
}

/** Subscribe to the live level (re-renders the caller every frame while it moves). */
export function useVoiceLevel(level: LevelStore): number {
  return useSyncExternalStore(level.subscribe, level.get, () => 0);
}

export function useVoice() {
  const [status, setStatus] = useState<VoiceStatus | null>(null);
  const [state, setState] = useState<VoiceState>('idle');
  const [level] = useState(levelStore);
  const ctxRef = useRef<AudioContext | null>(null);
  const recRef = useRef<MediaRecorder | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const startingRef = useRef(false); // getUserMedia in flight: no second recorder, no speaking over it
  const mountedRef = useRef(true);
  const chunksRef = useRef<Blob[]>([]);
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const urlRef = useRef<string | null>(null);
  const abortRef = useRef<AbortController | null>(null);
  // Bumped by every speak()/stopSpeaking()/listen(): a speak() whose audio arrives after a newer call drops it.
  const genRef = useRef(0);
  const rafRef = useRef<number | null>(null);
  const stopMeter = useCallback(() => {
    if (rafRef.current) cancelAnimationFrame(rafRef.current);
    rafRef.current = null;
    level.set(0);
  }, [level]);

  useEffect(() => {
    let off = false;
    voiceService.status().then((s) => { if (!off) setStatus(s); }).catch(() => { if (!off) setStatus({ stt: false, tts: false }); });
    return () => { off = true; };
  }, []);

  const ctx = useCallback(() => {
    if (!ctxRef.current) {
      const AC = window.AudioContext || (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
      ctxRef.current = new AC();
    }
    void ctxRef.current.resume();
    return ctxRef.current;
  }, []);

  const meter = useCallback((analyser: AnalyserNode) => {
    const buf = new Uint8Array(analyser.fftSize) as Uint8Array<ArrayBuffer>;
    const tick = () => {
      level.set(rms(analyser, buf));
      rafRef.current = requestAnimationFrame(tick);
    };
    stopMeter();
    rafRef.current = requestAnimationFrame(tick);
  }, [level, stopMeter]);

  const revoke = useCallback(() => {
    if (urlRef.current) URL.revokeObjectURL(urlRef.current);
    urlRef.current = null;
  }, []);

  /** Stop talking now (barge-in when the user presses the mic); also drops audio still on its way. */
  const stopSpeaking = useCallback(() => {
    genRef.current += 1;
    abortRef.current?.abort();
    abortRef.current = null;
    const audio = audioRef.current;
    audioRef.current = null;
    audio?.pause(); // fires onpause: the pending speak() settles
    revoke();
    if (typeof window !== 'undefined' && window.speechSynthesis) window.speechSynthesis.cancel();
    if (!recRef.current) stopMeter(); // the meter is the mic's while recording
    setState((s) => (s === 'speaking' ? 'idle' : s));
  }, [revoke, stopMeter]);

  /** Speak a reply: our TTS server, else a voice on this device (local only, never a cloud voice). */
  const speak = useCallback(async (markdown: string) => {
    const text = speakableText(markdown);
    if (!text || recRef.current || startingRef.current) return; // never talk into a recording
    stopSpeaking();
    const gen = genRef.current;
    const current = () => gen === genRef.current && mountedRef.current;
    setState('speaking');
    if (status?.tts) {
      const ac = new AbortController();
      abortRef.current = ac;
      try {
        const blob = await voiceService.speak(text, undefined, ac.signal);
        if (!current()) return;
        abortRef.current = null;
        const url = URL.createObjectURL(blob);
        urlRef.current = url;
        const audio = new Audio(url);
        audioRef.current = audio;
        const c = ctx();
        const src = c.createMediaElementSource(audio);
        const analyser = c.createAnalyser();
        analyser.fftSize = 512;
        src.connect(analyser);
        analyser.connect(c.destination);
        meter(analyser);
        await new Promise<void>((resolve) => {
          audio.onended = () => resolve();
          audio.onerror = () => resolve();
          audio.onpause = () => resolve();
          void audio.play().catch(() => resolve());
        });
        if (urlRef.current === url) revoke();
        if (current()) { stopMeter(); setState('idle'); }
        return;
      } catch {
        if (!current()) return;
        /* fall back to a device voice */
      }
    }
    const synth = typeof window !== 'undefined' ? window.speechSynthesis : undefined;
    if (!synth) { setState('idle'); return; }
    const voices = synth.getVoices().filter((v) => v.localService && v.lang.toLowerCase().startsWith('en'));
    const u = new SpeechSynthesisUtterance(text);
    u.voice = voices.find((v) => v.lang === 'en-GB') || voices[0] || null;
    u.rate = 1.02;
    // No audio stream to measure: move the mouth on each word instead.
    let t: ReturnType<typeof setTimeout> | null = null;
    u.onboundary = () => {
      if (!current()) return;
      level.set(0.45 + Math.random() * 0.45);
      if (t) clearTimeout(t);
      t = setTimeout(() => { if (current()) level.set(0.08); }, 160);
    };
    await new Promise<void>((resolve) => {
      u.onend = () => resolve();
      u.onerror = () => resolve();
      synth.speak(u);
    });
    if (t) clearTimeout(t);
    if (current()) { level.set(0); setState('idle'); }
  }, [status?.tts, ctx, level, meter, revoke, stopMeter, stopSpeaking]);

  const stopStream = useCallback(() => {
    streamRef.current?.getTracks().forEach((tr) => tr.stop());
    streamRef.current = null;
  }, []);

  /** Start recording (mic). Does nothing while a recording is already running or starting. */
  const listen = useCallback(async () => {
    if (recRef.current || startingRef.current) return;
    startingRef.current = true;
    stopSpeaking();
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } });
      if (!mountedRef.current) { stream.getTracks().forEach((tr) => tr.stop()); return; }
      streamRef.current = stream;
      const type = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4', 'audio/ogg'].find((ty) => MediaRecorder.isTypeSupported(ty));
      const rec = new MediaRecorder(stream, type ? { mimeType: type } : undefined);
      chunksRef.current = [];
      rec.ondataavailable = (e) => { if (e.data.size) chunksRef.current.push(e.data); };
      recRef.current = rec;
      rec.start();
      const c = ctx();
      const analyser = c.createAnalyser();
      analyser.fftSize = 512;
      c.createMediaStreamSource(stream).connect(analyser);
      meter(analyser);
      setState('listening');
    } catch (e) {
      recRef.current = null;
      stopStream();
      throw e;
    } finally {
      startingRef.current = false;
    }
  }, [ctx, meter, stopSpeaking, stopStream]);

  /** Stop recording and turn it into text. */
  const finish = useCallback(async (): Promise<string> => {
    const rec = recRef.current;
    if (!rec) return '';
    const stopped = new Promise<void>((resolve) => { rec.onstop = () => resolve(); });
    rec.stop();
    await stopped;
    stopStream();
    recRef.current = null;
    stopMeter();
    setState('transcribing');
    try {
      const blob = new Blob(chunksRef.current, { type: rec.mimeType || 'audio/webm' });
      return await voiceService.transcribe(blob);
    } finally {
      setState('idle');
    }
  }, [stopMeter, stopStream]);

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      stopSpeaking();
      if (recRef.current?.state === 'recording') recRef.current.stop();
      recRef.current = null;
      stopStream();
      stopMeter();
      void ctxRef.current?.close();
      ctxRef.current = null;
    };
  }, [stopSpeaking, stopStream, stopMeter]);

  return { status, state, level, speak, stopSpeaking, listen, finish };
}

export default useVoice;

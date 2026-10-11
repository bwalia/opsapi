'use client';

/**
 * Voice for the assistant: record (speech-to-text on our own voice server) and speak replies
 * (our text-to-speech, else a voice built into this device — never a cloud voice). Exposes a 0..1
 * `level` so the avatar's mouth (speaking) and listening ring (recording) move with the sound.
 */
import { useCallback, useEffect, useRef, useState } from 'react';
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

export function useVoice() {
  const [status, setStatus] = useState<VoiceStatus | null>(null);
  const [state, setState] = useState<VoiceState>('idle');
  const [level, setLevel] = useState(0);
  const ctxRef = useRef<AudioContext | null>(null);
  const recRef = useRef<MediaRecorder | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const chunksRef = useRef<Blob[]>([]);
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const rafRef = useRef<number | null>(null);
  const stopMeter = useCallback(() => {
    if (rafRef.current) cancelAnimationFrame(rafRef.current);
    rafRef.current = null;
    setLevel(0);
  }, []);

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
      setLevel(rms(analyser, buf));
      rafRef.current = requestAnimationFrame(tick);
    };
    stopMeter();
    rafRef.current = requestAnimationFrame(tick);
  }, [stopMeter]);

  /** Stop talking now (barge-in when the user presses the mic). */
  const stopSpeaking = useCallback(() => {
    audioRef.current?.pause();
    audioRef.current = null;
    if (typeof window !== 'undefined' && window.speechSynthesis) window.speechSynthesis.cancel();
    stopMeter();
    setState((s) => (s === 'speaking' ? 'idle' : s));
  }, [stopMeter]);

  /** Speak a reply: our TTS server, else a voice on this device (local only, never a cloud voice). */
  const speak = useCallback(async (markdown: string) => {
    const text = speakableText(markdown);
    if (!text) return;
    stopSpeaking();
    setState('speaking');
    if (status?.tts) {
      try {
        const blob = await voiceService.speak(text);
        const url = URL.createObjectURL(blob);
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
          void audio.play().catch(() => resolve());
        });
        URL.revokeObjectURL(url);
        if (audioRef.current === audio) { stopMeter(); setState('idle'); }
        return;
      } catch {
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
      setLevel(0.45 + Math.random() * 0.45);
      if (t) clearTimeout(t);
      t = setTimeout(() => setLevel(0.08), 160);
    };
    await new Promise<void>((resolve) => {
      u.onend = () => resolve();
      u.onerror = () => resolve();
      synth.speak(u);
    });
    setLevel(0);
    setState('idle');
  }, [status?.tts, ctx, meter, stopMeter, stopSpeaking]);

  /** Start recording (mic). */
  const listen = useCallback(async () => {
    stopSpeaking();
    const stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } });
    streamRef.current = stream;
    const type = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4', 'audio/ogg'].find((t) => MediaRecorder.isTypeSupported(t));
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
  }, [ctx, meter, stopSpeaking]);

  /** Stop recording and turn it into text. */
  const finish = useCallback(async (): Promise<string> => {
    const rec = recRef.current;
    if (!rec) return '';
    const stopped = new Promise<void>((resolve) => { rec.onstop = () => resolve(); });
    rec.stop();
    await stopped;
    streamRef.current?.getTracks().forEach((t) => t.stop());
    streamRef.current = null;
    recRef.current = null;
    stopMeter();
    setState('transcribing');
    try {
      const blob = new Blob(chunksRef.current, { type: rec.mimeType || 'audio/webm' });
      return await voiceService.transcribe(blob);
    } finally {
      setState('idle');
    }
  }, [stopMeter]);

  useEffect(() => () => {
    stopSpeaking();
    streamRef.current?.getTracks().forEach((t) => t.stop());
    void ctxRef.current?.close();
  }, [stopSpeaking]);

  return { status, state, level, speak, stopSpeaking, listen, finish };
}

export default useVoice;

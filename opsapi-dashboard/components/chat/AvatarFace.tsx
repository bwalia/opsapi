'use client';

/**
 * The assistant's face: a friendly animated head drawn in SVG (no outside service, no video model).
 * It blinks; listens (pulsing ring that follows the microphone level); thinks (eyes up, dots);
 * and speaks (the mouth opens with the voice's loudness, `level` 0..1).
 */
import React, { useEffect, useState } from 'react';
import { cn } from '@/lib/utils';

export type FaceMood = 'idle' | 'listening' | 'thinking' | 'speaking' | 'transcribing';

export default function AvatarFace({ mood = 'idle', level = 0, size = 64, label = 'Assistant' }: {
  mood?: FaceMood; level?: number; size?: number; label?: string;
}) {
  const [blink, setBlink] = useState(false);
  useEffect(() => {
    let t: ReturnType<typeof setTimeout>;
    const loop = () => {
      t = setTimeout(() => {
        setBlink(true);
        setTimeout(() => setBlink(false), 140);
        loop();
      }, 2600 + Math.random() * 3200);
    };
    loop();
    return () => clearTimeout(t);
  }, []);

  const talking = mood === 'speaking';
  const open = talking ? Math.max(0.08, Math.min(1, level)) : 0;
  const mouthRy = 1.6 + open * 7;
  const lookUp = mood === 'thinking' || mood === 'transcribing';
  const eyeY = lookUp ? 25 : 28;
  const eyeRy = blink ? 0.4 : 3.4;
  const ring = mood === 'listening' ? 1 + Math.min(1, level) * 0.18 : 1;
  const status = { idle: 'ready', listening: 'listening', thinking: 'thinking', transcribing: 'working out what you said', speaking: 'speaking' }[mood];

  return (
    <div className="relative inline-flex shrink-0" style={{ width: size, height: size }} role="img" aria-label={`${label}, ${status}`}>
      {mood === 'listening' && (
        <span
          className="absolute inset-0 rounded-full bg-error-500/25 transition-transform duration-75"
          style={{ transform: `scale(${ring})` }}
          aria-hidden
        />
      )}
      <svg viewBox="0 0 64 64" width={size} height={size} className="relative" aria-hidden>
        <defs>
          <linearGradient id="pa-skin" x1="0" y1="0" x2="1" y2="1">
            <stop offset="0" stopColor="#ff4d7d" />
            <stop offset="1" stopColor="#c20035" />
          </linearGradient>
        </defs>
        <circle cx="32" cy="32" r="30" fill="url(#pa-skin)" />
        {/* cheeks */}
        <circle cx="17" cy="38" r="4" fill="#ffffff" opacity={talking ? 0.22 : 0.14} />
        <circle cx="47" cy="38" r="4" fill="#ffffff" opacity={talking ? 0.22 : 0.14} />
        {/* brows lift while listening */}
        <path d={mood === 'listening' ? 'M18 19 Q23 15 28 18' : 'M18 21 Q23 18 28 20'} stroke="#fff" strokeWidth="2" fill="none" strokeLinecap="round" />
        <path d={mood === 'listening' ? 'M36 18 Q41 15 46 19' : 'M36 20 Q41 18 46 21'} stroke="#fff" strokeWidth="2" fill="none" strokeLinecap="round" />
        {/* eyes */}
        <ellipse cx="23" cy={eyeY} rx="3.2" ry={eyeRy} fill="#fff" />
        <ellipse cx="41" cy={eyeY} rx="3.2" ry={eyeRy} fill="#fff" />
        {/* mouth: a smile at rest, opens with the voice */}
        {talking ? (
          <ellipse cx="32" cy="44" rx={5 + open * 2.5} ry={mouthRy} fill="#3b0016" />
        ) : (
          <path d="M24 42 Q32 49 40 42" stroke="#fff" strokeWidth="2.4" fill="none" strokeLinecap="round" />
        )}
      </svg>
      {(mood === 'thinking' || mood === 'transcribing') && (
        <span className="absolute -right-1 -top-1 flex gap-0.5 rounded-full bg-surface px-1.5 py-1 shadow" aria-hidden>
          {[0, 1, 2].map((i) => (
            <span key={i} className={cn('h-1.5 w-1.5 animate-bounce rounded-full bg-primary-500')} style={{ animationDelay: `${i * 120}ms` }} />
          ))}
        </span>
      )}
    </div>
  );
}

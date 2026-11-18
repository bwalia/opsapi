'use client';

import React, { useCallback, useEffect, useRef, useState } from 'react';
import { Eraser } from 'lucide-react';
import { Button } from '@/components/ui';

/**
 * A box to sign in with a finger, pen or mouse (pointer events, so phones, tablets and desktops all work).
 * Calls onChange with a PNG data URL after every stroke, or null when cleared. The ink is drawn on white
 * so the saved image reads the same in light and dark mode.
 */
export function SignaturePad({ onChange, height = 180, label = 'Sign here' }: {
  onChange: (png: string | null) => void;
  height?: number;
  label?: string;
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const drawing = useRef(false);
  const last = useRef<{ x: number; y: number } | null>(null);
  const [empty, setEmpty] = useState(true);
  // The latest onChange, so a parent re-render never resets the canvas.
  const notify = useRef(onChange);
  useEffect(() => {
    notify.current = onChange;
  }, [onChange]);

  // Size the canvas for the screen (sharp on high-DPI) and paint it white. Drawing only: no state here.
  const paint = useCallback(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ratio = Math.max(1, window.devicePixelRatio || 1);
    const width = canvas.parentElement?.clientWidth || 400;
    canvas.width = Math.floor(width * ratio);
    canvas.height = Math.floor(height * ratio);
    canvas.style.width = `${width}px`;
    canvas.style.height = `${height}px`;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;
    ctx.scale(ratio, ratio);
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(0, 0, width, height);
    ctx.lineWidth = 2.2;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.strokeStyle = '#111827';
  }, [height]);

  useEffect(() => {
    paint();
  }, [paint]);

  const clear = () => {
    paint();
    setEmpty(true);
    notify.current(null);
  };

  const point = (e: React.PointerEvent<HTMLCanvasElement>) => {
    const r = e.currentTarget.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  };

  const down = (e: React.PointerEvent<HTMLCanvasElement>) => {
    e.preventDefault();
    e.currentTarget.setPointerCapture(e.pointerId);
    drawing.current = true;
    last.current = point(e);
    const ctx = e.currentTarget.getContext('2d');
    if (ctx && last.current) {
      ctx.beginPath();
      ctx.arc(last.current.x, last.current.y, 1.1, 0, Math.PI * 2);
      ctx.fillStyle = '#111827';
      ctx.fill();
    }
  };

  const move = (e: React.PointerEvent<HTMLCanvasElement>) => {
    if (!drawing.current || !last.current) return;
    const ctx = e.currentTarget.getContext('2d');
    if (!ctx) return;
    const p = point(e);
    ctx.beginPath();
    ctx.moveTo(last.current.x, last.current.y);
    ctx.lineTo(p.x, p.y);
    ctx.stroke();
    last.current = p;
  };

  const up = (e: React.PointerEvent<HTMLCanvasElement>) => {
    if (!drawing.current) return;
    drawing.current = false;
    last.current = null;
    setEmpty(false);
    notify.current(e.currentTarget.toDataURL('image/png'));
  };

  return (
    <div>
      <div className="flex items-center justify-between gap-2">
        <span className="text-sm font-medium text-secondary-700">{label}</span>
        <Button type="button" variant="ghost" size="sm" onClick={clear} disabled={empty} leftIcon={<Eraser className="h-3.5 w-3.5" />}>
          Clear
        </Button>
      </div>
      <div className="relative mt-1 overflow-hidden rounded-lg border-2 border-dashed border-secondary-300 bg-white">
        <canvas
          ref={canvasRef}
          role="img"
          aria-label={empty ? 'Signature box, empty' : 'Signature box, signed'}
          className="block cursor-crosshair touch-none select-none"
          onPointerDown={down}
          onPointerMove={move}
          onPointerUp={up}
          onPointerCancel={up}
        />
        {empty && (
          <span className="pointer-events-none absolute inset-x-0 bottom-3 text-center text-xs text-secondary-400">
            Sign with a finger, pen or mouse
          </span>
        )}
      </div>
    </div>
  );
}

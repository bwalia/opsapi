'use client';

/**
 * Replay of a web terminal tab's screen (docs/AI_RUNNER_WEB_TERMINAL.md §11): the terminal uploads its output as
 * gzipped asciicast parts; they are fetched only when someone presses Play (recordings can be large), unzipped in the
 * browser and handed to asciinema-player. Output only: what was typed (e.g. passwords) was never recorded.
 */
import React, { useEffect, useRef, useState } from 'react';
import { Loader2, Play } from 'lucide-react';
import 'asciinema-player/dist/bundle/asciinema-player.css';
import { Button } from '@/components/ui';
import { aiErrorText, aiRunner } from '@/services/ai-runner.service';

async function gunzip(buf: ArrayBuffer): Promise<string> {
  const stream = new Blob([buf]).stream().pipeThrough(new DecompressionStream('gzip'));
  return new Response(stream).text();
}

export function ScreenReplay({ uuid, parts }: { uuid: string; parts: number[] }) {
  const box = useRef<HTMLDivElement>(null);
  const player = useRef<{ dispose(): void } | null>(null);
  const [state, setState] = useState<'idle' | 'loading' | 'ready'>('idle');
  const [error, setError] = useState<string | null>(null);

  useEffect(() => () => player.current?.dispose(), []);

  async function play() {
    setState('loading');
    setError(null);
    try {
      let cast = '';
      for (const part of parts) {
        const text = await gunzip(await aiRunner.workLogRecordingPart(uuid, part));
        cast += text.endsWith('\n') ? text : `${text}\n`;
      }
      const { create } = await import('asciinema-player');
      if (!box.current) return;
      player.current?.dispose();
      player.current = create({ data: cast }, box.current, {
        autoPlay: true, fit: 'width', idleTimeLimit: 2, terminalFontSize: 'small',
      });
      setState('ready');
    } catch (e) {
      setError(aiErrorText(e));
      setState('idle');
    }
  }

  return (
    <div className="space-y-2" data-testid="air-worklog-replay">
      {state !== 'ready' && (
        <Button
          variant="outline"
          leftIcon={state === 'loading' ? <Loader2 className="h-4 w-4 animate-spin" aria-hidden /> : <Play className="h-4 w-4" aria-hidden />}
          onClick={() => void play()}
          disabled={state === 'loading'}
        >
          {state === 'loading' ? 'Loading the recording…' : 'Play the screen recording'}
        </Button>
      )}
      {error && <p className="text-sm text-error-600" role="alert">{error}</p>}
      <div ref={box} className="overflow-hidden rounded-lg" />
    </div>
  );
}

export default ScreenReplay;

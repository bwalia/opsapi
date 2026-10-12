/**
 * Voice for the assistant: speech-to-text and text-to-speech on our OWN voice server
 * (routes/voice.lua → Speaches: faster-whisper + Kokoro/Piper). Never a public cloud speech API.
 */
import apiClient from '@/lib/api-client';

export interface VoiceStatus {
  stt: boolean;
  tts: boolean;
  voice?: string;
}

export const voiceService = {
  async status(): Promise<VoiceStatus> {
    const res = await apiClient.get<{ data: VoiceStatus }>('/api/v2/voice/status');
    return res.data.data;
  },

  /** Recorded audio → text. */
  async transcribe(audio: Blob): Promise<string> {
    const type = (audio.type || 'audio/webm').split(';')[0];
    const res = await apiClient.post<{ data: { text: string } }>('/api/v2/voice/transcribe', audio, {
      headers: { 'Content-Type': type },
      timeout: 120000,
    });
    return res.data.data.text || '';
  },

  /** Text → spoken audio (mp3). */
  async speak(text: string, voice?: string, signal?: AbortSignal): Promise<Blob> {
    const res = await apiClient.post<Blob>('/api/v2/voice/speak', { text, voice }, {
      headers: { 'Content-Type': 'application/json' },
      responseType: 'blob',
      timeout: 60000,
      signal,
    });
    return res.data;
  },
};

export default voiceService;

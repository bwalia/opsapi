import { create } from 'zustand';

/**
 * Page AI assistant panel state, shared by the launcher (PageAssistant) and the
 * app-wide ChatNotifier (which opens it from an "Assistant finished" notice and
 * stays quiet when the panel is already showing that page).
 */
interface AssistantState {
  open: boolean;
  setOpen: (open: boolean) => void;
  toggle: () => void;
  /** A message for the panel to send as soon as it is open ("Ask AI to do it" buttons). */
  queued: string | null;
  ask: (text: string) => void;
  clearQueued: () => void;
}

export const useAssistant = create<AssistantState>((set) => ({
  open: false,
  setOpen: (open) => set({ open }),
  toggle: () => set((s) => ({ open: !s.open })),
  queued: null,
  ask: (text) => set({ open: true, queued: text }),
  clearQueued: () => set({ queued: null }),
}));

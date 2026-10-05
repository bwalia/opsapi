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
}

export const useAssistant = create<AssistantState>((set) => ({
  open: false,
  setOpen: (open) => set({ open }),
  toggle: () => set((s) => ({ open: !s.open })),
}));

import { create } from 'zustand';

// Connectivity + background-sync state, surfaced in the UI (OfflineIndicator).
interface OfflineState {
  online: boolean;
  pending: number; // queued writes awaiting sync
  syncing: boolean;
  lastSyncedAt: number | null;
  setOnline: (online: boolean) => void;
  setPending: (pending: number) => void;
  setSyncing: (syncing: boolean) => void;
  markSynced: () => void;
}

export const useOfflineStore = create<OfflineState>((set) => ({
  // Optimistic: navigator.onLine is unreliable (often stuck false), so we start
  // online and let real request outcomes correct it (see api-client). This
  // avoids a sticky "offline" banner when the app is actually reachable.
  online: true,
  pending: 0,
  syncing: false,
  lastSyncedAt: null,
  setOnline: (online) => set({ online }),
  setPending: (pending) => set({ pending }),
  setSyncing: (syncing) => set({ syncing }),
  markSynced: () => set({ lastSyncedAt: Date.now() }),
}));

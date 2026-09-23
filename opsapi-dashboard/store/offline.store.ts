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
  online: typeof navigator !== 'undefined' ? navigator.onLine : true,
  pending: 0,
  syncing: false,
  lastSyncedAt: null,
  setOnline: (online) => set({ online }),
  setPending: (pending) => set({ pending }),
  setSyncing: (syncing) => set({ syncing }),
  markSynced: () => set({ lastSyncedAt: Date.now() }),
}));

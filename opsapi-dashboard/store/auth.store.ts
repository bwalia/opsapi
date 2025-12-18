import { create } from 'zustand';
import { persist } from 'zustand/middleware';
import type { User, AuthState, LoginCredentials } from '@/types';
import { authService } from '@/services/auth.service';
import { AUTH_TOKEN_KEY, clearAllAuthStorage } from '@/lib/api-client';

interface AuthStore extends AuthState {
  login: (credentials: LoginCredentials) => Promise<void>;
  logout: () => Promise<void>;
  setUser: (user: User | null) => void;
  setToken: (token: string | null) => void;
  checkAuth: () => Promise<boolean>;
  clearError: () => void;
  error: string | null;
  _hasHydrated: boolean;
  setHasHydrated: (state: boolean) => void;
}

export const useAuthStore = create<AuthStore>()(
  persist(
    (set, get) => ({
      user: null,
      token: null,
      isAuthenticated: false,
      isLoading: false,
      error: null,
      _hasHydrated: false,

      setHasHydrated: (state: boolean) => {
        set({ _hasHydrated: state });
      },

      login: async (credentials: LoginCredentials) => {
        set({ isLoading: true, error: null });
        try {
          const response = await authService.login(credentials);
          // Sync token to direct localStorage key for API client
          if (response.token && typeof window !== 'undefined') {
            localStorage.setItem(AUTH_TOKEN_KEY, response.token);
          }
          set({
            user: response.user,
            token: response.token,
            isAuthenticated: true,
            isLoading: false,
            error: null,
          });
        } catch (error) {
          const message = error instanceof Error ? error.message : 'Login failed';
          // Clear all auth storage on failed login attempt
          clearAllAuthStorage();
          set({
            user: null,
            token: null,
            isAuthenticated: false,
            isLoading: false,
            error: message,
          });
          throw error;
        }
      },

      logout: async () => {
        set({ isLoading: true });
        try {
          await authService.logout();
        } finally {
          // Clear all auth storage to ensure clean state
          clearAllAuthStorage();
          set({
            user: null,
            token: null,
            isAuthenticated: false,
            isLoading: false,
            error: null,
          });
        }
      },

      setUser: (user: User | null) => {
        set({ user, isAuthenticated: !!user });
      },

      setToken: (token: string | null) => {
        set({ token });
        if (token) {
          authService.setToken(token);
          // Sync to direct localStorage key
          if (typeof window !== 'undefined') {
            localStorage.setItem(AUTH_TOKEN_KEY, token);
          }
        } else {
          // Clear all auth storage when token is explicitly set to null
          clearAllAuthStorage();
        }
      },

      checkAuth: async () => {
        const { token } = get();
        if (!token) {
          clearAllAuthStorage();
          set({ isAuthenticated: false });
          return false;
        }

        try {
          const isValid = await authService.validateToken();
          if (!isValid) {
            clearAllAuthStorage();
            set({ user: null, token: null, isAuthenticated: false });
            return false;
          }

          const user = await authService.getCurrentUser();
          if (user) {
            set({ user, isAuthenticated: true });
            return true;
          }

          return false;
        } catch {
          clearAllAuthStorage();
          set({ user: null, token: null, isAuthenticated: false });
          return false;
        }
      },

      clearError: () => {
        set({ error: null });
      },
    }),
    {
      name: 'auth-storage',
      partialize: (state) => ({
        token: state.token,
        user: state.user,
        isAuthenticated: state.isAuthenticated,
      }),
      onRehydrateStorage: () => (state) => {
        state?.setHasHydrated(true);
      },
    }
  )
);

export default useAuthStore;

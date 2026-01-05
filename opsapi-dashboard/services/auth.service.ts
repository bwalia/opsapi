import { apiClient, toFormData, AUTH_TOKEN_KEY, AUTH_USER_KEY, clearAllAuthStorage } from '@/lib/api-client';
import type { LoginCredentials, LoginResponse, User, NamespacePermissions } from '@/types';

/**
 * Decode JWT payload (base64url)
 */
function decodeJWTPayload(token: string): Record<string, unknown> | null {
  try {
    const parts = token.split('.');
    if (parts.length !== 3) return null;

    // Base64url decode
    let payload = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    // Add padding
    while (payload.length % 4) {
      payload += '=';
    }

    const decoded = atob(payload);
    return JSON.parse(decoded);
  } catch {
    return null;
  }
}

/**
 * Authentication Service
 * Handles all authentication-related API calls and token management
 */
export const authService = {
  /**
   * Login user with credentials
   */
  async login(credentials: LoginCredentials): Promise<LoginResponse> {
    const response = await apiClient.post<LoginResponse>(
      '/auth/login',
      toFormData({
        username: credentials.username,
        password: credentials.password,
      })
    );

    const data = response.data;

    // Store token and user in localStorage
    if (data.token) {
      this.setToken(data.token);

      // Decode JWT to extract namespace permissions
      const jwtPayload = decodeJWTPayload(data.token);
      if (jwtPayload?.userinfo) {
        const userinfo = jwtPayload.userinfo as {
          namespace?: {
            id?: number;
            uuid?: string;
            name?: string;
            slug?: string;
            is_owner?: boolean;
            role?: string;
            permissions?: NamespacePermissions;
          };
        };

        // Merge namespace info with user object so it's available in the auth store
        if (userinfo.namespace && data.user) {
          (data.user as User & { namespace?: typeof userinfo.namespace }).namespace = userinfo.namespace;
        }
      }
    }
    if (data.user) {
      this.setUser(data.user);
    }

    return data;
  },

  /**
   * Logout user
   */
  async logout(): Promise<void> {
    try {
      await apiClient.post('/auth/logout');
    } catch {
      // Ignore logout errors
    } finally {
      this.clearAuth();
    }
  },

  /**
   * Get current user from API by validating token
   */
  async getCurrentUser(): Promise<User | null> {
    try {
      const token = this.getToken();
      if (!token) return null;

      const response = await apiClient.post<{ user: { id: string; email: string; name: string; role: string[] } }>(
        '/auth/oauth/validate',
        toFormData({ token })
      );

      // Map the response to our User type
      if (response.data?.user) {
        const apiUser = response.data.user;
        // Return from local storage which has full user data
        const storedUser = this.getUser();
        if (storedUser) {
          return storedUser;
        }
        // Fallback to minimal user from API
        return {
          id: 0,
          uuid: apiUser.id,
          email: apiUser.email,
          username: apiUser.email,
          first_name: apiUser.name?.split(' ')[0] || '',
          last_name: apiUser.name?.split(' ').slice(1).join(' ') || '',
          active: true,
          created_at: '',
          updated_at: '',
        } as User;
      }
      return null;
    } catch {
      return null;
    }
  },

  /**
   * Validate token
   */
  async validateToken(): Promise<boolean> {
    try {
      const token = this.getToken();
      if (!token) return false;

      const response = await apiClient.post('/auth/oauth/validate', toFormData({ token }));
      // The API returns { user, token } on success, or error status on failure
      return response.status === 200 && !!response.data?.user;
    } catch {
      return false;
    }
  },

  /**
   * Refresh token
   */
  async refreshToken(): Promise<string | null> {
    try {
      const response = await apiClient.post<{ token: string }>('/auth/refresh');
      const newToken = response.data.token;
      if (newToken) {
        this.setToken(newToken);
        return newToken;
      }
      return null;
    } catch {
      return null;
    }
  },

  // ============================================
  // Token Management
  // ============================================

  getToken(): string | null {
    if (typeof window === 'undefined') return null;
    return localStorage.getItem(AUTH_TOKEN_KEY);
  },

  setToken(token: string): void {
    if (typeof window === 'undefined') return;
    localStorage.setItem(AUTH_TOKEN_KEY, token);
  },

  getUser(): User | null {
    if (typeof window === 'undefined') return null;
    const userStr = localStorage.getItem(AUTH_USER_KEY);
    if (!userStr) return null;
    try {
      return JSON.parse(userStr);
    } catch {
      return null;
    }
  },

  setUser(user: User): void {
    if (typeof window === 'undefined') return;
    localStorage.setItem(AUTH_USER_KEY, JSON.stringify(user));
  },

  clearAuth(): void {
    // Use centralized function to clear all auth storage including Zustand
    clearAllAuthStorage();
  },

  isAuthenticated(): boolean {
    return !!this.getToken();
  },
};

export default authService;

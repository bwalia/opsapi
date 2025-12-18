import axios, { AxiosError, type AxiosInstance, type InternalAxiosRequestConfig } from 'axios';

const API_BASE_URL = process.env.NEXT_PUBLIC_API_URL || 'http://localhost:4010';

/**
 * Create axios instance with default configuration
 */
export const apiClient: AxiosInstance = axios.create({
  baseURL: API_BASE_URL,
  timeout: 30000,
  headers: {
    'Content-Type': 'application/x-www-form-urlencoded',
    Accept: 'application/json',
  },
});

// Storage keys
export const NAMESPACE_KEY = 'current_namespace';
export const AUTH_TOKEN_KEY = 'auth_token';
export const AUTH_USER_KEY = 'auth_user';
export const ZUSTAND_AUTH_KEY = 'auth-storage';

// Track if we're currently redirecting to prevent loops
let isRedirecting = false;

/**
 * Get auth token from multiple possible storage locations
 * Priority: 1. Direct localStorage key, 2. Zustand persisted storage
 */
function getAuthToken(): string | null {
  if (typeof window === 'undefined') return null;

  // First try direct key
  const directToken = localStorage.getItem(AUTH_TOKEN_KEY);
  if (directToken) return directToken;

  // Fallback to Zustand persisted state
  try {
    const zustandData = localStorage.getItem(ZUSTAND_AUTH_KEY);
    if (zustandData) {
      const parsed = JSON.parse(zustandData);
      if (parsed?.state?.token) {
        // Sync to direct key for consistency
        localStorage.setItem(AUTH_TOKEN_KEY, parsed.state.token);
        return parsed.state.token;
      }
    }
  } catch {
    // Ignore parse errors
  }

  return null;
}

/**
 * Clear all auth-related storage
 */
export function clearAllAuthStorage(): void {
  if (typeof window === 'undefined') return;

  localStorage.removeItem(AUTH_TOKEN_KEY);
  localStorage.removeItem(AUTH_USER_KEY);
  localStorage.removeItem(ZUSTAND_AUTH_KEY);
  localStorage.removeItem(NAMESPACE_KEY);
}

/**
 * Request interceptor to add auth token and namespace header
 */
apiClient.interceptors.request.use(
  (config: InternalAxiosRequestConfig) => {
    if (typeof window !== 'undefined') {
      const token = getAuthToken();
      if (token && config.headers) {
        config.headers.Authorization = `Bearer ${token}`;
      }

      // Add namespace header from localStorage (user's current namespace context)
      const namespaceData = localStorage.getItem(NAMESPACE_KEY);
      if (namespaceData && config.headers) {
        try {
          const namespace = JSON.parse(namespaceData);
          if (namespace?.uuid) {
            config.headers['X-Namespace-Id'] = namespace.uuid;
          }
        } catch {
          // Ignore parse errors
        }
      }
    }
    return config;
  },
  (error) => Promise.reject(error)
);

/**
 * Response interceptor for error handling
 */
apiClient.interceptors.response.use(
  (response) => response,
  (error: AxiosError) => {
    if (error.response?.status === 401) {
      if (typeof window !== 'undefined') {
        // Clear ALL auth storage to prevent state mismatch
        clearAllAuthStorage();

        // Prevent redirect loop - only redirect if:
        // 1. Not already redirecting
        // 2. Not already on login page
        // 3. Not an auth-related endpoint (login, validate, etc.)
        const isAuthEndpoint = error.config?.url?.includes('/auth/');
        const isOnLoginPage = window.location.pathname.includes('/login');

        if (!isRedirecting && !isOnLoginPage && !isAuthEndpoint) {
          isRedirecting = true;
          // Use replace instead of href to prevent browser history issues
          window.location.replace('/login');
          // Reset flag after a delay (in case redirect fails)
          setTimeout(() => {
            isRedirecting = false;
          }, 3000);
        }
      }
    }
    return Promise.reject(error);
  }
);

/**
 * Convert object to URL-encoded form data (Lapis API requirement)
 */
export function toFormData(data: Record<string, unknown>): string {
  const params = new URLSearchParams();

  Object.entries(data).forEach(([key, value]) => {
    if (value !== undefined && value !== null) {
      if (Array.isArray(value)) {
        value.forEach((item) => params.append(key, String(item)));
      } else if (typeof value === 'object') {
        params.append(key, JSON.stringify(value));
      } else {
        params.append(key, String(value));
      }
    }
  });

  return params.toString();
}

/**
 * Build query string from params object
 */
export function buildQueryString(params: Record<string, unknown>): string {
  const searchParams = new URLSearchParams();

  Object.entries(params).forEach(([key, value]) => {
    if (value !== undefined && value !== null && value !== '') {
      searchParams.append(key, String(value));
    }
  });

  const queryString = searchParams.toString();
  return queryString ? `?${queryString}` : '';
}

export default apiClient;

'use client';
import { createContext, useContext, useState, useEffect, ReactNode } from 'react';
import api from '@/lib/api';

import { User } from '@/types';

interface AuthContextType {
  user: User | null;
  login: (email: string, password: string) => Promise<User>;
  register: (data: any) => Promise<void>;
  logout: () => Promise<void>;
  loading: boolean;
  loginWithGoogle: (redirectPath?: string) => void;
  loginWithFacebook: (redirectPath?: string) => void;
  handleOAuthCallback: (token: string) => Promise<User>;
}

const AuthContext = createContext<AuthContextType | undefined>(undefined);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const token = localStorage.getItem('token');
    const userData = localStorage.getItem('user');
    
    if (token && userData) {
      try {
        api.setToken(token);
        const parsedUser = JSON.parse(userData);
        setUser(parsedUser);
      } catch (error) {
        console.error('Failed to parse stored user data:', error);
        localStorage.removeItem('token');
        localStorage.removeItem('user');
      }
    }
    setLoading(false);
  }, []);

  const login = async (username: string, password: string) => {
    try {
      const response = await api.login({ username, password });
      setUser(response.user);
      // Store user data for persistence
      if (typeof window !== 'undefined') {
        localStorage.setItem('user', JSON.stringify(response.user));
      }
      return response.user; // Return user for role-based redirect
    } catch (error) {
      throw error;
    }
  };

  const register = async (data: any) => {
    try {
      await api.register(data);
    } catch (error) {
      throw error;
    }
  };

  const logout = async () => {
    try {
      await api.logout();
    } catch (error) {
      console.error('Logout error:', error);
    } finally {
      // Always clear local data regardless of API response
      api.clearToken();
      setUser(null);
      if (typeof window !== 'undefined') {
        localStorage.removeItem('user');
      }
    }
  };

  const loginWithGoogle = (redirectPath?: string) => {
    if (typeof window !== 'undefined') {
      window.location.href = api.getGoogleAuthUrl(redirectPath);
    }
  };

  const loginWithFacebook = (redirectPath?: string) => {
    if (typeof window !== 'undefined') {
      window.location.href = api.getFacebookAuthUrl(redirectPath);
    }
  };

  const handleOAuthCallback = async (token: string) => {
    try {
      const response = await api.validateOAuthToken(token);
      api.setToken(response.token);
      setUser(response.user);
      
      if (typeof window !== 'undefined') {
        localStorage.setItem('user', JSON.stringify(response.user));
      }
      
      return response.user;
    } catch (error) {
      console.error('OAuth callback error:', error);
      throw error;
    }
  };

  return (
    <AuthContext.Provider value={{ 
      user, 
      login, 
      register, 
      logout, 
      loading, 
      loginWithGoogle, 
      loginWithFacebook, 
      handleOAuthCallback 
    }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  const context = useContext(AuthContext);
  if (context === undefined) {
    throw new Error('useAuth must be used within an AuthProvider');
  }
  return context;
}
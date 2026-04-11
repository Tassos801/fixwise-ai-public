import { createContext, useCallback, useContext, useEffect, useState } from 'react';
import type { ReactNode } from 'react';
import { api, AUTH_CHANGED_EVENT, clearStoredTokens, storeTokens } from './api';

interface User {
  id: string;
  email: string;
  displayName: string | null;
  tier: string;
  hasApiKey: boolean;
  apiKeyMask: string | null;
}

interface AuthContextType {
  user: User | null;
  isLoading: boolean;
  login: (email: string, password: string) => Promise<void>;
  register: (email: string, password: string, displayName?: string) => Promise<void>;
  logout: () => void;
  refreshUser: () => Promise<void>;
}

const AuthContext = createContext<AuthContextType | null>(null);

const TOKEN_KEY = 'fixwise_auth_token';
export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
  const [isLoading, setIsLoading] = useState(true);

  const fetchUser = useCallback(async () => {
    const token = localStorage.getItem(TOKEN_KEY);
    if (!token) {
      setUser(null);
      setIsLoading(false);
      return;
    }

    try {
      const data = await api.get('/api/auth/me');
      setUser(data);
    } catch {
      clearStoredTokens();
      setUser(null);
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchUser();
  }, [fetchUser]);

  useEffect(() => {
    const syncUser = () => {
      void fetchUser();
    };

    window.addEventListener(AUTH_CHANGED_EVENT, syncUser);
    window.addEventListener('storage', syncUser);

    return () => {
      window.removeEventListener(AUTH_CHANGED_EVENT, syncUser);
      window.removeEventListener('storage', syncUser);
    };
  }, [fetchUser]);

  const login = async (email: string, password: string) => {
    const data = await api.post('/api/auth/login', { email, password });
    storeTokens(data.access_token, data.refresh_token);
    setUser(data.user);
  };

  const register = async (email: string, password: string, displayName?: string) => {
    const data = await api.post('/api/auth/register', {
      email,
      password,
      display_name: displayName,
    });
    storeTokens(data.access_token, data.refresh_token);
    setUser(data.user);
  };

  const logout = () => {
    clearStoredTokens();
    setUser(null);
  };

  return (
    <AuthContext.Provider value={{ user, isLoading, login, register, logout, refreshUser: fetchUser }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth(): AuthContextType {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth must be used within AuthProvider');
  return ctx;
}

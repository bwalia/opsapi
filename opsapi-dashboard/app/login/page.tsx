"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";
import { LoginForm } from "@/components/auth";
import { useAuthStore } from "@/store/auth.store";
import { AUTH_TOKEN_KEY } from "@/lib/api-client";
import { Loader2 } from "lucide-react";

export default function LoginPage() {
  const router = useRouter();
  const { isAuthenticated, token, _hasHydrated, setToken } = useAuthStore();

  useEffect(() => {
    // Wait for hydration before redirecting
    if (!_hasHydrated) return;

    // Verify actual localStorage token matches Zustand state
    // This prevents redirect loops when 401 clears localStorage but Zustand still thinks authenticated
    const actualToken = localStorage.getItem(AUTH_TOKEN_KEY);

    // If Zustand thinks we're authenticated but localStorage has no token, clear Zustand state
    if (isAuthenticated && !actualToken) {
      setToken(null);
      return;
    }

    // Only redirect if both Zustand state AND localStorage have valid token
    if (isAuthenticated && token && actualToken) {
      router.push("/dashboard");
    }
  }, [isAuthenticated, token, _hasHydrated, router, setToken]);

  // Show loading while hydrating — same neutral background as the app shell.
  if (!_hasHydrated) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-background">
        <Loader2 className="w-10 h-10 text-primary-500 animate-spin" />
      </div>
    );
  }

  return (
    // Uses the same `bg-background` token as the dashboard so the login screen
    // stays visually consistent across light/dark themes (no inverting
    // gradient). A pair of soft, theme-aware accent glows add depth without
    // fighting the surface palette.
    <div className="relative min-h-screen flex items-center justify-center bg-background p-4 overflow-hidden">
      {/* Subtle accent glows — tinted by the active accent, faint in both themes */}
      <div className="pointer-events-none absolute inset-0 overflow-hidden" aria-hidden="true">
        <div className="absolute -top-40 -right-40 w-[32rem] h-[32rem] bg-primary-500/10 rounded-full blur-3xl" />
        <div className="absolute -bottom-40 -left-40 w-[32rem] h-[32rem] bg-primary-500/5 rounded-full blur-3xl" />
      </div>

      <div className="relative z-10 w-full max-w-md">
        <LoginForm />
      </div>
    </div>
  );
}

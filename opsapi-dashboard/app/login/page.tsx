'use client';

import { useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { motion, useReducedMotion } from 'framer-motion';
import { ShieldCheck, Boxes, GitBranch } from 'lucide-react';
import LoginPanel from '@/components/auth/LoginPanel';
import ParticleField from '@/components/auth/ParticleField';
import { Logo } from '@/components/brand/Logo';
import PublicThemeStyles from '@/components/layout/PublicThemeStyles';
import { useAuthStore } from '@/store/auth.store';
import { AUTH_TOKEN_KEY } from '@/lib/api-client';
import { Loader2 } from 'lucide-react';

const EASE = [0.16, 1, 0.3, 1] as const;

const FEATURES = [
  { icon: Boxes, title: 'One platform, every module', desc: 'CRM, invoicing, tax, e-commerce and more — behind a single API.' },
  { icon: ShieldCheck, title: 'Multi-tenant by design', desc: 'Namespace isolation and fine-grained RBAC on every request.' },
  { icon: GitBranch, title: 'Ops that ship themselves', desc: 'Domains, DNS and edge routing synced straight from the dashboard.' },
];

export default function LoginPage() {
  const router = useRouter();
  const { isAuthenticated, token, _hasHydrated, setToken } = useAuthStore();
  const reduce = useReducedMotion();

  useEffect(() => {
    if (!_hasHydrated) return;
    const actualToken = localStorage.getItem(AUTH_TOKEN_KEY);
    if (isAuthenticated && !actualToken) {
      setToken(null);
      return;
    }
    if (isAuthenticated && token && actualToken) {
      router.push('/dashboard');
    }
  }, [isAuthenticated, token, _hasHydrated, router, setToken]);

  if (!_hasHydrated) {
    return (
      <div className="flex min-h-dvh items-center justify-center bg-secondary-950">
        <Loader2 className="h-10 w-10 animate-spin text-primary-500" />
      </div>
    );
  }

  const container = {
    hidden: {},
    show: { transition: { staggerChildren: reduce ? 0 : 0.12, delayChildren: 0.1 } },
  };
  const item = {
    hidden: { opacity: 0, y: reduce ? 0 : 18 },
    show: { opacity: 1, y: 0, transition: { duration: 0.7, ease: EASE } },
  };

  return (
    <div className="flex min-h-dvh bg-white">
      <PublicThemeStyles />

      {/* ── Left: branded cinematic panel (desktop only) ───────────────── */}
      <div className="relative hidden overflow-hidden lg:flex lg:w-[56%] bg-secondary-950">
        {/* deep gradient base */}
        <div className="absolute inset-0 bg-linear-to-br from-secondary-950 via-secondary-900 to-[#2a0a18]" />
        {/* ambient brand blobs */}
        <motion.div
          aria-hidden
          className="absolute -left-40 top-[-10%] h-[36rem] w-[36rem] rounded-full bg-primary-500/25 blur-[120px]"
          animate={reduce ? undefined : { x: [0, 40, 0], y: [0, 30, 0] }}
          transition={{ duration: 18, repeat: Infinity, ease: 'easeInOut' }}
        />
        <motion.div
          aria-hidden
          className="absolute -right-32 bottom-[-15%] h-[32rem] w-[32rem] rounded-full bg-[#7c1d3a]/30 blur-[120px]"
          animate={reduce ? undefined : { x: [0, -30, 0], y: [0, -20, 0] }}
          transition={{ duration: 22, repeat: Infinity, ease: 'easeInOut' }}
        />
        {/* constellation */}
        <ParticleField className="absolute inset-0 h-full w-full" />
        {/* subtle vignette for text legibility */}
        <div className="absolute inset-0 bg-linear-to-t from-secondary-950/70 via-transparent to-transparent" />

        <motion.div
          variants={container}
          initial="hidden"
          animate="show"
          className="relative z-10 flex w-full flex-col justify-between p-12 xl:p-16"
        >
          <motion.div variants={item}>
            <Logo size={40} tone="light" />
          </motion.div>

          <div className="max-w-md">
            <motion.h2 variants={item} className="text-4xl font-bold leading-tight text-white xl:text-5xl">
              The platform that runs
              <span className="bg-linear-to-r from-primary-400 to-primary-600 bg-clip-text text-transparent"> your operations.</span>
            </motion.h2>
            <motion.p variants={item} className="mt-4 text-base leading-relaxed text-secondary-300">
              One multi-tenant API for your whole business — from CRM to tax filing to edge routing.
            </motion.p>

            <motion.ul variants={container} className="mt-10 space-y-5">
              {FEATURES.map((f) => (
                <motion.li key={f.title} variants={item} className="flex items-start gap-3.5">
                  <span className="mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-lg border border-white/10 bg-white/5 backdrop-blur-sm">
                    <f.icon className="h-[18px] w-[18px] text-primary-400" />
                  </span>
                  <span>
                    <span className="block text-sm font-semibold text-white">{f.title}</span>
                    <span className="block text-sm text-secondary-400">{f.desc}</span>
                  </span>
                </motion.li>
              ))}
            </motion.ul>
          </div>

          <motion.p variants={item} className="text-xs text-secondary-500">
            © {new Date().getFullYear()} OpsAPI · Secure multi-tenant SaaS platform
          </motion.p>
        </motion.div>
      </div>

      {/* ── Right: sign-in ─────────────────────────────────────────────── */}
      <div className="flex flex-1 items-center justify-center px-6 py-12 sm:px-10">
        <motion.div
          initial={{ opacity: 0, y: reduce ? 0 : 14 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.6, ease: EASE, delay: 0.05 }}
          className="w-full max-w-sm"
        >
          {/* mobile logo (left panel is hidden < lg) */}
          <div className="mb-10 lg:hidden">
            <Logo size={34} tone="dark" />
          </div>
          <LoginPanel />
        </motion.div>
      </div>
    </div>
  );
}

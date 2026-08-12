'use client';

import React from 'react';
import { motion, useReducedMotion } from 'framer-motion';
import { ShieldCheck, Boxes, GitBranch } from 'lucide-react';
import ParticleField from '@/components/auth/ParticleField';
import { Logo } from '@/components/brand/Logo';
import PublicThemeStyles from '@/components/layout/PublicThemeStyles';

const EASE = [0.16, 1, 0.3, 1] as const;

const FEATURES = [
  { icon: Boxes, title: 'One platform, every module', desc: 'CRM, invoicing, tax, e-commerce and more — behind a single API.' },
  { icon: ShieldCheck, title: 'Multi-tenant by design', desc: 'Namespace isolation and fine-grained RBAC on every request.' },
  { icon: GitBranch, title: 'Ops that ship themselves', desc: 'Domains, DNS and edge routing synced straight from the dashboard.' },
];

/**
 * Shared split-screen auth layout: a cinematic branded panel on the left
 * (constellation + ambient glow + logo + feature reveal) and a centered slot on
 * the right for the sign-in / OTP / other auth form. Used by /login and
 * /verify-otp so the two flows feel like one continuous experience.
 */
export default function AuthShell({ children }: { children: React.ReactNode }) {
  const reduce = useReducedMotion();

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
      {/* Fixed dark colours (NOT secondary-* tokens): this panel is always the
          dark cinematic hero, but the secondary scale inverts under `.dark`
          (secondary-950 -> #fff) and the tenant theme also overrides it, which
          turned the gradient into a washed-out pale smear. Hard-coded hexes keep
          it correct in light AND dark mode and under any namespace theme. */}
      <div className="relative hidden overflow-hidden lg:flex lg:w-[56%] bg-[#0b1120]">
        <div className="absolute inset-0 bg-linear-to-br from-[#0b1120] via-[#12182b] to-[#2a0a18]" />
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
        <ParticleField className="absolute inset-0 h-full w-full" />
        <div className="absolute inset-0 bg-linear-to-t from-[#0b1120]/70 via-transparent to-transparent" />

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
            <motion.p variants={item} className="mt-4 text-base leading-relaxed text-white/70">
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
                    <span className="block text-sm text-white/55">{f.desc}</span>
                  </span>
                </motion.li>
              ))}
            </motion.ul>
          </div>

          <motion.p variants={item} className="text-xs text-white/40">
            © {new Date().getFullYear()} OpsAPI · Secure multi-tenant SaaS platform
          </motion.p>
        </motion.div>
      </div>

      {/* ── Right: form slot ───────────────────────────────────────────── */}
      <div className="flex flex-1 items-center justify-center px-6 py-12 sm:px-10">
        <motion.div
          initial={{ opacity: 0, y: reduce ? 0 : 14 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.6, ease: EASE, delay: 0.05 }}
          className="w-full max-w-sm"
        >
          <div className="mb-10 lg:hidden">
            <Logo size={34} tone="dark" />
          </div>
          {children}
        </motion.div>
      </div>
    </div>
  );
}

/** Full-screen dark loader used by auth pages while they hydrate/read session. */
export function AuthLoader() {
  return (
    <div className="flex min-h-dvh items-center justify-center bg-[#0b1120]">
      <div className="h-10 w-10 animate-spin rounded-full border-2 border-white/15 border-t-primary-500" />
    </div>
  );
}

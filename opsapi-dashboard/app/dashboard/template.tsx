'use client';

import React from 'react';
import { motion, useReducedMotion } from 'framer-motion';

/**
 * Route template for the dashboard. Next.js re-mounts a `template.tsx` on every
 * navigation (unlike `layout.tsx`), so this gives *every* dashboard page a
 * consistent, subtle entrance transition — modern page motion with one file,
 * no per-page edits. Honours prefers-reduced-motion.
 */
export default function DashboardTemplate({ children }: { children: React.ReactNode }) {
  const reduce = useReducedMotion();
  return (
    <motion.div
      initial={{ opacity: 0, y: reduce ? 0 : 10 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.35, ease: [0.16, 1, 0.3, 1] }}
    >
      {children}
    </motion.div>
  );
}

'use client';

import React from 'react';
import { motion, useReducedMotion, type Variants } from 'framer-motion';

/**
 * Lightweight entrance-motion primitives shared across dashboard pages.
 *
 * <Stagger> is a container that reveals its <RevealItem> children in sequence;
 * both honour prefers-reduced-motion (fade only, no movement). Use them to give
 * any page a modern, cohesive "content settles in" feel with one wrapper.
 */

const EASE = [0.16, 1, 0.3, 1] as const;

export function Stagger({
  children,
  className,
  gap = 0.07,
}: {
  children: React.ReactNode;
  className?: string;
  gap?: number;
}) {
  const reduce = useReducedMotion();
  return (
    <motion.div
      className={className}
      initial="hidden"
      animate="show"
      variants={{ hidden: {}, show: { transition: { staggerChildren: reduce ? 0 : gap, delayChildren: 0.04 } } }}
    >
      {children}
    </motion.div>
  );
}

export function RevealItem({ children, className }: { children: React.ReactNode; className?: string }) {
  const reduce = useReducedMotion();
  const variants: Variants = reduce
    ? { hidden: { opacity: 0 }, show: { opacity: 1, transition: { duration: 0.3 } } }
    : { hidden: { opacity: 0, y: 16 }, show: { opacity: 1, y: 0, transition: { duration: 0.55, ease: EASE } } };
  return (
    <motion.div className={className} variants={variants}>
      {children}
    </motion.div>
  );
}

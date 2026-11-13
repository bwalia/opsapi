'use client';

import React from 'react';
import {
  BarChart3,
  Briefcase,
  Car,
  Coins,
  Gift,
  Globe,
  GraduationCap,
  HandCoins,
  Heart,
  Home,
  Landmark,
  Laptop,
  PieChart,
  PiggyBank,
  Plane,
  Receipt,
  ShieldCheck,
  Store,
  Sunrise,
  TrendingUp,
  Wallet,
  type LucideIcon,
} from 'lucide-react';

/** Icons an administrator can pick for an income type (stored by name in income_types.icon). */
export const INCOME_ICONS: Record<string, LucideIcon> = {
  Briefcase, Store, Home, Plane, TrendingUp, Globe, PieChart, PiggyBank, Landmark, Sunrise,
  ShieldCheck, BarChart3, Wallet, Coins, HandCoins, Receipt, Gift, Heart, Car, Laptop, GraduationCap,
};

export function IncomeIcon({ name, className = 'h-5 w-5' }: { name?: string | null; className?: string }) {
  const Icon = (name && INCOME_ICONS[name]) || Wallet;
  return <Icon className={className} aria-hidden="true" />;
}

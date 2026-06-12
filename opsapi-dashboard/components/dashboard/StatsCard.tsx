'use client';

import React, { memo } from 'react';
import { cn } from '@/lib/utils';
import { TrendingUp, TrendingDown } from 'lucide-react';

export interface StatsCardProps {
  title: string;
  value: string | number;
  icon: React.ReactNode;
  trend?: {
    value: number;
    isPositive: boolean;
  };
  description?: string;
  className?: string;
  isLoading?: boolean;
}

const StatsCard: React.FC<StatsCardProps> = memo(function StatsCard({
  title,
  value,
  icon,
  trend,
  description,
  className,
  isLoading = false,
}) {
  return (
    <div
      className={cn(
        'group relative overflow-hidden bg-surface rounded-2xl border border-secondary-200/70',
        'p-4 sm:p-6 shadow-sm transition-all duration-300',
        'hover:shadow-xl hover:shadow-secondary-900/5 hover:-translate-y-0.5 hover:border-primary-200',
        className
      )}
    >
      {/* Top accent bar — reveals on hover */}
      <div className="absolute inset-x-0 top-0 h-1 gradient-primary opacity-0 group-hover:opacity-100 transition-opacity duration-300" />
      {/* Soft brand glow in the corner */}
      <div className="pointer-events-none absolute -top-10 -right-10 w-28 h-28 rounded-full bg-primary-500/5 blur-2xl opacity-0 group-hover:opacity-100 transition-opacity duration-500" />

      <div className="relative flex items-start justify-between gap-3">
        <div className="flex-1 min-w-0">
          <p className="text-xs sm:text-sm font-medium text-secondary-500 truncate">{title}</p>

          {isLoading ? (
            <div className="h-7 sm:h-9 w-20 sm:w-24 bg-secondary-200 rounded-lg animate-pulse mt-2" />
          ) : (
            <p className="text-2xl sm:text-3xl font-bold tracking-tight text-secondary-900 mt-1.5 sm:mt-2 truncate">
              {value}
            </p>
          )}

          {trend && !isLoading && (
            <div className="flex items-center gap-2 mt-3 flex-wrap">
              <span
                className={cn(
                  'inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-semibold',
                  trend.isPositive
                    ? 'bg-success-500/10 text-success-600'
                    : 'bg-error-500/10 text-error-600'
                )}
              >
                {trend.isPositive ? (
                  <TrendingUp className="w-3.5 h-3.5 flex-shrink-0" />
                ) : (
                  <TrendingDown className="w-3.5 h-3.5 flex-shrink-0" />
                )}
                {trend.isPositive ? '+' : '-'}
                {Math.abs(trend.value)}%
              </span>
              {description && (
                <span className="text-xs text-secondary-400 hidden sm:inline">{description}</span>
              )}
            </div>
          )}

          {isLoading && (
            <div className="h-4 w-24 bg-secondary-100 rounded animate-pulse mt-3" />
          )}
        </div>

        <div className="w-11 h-11 sm:w-12 sm:h-12 gradient-primary rounded-xl flex items-center justify-center text-white shadow-lg shadow-primary-500/25 ring-1 ring-white/20 flex-shrink-0 transition-transform duration-300 group-hover:scale-105">
          <div className="[&>svg]:w-5 [&>svg]:h-5 sm:[&>svg]:w-6 sm:[&>svg]:h-6">{icon}</div>
        </div>
      </div>
    </div>
  );
});

export default StatsCard;

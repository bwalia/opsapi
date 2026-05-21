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
        // Hairline border that warms to the accent on hover + a soft lift.
        'group bg-surface rounded-xl border border-secondary-200 p-5 transition-all duration-200',
        'hover:border-primary-300 hover:shadow-md',
        className,
      )}
    >
      {/* Header row: label + soft tinted icon tile (not a heavy gradient) */}
      <div className="flex items-center justify-between gap-2">
        <p className="text-sm font-medium text-secondary-500 truncate">{title}</p>
        <div className="w-9 h-9 rounded-lg bg-primary-500/10 text-primary-600 flex items-center justify-center shrink-0 transition-colors group-hover:bg-primary-500/15">
          <div className="[&>svg]:w-[18px] [&>svg]:h-[18px]">{icon}</div>
        </div>
      </div>

      {/* Value */}
      {isLoading ? (
        <div className="h-8 w-24 bg-secondary-200 rounded-md animate-pulse mt-3" />
      ) : (
        <p className="text-[26px] sm:text-[28px] leading-none font-semibold text-secondary-900 mt-3 tracking-tight tabular-nums truncate">
          {value}
        </p>
      )}

      {/* Trend pill + description */}
      {isLoading ? (
        <div className="h-4 w-28 bg-secondary-100 rounded animate-pulse mt-3" />
      ) : trend ? (
        <div className="flex items-center gap-2 mt-3">
          <span
            className={cn(
              'inline-flex items-center gap-1 px-1.5 py-0.5 rounded-md text-xs font-semibold',
              trend.isPositive
                ? 'bg-success-500/10 text-success-600'
                : 'bg-error-500/10 text-error-600',
            )}
          >
            {trend.isPositive ? (
              <TrendingUp className="w-3 h-3" />
            ) : (
              <TrendingDown className="w-3 h-3" />
            )}
            {trend.isPositive ? '+' : '-'}
            {Math.abs(trend.value)}%
          </span>
          {description && (
            <span className="text-xs text-secondary-400 truncate hidden sm:inline">{description}</span>
          )}
        </div>
      ) : null}
    </div>
  );
});

export default StatsCard;

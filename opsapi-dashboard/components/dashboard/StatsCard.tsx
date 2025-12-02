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
        'bg-white rounded-xl border border-secondary-200 p-4 sm:p-6 hover:shadow-lg transition-shadow duration-300',
        className
      )}
    >
      <div className="flex items-start justify-between gap-2">
        <div className="flex-1 min-w-0">
          <p className="text-xs sm:text-sm font-medium text-secondary-500 truncate">{title}</p>

          {isLoading ? (
            <div className="h-6 sm:h-8 w-16 sm:w-20 bg-secondary-200 rounded animate-pulse mt-1 sm:mt-2" />
          ) : (
            <p className="text-lg sm:text-2xl font-bold text-secondary-900 mt-1 sm:mt-2 truncate">
              {value}
            </p>
          )}

          {trend && !isLoading && (
            <div className="flex items-center gap-1 mt-2 sm:mt-3 flex-wrap">
              {trend.isPositive ? (
                <TrendingUp className="w-3 h-3 sm:w-4 sm:h-4 text-success-500 flex-shrink-0" />
              ) : (
                <TrendingDown className="w-3 h-3 sm:w-4 sm:h-4 text-error-500 flex-shrink-0" />
              )}
              <span
                className={cn(
                  'text-xs sm:text-sm font-medium',
                  trend.isPositive ? 'text-success-600' : 'text-error-600'
                )}
              >
                {trend.isPositive ? '+' : '-'}
                {Math.abs(trend.value)}%
              </span>
              {description && (
                <span className="text-xs text-secondary-400 hidden sm:inline">{description}</span>
              )}
            </div>
          )}

          {isLoading && (
            <div className="h-3 sm:h-4 w-20 sm:w-24 bg-secondary-100 rounded animate-pulse mt-2 sm:mt-3" />
          )}
        </div>

        <div className="w-10 h-10 sm:w-12 sm:h-12 gradient-primary rounded-lg sm:rounded-xl flex items-center justify-center text-white shadow-lg shadow-primary-500/25 flex-shrink-0">
          <div className="[&>svg]:w-5 [&>svg]:h-5 sm:[&>svg]:w-6 sm:[&>svg]:h-6">{icon}</div>
        </div>
      </div>
    </div>
  );
});

export default StatsCard;

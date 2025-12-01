'use client';

import React from 'react';
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
}

const StatsCard: React.FC<StatsCardProps> = ({
  title,
  value,
  icon,
  trend,
  description,
  className,
}) => {
  return (
    <div
      className={cn(
        'bg-white rounded-xl border border-secondary-200 p-6 hover:shadow-lg transition-shadow duration-300',
        className
      )}
    >
      <div className="flex items-start justify-between">
        <div className="flex-1">
          <p className="text-sm font-medium text-secondary-500">{title}</p>
          <p className="text-2xl font-bold text-secondary-900 mt-2">{value}</p>

          {trend && (
            <div className="flex items-center gap-1 mt-3">
              {trend.isPositive ? (
                <TrendingUp className="w-4 h-4 text-success-500" />
              ) : (
                <TrendingDown className="w-4 h-4 text-error-500" />
              )}
              <span
                className={cn(
                  'text-sm font-medium',
                  trend.isPositive ? 'text-success-600' : 'text-error-600'
                )}
              >
                {trend.isPositive ? '+' : '-'}{Math.abs(trend.value)}%
              </span>
              {description && (
                <span className="text-sm text-secondary-400 ml-1">{description}</span>
              )}
            </div>
          )}
        </div>

        <div className="w-12 h-12 gradient-primary rounded-xl flex items-center justify-center text-white shadow-lg shadow-primary-500/25">
          {icon}
        </div>
      </div>
    </div>
  );
};

export default StatsCard;

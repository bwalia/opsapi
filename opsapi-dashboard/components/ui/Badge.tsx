'use client';

import React from 'react';
import { cn, getStatusColor, snakeToTitle } from '@/lib/utils';

export interface BadgeProps extends React.HTMLAttributes<HTMLSpanElement> {
  variant?: 'default' | 'success' | 'warning' | 'error' | 'info';
  size?: 'sm' | 'md';
  status?: string;
}

const Badge: React.FC<BadgeProps> = ({
  className,
  variant = 'default',
  size = 'md',
  status,
  children,
  ...props
}) => {
  const variants = {
    default: 'bg-secondary-100 text-secondary-700',
    success: 'bg-success-500/10 text-success-600',
    warning: 'bg-warning-500/10 text-warning-600',
    error: 'bg-error-500/10 text-error-600',
    info: 'bg-info-500/10 text-info-600',
  };

  const sizes = {
    sm: 'px-2 py-0.5 text-xs',
    md: 'px-2.5 py-1 text-xs',
  };

  // If status prop is provided, use automatic status coloring
  if (status) {
    return (
      <span
        className={cn(
          'inline-flex items-center font-medium rounded-full',
          sizes[size],
          getStatusColor(status),
          className
        )}
        {...props}
      >
        {children || snakeToTitle(status)}
      </span>
    );
  }

  return (
    <span
      className={cn(
        'inline-flex items-center font-medium rounded-full',
        variants[variant],
        sizes[size],
        className
      )}
      {...props}
    >
      {children}
    </span>
  );
};

export default Badge;

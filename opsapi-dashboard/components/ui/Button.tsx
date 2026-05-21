'use client';

import React from 'react';
import { cn } from '@/lib/utils';
import { Loader2 } from 'lucide-react';

export interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: 'primary' | 'secondary' | 'outline' | 'ghost' | 'danger';
  size?: 'sm' | 'md' | 'lg';
  isLoading?: boolean;
  leftIcon?: React.ReactNode;
  rightIcon?: React.ReactNode;
}

const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  (
    {
      className,
      variant = 'primary',
      size = 'md',
      isLoading = false,
      leftIcon,
      rightIcon,
      disabled,
      children,
      ...props
    },
    ref
  ) => {
    const baseStyles =
      'inline-flex items-center justify-center font-medium rounded-lg transition-all duration-150 focus:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:ring-offset-surface disabled:opacity-50 disabled:cursor-not-allowed select-none';

    const variants = {
      // Solid brand. Subtle ring on hover gives a crisp, premium edge.
      primary:
        'bg-primary-500 text-white hover:bg-primary-600 active:bg-primary-700 focus-visible:ring-primary-500 shadow-sm',
      // Neutral subtle button — works in light AND dark (uses surface + border).
      secondary:
        'bg-surface text-secondary-800 border border-secondary-300 hover:bg-secondary-100 hover:border-secondary-400 focus-visible:ring-secondary-400 shadow-sm',
      // 1px outline (not 2px) for the refined look.
      outline:
        'border border-primary-500 text-primary-600 hover:bg-primary-500/10 focus-visible:ring-primary-500',
      ghost:
        'text-secondary-600 hover:bg-secondary-100 hover:text-secondary-900 focus-visible:ring-secondary-400',
      danger:
        'bg-error-500 text-white hover:bg-error-600 focus-visible:ring-error-500 shadow-sm',
    };

    const sizes = {
      sm: 'h-8 px-3 text-[13px] gap-1.5',
      md: 'h-9 px-4 text-sm gap-2',
      lg: 'h-11 px-6 text-[15px] gap-2.5',
    };

    return (
      <button
        ref={ref}
        className={cn(baseStyles, variants[variant], sizes[size], className)}
        disabled={disabled || isLoading}
        {...props}
      >
        {isLoading ? (
          <Loader2 className="w-4 h-4 animate-spin" />
        ) : (
          leftIcon
        )}
        {children}
        {!isLoading && rightIcon}
      </button>
    );
  }
);

Button.displayName = 'Button';

export default Button;

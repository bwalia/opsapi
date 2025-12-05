'use client';

import React, { forwardRef } from 'react';
import { cn } from '@/lib/utils';
import { ChevronDown } from 'lucide-react';

export interface SelectProps extends React.SelectHTMLAttributes<HTMLSelectElement> {
  error?: boolean;
  helperText?: string;
}

const Select = forwardRef<HTMLSelectElement, SelectProps>(
  ({ className, error, helperText, children, ...props }, ref) => {
    return (
      <div className="relative w-full">
        <select
          ref={ref}
          className={cn(
            'w-full appearance-none rounded-lg border border-secondary-300 bg-white px-4 py-2.5 pr-10 text-sm text-secondary-900',
            'focus:border-primary-500 focus:outline-none focus:ring-2 focus:ring-primary-500/20',
            'disabled:cursor-not-allowed disabled:bg-secondary-50 disabled:text-secondary-500',
            'transition-colors duration-200',
            error && 'border-error-500 focus:border-error-500 focus:ring-error-500/20',
            className
          )}
          {...props}
        >
          {children}
        </select>
        <div className="pointer-events-none absolute inset-y-0 right-0 flex items-center pr-3">
          <ChevronDown className="h-4 w-4 text-secondary-400" aria-hidden="true" />
        </div>
        {helperText && (
          <p className={cn(
            'mt-1 text-xs',
            error ? 'text-error-500' : 'text-secondary-500'
          )}>
            {helperText}
          </p>
        )}
      </div>
    );
  }
);

Select.displayName = 'Select';

export default Select;

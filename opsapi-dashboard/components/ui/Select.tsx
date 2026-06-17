'use client';

import React, { forwardRef } from 'react';
import { cn } from '@/lib/utils';
import { ChevronDown } from 'lucide-react';

export interface SelectProps extends React.SelectHTMLAttributes<HTMLSelectElement> {
  label?: string;
  error?: boolean;
  helperText?: string;
}

const Select = forwardRef<HTMLSelectElement, SelectProps>(
  ({ className, label, error, helperText, id, children, ...props }, ref) => {
    const selectId = id || label?.toLowerCase().replace(/\s+/g, '-');
    const helperId = helperText ? `${selectId}-helper` : undefined;

    return (
      <div className="w-full">
        {label && (
          <label
            htmlFor={selectId}
            className="block text-sm font-medium text-secondary-700 mb-1.5"
          >
            {label}
          </label>
        )}
        <div className="relative">
          <select
            ref={ref}
            id={selectId}
            aria-invalid={error ? 'true' : undefined}
            aria-describedby={helperId}
            className={cn(
              'w-full appearance-none rounded-lg border border-secondary-300 bg-surface px-4 py-2.5 pr-10 text-sm text-secondary-900',
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
        </div>
        {helperText && (
          <p id={helperId} className={cn(
            'mt-1.5 text-xs',
            error ? 'text-error-600' : 'text-secondary-500'
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

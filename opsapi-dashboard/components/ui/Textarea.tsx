'use client';

import React from 'react';
import { cn } from '@/lib/utils';

export interface TextareaProps extends React.TextareaHTMLAttributes<HTMLTextAreaElement> {
  label?: string;
  error?: string;
  helperText?: string;
}

const Textarea = React.forwardRef<HTMLTextAreaElement, TextareaProps>(
  ({ className, label, error, helperText, id, rows = 4, ...props }, ref) => {
    const textareaId = id || label?.toLowerCase().replace(/\s+/g, '-');

    return (
      <div className="w-full">
        {label && (
          <label
            htmlFor={textareaId}
            className="block text-sm font-medium text-secondary-700 mb-1.5"
          >
            {label}
          </label>
        )}
        <textarea
          ref={ref}
          id={textareaId}
          rows={rows}
          className={cn(
            'w-full px-4 py-2.5 rounded-lg border text-sm transition-all duration-200',
            'bg-white text-secondary-900 placeholder:text-secondary-400',
            'focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500',
            'disabled:bg-secondary-50 disabled:text-secondary-500 disabled:cursor-not-allowed',
            'resize-y min-h-[80px]',
            error
              ? 'border-error-500 focus:ring-error-500/20 focus:border-error-500'
              : 'border-secondary-300 hover:border-secondary-400',
            className
          )}
          {...props}
        />
        {error && <p className="mt-1.5 text-sm text-error-500">{error}</p>}
        {helperText && !error && (
          <p className="mt-1.5 text-sm text-secondary-500">{helperText}</p>
        )}
      </div>
    );
  }
);

Textarea.displayName = 'Textarea';

export default Textarea;

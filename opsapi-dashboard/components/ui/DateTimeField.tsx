'use client';

import React, { useRef } from 'react';
import { CalendarClock, CalendarDays } from 'lucide-react';
import Input, { type InputProps } from './Input';

export interface DateTimeFieldProps extends Omit<InputProps, 'type' | 'rightIcon'> {
  /** 'datetime' → date + time (default); 'date' → date only. */
  mode?: 'datetime' | 'date';
}

/**
 * A polished date / time field. It keeps the native picker — localized,
 * accessible and mobile-friendly — but replaces the browser's faint default
 * indicator with a branded calendar icon, and opens the picker when the icon is
 * clicked (showPicker where supported). The date segments still accept typing.
 */
export const DateTimeField = React.forwardRef<HTMLInputElement, DateTimeFieldProps>(
  ({ mode = 'datetime', className, ...props }, ref) => {
    const innerRef = useRef<HTMLInputElement | null>(null);
    const attach = (el: HTMLInputElement | null) => {
      innerRef.current = el;
      if (typeof ref === 'function') ref(el);
      else if (ref) (ref as React.MutableRefObject<HTMLInputElement | null>).current = el;
    };
    const open = () => {
      // showPicker needs a user gesture + a modern browser; harmless if absent.
      try {
        innerRef.current?.showPicker?.();
      } catch {
        /* not permitted — the field still focuses/types normally */
      }
    };
    const Icon = mode === 'date' ? CalendarDays : CalendarClock;
    return (
      <Input
        ref={attach}
        type={mode === 'date' ? 'date' : 'datetime-local'}
        className={['fs-datetime', className].filter(Boolean).join(' ')}
        rightIcon={
          <button
            type="button"
            tabIndex={-1}
            onClick={open}
            aria-label="Open calendar"
            className="pointer-events-auto -m-1 p-1 text-secondary-400 hover:text-primary-600 transition-colors"
          >
            <Icon className="w-4 h-4" />
          </button>
        }
        {...props}
      />
    );
  }
);

DateTimeField.displayName = 'DateTimeField';
export default DateTimeField;

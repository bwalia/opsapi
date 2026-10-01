import React from 'react';

/** A compact on/off switch (role="switch"). Give it an aria-label when no visible label names it. */
const Switch: React.FC<{
  checked: boolean;
  onChange: (v: boolean) => void;
  disabled?: boolean;
  'aria-label'?: string;
}> = ({ checked, onChange, disabled, 'aria-label': ariaLabel }) => (
  <button
    type="button"
    role="switch"
    aria-checked={checked}
    aria-label={ariaLabel}
    disabled={disabled}
    onClick={() => onChange(!checked)}
    className={`relative inline-flex h-6 w-11 shrink-0 cursor-pointer items-center rounded-full transition-colors focus:outline-none focus:ring-2 focus:ring-primary-500/30 disabled:cursor-not-allowed disabled:opacity-50 ${checked ? 'bg-primary-600' : 'bg-secondary-300'}`}
  >
    <span className={`inline-block h-5 w-5 transform rounded-full bg-white shadow transition-transform ${checked ? 'translate-x-5' : 'translate-x-0.5'}`} />
  </button>
);

export default Switch;

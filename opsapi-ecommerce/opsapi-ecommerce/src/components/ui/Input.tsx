import React from "react";

export interface InputProps
  extends React.InputHTMLAttributes<HTMLInputElement> {
  error?: boolean;
  helperText?: string;
}

const Input = React.forwardRef<HTMLInputElement, InputProps>(
  ({ className = "", type, error, helperText, ...props }, ref) => {
    const inputClasses = `flex h-10 w-full rounded-md border px-3 py-2 text-sm bg-white placeholder:text-gray-500 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-50 ${
      error
        ? "border-red-500 focus-visible:ring-red-500"
        : "border-gray-300 focus-visible:ring-primary"
    } ${className}`;

    return (
      <div className="w-full">
        <input type={type} className={inputClasses} ref={ref} {...props} />
        {helperText && (
          <p
            className={`mt-1 text-xs ${
              error ? "text-red-600" : "text-gray-500"
            }`}
          >
            {helperText}
          </p>
        )}
      </div>
    );
  }
);

Input.displayName = "Input";

export { Input };

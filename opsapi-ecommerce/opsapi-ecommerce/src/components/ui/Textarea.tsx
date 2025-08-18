import React from "react";

export interface TextareaProps
  extends React.TextareaHTMLAttributes<HTMLTextAreaElement> {
  error?: boolean;
  helperText?: string;
}

const Textarea = React.forwardRef<HTMLTextAreaElement, TextareaProps>(
  ({ className = "", error, helperText, ...props }, ref) => {
    const textareaClasses = `flex min-h-[80px] w-full rounded-md border px-3 py-2 text-sm bg-white placeholder:text-gray-500 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-50 ${
      error
        ? "border-red-500 focus-visible:ring-red-500"
        : "border-gray-300 focus-visible:ring-primary"
    } ${className}`;

    return (
      <div className="w-full">
        <textarea className={textareaClasses} ref={ref} {...props} />
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

Textarea.displayName = "Textarea";

export { Textarea };

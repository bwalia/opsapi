import React from 'react';

/**
 * Shared page header for dashboard pages — a consistent, modern title block:
 * optional accent icon, larger title, muted description, and a right-aligned
 * actions slot. Uses semantic tokens, so it's dark-aware for free; the page's
 * entrance motion is handled globally by app/dashboard/template.tsx.
 */
export function PageHeader({
  title,
  description,
  actions,
  icon,
}: {
  title: string;
  description?: string;
  actions?: React.ReactNode;
  icon?: React.ReactNode;
}) {
  return (
    <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
      <div className="flex items-start gap-3.5">
        {icon && (
          <span className="mt-0.5 flex h-11 w-11 shrink-0 items-center justify-center rounded-xl bg-primary-500/10 text-primary-500">
            {icon}
          </span>
        )}
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-secondary-900 sm:text-3xl">{title}</h1>
          {description && <p className="mt-1 text-secondary-500">{description}</p>}
        </div>
      </div>
      {actions && <div className="flex shrink-0 items-center gap-2">{actions}</div>}
    </div>
  );
}

export default PageHeader;

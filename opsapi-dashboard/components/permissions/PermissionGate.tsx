'use client';

import React, { memo, ReactNode } from 'react';
import { useRouter } from 'next/navigation';
import { usePermissions } from '@/contexts/PermissionsContext';
import type { DashboardModule, NamespaceModule, PermissionAction } from '@/types';
import { Lock, ShieldOff, ArrowLeft } from 'lucide-react';

interface PermissionGateProps {
  module: DashboardModule | NamespaceModule;
  action?: PermissionAction;
  children: ReactNode;
  fallback?: ReactNode;
  showLocked?: boolean;
}

/**
 * Permission gate component that conditionally renders children based on permissions
 */
const PermissionGate: React.FC<PermissionGateProps> = memo(function PermissionGate({
  module,
  action,
  children,
  fallback,
  showLocked = false,
}) {
  const { hasPermission, canAccess, isLoading } = usePermissions();

  // While loading, show nothing or a skeleton
  if (isLoading) {
    return null;
  }

  // Check permission
  const hasAccess = action ? hasPermission(module, action) : canAccess(module);

  if (hasAccess) {
    return <>{children}</>;
  }

  // Show fallback if provided
  if (fallback) {
    return <>{fallback}</>;
  }

  // Show locked indicator if enabled
  if (showLocked) {
    return (
      <div className="flex items-center justify-center p-4 bg-secondary-50 rounded-lg border border-secondary-200">
        <Lock className="w-5 h-5 text-secondary-400 mr-2" />
        <span className="text-sm text-secondary-500">Access Restricted</span>
      </div>
    );
  }

  return null;
});

/**
 * Require specific permission to render children
 */
export const RequirePermission: React.FC<{
  module: DashboardModule;
  action: PermissionAction;
  children: ReactNode;
}> = memo(function RequirePermission({ module, action, children }) {
  return (
    <PermissionGate module={module} action={action}>
      {children}
    </PermissionGate>
  );
});

/**
 * Require create permission
 */
export const RequireCreate: React.FC<{
  module: DashboardModule;
  children: ReactNode;
}> = memo(function RequireCreate({ module, children }) {
  return (
    <PermissionGate module={module} action="create">
      {children}
    </PermissionGate>
  );
});

/**
 * Require update permission
 */
export const RequireUpdate: React.FC<{
  module: DashboardModule;
  children: ReactNode;
}> = memo(function RequireUpdate({ module, children }) {
  return (
    <PermissionGate module={module} action="update">
      {children}
    </PermissionGate>
  );
});

/**
 * Require delete permission
 */
export const RequireDelete: React.FC<{
  module: DashboardModule;
  children: ReactNode;
}> = memo(function RequireDelete({ module, children }) {
  return (
    <PermissionGate module={module} action="delete">
      {children}
    </PermissionGate>
  );
});

/**
 * Require admin role
 */
export const RequireAdmin: React.FC<{
  children: ReactNode;
  fallback?: ReactNode;
}> = memo(function RequireAdmin({ children, fallback }) {
  const { isAdmin, isLoading } = usePermissions();

  if (isLoading) {
    return null;
  }

  if (isAdmin) {
    return <>{children}</>;
  }

  return fallback ? <>{fallback}</> : null;
});

/**
 * Access Denied page component - shown when user lacks permission to view a page
 */
export const AccessDenied: React.FC<{
  title?: string;
  message?: string;
}> = memo(function AccessDenied({
  title = 'Access Denied',
  message = "You don't have permission to access this page.",
}) {
  const router = useRouter();

  return (
    <div className="min-h-[400px] flex items-center justify-center p-8">
      <div className="text-center max-w-md">
        <div className="w-16 h-16 mx-auto mb-6 bg-error-100 rounded-full flex items-center justify-center">
          <ShieldOff className="w-8 h-8 text-error-600" />
        </div>
        <h2 className="text-xl font-semibold text-secondary-900 mb-2">{title}</h2>
        <p className="text-secondary-600 mb-6">{message}</p>
        <button
          onClick={() => router.push('/dashboard')}
          className="inline-flex items-center gap-2 px-4 py-2 bg-primary-500 text-white rounded-lg hover:bg-primary-600 transition-colors"
        >
          <ArrowLeft className="w-4 h-4" />
          Back to Dashboard
        </button>
      </div>
    </div>
  );
});

/**
 * Protected page wrapper - redirects/shows access denied if user lacks module access
 */
export const ProtectedPage: React.FC<{
  module: DashboardModule | NamespaceModule;
  action?: PermissionAction;
  children: ReactNode;
  title?: string;
}> = memo(function ProtectedPage({ module, action, children, title }) {
  const { hasPermission, canAccess, isLoading } = usePermissions();

  // Show loading skeleton while checking permissions
  if (isLoading) {
    return (
      <div className="animate-pulse space-y-4 p-6">
        <div className="h-8 bg-secondary-200 rounded w-1/4"></div>
        <div className="h-4 bg-secondary-200 rounded w-1/2"></div>
        <div className="h-64 bg-secondary-200 rounded"></div>
      </div>
    );
  }

  // Check permission
  const hasAccess = action ? hasPermission(module, action) : canAccess(module);

  if (!hasAccess) {
    return (
      <AccessDenied
        title={title ? `Cannot Access ${title}` : undefined}
        message={`You don't have permission to access the ${module} module. Contact your administrator to request access.`}
      />
    );
  }

  return <>{children}</>;
});

export default PermissionGate;

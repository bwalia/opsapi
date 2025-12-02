'use client';

import React, { memo, ReactNode } from 'react';
import { usePermissions } from '@/contexts/PermissionsContext';
import type { DashboardModule, PermissionAction } from '@/types';
import { Lock } from 'lucide-react';

interface PermissionGateProps {
  module: DashboardModule;
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

export default PermissionGate;

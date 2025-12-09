'use client';

import React, { memo } from 'react';
import { Shield, Check } from 'lucide-react';
import { Card } from '@/components/ui';
import { RoleBadge } from '@/components/permissions';
import { cn } from '@/lib/utils';
import type { User, Role } from '@/types';

export interface UserRolesCardProps {
  user: User;
  isLoading?: boolean;
}

interface RolePermission {
  name: string;
  description: string;
}

const ROLE_DESCRIPTIONS: Record<string, { description: string; permissions: string[] }> = {
  administrative: {
    description: 'Full system access with all permissions',
    permissions: ['Manage Users', 'Manage Roles', 'Manage Namespaces', 'System Settings', 'View Analytics'],
  },
  admin: {
    description: 'Full system access with all permissions',
    permissions: ['Manage Users', 'Manage Roles', 'Manage Namespaces', 'System Settings', 'View Analytics'],
  },
  seller: {
    description: 'Can manage stores, products, and orders',
    permissions: ['Manage Products', 'View Orders', 'Manage Store', 'View Analytics'],
  },
  buyer: {
    description: 'Can browse and purchase products',
    permissions: ['View Products', 'Place Orders', 'Manage Profile'],
  },
  delivery_partner: {
    description: 'Can manage and fulfill deliveries',
    permissions: ['View Assigned Orders', 'Update Delivery Status', 'View Routes'],
  },
};

const UserRolesCard: React.FC<UserRolesCardProps> = memo(function UserRolesCard({
  user,
  isLoading,
}) {
  if (isLoading) {
    return (
      <Card className="p-6 animate-pulse">
        <div className="h-5 bg-secondary-200 rounded w-32 mb-6" />
        <div className="space-y-4">
          <div className="h-10 bg-secondary-200 rounded" />
          <div className="h-24 bg-secondary-200 rounded" />
        </div>
      </Card>
    );
  }

  const roles = user.roles || [];

  if (roles.length === 0) {
    return (
      <Card className="p-6">
        <h3 className="text-sm font-semibold text-secondary-500 uppercase tracking-wider mb-4">
          Platform Roles
        </h3>
        <div className="text-center py-6 text-secondary-500">
          <Shield className="w-10 h-10 mx-auto mb-2 text-secondary-300" />
          <p className="text-sm">No roles assigned</p>
        </div>
      </Card>
    );
  }

  return (
    <Card className="p-6">
      <h3 className="text-sm font-semibold text-secondary-500 uppercase tracking-wider mb-4">
        Platform Roles
      </h3>

      <div className="space-y-4">
        {roles.map((role, index) => {
          const roleName = role.role_name || role.name || 'user';
          const roleInfo = ROLE_DESCRIPTIONS[roleName.toLowerCase()] || {
            description: 'Standard user permissions',
            permissions: ['Basic Access'],
          };

          return (
            <div
              key={role.id || index}
              className={cn(
                'p-4 rounded-lg border',
                index === 0
                  ? 'bg-primary-50 border-primary-200'
                  : 'bg-secondary-50 border-secondary-200'
              )}
            >
              <div className="flex items-center gap-2 mb-2">
                <RoleBadge roleName={roleName} size="sm" />
                {index === 0 && (
                  <span className="text-xs text-primary-600 font-medium">Primary</span>
                )}
              </div>
              <p className="text-sm text-secondary-600 mb-3">{roleInfo.description}</p>
              <div className="flex flex-wrap gap-2">
                {roleInfo.permissions.map((permission, permIndex) => (
                  <span
                    key={permIndex}
                    className="inline-flex items-center gap-1 text-xs px-2 py-1 bg-white rounded-md border border-secondary-200 text-secondary-600"
                  >
                    <Check className="w-3 h-3 text-success-500" />
                    {permission}
                  </span>
                ))}
              </div>
            </div>
          );
        })}
      </div>
    </Card>
  );
});

export default UserRolesCard;

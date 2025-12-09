'use client';

import React, { memo } from 'react';
import { ArrowLeft, Edit, Mail, Shield, MoreVertical } from 'lucide-react';
import { Button, Badge } from '@/components/ui';
import { RoleBadge } from '@/components/permissions';
import { cn, getInitials, getFullName } from '@/lib/utils';
import Link from 'next/link';
import type { User } from '@/types';

export interface UserHeaderProps {
  user: User;
  onEdit?: () => void;
  isLoading?: boolean;
}

const UserHeader: React.FC<UserHeaderProps> = memo(function UserHeader({
  user,
  onEdit,
  isLoading,
}) {
  const primaryRole = user.roles?.[0]?.role_name || user.roles?.[0]?.name || 'user';

  if (isLoading) {
    return (
      <div className="bg-white rounded-xl border border-secondary-200 p-6 animate-pulse">
        <div className="flex items-center gap-4">
          <div className="w-20 h-20 rounded-xl bg-secondary-200" />
          <div className="flex-1 space-y-2">
            <div className="h-6 bg-secondary-200 rounded w-48" />
            <div className="h-4 bg-secondary-200 rounded w-32" />
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="bg-white rounded-xl border border-secondary-200 overflow-hidden">
      {/* Banner */}
      <div className="h-24 bg-gradient-to-r from-primary-500 to-primary-600" />

      {/* Content */}
      <div className="px-6 pb-6">
        {/* Avatar and actions row */}
        <div className="flex items-start justify-between -mt-10">
          <div className="flex items-end gap-4">
            {/* Avatar */}
            <div className="w-20 h-20 rounded-xl bg-white border-4 border-white shadow-md flex items-center justify-center overflow-hidden">
              <div className="w-full h-full gradient-primary flex items-center justify-center text-white font-bold text-2xl">
                {getInitials(user.first_name, user.last_name)}
              </div>
            </div>
          </div>

          {/* Actions */}
          <div className="flex items-center gap-2 pt-12">
            <Link href="/dashboard/users">
              <Button variant="ghost" size="sm" leftIcon={<ArrowLeft className="w-4 h-4" />}>
                Back to Users
              </Button>
            </Link>
            {onEdit && (
              <Button
                variant="outline"
                size="sm"
                leftIcon={<Edit className="w-4 h-4" />}
                onClick={onEdit}
              >
                Edit
              </Button>
            )}
          </div>
        </div>

        {/* User Info */}
        <div className="mt-4">
          <div className="flex items-center gap-3 flex-wrap">
            <h1 className="text-2xl font-bold text-secondary-900">
              {getFullName(user.first_name, user.last_name)}
            </h1>
            <RoleBadge roleName={primaryRole} size="sm" />
            <Badge size="sm" status={user.active ? 'active' : 'inactive'} />
          </div>
          <p className="text-sm text-secondary-500 mt-1">@{user.username}</p>
          <div className="flex items-center gap-2 mt-3 text-secondary-600">
            <Mail className="w-4 h-4 text-secondary-400" />
            <a href={`mailto:${user.email}`} className="hover:text-primary-600 transition-colors">
              {user.email}
            </a>
          </div>
        </div>
      </div>
    </div>
  );
});

export default UserHeader;

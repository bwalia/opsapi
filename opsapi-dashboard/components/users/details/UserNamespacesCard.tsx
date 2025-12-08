'use client';

import React, { memo } from 'react';
import { Building2, Crown, ExternalLink } from 'lucide-react';
import { Card, Badge } from '@/components/ui';
import { formatDate } from '@/lib/utils';
import Link from 'next/link';
import type { User } from '@/types';

export interface UserNamespacesCardProps {
  user: User;
  isLoading?: boolean;
}

interface NamespaceMembership {
  membership_id: number;
  membership_status: string;
  is_owner: boolean;
  joined_at: string;
  namespace_id: number;
  namespace_uuid: string;
  namespace_name: string;
  namespace_slug: string;
  namespace_logo?: string;
  namespace_status: string;
  roles?: Array<{
    id: number;
    role_name: string;
    display_name?: string;
  }>;
}

const UserNamespacesCard: React.FC<UserNamespacesCardProps> = memo(function UserNamespacesCard({
  user,
  isLoading,
}) {
  const namespaces = (user as User & { namespaces?: NamespaceMembership[] }).namespaces || [];

  if (isLoading) {
    return (
      <Card className="p-6 animate-pulse">
        <div className="h-5 bg-secondary-200 rounded w-40 mb-6" />
        <div className="space-y-4">
          {[1, 2].map((i) => (
            <div key={i} className="flex items-center gap-3 p-4 bg-secondary-50 rounded-lg">
              <div className="w-10 h-10 rounded-lg bg-secondary-200" />
              <div className="flex-1 space-y-2">
                <div className="h-4 bg-secondary-200 rounded w-32" />
                <div className="h-3 bg-secondary-200 rounded w-24" />
              </div>
            </div>
          ))}
        </div>
      </Card>
    );
  }

  if (namespaces.length === 0) {
    return (
      <Card className="p-6">
        <h3 className="text-sm font-semibold text-secondary-500 uppercase tracking-wider mb-4">
          Namespace Memberships
        </h3>
        <div className="text-center py-6 text-secondary-500">
          <Building2 className="w-10 h-10 mx-auto mb-2 text-secondary-300" />
          <p className="text-sm">Not a member of any namespace</p>
        </div>
      </Card>
    );
  }

  return (
    <Card className="p-6">
      <div className="flex items-center justify-between mb-4">
        <h3 className="text-sm font-semibold text-secondary-500 uppercase tracking-wider">
          Namespace Memberships
        </h3>
        <span className="text-xs text-secondary-400">{namespaces.length} namespace(s)</span>
      </div>

      <div className="space-y-3">
        {namespaces.map((ns) => (
          <Link
            key={ns.namespace_uuid}
            href={`/dashboard/namespaces/${ns.namespace_uuid}`}
            className="flex items-center gap-3 p-4 bg-secondary-50 hover:bg-secondary-100 rounded-lg border border-secondary-100 transition-colors group"
          >
            {/* Logo */}
            <div className="w-10 h-10 rounded-lg bg-white border border-secondary-200 flex items-center justify-center flex-shrink-0 overflow-hidden">
              {ns.namespace_logo ? (
                <img
                  src={ns.namespace_logo}
                  alt={ns.namespace_name}
                  className="w-full h-full object-cover"
                />
              ) : (
                <Building2 className="w-5 h-5 text-secondary-400" />
              )}
            </div>

            {/* Info */}
            <div className="flex-1 min-w-0">
              <div className="flex items-center gap-2">
                <span className="font-medium text-secondary-900 truncate group-hover:text-primary-600 transition-colors">
                  {ns.namespace_name}
                </span>
                {ns.is_owner && (
                  <span title="Owner">
                    <Crown className="w-4 h-4 text-warning-500" />
                  </span>
                )}
              </div>
              <div className="flex items-center gap-2 mt-0.5">
                <span className="text-xs text-secondary-500">@{ns.namespace_slug}</span>
                {ns.roles && ns.roles.length > 0 && (
                  <>
                    <span className="text-secondary-300">|</span>
                    <span className="text-xs text-secondary-500">
                      {ns.roles.map(r => r.display_name || r.role_name).join(', ')}
                    </span>
                  </>
                )}
              </div>
            </div>

            {/* Status & Arrow */}
            <div className="flex items-center gap-2">
              <Badge
                size="sm"
                status={ns.membership_status === 'active' ? 'active' : 'inactive'}
              />
              <ExternalLink className="w-4 h-4 text-secondary-400 opacity-0 group-hover:opacity-100 transition-opacity" />
            </div>
          </Link>
        ))}
      </div>
    </Card>
  );
});

export default UserNamespacesCard;

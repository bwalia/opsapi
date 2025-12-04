'use client';

import React, { memo, useState, useCallback, useEffect } from 'react';
import { Users, Crown, Shield, MoreVertical, UserPlus, Search, ChevronRight } from 'lucide-react';
import { Card, Button, Badge, Input } from '@/components/ui';
import { cn } from '@/lib/utils';
import Link from 'next/link';
import type { NamespaceMember, Namespace, NamespaceMemberStatus } from '@/types';
import { namespaceService } from '@/services';

export interface NamespaceMembersCardProps {
  namespace: Namespace;
  onInviteMember?: () => void;
  maxDisplay?: number;
}

const STATUS_CONFIG: Record<NamespaceMemberStatus, { variant: 'success' | 'warning' | 'error' | 'default'; label: string }> = {
  active: { variant: 'success', label: 'Active' },
  invited: { variant: 'warning', label: 'Invited' },
  suspended: { variant: 'error', label: 'Suspended' },
  removed: { variant: 'default', label: 'Removed' },
};

interface MemberRowProps {
  member: NamespaceMember;
  onAction?: (action: string, member: NamespaceMember) => void;
}

const MemberRow: React.FC<MemberRowProps> = memo(function MemberRow({ member, onAction }) {
  const statusConfig = STATUS_CONFIG[member.status] || STATUS_CONFIG.active;
  const displayName = member.user?.full_name ||
    `${member.user?.first_name || ''} ${member.user?.last_name || ''}`.trim() ||
    member.user?.email ||
    'Unknown';

  const initials = displayName
    .split(' ')
    .map((n) => n[0])
    .slice(0, 2)
    .join('')
    .toUpperCase();

  return (
    <div className="flex items-center justify-between py-3 border-b border-secondary-100 last:border-b-0">
      <div className="flex items-center gap-3">
        {/* Avatar */}
        <div className="w-9 h-9 rounded-full bg-primary-100 flex items-center justify-center text-primary-700 text-sm font-medium">
          {initials || '?'}
        </div>

        {/* Info */}
        <div>
          <div className="flex items-center gap-2">
            <span className="font-medium text-secondary-900 text-sm">{displayName}</span>
            {member.is_owner && (
              <span title="Owner">
                <Crown className="w-3.5 h-3.5 text-warning-500" />
              </span>
            )}
          </div>
          <p className="text-xs text-secondary-500">{member.user?.email}</p>
        </div>
      </div>

      <div className="flex items-center gap-3">
        {/* Roles */}
        {member.roles && member.roles.length > 0 && (
          <div className="flex items-center gap-1">
            {member.roles.slice(0, 2).map((role) => (
              <span
                key={role.uuid}
                className="text-xs bg-secondary-100 text-secondary-600 px-2 py-0.5 rounded"
              >
                {role.display_name}
              </span>
            ))}
            {member.roles.length > 2 && (
              <span className="text-xs text-secondary-400">+{member.roles.length - 2}</span>
            )}
          </div>
        )}

        {/* Status */}
        <Badge variant={statusConfig.variant} size="sm">
          {statusConfig.label}
        </Badge>
      </div>
    </div>
  );
});

const LoadingSkeleton = memo(function LoadingSkeleton() {
  return (
    <Card className="p-6">
      <div className="animate-pulse space-y-4">
        <div className="flex items-center justify-between">
          <div className="h-5 bg-secondary-200 rounded w-24" />
          <div className="h-8 bg-secondary-200 rounded w-28" />
        </div>
        {[1, 2, 3].map((i) => (
          <div key={i} className="flex items-center gap-3 py-3">
            <div className="w-9 h-9 rounded-full bg-secondary-200" />
            <div className="flex-1 space-y-2">
              <div className="h-4 bg-secondary-200 rounded w-32" />
              <div className="h-3 bg-secondary-200 rounded w-48" />
            </div>
          </div>
        ))}
      </div>
    </Card>
  );
});

const NamespaceMembersCard: React.FC<NamespaceMembersCardProps> = memo(function NamespaceMembersCard({
  namespace,
  onInviteMember,
  maxDisplay = 5,
}) {
  const [members, setMembers] = useState<NamespaceMember[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [totalMembers, setTotalMembers] = useState(0);

  const fetchMembers = useCallback(async () => {
    setIsLoading(true);
    try {
      // Note: This would need the namespace context to be set
      // For admin view, we might need a different endpoint
      const response = await namespaceService.getMembers({
        perPage: maxDisplay,
        page: 1
      });
      setMembers(response.data || []);
      setTotalMembers(response.total || 0);
    } catch (error) {
      console.error('Failed to fetch members:', error);
      setMembers([]);
    } finally {
      setIsLoading(false);
    }
  }, [maxDisplay]);

  useEffect(() => {
    fetchMembers();
  }, [fetchMembers]);

  if (isLoading) {
    return <LoadingSkeleton />;
  }

  return (
    <Card className="p-6">
      <div className="flex items-center justify-between mb-4">
        <div className="flex items-center gap-2">
          <Users className="w-5 h-5 text-secondary-500" />
          <h2 className="text-lg font-semibold text-secondary-900">Members</h2>
          <span className="text-sm text-secondary-500">({totalMembers})</span>
        </div>
        {onInviteMember && (
          <Button
            variant="outline"
            size="sm"
            leftIcon={<UserPlus className="w-4 h-4" />}
            onClick={onInviteMember}
          >
            Invite
          </Button>
        )}
      </div>

      {members.length === 0 ? (
        <div className="text-center py-8">
          <Users className="w-12 h-12 text-secondary-300 mx-auto mb-3" />
          <p className="text-secondary-500 text-sm">No members found</p>
          {onInviteMember && (
            <Button
              variant="primary"
              size="sm"
              className="mt-3"
              leftIcon={<UserPlus className="w-4 h-4" />}
              onClick={onInviteMember}
            >
              Invite Members
            </Button>
          )}
        </div>
      ) : (
        <>
          <div className="divide-y divide-secondary-100">
            {members.map((member) => (
              <MemberRow key={member.uuid} member={member} />
            ))}
          </div>

          {totalMembers > maxDisplay && (
            <div className="mt-4 pt-4 border-t border-secondary-100">
              <Link
                href={`/dashboard/namespaces/${namespace.uuid}/members`}
                className="flex items-center justify-center gap-1 text-sm text-primary-600 hover:text-primary-700 font-medium"
              >
                View all {totalMembers} members
                <ChevronRight className="w-4 h-4" />
              </Link>
            </div>
          )}
        </>
      )}
    </Card>
  );
});

export default NamespaceMembersCard;

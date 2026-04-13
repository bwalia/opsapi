'use client';

import React, { memo } from 'react';
import { Crown, Shield, Clock, MoreVertical, Mail } from 'lucide-react';
import { Card, Button, Badge } from '@/components/ui';
import type { NamespaceMember, NamespaceRole } from '@/types';

interface MembersTableProps {
  members: NamespaceMember[];
  isLoading?: boolean;
  onMemberAction?: (action: string, member: NamespaceMember) => void;
  currentUserUuid?: string;
  isOwner?: boolean;
}

const StatusBadge = memo(function StatusBadge({ status }: { status: string }) {
  const variants: Record<string, 'success' | 'warning' | 'error' | 'secondary'> = {
    active: 'success',
    invited: 'warning',
    suspended: 'error',
    removed: 'secondary',
  };

  return (
    <Badge variant={variants[status] || 'secondary'} size="sm">
      {status.charAt(0).toUpperCase() + status.slice(1)}
    </Badge>
  );
});

const RoleBadges = memo(function RoleBadges({ roles }: { roles?: NamespaceRole[] }) {
  if (!roles || roles.length === 0) {
    return <span className="text-secondary-400 text-sm">No role assigned</span>;
  }

  return (
    <div className="flex flex-wrap gap-1">
      {roles.slice(0, 2).map((role) => (
        <Badge key={role.id} variant="secondary" size="sm">
          {role.display_name || role.role_name}
        </Badge>
      ))}
      {roles.length > 2 && (
        <Badge variant="secondary" size="sm">
          +{roles.length - 2}
        </Badge>
      )}
    </div>
  );
});

const MemberRow = memo(function MemberRow({
  member,
  onAction,
  isCurrentUser,
  canManage,
}: {
  member: NamespaceMember;
  onAction?: (action: string, member: NamespaceMember) => void;
  isCurrentUser: boolean;
  canManage: boolean;
}) {
  const user = member.user;
  const fullName = user?.full_name || `${user?.first_name || ''} ${user?.last_name || ''}`.trim();
  const initials = fullName
    ? fullName.split(' ').map(n => n[0]).join('').toUpperCase().slice(0, 2)
    : user?.email?.charAt(0).toUpperCase() || '?';

  return (
    <tr className="border-b border-secondary-100 hover:bg-secondary-50 transition-colors">
      {/* Member Info */}
      <td className="px-4 py-3">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 rounded-full bg-primary-100 flex items-center justify-center text-primary-600 font-medium text-sm">
            {initials}
          </div>
          <div className="min-w-0">
            <div className="flex items-center gap-2">
              <span className="font-medium text-secondary-900 truncate">
                {fullName || 'Unknown User'}
              </span>
              {member.is_owner && (
                <span title="Namespace Owner">
                  <Crown className="w-4 h-4 text-warning-500" />
                </span>
              )}
              {isCurrentUser && (
                <Badge variant="secondary" size="sm">You</Badge>
              )}
            </div>
            <p className="text-sm text-secondary-500 truncate">{user?.email || 'No email'}</p>
          </div>
        </div>
      </td>

      {/* Roles */}
      <td className="px-4 py-3">
        <RoleBadges roles={member.roles} />
      </td>

      {/* Status */}
      <td className="px-4 py-3">
        <StatusBadge status={member.status} />
      </td>

      {/* Joined */}
      <td className="px-4 py-3">
        <div className="flex items-center gap-1 text-sm text-secondary-500">
          <Clock className="w-3.5 h-3.5" />
          <span>
            {member.joined_at
              ? new Date(member.joined_at).toLocaleDateString()
              : member.status === 'invited'
                ? 'Pending'
                : '-'}
          </span>
        </div>
      </td>

      {/* Actions */}
      <td className="px-4 py-3">
        {canManage && !isCurrentUser && !member.is_owner && (
          <div className="flex items-center justify-end">
            <div className="relative group">
              <Button
                variant="ghost"
                size="sm"
                className="p-1"
                onClick={() => onAction?.('menu', member)}
              >
                <MoreVertical className="w-4 h-4" />
              </Button>
              {/* Dropdown menu would be handled by parent */}
            </div>
          </div>
        )}
      </td>
    </tr>
  );
});

const LoadingSkeleton = memo(function LoadingSkeleton() {
  return (
    <>
      {[1, 2, 3, 4, 5].map((i) => (
        <tr key={i} className="border-b border-secondary-100">
          <td className="px-4 py-3">
            <div className="flex items-center gap-3">
              <div className="w-10 h-10 rounded-full bg-secondary-200 animate-pulse" />
              <div className="space-y-2">
                <div className="h-4 w-32 bg-secondary-200 rounded animate-pulse" />
                <div className="h-3 w-40 bg-secondary-200 rounded animate-pulse" />
              </div>
            </div>
          </td>
          <td className="px-4 py-3">
            <div className="h-5 w-20 bg-secondary-200 rounded animate-pulse" />
          </td>
          <td className="px-4 py-3">
            <div className="h-5 w-16 bg-secondary-200 rounded animate-pulse" />
          </td>
          <td className="px-4 py-3">
            <div className="h-4 w-24 bg-secondary-200 rounded animate-pulse" />
          </td>
          <td className="px-4 py-3">
            <div className="h-6 w-6 bg-secondary-200 rounded animate-pulse" />
          </td>
        </tr>
      ))}
    </>
  );
});

const EmptyState = memo(function EmptyState() {
  return (
    <tr>
      <td colSpan={5} className="px-4 py-12 text-center">
        <div className="flex flex-col items-center">
          <Shield className="w-12 h-12 text-secondary-300 mb-3" />
          <h3 className="text-lg font-medium text-secondary-900 mb-1">No members found</h3>
          <p className="text-secondary-500">
            Invite team members to collaborate in this namespace.
          </p>
        </div>
      </td>
    </tr>
  );
});

export const MembersTable = memo(function MembersTable({
  members,
  isLoading = false,
  onMemberAction,
  currentUserUuid,
  isOwner = false,
}: MembersTableProps) {
  // Ensure members is always an array
  const safeMembers = Array.isArray(members) ? members : [];

  return (
    <Card className="overflow-hidden">
      <div className="overflow-x-auto">
        <table className="w-full">
          <thead>
            <tr className="bg-secondary-50 border-b border-secondary-100">
              <th className="px-4 py-3 text-left text-xs font-medium text-secondary-500 uppercase tracking-wider">
                Member
              </th>
              <th className="px-4 py-3 text-left text-xs font-medium text-secondary-500 uppercase tracking-wider">
                Roles
              </th>
              <th className="px-4 py-3 text-left text-xs font-medium text-secondary-500 uppercase tracking-wider">
                Status
              </th>
              <th className="px-4 py-3 text-left text-xs font-medium text-secondary-500 uppercase tracking-wider">
                Joined
              </th>
              <th className="px-4 py-3 text-right text-xs font-medium text-secondary-500 uppercase tracking-wider w-16">
                Actions
              </th>
            </tr>
          </thead>
          <tbody>
            {isLoading ? (
              <LoadingSkeleton />
            ) : safeMembers.length === 0 ? (
              <EmptyState />
            ) : (
              safeMembers.map((member) => (
                <MemberRow
                  key={member.id}
                  member={member}
                  onAction={onMemberAction}
                  isCurrentUser={member.user?.uuid === currentUserUuid}
                  canManage={isOwner}
                />
              ))
            )}
          </tbody>
        </table>
      </div>
    </Card>
  );
});

export default MembersTable;

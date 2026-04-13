'use client';

import React, { memo } from 'react';
import { Mail, Clock, RefreshCw, XCircle, MoreVertical, Send, AlertCircle } from 'lucide-react';
import { Card, Button, Badge } from '@/components/ui';
import type { NamespaceInvitation } from '@/types';

interface InvitationsTableProps {
  invitations: NamespaceInvitation[];
  isLoading?: boolean;
  onResend?: (invitation: NamespaceInvitation) => void;
  onRevoke?: (invitation: NamespaceInvitation) => void;
}

const StatusBadge = memo(function StatusBadge({ status }: { status: string }) {
  const config: Record<string, { variant: 'warning' | 'success' | 'error' | 'secondary'; label: string }> = {
    pending: { variant: 'warning', label: 'Pending' },
    accepted: { variant: 'success', label: 'Accepted' },
    declined: { variant: 'error', label: 'Declined' },
    expired: { variant: 'secondary', label: 'Expired' },
    revoked: { variant: 'secondary', label: 'Revoked' },
  };

  const { variant, label } = config[status] || { variant: 'secondary' as const, label: status };

  return (
    <Badge variant={variant} size="sm">
      {label}
    </Badge>
  );
});

const InvitationRow = memo(function InvitationRow({
  invitation,
  onResend,
  onRevoke,
}: {
  invitation: NamespaceInvitation;
  onResend?: (invitation: NamespaceInvitation) => void;
  onRevoke?: (invitation: NamespaceInvitation) => void;
}) {
  const isExpired = new Date(invitation.expires_at) < new Date();
  const canResend = invitation.status === 'pending' || invitation.status === 'expired';
  const canRevoke = invitation.status === 'pending';

  const formatDate = (dateString: string) => {
    const date = new Date(dateString);
    return date.toLocaleDateString(undefined, {
      month: 'short',
      day: 'numeric',
      year: 'numeric',
    });
  };

  const getTimeRemaining = (expiresAt: string) => {
    const now = new Date();
    const expires = new Date(expiresAt);
    const diff = expires.getTime() - now.getTime();

    if (diff <= 0) return 'Expired';

    const days = Math.floor(diff / (1000 * 60 * 60 * 24));
    const hours = Math.floor((diff % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60));

    if (days > 0) return `${days}d ${hours}h remaining`;
    if (hours > 0) return `${hours}h remaining`;
    return 'Expiring soon';
  };

  return (
    <tr className="border-b border-secondary-100 hover:bg-secondary-50 transition-colors">
      {/* Email */}
      <td className="px-4 py-3">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 rounded-full bg-secondary-100 flex items-center justify-center">
            <Mail className="w-5 h-5 text-secondary-500" />
          </div>
          <div className="min-w-0">
            <p className="font-medium text-secondary-900 truncate">{invitation.email}</p>
            {invitation.role && (
              <p className="text-sm text-secondary-500">
                Role: {invitation.role.display_name || invitation.role.role_name}
              </p>
            )}
          </div>
        </div>
      </td>

      {/* Status */}
      <td className="px-4 py-3">
        <StatusBadge status={isExpired && invitation.status === 'pending' ? 'expired' : invitation.status} />
      </td>

      {/* Invited By */}
      <td className="px-4 py-3">
        <span className="text-sm text-secondary-600">
          {invitation.inviter
            ? `${invitation.inviter.first_name || ''} ${invitation.inviter.last_name || ''}`.trim() || 'Unknown'
            : 'Unknown'}
        </span>
      </td>

      {/* Sent */}
      <td className="px-4 py-3">
        <div className="text-sm text-secondary-500">
          {formatDate(invitation.created_at)}
        </div>
      </td>

      {/* Expires */}
      <td className="px-4 py-3">
        <div className="flex items-center gap-1 text-sm">
          {invitation.status === 'pending' && !isExpired ? (
            <>
              <Clock className="w-3.5 h-3.5 text-secondary-400" />
              <span className={isExpired ? 'text-error-500' : 'text-secondary-500'}>
                {getTimeRemaining(invitation.expires_at)}
              </span>
            </>
          ) : invitation.status === 'accepted' ? (
            <span className="text-success-600">Accepted</span>
          ) : (
            <span className="text-secondary-400">-</span>
          )}
        </div>
      </td>

      {/* Actions */}
      <td className="px-4 py-3">
        <div className="flex items-center justify-end gap-1">
          {canResend && (
            <Button
              variant="ghost"
              size="sm"
              onClick={() => onResend?.(invitation)}
              className="p-1.5 h-auto"
              title="Resend invitation"
            >
              <RefreshCw className="w-4 h-4" />
            </Button>
          )}
          {canRevoke && (
            <Button
              variant="ghost"
              size="sm"
              onClick={() => onRevoke?.(invitation)}
              className="p-1.5 h-auto text-error-500 hover:text-error-600 hover:bg-error-50"
              title="Revoke invitation"
            >
              <XCircle className="w-4 h-4" />
            </Button>
          )}
        </div>
      </td>
    </tr>
  );
});

const LoadingSkeleton = memo(function LoadingSkeleton() {
  return (
    <>
      {[1, 2, 3].map((i) => (
        <tr key={i} className="border-b border-secondary-100">
          <td className="px-4 py-3">
            <div className="flex items-center gap-3">
              <div className="w-10 h-10 rounded-full bg-secondary-200 animate-pulse" />
              <div className="space-y-2">
                <div className="h-4 w-40 bg-secondary-200 rounded animate-pulse" />
                <div className="h-3 w-24 bg-secondary-200 rounded animate-pulse" />
              </div>
            </div>
          </td>
          <td className="px-4 py-3">
            <div className="h-5 w-16 bg-secondary-200 rounded animate-pulse" />
          </td>
          <td className="px-4 py-3">
            <div className="h-4 w-24 bg-secondary-200 rounded animate-pulse" />
          </td>
          <td className="px-4 py-3">
            <div className="h-4 w-20 bg-secondary-200 rounded animate-pulse" />
          </td>
          <td className="px-4 py-3">
            <div className="h-4 w-20 bg-secondary-200 rounded animate-pulse" />
          </td>
          <td className="px-4 py-3">
            <div className="h-6 w-12 bg-secondary-200 rounded animate-pulse" />
          </td>
        </tr>
      ))}
    </>
  );
});

const EmptyState = memo(function EmptyState() {
  return (
    <tr>
      <td colSpan={6} className="px-4 py-12 text-center">
        <div className="flex flex-col items-center">
          <Send className="w-12 h-12 text-secondary-300 mb-3" />
          <h3 className="text-lg font-medium text-secondary-900 mb-1">No pending invitations</h3>
          <p className="text-secondary-500">
            Invite team members to collaborate in this namespace.
          </p>
        </div>
      </td>
    </tr>
  );
});

export const InvitationsTable = memo(function InvitationsTable({
  invitations,
  isLoading = false,
  onResend,
  onRevoke,
}: InvitationsTableProps) {
  // Ensure invitations is always an array and filter to show only relevant ones
  const safeInvitations = Array.isArray(invitations) ? invitations : [];
  const filteredInvitations = safeInvitations.filter(
    (inv) => inv.status === 'pending' || inv.status === 'expired'
  );

  return (
    <Card className="overflow-hidden">
      <div className="px-4 py-3 border-b border-secondary-100 bg-secondary-50">
        <div className="flex items-center gap-2">
          <Send className="w-4 h-4 text-secondary-500" />
          <h3 className="font-medium text-secondary-900">Pending Invitations</h3>
          {filteredInvitations.length > 0 && (
            <Badge variant="secondary" size="sm">
              {filteredInvitations.length}
            </Badge>
          )}
        </div>
      </div>

      <div className="overflow-x-auto">
        <table className="w-full">
          <thead>
            <tr className="border-b border-secondary-100">
              <th className="px-4 py-3 text-left text-xs font-medium text-secondary-500 uppercase tracking-wider">
                Email
              </th>
              <th className="px-4 py-3 text-left text-xs font-medium text-secondary-500 uppercase tracking-wider">
                Status
              </th>
              <th className="px-4 py-3 text-left text-xs font-medium text-secondary-500 uppercase tracking-wider">
                Invited By
              </th>
              <th className="px-4 py-3 text-left text-xs font-medium text-secondary-500 uppercase tracking-wider">
                Sent
              </th>
              <th className="px-4 py-3 text-left text-xs font-medium text-secondary-500 uppercase tracking-wider">
                Expires
              </th>
              <th className="px-4 py-3 text-right text-xs font-medium text-secondary-500 uppercase tracking-wider w-24">
                Actions
              </th>
            </tr>
          </thead>
          <tbody>
            {isLoading ? (
              <LoadingSkeleton />
            ) : filteredInvitations.length === 0 ? (
              <EmptyState />
            ) : (
              filteredInvitations.map((invitation) => (
                <InvitationRow
                  key={invitation.id}
                  invitation={invitation}
                  onResend={onResend}
                  onRevoke={onRevoke}
                />
              ))
            )}
          </tbody>
        </table>
      </div>
    </Card>
  );
});

export default InvitationsTable;

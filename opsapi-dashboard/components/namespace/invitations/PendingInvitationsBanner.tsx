'use client';

import React, { memo, useState, useEffect, useCallback } from 'react';
import { Mail, Check, X, Clock, Building2, ChevronRight, Loader2 } from 'lucide-react';
import { Button, Badge } from '@/components/ui';
import { namespaceService } from '@/services';
import type { NamespaceInvitation } from '@/types';
import toast from 'react-hot-toast';
import { cn } from '@/lib/utils';

interface PendingInvitationsBannerProps {
  className?: string;
  onInvitationAccepted?: (invitation: NamespaceInvitation) => void;
}

export const PendingInvitationsBanner = memo(function PendingInvitationsBanner({
  className,
  onInvitationAccepted,
}: PendingInvitationsBannerProps) {
  const [invitations, setInvitations] = useState<NamespaceInvitation[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [processingId, setProcessingId] = useState<string | null>(null);
  const [expandedId, setExpandedId] = useState<string | null>(null);

  const fetchInvitations = useCallback(async () => {
    try {
      const data = await namespaceService.getMyPendingInvitations();
      setInvitations(Array.isArray(data) ? data : []);
    } catch (err) {
      console.error('Failed to fetch pending invitations:', err);
      setInvitations([]);
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchInvitations();
  }, [fetchInvitations]);

  const handleAccept = useCallback(async (invitation: NamespaceInvitation) => {
    if (!invitation.token) {
      toast.error('Invalid invitation');
      return;
    }

    setProcessingId(invitation.uuid || invitation.id?.toString() || null);
    try {
      await namespaceService.acceptInvitation(invitation.token);
      toast.success(`You've joined ${invitation.namespace?.name || 'the namespace'}!`);

      // Remove from list
      setInvitations(prev => prev.filter(inv => inv.id !== invitation.id));
      onInvitationAccepted?.(invitation);
    } catch (err) {
      const errorMessage = err instanceof Error ? err.message : 'Failed to accept invitation';
      toast.error(errorMessage);
    } finally {
      setProcessingId(null);
    }
  }, [onInvitationAccepted]);

  const handleDecline = useCallback(async (invitation: NamespaceInvitation) => {
    if (!invitation.token) {
      toast.error('Invalid invitation');
      return;
    }

    setProcessingId(invitation.uuid || invitation.id?.toString() || null);
    try {
      await namespaceService.declineInvitation(invitation.token);
      toast.success('Invitation declined');

      // Remove from list
      setInvitations(prev => prev.filter(inv => inv.id !== invitation.id));
    } catch (err) {
      const errorMessage = err instanceof Error ? err.message : 'Failed to decline invitation';
      toast.error(errorMessage);
    } finally {
      setProcessingId(null);
    }
  }, []);

  const getTimeRemaining = (expiresAt: string) => {
    const now = new Date();
    const expires = new Date(expiresAt);
    const diff = expires.getTime() - now.getTime();

    if (diff <= 0) return 'Expired';

    const days = Math.floor(diff / (1000 * 60 * 60 * 24));
    const hours = Math.floor((diff % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60));

    if (days > 0) return `${days}d ${hours}h left`;
    if (hours > 0) return `${hours}h left`;
    return 'Expiring soon';
  };

  if (isLoading) {
    return null; // Don't show loading state for banner
  }

  if (invitations.length === 0) {
    return null;
  }

  return (
    <div className={cn('space-y-3', className)}>
      {invitations.map((invitation) => {
        const isProcessing = processingId === (invitation.uuid || invitation.id?.toString());
        const isExpanded = expandedId === (invitation.uuid || invitation.id?.toString());
        const invitationKey = invitation.uuid || invitation.id?.toString() || '';

        return (
          <div
            key={invitationKey}
            className="bg-gradient-to-r from-primary-50 to-primary-100/50 border border-primary-200 rounded-lg overflow-hidden"
          >
            {/* Main Banner */}
            <div className="flex items-center gap-4 px-4 py-3">
              {/* Icon */}
              <div className="w-10 h-10 rounded-full bg-primary-100 flex items-center justify-center flex-shrink-0">
                <Mail className="w-5 h-5 text-primary-600" />
              </div>

              {/* Content */}
              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2">
                  <h4 className="font-medium text-secondary-900">
                    Invitation to join{' '}
                    <span className="text-primary-600">
                      {invitation.namespace?.name || 'a namespace'}
                    </span>
                  </h4>
                  <Badge variant="warning" size="sm">
                    <Clock className="w-3 h-3 mr-1" />
                    {getTimeRemaining(invitation.expires_at)}
                  </Badge>
                </div>
                <p className="text-sm text-secondary-600 mt-0.5">
                  {invitation.inviter?.name || invitation.inviter?.first_name || invitation.inviter?.last_name
                    ? `Invited by ${invitation.inviter.name || `${invitation.inviter.first_name || ''} ${invitation.inviter.last_name || ''}`.trim()}`
                    : 'You have been invited'}
                  {invitation.role && (
                    <> as <span className="font-medium">{invitation.role.display_name || invitation.role.role_name}</span></>
                  )}
                </p>
              </div>

              {/* Actions */}
              <div className="flex items-center gap-2">
                {invitation.message && (
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => setExpandedId(isExpanded ? null : invitationKey)}
                    className="text-secondary-500"
                  >
                    <ChevronRight className={cn(
                      'w-4 h-4 transition-transform',
                      isExpanded && 'rotate-90'
                    )} />
                  </Button>
                )}
                <Button
                  variant="outline"
                  size="sm"
                  onClick={() => handleDecline(invitation)}
                  disabled={isProcessing}
                  className="text-secondary-600 hover:text-error-600 hover:border-error-300"
                >
                  {isProcessing ? (
                    <Loader2 className="w-4 h-4 animate-spin" />
                  ) : (
                    <>
                      <X className="w-4 h-4 mr-1" />
                      Decline
                    </>
                  )}
                </Button>
                <Button
                  size="sm"
                  onClick={() => handleAccept(invitation)}
                  disabled={isProcessing}
                >
                  {isProcessing ? (
                    <Loader2 className="w-4 h-4 animate-spin" />
                  ) : (
                    <>
                      <Check className="w-4 h-4 mr-1" />
                      Accept
                    </>
                  )}
                </Button>
              </div>
            </div>

            {/* Expanded Message */}
            {isExpanded && invitation.message && (
              <div className="px-4 pb-3 pt-0">
                <div className="ml-14 p-3 bg-white/50 rounded-lg border border-primary-100">
                  <p className="text-sm text-secondary-600 italic">
                    "{invitation.message}"
                  </p>
                </div>
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
});

export default PendingInvitationsBanner;

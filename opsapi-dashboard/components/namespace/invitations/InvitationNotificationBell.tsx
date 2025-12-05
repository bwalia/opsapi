'use client';

import React, { memo, useState, useEffect, useCallback, useRef } from 'react';
import { Bell, Mail, Check, X, Clock, Building2, Loader2 } from 'lucide-react';
import { Button, Badge } from '@/components/ui';
import { namespaceService } from '@/services';
import type { NamespaceInvitation } from '@/types';
import toast from 'react-hot-toast';
import { cn } from '@/lib/utils';

interface InvitationNotificationBellProps {
  className?: string;
  onInvitationAccepted?: (invitation: NamespaceInvitation) => void;
}

export const InvitationNotificationBell = memo(function InvitationNotificationBell({
  className,
  onInvitationAccepted,
}: InvitationNotificationBellProps) {
  const [invitations, setInvitations] = useState<NamespaceInvitation[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [isOpen, setIsOpen] = useState(false);
  const [processingId, setProcessingId] = useState<string | null>(null);
  const dropdownRef = useRef<HTMLDivElement>(null);
  const buttonRef = useRef<HTMLButtonElement>(null);

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
    // Poll for new invitations every 60 seconds
    const interval = setInterval(fetchInvitations, 60000);
    return () => clearInterval(interval);
  }, [fetchInvitations]);

  // Close dropdown when clicking outside
  useEffect(() => {
    const handleClickOutside = (event: MouseEvent) => {
      if (
        dropdownRef.current &&
        !dropdownRef.current.contains(event.target as Node) &&
        buttonRef.current &&
        !buttonRef.current.contains(event.target as Node)
      ) {
        setIsOpen(false);
      }
    };

    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

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

      if (invitations.length <= 1) {
        setIsOpen(false);
      }
    } catch (err) {
      const errorMessage = err instanceof Error ? err.message : 'Failed to accept invitation';
      toast.error(errorMessage);
    } finally {
      setProcessingId(null);
    }
  }, [invitations.length, onInvitationAccepted]);

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

      if (invitations.length <= 1) {
        setIsOpen(false);
      }
    } catch (err) {
      const errorMessage = err instanceof Error ? err.message : 'Failed to decline invitation';
      toast.error(errorMessage);
    } finally {
      setProcessingId(null);
    }
  }, [invitations.length]);

  const getTimeRemaining = (expiresAt: string) => {
    const now = new Date();
    const expires = new Date(expiresAt);
    const diff = expires.getTime() - now.getTime();

    if (diff <= 0) return 'Expired';

    const days = Math.floor(diff / (1000 * 60 * 60 * 24));
    const hours = Math.floor((diff % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60));

    if (days > 0) return `${days}d left`;
    if (hours > 0) return `${hours}h left`;
    return 'Soon';
  };

  const pendingCount = invitations.length;

  return (
    <div className={cn('relative', className)}>
      {/* Bell Button */}
      <button
        ref={buttonRef}
        onClick={() => setIsOpen(!isOpen)}
        className={cn(
          'relative p-2 rounded-lg transition-colors',
          'hover:bg-secondary-100',
          isOpen && 'bg-secondary-100',
          pendingCount > 0 && 'text-primary-600'
        )}
        aria-label={`${pendingCount} pending invitations`}
      >
        <Bell className="w-5 h-5" />
        {pendingCount > 0 && (
          <span className="absolute -top-0.5 -right-0.5 w-5 h-5 bg-error-500 text-white text-xs font-bold rounded-full flex items-center justify-center">
            {pendingCount > 9 ? '9+' : pendingCount}
          </span>
        )}
      </button>

      {/* Dropdown */}
      {isOpen && (
        <div
          ref={dropdownRef}
          className="absolute right-0 mt-2 w-96 bg-white rounded-xl shadow-xl border border-secondary-200 overflow-hidden z-50"
        >
          {/* Header */}
          <div className="px-4 py-3 border-b border-secondary-100 bg-secondary-50">
            <div className="flex items-center justify-between">
              <h3 className="font-semibold text-secondary-900">
                Pending Invitations
              </h3>
              {pendingCount > 0 && (
                <Badge variant="info" size="sm">
                  {pendingCount}
                </Badge>
              )}
            </div>
          </div>

          {/* Content */}
          <div className="max-h-96 overflow-y-auto">
            {isLoading ? (
              <div className="flex items-center justify-center py-8">
                <Loader2 className="w-6 h-6 text-secondary-400 animate-spin" />
              </div>
            ) : invitations.length === 0 ? (
              <div className="flex flex-col items-center justify-center py-8 px-4">
                <div className="w-12 h-12 rounded-full bg-secondary-100 flex items-center justify-center mb-3">
                  <Mail className="w-6 h-6 text-secondary-400" />
                </div>
                <p className="text-secondary-600 text-center">
                  No pending invitations
                </p>
                <p className="text-sm text-secondary-400 text-center mt-1">
                  You'll see namespace invitations here
                </p>
              </div>
            ) : (
              <div className="divide-y divide-secondary-100">
                {invitations.map((invitation) => {
                  const isProcessing = processingId === (invitation.uuid || invitation.id?.toString());
                  const invitationKey = invitation.uuid || invitation.id?.toString() || '';

                  return (
                    <div key={invitationKey} className="p-4 hover:bg-secondary-50 transition-colors">
                      {/* Namespace Info */}
                      <div className="flex items-start gap-3 mb-3">
                        <div className="w-10 h-10 rounded-lg bg-primary-100 flex items-center justify-center flex-shrink-0">
                          {invitation.namespace?.logo_url ? (
                            <img
                              src={invitation.namespace.logo_url}
                              alt=""
                              className="w-full h-full object-cover rounded-lg"
                            />
                          ) : (
                            <Building2 className="w-5 h-5 text-primary-600" />
                          )}
                        </div>
                        <div className="flex-1 min-w-0">
                          <h4 className="font-medium text-secondary-900 truncate">
                            {invitation.namespace?.name || 'Unknown Namespace'}
                          </h4>
                          <p className="text-sm text-secondary-500 truncate">
                            {invitation.inviter?.name || invitation.inviter?.first_name || invitation.inviter?.last_name
                              ? `From ${invitation.inviter.name || `${invitation.inviter.first_name || ''} ${invitation.inviter.last_name || ''}`.trim()}`
                              : 'Invitation'}
                          </p>
                        </div>
                        <Badge variant="warning" size="sm" className="flex-shrink-0">
                          <Clock className="w-3 h-3 mr-1" />
                          {getTimeRemaining(invitation.expires_at)}
                        </Badge>
                      </div>

                      {/* Role */}
                      {invitation.role && (
                        <p className="text-sm text-secondary-600 mb-3">
                          Role: <span className="font-medium">{invitation.role.display_name || invitation.role.role_name}</span>
                        </p>
                      )}

                      {/* Message Preview */}
                      {invitation.message && (
                        <p className="text-sm text-secondary-500 italic mb-3 line-clamp-2">
                          "{invitation.message}"
                        </p>
                      )}

                      {/* Actions */}
                      <div className="flex items-center gap-2">
                        <Button
                          variant="outline"
                          size="sm"
                          onClick={() => handleDecline(invitation)}
                          disabled={isProcessing}
                          className="flex-1"
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
                          className="flex-1"
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
                  );
                })}
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
});

export default InvitationNotificationBell;

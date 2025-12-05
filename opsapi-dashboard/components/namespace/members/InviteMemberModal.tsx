'use client';

import React, { memo, useState, useCallback, useEffect } from 'react';
import { X, Mail, UserPlus, AlertCircle, Loader2, Search } from 'lucide-react';
import { Button, Input, Select } from '@/components/ui';
import { namespaceService } from '@/services';
import { UserSearchInput } from './UserSearchInput';
import type { NamespaceRole, InviteMemberDto, User } from '@/types';
import toast from 'react-hot-toast';
import { cn } from '@/lib/utils';

interface InviteMemberModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSuccess?: () => void;
  namespaceId?: string;
}

type InviteMode = 'search' | 'email';

export const InviteMemberModal = memo(function InviteMemberModal({
  isOpen,
  onClose,
  onSuccess,
  namespaceId,
}: InviteMemberModalProps) {
  const [mode, setMode] = useState<InviteMode>('search');
  const [selectedUser, setSelectedUser] = useState<User | null>(null);
  const [email, setEmail] = useState('');
  const [roleId, setRoleId] = useState<string>('');
  const [message, setMessage] = useState('');
  const [roles, setRoles] = useState<NamespaceRole[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [isLoadingRoles, setIsLoadingRoles] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Fetch roles when modal opens
  useEffect(() => {
    if (isOpen) {
      fetchRoles();
    }
  }, [isOpen]);

  // Reset form when modal closes
  useEffect(() => {
    if (!isOpen) {
      setMode('search');
      setSelectedUser(null);
      setEmail('');
      setRoleId('');
      setMessage('');
      setError(null);
    }
  }, [isOpen]);

  const fetchRoles = async () => {
    setIsLoadingRoles(true);
    try {
      // Pass namespaceId to fetch roles for the specific namespace (admin context)
      const availableRoles = await namespaceService.getRoles(
        undefined,
        namespaceId ? { namespaceId } : undefined
      );
      setRoles(Array.isArray(availableRoles) ? availableRoles : []);

      // Set default role if exists
      const defaultRole = availableRoles.find((r) => r?.is_default);
      if (defaultRole) {
        setRoleId(defaultRole.id.toString());
      }
    } catch (err) {
      console.error('Failed to fetch roles:', err);
      setRoles([]);
    } finally {
      setIsLoadingRoles(false);
    }
  };

  const validateEmail = (email: string): boolean => {
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    return emailRegex.test(email);
  };

  const getInviteEmail = (): string => {
    if (mode === 'search' && selectedUser) {
      return selectedUser.email;
    }
    return email.trim().toLowerCase();
  };

  const canSubmit = (): boolean => {
    if (mode === 'search') {
      return !!selectedUser;
    }
    return !!email.trim() && validateEmail(email);
  };

  const handleSubmit = useCallback(
    async (e: React.FormEvent) => {
      e.preventDefault();
      setError(null);

      const inviteEmail = getInviteEmail();

      // Validate
      if (!inviteEmail) {
        setError(mode === 'search' ? 'Please select a user' : 'Email is required');
        return;
      }

      if (mode === 'email' && !validateEmail(inviteEmail)) {
        setError('Please enter a valid email address');
        return;
      }

      setIsLoading(true);

      try {
        const inviteData: InviteMemberDto = {
          email: inviteEmail,
          role_id: roleId ? parseInt(roleId, 10) : undefined,
          message: message.trim() || undefined,
        };

        // Pass namespaceId to target the specific namespace (admin context)
        await namespaceService.createInvitation(
          inviteData,
          namespaceId ? { namespaceId } : undefined
        );

        toast.success(`Invitation sent to ${inviteEmail}`);
        onSuccess?.();
        onClose();
      } catch (err) {
        const errorMessage =
          err instanceof Error ? err.message : 'Failed to send invitation';
        if (errorMessage.includes('already a member')) {
          setError('This user is already a member of this namespace');
        } else if (errorMessage.includes('already pending')) {
          setError('An invitation is already pending for this email');
        } else if (errorMessage.includes('maximum member limit')) {
          setError('Namespace has reached the maximum member limit');
        } else {
          setError(errorMessage);
        }
        toast.error(errorMessage);
      } finally {
        setIsLoading(false);
      }
    },
    [mode, selectedUser, email, roleId, message, namespaceId, onSuccess, onClose]
  );

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      if (e.key === 'Escape') {
        onClose();
      }
    },
    [onClose]
  );

  const handleModeChange = (newMode: InviteMode) => {
    setMode(newMode);
    setError(null);
    if (newMode === 'search') {
      setEmail('');
    } else {
      setSelectedUser(null);
    }
  };

  if (!isOpen) return null;

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center"
      onKeyDown={handleKeyDown}
      role="dialog"
      aria-modal="true"
      aria-labelledby="invite-modal-title"
    >
      {/* Backdrop */}
      <div
        className="absolute inset-0 bg-black/50 backdrop-blur-sm"
        onClick={onClose}
        aria-hidden="true"
      />

      {/* Modal */}
      <div className="relative bg-white rounded-xl shadow-xl w-full max-w-md mx-4 overflow-hidden">
        {/* Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b border-secondary-200">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-full bg-primary-100 flex items-center justify-center">
              <UserPlus className="w-5 h-5 text-primary-600" />
            </div>
            <div>
              <h2
                id="invite-modal-title"
                className="text-lg font-semibold text-secondary-900"
              >
                Invite Member
              </h2>
              <p className="text-sm text-secondary-500">
                Send an invitation to join this namespace
              </p>
            </div>
          </div>
          <button
            onClick={onClose}
            className="p-2 hover:bg-secondary-100 rounded-lg transition-colors"
            aria-label="Close modal"
          >
            <X className="w-5 h-5 text-secondary-500" />
          </button>
        </div>

        {/* Form */}
        <form onSubmit={handleSubmit}>
          <div className="px-6 py-4 space-y-4">
            {/* Error Alert */}
            {error && (
              <div className="flex items-start gap-2 p-3 bg-error-50 border border-error-200 rounded-lg">
                <AlertCircle className="w-5 h-5 text-error-500 flex-shrink-0 mt-0.5" />
                <p className="text-sm text-error-700">{error}</p>
              </div>
            )}

            {/* Mode Tabs */}
            <div className="flex gap-1 p-1 bg-secondary-100 rounded-lg">
              <button
                type="button"
                onClick={() => handleModeChange('search')}
                className={cn(
                  'flex-1 flex items-center justify-center gap-2 px-3 py-2 rounded-md text-sm font-medium transition-colors',
                  mode === 'search'
                    ? 'bg-white text-secondary-900 shadow-sm'
                    : 'text-secondary-600 hover:text-secondary-900'
                )}
              >
                <Search className="w-4 h-4" />
                Search Users
              </button>
              <button
                type="button"
                onClick={() => handleModeChange('email')}
                className={cn(
                  'flex-1 flex items-center justify-center gap-2 px-3 py-2 rounded-md text-sm font-medium transition-colors',
                  mode === 'email'
                    ? 'bg-white text-secondary-900 shadow-sm'
                    : 'text-secondary-600 hover:text-secondary-900'
                )}
              >
                <Mail className="w-4 h-4" />
                Enter Email
              </button>
            </div>

            {/* User Selection / Email Input */}
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">
                {mode === 'search' ? 'Select User' : 'Email Address'}{' '}
                <span className="text-error-500">*</span>
              </label>

              {mode === 'search' ? (
                <UserSearchInput
                  value={selectedUser}
                  onChange={(user) => {
                    setSelectedUser(user);
                    setError(null);
                  }}
                  disabled={isLoading}
                  placeholder="Search by name or email..."
                />
              ) : (
                <>
                  <div className="relative">
                    <Mail className="absolute left-3 top-1/2 -translate-y-1/2 w-5 h-5 text-secondary-400" />
                    <Input
                      id="invite-email"
                      type="email"
                      value={email}
                      onChange={(e) => {
                        setEmail(e.target.value);
                        setError(null);
                      }}
                      placeholder="colleague@company.com"
                      className="pl-10"
                      disabled={isLoading}
                      autoFocus
                    />
                  </div>
                  <p className="mt-1 text-xs text-secondary-500">
                    An invitation email will be sent to this address
                  </p>
                </>
              )}
            </div>

            {/* Role Select */}
            <div>
              <label
                htmlFor="invite-role"
                className="block text-sm font-medium text-secondary-700 mb-1"
              >
                Assign Role
              </label>
              <Select
                id="invite-role"
                value={roleId}
                onChange={(e) => setRoleId(e.target.value)}
                disabled={isLoading || isLoadingRoles}
              >
                <option value="">Select a role (optional)</option>
                {roles.map((role) => (
                  <option key={role.id} value={role.id.toString()}>
                    {role.display_name || role.role_name}
                    {role.is_default ? ' (Default)' : ''}
                  </option>
                ))}
              </Select>
              <p className="mt-1 text-xs text-secondary-500">
                {roleId
                  ? 'Member will be assigned this role upon accepting'
                  : 'Default role will be assigned if none selected'}
              </p>
            </div>

            {/* Personal Message */}
            <div>
              <label
                htmlFor="invite-message"
                className="block text-sm font-medium text-secondary-700 mb-1"
              >
                Personal Message
              </label>
              <textarea
                id="invite-message"
                value={message}
                onChange={(e) => setMessage(e.target.value)}
                placeholder="Add a personal message to the invitation..."
                className="w-full px-3 py-2 border border-secondary-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-primary-500 resize-none"
                rows={3}
                disabled={isLoading}
                maxLength={500}
              />
              <p className="mt-1 text-xs text-secondary-500 text-right">
                {message.length}/500
              </p>
            </div>
          </div>

          {/* Footer */}
          <div className="flex items-center justify-end gap-3 px-6 py-4 border-t border-secondary-200 bg-secondary-50">
            <Button
              type="button"
              variant="outline"
              onClick={onClose}
              disabled={isLoading}
            >
              Cancel
            </Button>
            <Button type="submit" disabled={isLoading || !canSubmit()}>
              {isLoading ? (
                <>
                  <Loader2 className="w-4 h-4 mr-2 animate-spin" />
                  Sending...
                </>
              ) : (
                <>
                  <UserPlus className="w-4 h-4 mr-2" />
                  Send Invitation
                </>
              )}
            </Button>
          </div>
        </form>
      </div>
    </div>
  );
});

export default InviteMemberModal;

'use client';

import React, { useState, useEffect, useCallback, useRef } from 'react';
import {
  Share2,
  Clock,
  User,
  Trash2,
  Loader2,
  AlertCircle,
  Search,
  Check,
  X,
} from 'lucide-react';
import { Button, Select, Modal, Card } from '@/components/ui';
import { vaultService } from '@/services/vault.service';
import type { VaultSecret, VaultShare, VaultSharePermission, VaultShareableUser } from '@/types';
import toast from 'react-hot-toast';
import { format, addDays, addWeeks, addMonths } from 'date-fns';
import { cn } from '@/lib/utils';

interface ShareSecretModalProps {
  isOpen: boolean;
  onClose: () => void;
  secret: VaultSecret;
}

const EXPIRATION_OPTIONS = [
  { value: 'never', label: 'Never expires' },
  { value: '1d', label: '1 day' },
  { value: '7d', label: '7 days' },
  { value: '30d', label: '30 days' },
  { value: '90d', label: '90 days' },
  { value: 'custom', label: 'Custom date' },
];

const PERMISSION_OPTIONS: { value: VaultSharePermission; label: string; description: string }[] = [
  {
    value: 'read',
    label: 'Read only',
    description: 'Can view the secret value',
  },
  {
    value: 'write',
    label: 'Edit',
    description: 'Can view and edit the secret',
  },
];

const ShareSecretModal: React.FC<ShareSecretModalProps> = ({
  isOpen,
  onClose,
  secret,
}) => {
  const [selectedUser, setSelectedUser] = useState<VaultShareableUser | null>(null);
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState<VaultShareableUser[]>([]);
  const [isSearching, setIsSearching] = useState(false);
  const [showDropdown, setShowDropdown] = useState(false);
  const [permission, setPermission] = useState<VaultSharePermission>('read');
  const [expiration, setExpiration] = useState('never');
  const [customDate, setCustomDate] = useState('');
  const [isSharing, setIsSharing] = useState(false);
  const [shares, setShares] = useState<VaultShare[]>([]);
  const [isLoadingShares, setIsLoadingShares] = useState(false);
  const [revokingId, setRevokingId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const searchInputRef = useRef<HTMLInputElement>(null);
  const dropdownRef = useRef<HTMLDivElement>(null);
  const searchTimeoutRef = useRef<NodeJS.Timeout | null>(null);

  const loadShares = useCallback(async () => {
    setIsLoadingShares(true);
    try {
      const shareData = await vaultService.getSecretShares(secret.id);
      setShares(shareData);
    } catch (err) {
      console.error('Failed to load shares:', err);
    } finally {
      setIsLoadingShares(false);
    }
  }, [secret.id]);

  // Search users when query changes
  const searchUsers = useCallback(async (query: string) => {
    setIsSearching(true);
    try {
      const results = await vaultService.searchUsers(query, 10);
      setSearchResults(results);
    } catch (err) {
      console.error('Failed to search users:', err);
      setSearchResults([]);
    } finally {
      setIsSearching(false);
    }
  }, []);

  // Debounced search
  useEffect(() => {
    if (searchTimeoutRef.current) {
      clearTimeout(searchTimeoutRef.current);
    }

    if (showDropdown) {
      searchTimeoutRef.current = setTimeout(() => {
        searchUsers(searchQuery);
      }, 300);
    }

    return () => {
      if (searchTimeoutRef.current) {
        clearTimeout(searchTimeoutRef.current);
      }
    };
  }, [searchQuery, showDropdown, searchUsers]);

  // Load initial users when dropdown opens
  useEffect(() => {
    if (showDropdown && searchResults.length === 0 && !searchQuery) {
      searchUsers('');
    }
  }, [showDropdown, searchResults.length, searchQuery, searchUsers]);

  // Handle click outside to close dropdown
  useEffect(() => {
    const handleClickOutside = (event: MouseEvent) => {
      if (
        dropdownRef.current &&
        !dropdownRef.current.contains(event.target as Node) &&
        searchInputRef.current &&
        !searchInputRef.current.contains(event.target as Node)
      ) {
        setShowDropdown(false);
      }
    };

    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

  useEffect(() => {
    if (isOpen) {
      loadShares();
      setSelectedUser(null);
      setSearchQuery('');
      setSearchResults([]);
      setPermission('read');
      setExpiration('never');
      setCustomDate('');
      setError(null);
      setShowDropdown(false);
    }
  }, [isOpen, loadShares]);

  const calculateExpirationDate = (): string | undefined => {
    const now = new Date();
    switch (expiration) {
      case 'never':
        return undefined;
      case '1d':
        return addDays(now, 1).toISOString();
      case '7d':
        return addWeeks(now, 1).toISOString();
      case '30d':
        return addMonths(now, 1).toISOString();
      case '90d':
        return addMonths(now, 3).toISOString();
      case 'custom':
        return customDate ? new Date(customDate).toISOString() : undefined;
      default:
        return undefined;
    }
  };

  const handleSelectUser = (user: VaultShareableUser) => {
    setSelectedUser(user);
    setSearchQuery('');
    setShowDropdown(false);
    setError(null);
  };

  const handleClearSelection = () => {
    setSelectedUser(null);
    setSearchQuery('');
    setError(null);
  };

  const handleShare = async () => {
    setError(null);

    if (!selectedUser) {
      setError('Please select a user to share with');
      return;
    }

    if (!selectedUser.has_vault) {
      setError('This user does not have a vault yet. They need to create one first.');
      return;
    }

    if (expiration === 'custom' && !customDate) {
      setError('Please select an expiration date');
      return;
    }

    setIsSharing(true);
    try {
      await vaultService.shareSecret(secret.id, {
        target_user_id: selectedUser.id,
        permission,
        expires_at: calculateExpirationDate(),
      });
      toast.success(`Secret shared with ${selectedUser.full_name || selectedUser.email}`);
      setSelectedUser(null);
      setSearchQuery('');
      loadShares();
    } catch (err) {
      const error = err as Error;
      toast.error(error.message || 'Failed to share secret');
    } finally {
      setIsSharing(false);
    }
  };

  const handleRevoke = async (shareId: string) => {
    setRevokingId(shareId);
    try {
      await vaultService.revokeShare(shareId);
      toast.success('Share revoked successfully');
      loadShares();
    } catch (err) {
      const error = err as Error;
      toast.error(error.message || 'Failed to revoke share');
    } finally {
      setRevokingId(null);
    }
  };

  const minDate = format(addDays(new Date(), 1), 'yyyy-MM-dd');

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Share Secret" size="lg">
      <div className="space-y-6">
        {/* Secret Info */}
        <div className="p-4 bg-secondary-50 rounded-lg">
          <div className="flex items-center gap-3">
            <Share2 className="w-5 h-5 text-primary-600" />
            <div>
              <p className="font-medium text-secondary-900">{secret.name}</p>
              <p className="text-sm text-secondary-500">
                Share this secret with other users
              </p>
            </div>
          </div>
        </div>

        {/* Share Form */}
        <div className="space-y-4">
          <h3 className="text-sm font-medium text-secondary-700">Add New Share</h3>

          {/* User Search/Selection */}
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">
              Select User
            </label>

            {selectedUser ? (
              // Selected user display
              <div className="flex items-center justify-between p-3 bg-primary-50 border-2 border-primary-500 rounded-lg">
                <div className="flex items-center gap-3">
                  <div className="p-2 bg-primary-100 rounded-full">
                    <User className="w-4 h-4 text-primary-600" />
                  </div>
                  <div>
                    <p className="font-medium text-secondary-900">
                      {selectedUser.full_name || `${selectedUser.first_name} ${selectedUser.last_name}`}
                    </p>
                    <p className="text-sm text-secondary-500">{selectedUser.email}</p>
                  </div>
                  {!selectedUser.has_vault && (
                    <span className="px-2 py-0.5 text-xs bg-warning-100 text-warning-700 rounded-full">
                      No vault
                    </span>
                  )}
                </div>
                <button
                  onClick={handleClearSelection}
                  className="p-1.5 text-secondary-500 hover:text-secondary-700 hover:bg-secondary-100 rounded-lg transition-colors"
                >
                  <X className="w-4 h-4" />
                </button>
              </div>
            ) : (
              // Search input with dropdown
              <div className="relative">
                <div className="relative">
                  <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-secondary-400" />
                  <input
                    ref={searchInputRef}
                    type="text"
                    value={searchQuery}
                    onChange={(e) => setSearchQuery(e.target.value)}
                    onFocus={() => setShowDropdown(true)}
                    placeholder="Search by name or email..."
                    className={cn(
                      'w-full pl-10 pr-4 py-2.5 border rounded-lg transition-colors',
                      'focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-primary-500',
                      error ? 'border-error-500' : 'border-secondary-300'
                    )}
                  />
                  {isSearching && (
                    <Loader2 className="absolute right-3 top-1/2 -translate-y-1/2 w-4 h-4 text-secondary-400 animate-spin" />
                  )}
                </div>

                {/* Dropdown */}
                {showDropdown && (
                  <div
                    ref={dropdownRef}
                    className="absolute z-50 w-full mt-1 bg-white border border-secondary-200 rounded-lg shadow-lg max-h-64 overflow-y-auto"
                  >
                    {isSearching && searchResults.length === 0 ? (
                      <div className="p-4 text-center text-secondary-500">
                        <Loader2 className="w-5 h-5 animate-spin mx-auto mb-2" />
                        Searching...
                      </div>
                    ) : searchResults.length === 0 ? (
                      <div className="p-4 text-center text-secondary-500">
                        {searchQuery
                          ? 'No users found matching your search'
                          : 'No users available in this namespace'}
                      </div>
                    ) : (
                      <ul className="py-1">
                        {searchResults.map((user) => (
                          <li key={user.id}>
                            <button
                              onClick={() => handleSelectUser(user)}
                              className="w-full px-4 py-3 flex items-center gap-3 hover:bg-secondary-50 transition-colors text-left"
                            >
                              <div className="p-2 bg-secondary-100 rounded-full flex-shrink-0">
                                <User className="w-4 h-4 text-secondary-500" />
                              </div>
                              <div className="flex-1 min-w-0">
                                <p className="font-medium text-secondary-900 truncate">
                                  {user.full_name || `${user.first_name} ${user.last_name}`}
                                </p>
                                <p className="text-sm text-secondary-500 truncate">
                                  {user.email}
                                </p>
                              </div>
                              {user.has_vault ? (
                                <span className="px-2 py-0.5 text-xs bg-success-100 text-success-700 rounded-full flex-shrink-0">
                                  <Check className="w-3 h-3 inline mr-1" />
                                  Has vault
                                </span>
                              ) : (
                                <span className="px-2 py-0.5 text-xs bg-warning-100 text-warning-700 rounded-full flex-shrink-0">
                                  No vault
                                </span>
                              )}
                            </button>
                          </li>
                        ))}
                      </ul>
                    )}
                  </div>
                )}
              </div>
            )}

            {error && (
              <p className="mt-1 text-sm text-error-500">{error}</p>
            )}
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">
                Permission
              </label>
              <div className="space-y-2">
                {PERMISSION_OPTIONS.map((opt) => (
                  <label
                    key={opt.value}
                    className={`flex items-start gap-3 p-3 rounded-lg border-2 cursor-pointer transition-colors ${
                      permission === opt.value
                        ? 'border-primary-500 bg-primary-50'
                        : 'border-secondary-200 hover:border-secondary-300'
                    }`}
                  >
                    <input
                      type="radio"
                      name="permission"
                      value={opt.value}
                      checked={permission === opt.value}
                      onChange={() => setPermission(opt.value)}
                      className="mt-1"
                    />
                    <div>
                      <p className="font-medium text-secondary-900">{opt.label}</p>
                      <p className="text-xs text-secondary-500">{opt.description}</p>
                    </div>
                  </label>
                ))}
              </div>
            </div>

            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1">
                Expiration
              </label>
              <Select
                value={expiration}
                onChange={(e) => setExpiration(e.target.value)}
              >
                {EXPIRATION_OPTIONS.map((option) => (
                  <option key={option.value} value={option.value}>
                    {option.label}
                  </option>
                ))}
              </Select>
              {expiration === 'custom' && (
                <input
                  type="date"
                  value={customDate}
                  onChange={(e) => setCustomDate(e.target.value)}
                  min={minDate}
                  className="mt-2 w-full px-3 py-2 border border-secondary-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary-500 focus:border-primary-500"
                />
              )}
            </div>
          </div>

          <Button
            onClick={handleShare}
            isLoading={isSharing}
            disabled={!selectedUser || (selectedUser && !selectedUser.has_vault)}
            className="w-full"
          >
            <Share2 className="w-4 h-4 mr-2" />
            Share Secret
          </Button>
        </div>

        {/* Existing Shares */}
        <div>
          <h3 className="text-sm font-medium text-secondary-700 mb-3">
            Current Shares ({shares.length})
          </h3>

          {isLoadingShares ? (
            <div className="flex items-center justify-center py-8">
              <Loader2 className="w-6 h-6 text-primary-500 animate-spin" />
            </div>
          ) : shares.length === 0 ? (
            <Card className="p-6 text-center">
              <User className="w-8 h-8 text-secondary-300 mx-auto mb-2" />
              <p className="text-secondary-500">
                This secret hasn&apos;t been shared with anyone yet
              </p>
            </Card>
          ) : (
            <div className="space-y-2">
              {shares.map((share) => (
                <Card key={share.id} className="p-4">
                  <div className="flex items-center justify-between">
                    <div className="flex items-center gap-3">
                      <div className="p-2 bg-secondary-100 rounded-full">
                        <User className="w-4 h-4 text-secondary-500" />
                      </div>
                      <div>
                        <p className="font-medium text-secondary-900">
                          {share.shared_with_first_name && share.shared_with_last_name
                            ? `${share.shared_with_first_name} ${share.shared_with_last_name}`
                            : share.shared_with_email || 'Unknown User'}
                        </p>
                        <div className="flex items-center gap-3 text-xs text-secondary-500">
                          <span
                            className={`px-2 py-0.5 rounded-full ${
                              share.permission === 'read'
                                ? 'bg-info-100 text-info-700'
                                : 'bg-warning-100 text-warning-700'
                            }`}
                          >
                            {share.permission === 'read' ? 'Read only' : 'Can edit'}
                          </span>
                          {share.expires_at ? (
                            <span className="flex items-center gap-1">
                              <Clock className="w-3 h-3" />
                              Expires {format(new Date(share.expires_at), 'MMM d, yyyy')}
                            </span>
                          ) : (
                            <span>No expiration</span>
                          )}
                        </div>
                      </div>
                    </div>
                    <button
                      onClick={() => handleRevoke(share.id)}
                      disabled={revokingId === share.id}
                      className="p-2 text-error-500 hover:bg-error-50 rounded-lg transition-colors disabled:opacity-50"
                      title="Revoke share"
                    >
                      {revokingId === share.id ? (
                        <Loader2 className="w-4 h-4 animate-spin" />
                      ) : (
                        <Trash2 className="w-4 h-4" />
                      )}
                    </button>
                  </div>
                </Card>
              ))}
            </div>
          )}
        </div>

        {/* Warning */}
        <div className="p-4 bg-warning-50 rounded-lg border border-warning-200">
          <div className="flex items-start gap-3">
            <AlertCircle className="w-5 h-5 text-warning-600 flex-shrink-0 mt-0.5" />
            <div className="text-sm text-warning-700">
              <p className="font-medium mb-1">Important Security Note</p>
              <p>
                When you share a secret, it will be re-encrypted with the recipient&apos;s
                vault key. They will have their own copy of the secret. Revoking access
                will remove their copy.
              </p>
            </div>
          </div>
        </div>

        {/* Actions */}
        <div className="flex justify-end">
          <Button variant="ghost" onClick={onClose}>
            Done
          </Button>
        </div>
      </div>
    </Modal>
  );
};

export default ShareSecretModal;

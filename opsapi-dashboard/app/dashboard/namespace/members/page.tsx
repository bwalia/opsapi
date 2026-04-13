'use client';

import React, { useState, useEffect, useCallback, useRef } from 'react';
import {
  Users,
  Plus,
  Search,
  Crown,
  Trash2,
  Edit,
  MoreVertical,
  Mail,
  ShieldCheck,
  UserMinus,
  Loader2,
} from 'lucide-react';
import { Button, Input, Table, Badge, Pagination, Card, ConfirmDialog } from '@/components/ui';
import { useNamespace } from '@/contexts/NamespaceContext';
import { namespaceService } from '@/services';
import { formatDate, getInitials } from '@/lib/utils';
import type { NamespaceMember, NamespaceRole, TableColumn, PaginatedResponse } from '@/types';
import toast from 'react-hot-toast';

export default function NamespaceMembersPage() {
  const { currentNamespace, isNamespaceOwner, hasPermission } = useNamespace();
  const [members, setMembers] = useState<NamespaceMember[]>([]);
  const [roles, setRoles] = useState<NamespaceRole[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState('');
  const [currentPage, setCurrentPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);
  const [memberToRemove, setMemberToRemove] = useState<NamespaceMember | null>(null);
  const [isRemoving, setIsRemoving] = useState(false);
  const [inviteModalOpen, setInviteModalOpen] = useState(false);
  const fetchIdRef = useRef(0);

  const perPage = 10;
  const canManageMembers = isNamespaceOwner || hasPermission('users', 'manage');

  const fetchMembers = useCallback(async () => {
    if (!currentNamespace) return;

    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);
    try {
      const response = await namespaceService.getMembers({
        page: currentPage,
        perPage,
        search: searchQuery || undefined,
      });

      if (fetchId === fetchIdRef.current) {
        setMembers(response.data || []);
        setTotalPages(response.totalPages || 1);
        setTotalItems(response.total || 0);
      }
    } catch (error) {
      if (fetchId === fetchIdRef.current) {
        console.error('Failed to fetch members:', error);
        toast.error('Failed to load members');
      }
    } finally {
      if (fetchId === fetchIdRef.current) {
        setIsLoading(false);
      }
    }
  }, [currentNamespace, currentPage, searchQuery]);

  const fetchRoles = useCallback(async () => {
    if (!currentNamespace) return;
    try {
      const data = await namespaceService.getRoles();
      setRoles(data);
    } catch (error) {
      console.error('Failed to fetch roles:', error);
    }
  }, [currentNamespace]);

  useEffect(() => {
    fetchMembers();
    fetchRoles();
  }, [fetchMembers, fetchRoles]);

  const handleSearch = (value: string) => {
    setSearchQuery(value);
    setCurrentPage(1);
  };

  const handleRemoveClick = (member: NamespaceMember) => {
    setMemberToRemove(member);
    setDeleteDialogOpen(true);
  };

  const handleRemoveConfirm = async () => {
    if (!memberToRemove) return;

    setIsRemoving(true);
    try {
      await namespaceService.removeMember(memberToRemove.uuid);
      toast.success('Member removed successfully');
      fetchMembers();
    } catch (error) {
      toast.error('Failed to remove member');
    } finally {
      setIsRemoving(false);
      setDeleteDialogOpen(false);
      setMemberToRemove(null);
    }
  };

  const columns: TableColumn<NamespaceMember>[] = [
    {
      key: 'user',
      header: 'Member',
      render: (member) => (
        <div className="flex items-center gap-3">
          <div className="w-9 h-9 rounded-lg bg-primary-100 flex items-center justify-center text-primary-600 font-semibold text-sm">
            {getInitials(member.user?.first_name, member.user?.last_name)}
          </div>
          <div>
            <div className="flex items-center gap-1.5">
              <p className="font-medium text-secondary-900">
                {member.user?.full_name || `${member.user?.first_name} ${member.user?.last_name}`}
              </p>
              {member.is_owner && <Crown className="w-3.5 h-3.5 text-amber-500" />}
            </div>
            <p className="text-sm text-secondary-500">{member.user?.email}</p>
          </div>
        </div>
      ),
    },
    {
      key: 'roles',
      header: 'Roles',
      render: (member) => (
        <div className="flex flex-wrap gap-1">
          {member.is_owner ? (
            <Badge variant="warning">Owner</Badge>
          ) : member.roles && member.roles.length > 0 ? (
            member.roles.map((role) => (
              <Badge key={role.uuid} variant="default">
                {role.display_name || role.role_name}
              </Badge>
            ))
          ) : (
            <span className="text-secondary-400 text-sm">No roles</span>
          )}
        </div>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      render: (member) => (
        <Badge
          variant={
            member.status === 'active'
              ? 'success'
              : member.status === 'invited'
              ? 'warning'
              : 'default'
          }
          className="capitalize"
        >
          {member.status}
        </Badge>
      ),
    },
    {
      key: 'joined_at',
      header: 'Joined',
      render: (member) => (
        <span className="text-secondary-600 text-sm">
          {member.joined_at ? formatDate(member.joined_at) : '-'}
        </span>
      ),
    },
  ];

  // Add actions column if user can manage members
  if (canManageMembers) {
    columns.push({
      key: 'actions',
      header: '',
      width: '100px',
      render: (member) => (
        <div className="flex items-center justify-end gap-1">
          {!member.is_owner && (
            <>
              <button
                onClick={() => {/* TODO: Edit member roles */}}
                className="p-1.5 text-secondary-500 hover:text-primary-600 hover:bg-primary-50 rounded-lg transition-colors"
                title="Edit roles"
              >
                <Edit className="w-4 h-4" />
              </button>
              <button
                onClick={() => handleRemoveClick(member)}
                className="p-1.5 text-secondary-500 hover:text-error-600 hover:bg-error-50 rounded-lg transition-colors"
                title="Remove member"
              >
                <Trash2 className="w-4 h-4" />
              </button>
            </>
          )}
        </div>
      ),
    });
  }

  if (!currentNamespace) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-bold text-secondary-900">Namespace Members</h1>
        <Card className="p-8 text-center">
          <Users className="w-12 h-12 text-secondary-300 mx-auto mb-4" />
          <p className="text-secondary-500">No namespace selected</p>
        </Card>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Namespace Members</h1>
          <p className="text-secondary-500 mt-1">
            Manage members of {currentNamespace.name}
          </p>
        </div>

        {canManageMembers && (
          <Button onClick={() => setInviteModalOpen(true)}>
            <Plus className="w-4 h-4 mr-2" />
            Invite Member
          </Button>
        )}
      </div>

      {/* Search */}
      <Card className="p-4">
        <div className="flex flex-col sm:flex-row gap-4">
          <div className="flex-1">
            <Input
              placeholder="Search members..."
              value={searchQuery}
              onChange={(e) => handleSearch(e.target.value)}
              leftIcon={<Search className="w-4 h-4" />}
            />
          </div>
        </div>
      </Card>

      {/* Members Table */}
      <Card>
        <Table
          data={members}
          columns={columns}
          keyExtractor={(member) => member.uuid}
          isLoading={isLoading}
          emptyMessage="No members found"
        />

        {totalPages > 1 && (
          <div className="px-4 py-3 border-t border-secondary-200">
            <Pagination
              currentPage={currentPage}
              totalPages={totalPages}
              onPageChange={setCurrentPage}
              totalItems={totalItems}
              perPage={perPage}
            />
          </div>
        )}
      </Card>

      {/* Remove Confirmation Dialog */}
      <ConfirmDialog
        isOpen={deleteDialogOpen}
        onClose={() => setDeleteDialogOpen(false)}
        onConfirm={handleRemoveConfirm}
        title="Remove Member"
        message={`Are you sure you want to remove ${memberToRemove?.user?.full_name || memberToRemove?.user?.email} from this namespace? They will lose access to all namespace resources.`}
        confirmText="Remove"
        variant="danger"
        isLoading={isRemoving}
      />

      {/* Invite Modal */}
      {inviteModalOpen && (
        <InviteMemberModal
          roles={roles}
          onClose={() => setInviteModalOpen(false)}
          onSuccess={() => {
            setInviteModalOpen(false);
            fetchMembers();
          }}
        />
      )}
    </div>
  );
}

// Invite Member Modal Component
function InviteMemberModal({
  roles,
  onClose,
  onSuccess,
}: {
  roles: NamespaceRole[];
  onClose: () => void;
  onSuccess: () => void;
}) {
  const [email, setEmail] = useState('');
  const [selectedRoleId, setSelectedRoleId] = useState<number | undefined>();
  const [isSubmitting, setIsSubmitting] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!email.trim()) {
      toast.error('Email is required');
      return;
    }

    setIsSubmitting(true);
    try {
      await namespaceService.inviteMember({
        email: email.trim(),
        role_id: selectedRoleId,
      });
      toast.success('Invitation sent successfully');
      onSuccess();
    } catch (error) {
      toast.error('Failed to send invitation');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      <div className="absolute inset-0 bg-secondary-900/50 backdrop-blur-sm" onClick={onClose} />
      <div className="relative bg-white rounded-xl shadow-2xl w-full max-w-md mx-4 p-6">
        <h2 className="text-xl font-semibold text-secondary-900 mb-4">
          Invite New Member
        </h2>

        <form onSubmit={handleSubmit} className="space-y-4">
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1.5">
              Email Address <span className="text-error-500">*</span>
            </label>
            <Input
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="member@example.com"
              leftIcon={<Mail className="w-4 h-4" />}
            />
          </div>

          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1.5">
              Assign Role
            </label>
            <select
              value={selectedRoleId || ''}
              onChange={(e) => setSelectedRoleId(e.target.value ? Number(e.target.value) : undefined)}
              className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
            >
              <option value="">Default Role</option>
              {roles.map((role) => (
                <option key={role.id} value={role.id}>
                  {role.display_name || role.role_name}
                </option>
              ))}
            </select>
          </div>

          <div className="flex justify-end gap-3 pt-2">
            <Button type="button" variant="secondary" onClick={onClose}>
              Cancel
            </Button>
            <Button type="submit" disabled={isSubmitting || !email.trim()}>
              {isSubmitting && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}
              Send Invitation
            </Button>
          </div>
        </form>
      </div>
    </div>
  );
}

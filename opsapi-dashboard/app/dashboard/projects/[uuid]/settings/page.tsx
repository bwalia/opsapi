'use client';

import React, { useEffect, useState, useCallback, useMemo } from 'react';
import { useParams, useRouter } from 'next/navigation';
import {
  ArrowLeft,
  Settings,
  Users,
  Shield,
  DollarSign,
  Calendar,
  Palette,
  Trash2,
  Save,
  Plus,
  X,
  Crown,
  UserMinus,
  Mail,
  AlertTriangle,
  Eye,
  EyeOff,
  Globe,
  Lock,
  Building,
  Check,
  Clock,
  Target,
  BarChart3,
} from 'lucide-react';
import { toast } from 'react-hot-toast';
import Button from '@/components/ui/Button';
import Input from '@/components/ui/Input';
import Card, { CardHeader, CardContent } from '@/components/ui/Card';
import Modal from '@/components/ui/Modal';
import Badge from '@/components/ui/Badge';
import { ConfirmDialog } from '@/components/ui/Modal';
import { useKanbanStore } from '@/store/kanban.store';
import { kanbanService } from '@/services/kanban.service';
import usersService from '@/services/users.service';
import type {
  User,
  KanbanProject,
  KanbanProjectMember,
  KanbanProjectStatus,
  KanbanProjectVisibility,
  BudgetCurrency,
  UpdateKanbanProjectDto,
  KanbanMemberRole,
} from '@/types';
import { cn } from '@/lib/utils';

// ============================================
// Types & Constants
// ============================================

type SettingsTab = 'general' | 'members' | 'visibility' | 'budget' | 'dates' | 'danger';

interface TabConfig {
  id: SettingsTab;
  label: string;
  icon: React.ElementType;
  description: string;
}

const TABS: TabConfig[] = [
  { id: 'general', label: 'General', icon: Settings, description: 'Basic project information' },
  { id: 'members', label: 'Members', icon: Users, description: 'Team members and roles' },
  { id: 'visibility', label: 'Visibility', icon: Eye, description: 'Privacy and access control' },
  { id: 'budget', label: 'Budget', icon: DollarSign, description: 'Budget and billing settings' },
  { id: 'dates', label: 'Timeline', icon: Calendar, description: 'Project dates and deadlines' },
  { id: 'danger', label: 'Danger Zone', icon: AlertTriangle, description: 'Destructive actions' },
];

const PROJECT_STATUSES: { value: KanbanProjectStatus; label: string; color: string }[] = [
  { value: 'active', label: 'Active', color: '#22c55e' },
  { value: 'on_hold', label: 'On Hold', color: '#f59e0b' },
  { value: 'completed', label: 'Completed', color: '#3b82f6' },
  { value: 'archived', label: 'Archived', color: '#6b7280' },
  { value: 'cancelled', label: 'Cancelled', color: '#ef4444' },
];

const VISIBILITY_OPTIONS: { value: KanbanProjectVisibility; label: string; icon: React.ElementType; description: string }[] = [
  { value: 'private', label: 'Private', icon: Lock, description: 'Only project members can access' },
  { value: 'internal', label: 'Internal', icon: Building, description: 'All namespace members can view' },
  { value: 'public', label: 'Public', icon: Globe, description: 'Anyone with the link can view' },
];

const CURRENCIES: { value: BudgetCurrency; label: string; symbol: string }[] = [
  { value: 'USD', label: 'US Dollar', symbol: '$' },
  { value: 'EUR', label: 'Euro', symbol: '€' },
  { value: 'GBP', label: 'British Pound', symbol: '£' },
  { value: 'INR', label: 'Indian Rupee', symbol: '₹' },
  { value: 'CAD', label: 'Canadian Dollar', symbol: 'C$' },
  { value: 'AUD', label: 'Australian Dollar', symbol: 'A$' },
  { value: 'JPY', label: 'Japanese Yen', symbol: '¥' },
  { value: 'CNY', label: 'Chinese Yuan', symbol: '¥' },
];

const MEMBER_ROLES: { value: KanbanMemberRole; label: string; description: string }[] = [
  { value: 'owner', label: 'Owner', description: 'Full access, can delete project' },
  { value: 'admin', label: 'Admin', description: 'Can manage members and settings' },
  { value: 'member', label: 'Member', description: 'Can create and edit tasks' },
  { value: 'viewer', label: 'Viewer', description: 'Can only view project' },
  { value: 'guest', label: 'Guest', description: 'Limited access to specific items' },
];

const PROJECT_COLORS = [
  '#ef4444', '#f97316', '#f59e0b', '#eab308', '#84cc16',
  '#22c55e', '#10b981', '#14b8a6', '#06b6d4', '#0ea5e9',
  '#3b82f6', '#6366f1', '#8b5cf6', '#a855f7', '#d946ef',
  '#ec4899', '#f43f5e', '#6b7280', '#78716c', '#71717a',
];

// ============================================
// Helper Components
// ============================================

interface StatCardProps {
  label: string;
  value: string | number;
  icon: React.ElementType;
  color?: string;
}

const StatCard = ({ label, value, icon: Icon, color = '#3b82f6' }: StatCardProps) => (
  <div className="flex items-center gap-3 p-4 bg-secondary-50 rounded-lg">
    <div
      className="w-10 h-10 rounded-lg flex items-center justify-center"
      style={{ backgroundColor: `${color}20` }}
    >
      <Icon size={20} style={{ color }} />
    </div>
    <div>
      <p className="text-2xl font-bold text-secondary-900">{value}</p>
      <p className="text-sm text-secondary-500">{label}</p>
    </div>
  </div>
);

interface MemberAvatarProps {
  member: KanbanProjectMember;
  size?: 'sm' | 'md' | 'lg';
}

const MemberAvatar = ({ member, size = 'md' }: MemberAvatarProps) => {
  const sizes = { sm: 'w-8 h-8 text-xs', md: 'w-10 h-10 text-sm', lg: 'w-12 h-12 text-base' };
  const initials = member.user
    ? `${member.user.first_name?.[0] || ''}${member.user.last_name?.[0] || ''}`.toUpperCase() || 'U'
    : 'U';

  return (
    <div
      className={cn(
        sizes[size],
        'rounded-full bg-gradient-to-br from-primary-400 to-primary-600 flex items-center justify-center text-white font-medium'
      )}
    >
      {initials}
    </div>
  );
};

interface ColorPickerProps {
  value?: string;
  onChange: (color: string) => void;
}

const ColorPicker = ({ value, onChange }: ColorPickerProps) => (
  <div className="grid grid-cols-10 gap-2">
    {PROJECT_COLORS.map((color) => (
      <button
        key={color}
        type="button"
        onClick={() => onChange(color)}
        className={cn(
          'w-8 h-8 rounded-lg transition-all duration-200',
          value === color ? 'ring-2 ring-offset-2 ring-primary-500 scale-110' : 'hover:scale-105'
        )}
        style={{ backgroundColor: color }}
      />
    ))}
  </div>
);

// ============================================
// Invite Member Modal Component
// ============================================

interface InviteMemberModalProps {
  isOpen: boolean;
  onClose: () => void;
  onInvite: (userUuid: string, role: KanbanMemberRole) => Promise<void>;
  existingMemberUuids: string[];
  isLoading?: boolean;
}

const InviteMemberModal = ({ isOpen, onClose, onInvite, existingMemberUuids, isLoading }: InviteMemberModalProps) => {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState<User[]>([]);
  const [selectedUser, setSelectedUser] = useState<User | null>(null);
  const [role, setRole] = useState<KanbanMemberRole>('member');
  const [error, setError] = useState('');
  const [isSearching, setIsSearching] = useState(false);
  const searchTimeoutRef = React.useRef<NodeJS.Timeout | null>(null);

  // Search users as they type
  useEffect(() => {
    if (searchTimeoutRef.current) {
      clearTimeout(searchTimeoutRef.current);
    }

    if (searchQuery.trim().length < 2) {
      setSearchResults([]);
      return;
    }

    setIsSearching(true);
    searchTimeoutRef.current = setTimeout(async () => {
      try {
        const results = await usersService.searchUsers(searchQuery, { limit: 10 });
        // Filter out existing members
        const filtered = results.filter((u) => !existingMemberUuids.includes(u.uuid));
        setSearchResults(filtered);
      } catch (err) {
        console.error('Failed to search users:', err);
        setSearchResults([]);
      } finally {
        setIsSearching(false);
      }
    }, 300);

    return () => {
      if (searchTimeoutRef.current) {
        clearTimeout(searchTimeoutRef.current);
      }
    };
  }, [searchQuery, existingMemberUuids]);

  // Reset state when modal closes
  useEffect(() => {
    if (!isOpen) {
      setSearchQuery('');
      setSearchResults([]);
      setSelectedUser(null);
      setRole('member');
      setError('');
    }
  }, [isOpen]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');

    if (!selectedUser) {
      setError('Please select a user to invite');
      return;
    }

    try {
      await onInvite(selectedUser.uuid, role);
      onClose();
    } catch (err) {
      setError('Failed to add member. Please try again.');
    }
  };

  const handleSelectUser = (user: User) => {
    setSelectedUser(user);
    setSearchQuery('');
    setSearchResults([]);
  };

  const handleClearSelection = () => {
    setSelectedUser(null);
    setSearchQuery('');
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose} title="Add Team Member" size="md">
      <form onSubmit={handleSubmit} className="space-y-6">
        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-2">Search User</label>
          {selectedUser ? (
            <div className="flex items-center gap-3 p-3 bg-primary-50 border border-primary-200 rounded-lg">
              <div className="w-10 h-10 rounded-full bg-gradient-to-br from-primary-400 to-primary-600 flex items-center justify-center text-white font-medium">
                {`${selectedUser.first_name?.[0] || ''}${selectedUser.last_name?.[0] || ''}`.toUpperCase() || 'U'}
              </div>
              <div className="flex-1 min-w-0">
                <p className="font-medium text-secondary-900 truncate">
                  {selectedUser.first_name} {selectedUser.last_name}
                </p>
                <p className="text-sm text-secondary-500 truncate">{selectedUser.email}</p>
              </div>
              <button
                type="button"
                onClick={handleClearSelection}
                className="p-1 text-secondary-400 hover:text-secondary-600 rounded"
              >
                <X size={18} />
              </button>
            </div>
          ) : (
            <div className="relative">
              <Input
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                placeholder="Search by name or email..."
                leftIcon={<Users size={18} />}
                autoFocus
              />
              {(searchResults.length > 0 || isSearching) && (
                <div className="absolute z-10 mt-1 w-full bg-white rounded-lg border border-secondary-200 shadow-lg max-h-60 overflow-auto">
                  {isSearching ? (
                    <div className="p-4 text-center text-secondary-500">
                      <div className="animate-spin inline-block w-5 h-5 border-2 border-primary-500 border-t-transparent rounded-full" />
                      <p className="mt-2 text-sm">Searching...</p>
                    </div>
                  ) : searchResults.length === 0 ? (
                    <div className="p-4 text-center text-secondary-500 text-sm">
                      No users found
                    </div>
                  ) : (
                    searchResults.map((user) => (
                      <button
                        key={user.uuid}
                        type="button"
                        onClick={() => handleSelectUser(user)}
                        className="w-full flex items-center gap-3 p-3 hover:bg-secondary-50 transition-colors text-left"
                      >
                        <div className="w-8 h-8 rounded-full bg-gradient-to-br from-primary-400 to-primary-600 flex items-center justify-center text-white text-xs font-medium">
                          {`${user.first_name?.[0] || ''}${user.last_name?.[0] || ''}`.toUpperCase() || 'U'}
                        </div>
                        <div className="flex-1 min-w-0">
                          <p className="font-medium text-secondary-900 truncate">
                            {user.first_name} {user.last_name}
                          </p>
                          <p className="text-sm text-secondary-500 truncate">{user.email}</p>
                        </div>
                      </button>
                    ))
                  )}
                </div>
              )}
            </div>
          )}
          {error && <p className="mt-2 text-sm text-error-500">{error}</p>}
        </div>

        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-2">Role</label>
          <div className="space-y-2">
            {MEMBER_ROLES.filter((r) => r.value !== 'owner').map((roleOption) => (
              <label
                key={roleOption.value}
                className={cn(
                  'flex items-start gap-3 p-3 rounded-lg border cursor-pointer transition-colors',
                  role === roleOption.value
                    ? 'border-primary-500 bg-primary-50'
                    : 'border-secondary-200 hover:border-secondary-300'
                )}
              >
                <input
                  type="radio"
                  name="role"
                  value={roleOption.value}
                  checked={role === roleOption.value}
                  onChange={() => setRole(roleOption.value)}
                  className="mt-1"
                />
                <div>
                  <p className="font-medium text-secondary-900">{roleOption.label}</p>
                  <p className="text-sm text-secondary-500">{roleOption.description}</p>
                </div>
              </label>
            ))}
          </div>
        </div>

        <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
          <Button type="button" variant="outline" onClick={onClose} disabled={isLoading}>
            Cancel
          </Button>
          <Button
            type="submit"
            isLoading={isLoading}
            leftIcon={<Plus size={16} />}
            disabled={!selectedUser}
          >
            Add Member
          </Button>
        </div>
      </form>
    </Modal>
  );
};

// ============================================
// Member Row Component
// ============================================

interface MemberRowProps {
  member: KanbanProjectMember;
  currentUserUuid: string;
  isOwner: boolean;
  onUpdateRole: (userUuid: string, role: KanbanMemberRole) => Promise<void>;
  onRemove: (userUuid: string) => void;
}

const MemberRow = ({ member, currentUserUuid, isOwner, onUpdateRole, onRemove }: MemberRowProps) => {
  const [isEditing, setIsEditing] = useState(false);
  const [selectedRole, setSelectedRole] = useState(member.role);
  const [isSaving, setIsSaving] = useState(false);

  const isCurrentUser = member.user_uuid === currentUserUuid;
  const canEdit = isOwner && !isCurrentUser && member.role !== 'owner';

  const handleSaveRole = async () => {
    if (selectedRole === member.role) {
      setIsEditing(false);
      return;
    }

    setIsSaving(true);
    try {
      await onUpdateRole(member.user_uuid, selectedRole);
      setIsEditing(false);
    } catch {
      setSelectedRole(member.role);
    } finally {
      setIsSaving(false);
    }
  };

  const getRoleBadgeVariant = (role: KanbanMemberRole) => {
    switch (role) {
      case 'owner':
        return 'warning';
      case 'admin':
        return 'info';
      case 'member':
        return 'default';
      case 'viewer':
        return 'secondary';
      default:
        return 'default';
    }
  };

  return (
    <div className="flex items-center justify-between py-4 border-b border-secondary-100 last:border-0">
      <div className="flex items-center gap-4">
        <MemberAvatar member={member} />
        <div>
          <div className="flex items-center gap-2">
            <p className="font-medium text-secondary-900">
              {member.user?.first_name} {member.user?.last_name}
              {isCurrentUser && <span className="text-secondary-500 font-normal"> (you)</span>}
            </p>
            {member.role === 'owner' && <Crown size={16} className="text-yellow-500" />}
          </div>
          <p className="text-sm text-secondary-500">{member.user?.email}</p>
        </div>
      </div>

      <div className="flex items-center gap-3">
        {isEditing ? (
          <>
            <select
              value={selectedRole}
              onChange={(e) => setSelectedRole(e.target.value as KanbanMemberRole)}
              className="px-3 py-1.5 text-sm border border-secondary-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary-500/20"
              disabled={isSaving}
            >
              {MEMBER_ROLES.filter((r) => r.value !== 'owner').map((r) => (
                <option key={r.value} value={r.value}>
                  {r.label}
                </option>
              ))}
            </select>
            <Button size="sm" onClick={handleSaveRole} isLoading={isSaving}>
              <Check size={14} />
            </Button>
            <Button
              size="sm"
              variant="ghost"
              onClick={() => {
                setSelectedRole(member.role);
                setIsEditing(false);
              }}
              disabled={isSaving}
            >
              <X size={14} />
            </Button>
          </>
        ) : (
          <>
            <Badge variant={getRoleBadgeVariant(member.role)} size="sm">
              {MEMBER_ROLES.find((r) => r.value === member.role)?.label || member.role}
            </Badge>
            {canEdit && (
              <div className="flex items-center gap-1">
                <Button size="sm" variant="ghost" onClick={() => setIsEditing(true)}>
                  Edit
                </Button>
                <Button
                  size="sm"
                  variant="ghost"
                  onClick={() => onRemove(member.user_uuid)}
                  className="text-error-600 hover:text-error-700 hover:bg-error-50"
                >
                  <UserMinus size={16} />
                </Button>
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
};

// ============================================
// Settings Tab Components
// ============================================

interface GeneralTabProps {
  project: KanbanProject;
  formData: UpdateKanbanProjectDto;
  setFormData: React.Dispatch<React.SetStateAction<UpdateKanbanProjectDto>>;
  onSave: () => Promise<void>;
  isSaving: boolean;
}

const GeneralTab = ({ project, formData, setFormData, onSave, isSaving }: GeneralTabProps) => (
  <Card>
    <div className="p-6 border-b border-secondary-200">
      <h2 className="text-lg font-semibold text-secondary-900">General Settings</h2>
      <p className="text-sm text-secondary-500 mt-1">Basic project information and configuration</p>
    </div>

    <div className="p-6 space-y-6">
      {/* Project Stats */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <StatCard label="Total Tasks" value={project.task_count} icon={Target} color="#3b82f6" />
        <StatCard label="Completed" value={project.completed_task_count} icon={Check} color="#22c55e" />
        <StatCard label="Members" value={project.member_count} icon={Users} color="#8b5cf6" />
        <StatCard label="Boards" value={project.board_count || 1} icon={BarChart3} color="#f59e0b" />
      </div>

      {/* Form Fields */}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        <div className="md:col-span-2">
          <Input
            label="Project Name"
            value={formData.name || ''}
            onChange={(e) => setFormData((prev) => ({ ...prev, name: e.target.value }))}
            placeholder="Enter project name"
          />
        </div>

        <div className="md:col-span-2">
          <label className="block text-sm font-medium text-secondary-700 mb-1">Description</label>
          <textarea
            value={formData.description || ''}
            onChange={(e) => setFormData((prev) => ({ ...prev, description: e.target.value }))}
            placeholder="Describe your project..."
            rows={4}
            className="w-full px-4 py-3 border border-secondary-300 rounded-lg resize-none focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 transition-colors"
          />
        </div>

        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1">Status</label>
          <select
            value={formData.status || 'active'}
            onChange={(e) => setFormData((prev) => ({ ...prev, status: e.target.value as KanbanProjectStatus }))}
            className="w-full px-4 py-2.5 border border-secondary-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 transition-colors"
          >
            {PROJECT_STATUSES.map((status) => (
              <option key={status.value} value={status.value}>
                {status.label}
              </option>
            ))}
          </select>
        </div>

        <div>
          <Input
            label="Project Slug"
            value={formData.slug || ''}
            onChange={(e) => setFormData((prev) => ({ ...prev, slug: e.target.value.toLowerCase().replace(/\s+/g, '-') }))}
            placeholder="project-slug"
            helperText="URL-friendly identifier"
          />
        </div>
      </div>

      {/* Color Picker */}
      <div>
        <label className="block text-sm font-medium text-secondary-700 mb-3">Project Color</label>
        <ColorPicker
          value={formData.color}
          onChange={(color) => setFormData((prev) => ({ ...prev, color }))}
        />
      </div>

      {/* Save Button */}
      <div className="flex justify-end pt-4 border-t border-secondary-200">
        <Button onClick={onSave} isLoading={isSaving} leftIcon={<Save size={16} />}>
          Save Changes
        </Button>
      </div>
    </div>
  </Card>
);

interface MembersTabProps {
  members: KanbanProjectMember[];
  currentUserUuid: string;
  isOwner: boolean;
  onInvite: () => void;
  onUpdateRole: (memberUuid: string, role: KanbanMemberRole) => Promise<void>;
  onRemove: (memberUuid: string) => void;
}

const MembersTab = ({ members, currentUserUuid, isOwner, onInvite, onUpdateRole, onRemove }: MembersTabProps) => (
  <Card>
    <div className="p-6 border-b border-secondary-200 flex items-center justify-between">
      <div>
        <h2 className="text-lg font-semibold text-secondary-900">Team Members</h2>
        <p className="text-sm text-secondary-500 mt-1">Manage who has access to this project</p>
      </div>
      {isOwner && (
        <Button onClick={onInvite} leftIcon={<Plus size={16} />}>
          Invite Member
        </Button>
      )}
    </div>

    <div className="p-6">
      {members.length === 0 ? (
        <div className="text-center py-8 text-secondary-500">
          <Users size={48} className="mx-auto mb-4 text-secondary-300" />
          <p className="text-lg font-medium">No team members yet</p>
          <p className="text-sm mt-1">Invite people to collaborate on this project</p>
        </div>
      ) : (
        <div className="divide-y divide-secondary-100">
          {members.map((member) => (
            <MemberRow
              key={member.uuid}
              member={member}
              currentUserUuid={currentUserUuid}
              isOwner={isOwner}
              onUpdateRole={onUpdateRole}
              onRemove={onRemove}
            />
          ))}
        </div>
      )}
    </div>
  </Card>
);

interface VisibilityTabProps {
  formData: UpdateKanbanProjectDto;
  setFormData: React.Dispatch<React.SetStateAction<UpdateKanbanProjectDto>>;
  onSave: () => Promise<void>;
  isSaving: boolean;
}

const VisibilityTab = ({ formData, setFormData, onSave, isSaving }: VisibilityTabProps) => (
  <Card>
    <div className="p-6 border-b border-secondary-200">
      <h2 className="text-lg font-semibold text-secondary-900">Visibility & Access</h2>
      <p className="text-sm text-secondary-500 mt-1">Control who can see and access this project</p>
    </div>

    <div className="p-6 space-y-4">
      {VISIBILITY_OPTIONS.map((option) => {
        const Icon = option.icon;
        const isSelected = formData.visibility === option.value;

        return (
          <label
            key={option.value}
            className={cn(
              'flex items-start gap-4 p-4 rounded-xl border-2 cursor-pointer transition-all duration-200',
              isSelected
                ? 'border-primary-500 bg-primary-50'
                : 'border-secondary-200 hover:border-secondary-300'
            )}
          >
            <input
              type="radio"
              name="visibility"
              value={option.value}
              checked={isSelected}
              onChange={() => setFormData((prev) => ({ ...prev, visibility: option.value }))}
              className="sr-only"
            />
            <div
              className={cn(
                'w-12 h-12 rounded-xl flex items-center justify-center transition-colors',
                isSelected ? 'bg-primary-500 text-white' : 'bg-secondary-100 text-secondary-500'
              )}
            >
              <Icon size={24} />
            </div>
            <div className="flex-1">
              <div className="flex items-center gap-2">
                <p className="font-semibold text-secondary-900">{option.label}</p>
                {isSelected && <Check size={16} className="text-primary-500" />}
              </div>
              <p className="text-sm text-secondary-500 mt-1">{option.description}</p>
            </div>
          </label>
        );
      })}

      <div className="flex justify-end pt-4 border-t border-secondary-200 mt-6">
        <Button onClick={onSave} isLoading={isSaving} leftIcon={<Save size={16} />}>
          Save Changes
        </Button>
      </div>
    </div>
  </Card>
);

interface BudgetTabProps {
  project: KanbanProject;
  formData: UpdateKanbanProjectDto;
  setFormData: React.Dispatch<React.SetStateAction<UpdateKanbanProjectDto>>;
  onSave: () => Promise<void>;
  isSaving: boolean;
}

const BudgetTab = ({ project, formData, setFormData, onSave, isSaving }: BudgetTabProps) => {
  const currencySymbol = CURRENCIES.find((c) => c.value === (formData.budget_currency || 'USD'))?.symbol || '$';
  const budgetProgress = project.budget > 0 ? Math.min((project.budget_spent / project.budget) * 100, 100) : 0;

  return (
    <Card>
      <div className="p-6 border-b border-secondary-200">
        <h2 className="text-lg font-semibold text-secondary-900">Budget & Billing</h2>
        <p className="text-sm text-secondary-500 mt-1">Configure project budget and hourly rates</p>
      </div>

      <div className="p-6 space-y-6">
        {/* Budget Overview */}
        {project.budget > 0 && (
          <div className="p-4 bg-secondary-50 rounded-xl">
            <div className="flex items-center justify-between mb-2">
              <span className="text-sm font-medium text-secondary-700">Budget Used</span>
              <span className="text-sm text-secondary-500">
                {currencySymbol}{project.budget_spent.toLocaleString()} / {currencySymbol}{project.budget.toLocaleString()}
              </span>
            </div>
            <div className="w-full h-3 bg-secondary-200 rounded-full overflow-hidden">
              <div
                className={cn(
                  'h-full rounded-full transition-all duration-500',
                  budgetProgress < 70 ? 'bg-green-500' : budgetProgress < 90 ? 'bg-yellow-500' : 'bg-red-500'
                )}
                style={{ width: `${budgetProgress}%` }}
              />
            </div>
            <p className="text-xs text-secondary-500 mt-2">{budgetProgress.toFixed(1)}% of budget used</p>
          </div>
        )}

        {/* Budget Form */}
        <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1">Currency</label>
            <select
              value={formData.budget_currency || 'USD'}
              onChange={(e) => setFormData((prev) => ({ ...prev, budget_currency: e.target.value as BudgetCurrency }))}
              className="w-full px-4 py-2.5 border border-secondary-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 transition-colors"
            >
              {CURRENCIES.map((currency) => (
                <option key={currency.value} value={currency.value}>
                  {currency.symbol} - {currency.label}
                </option>
              ))}
            </select>
          </div>

          <Input
            label="Total Budget"
            type="number"
            value={formData.budget?.toString() || ''}
            onChange={(e) => setFormData((prev) => ({ ...prev, budget: parseFloat(e.target.value) || 0 }))}
            placeholder="0.00"
            leftIcon={<DollarSign size={18} />}
          />

          <Input
            label="Hourly Rate"
            type="number"
            value={formData.hourly_rate?.toString() || ''}
            onChange={(e) => setFormData((prev) => ({ ...prev, hourly_rate: parseFloat(e.target.value) || undefined }))}
            placeholder="0.00"
            leftIcon={<Clock size={18} />}
            helperText="Rate per hour for time tracking"
          />
        </div>

        <div className="flex justify-end pt-4 border-t border-secondary-200">
          <Button onClick={onSave} isLoading={isSaving} leftIcon={<Save size={16} />}>
            Save Changes
          </Button>
        </div>
      </div>
    </Card>
  );
};

interface DatesTabProps {
  formData: UpdateKanbanProjectDto;
  setFormData: React.Dispatch<React.SetStateAction<UpdateKanbanProjectDto>>;
  onSave: () => Promise<void>;
  isSaving: boolean;
}

const DatesTab = ({ formData, setFormData, onSave, isSaving }: DatesTabProps) => (
  <Card>
    <div className="p-6 border-b border-secondary-200">
      <h2 className="text-lg font-semibold text-secondary-900">Project Timeline</h2>
      <p className="text-sm text-secondary-500 mt-1">Set project start and due dates</p>
    </div>

    <div className="p-6 space-y-6">
      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        <Input
          label="Start Date"
          type="date"
          value={formData.start_date?.split('T')[0] || ''}
          onChange={(e) => setFormData((prev) => ({ ...prev, start_date: e.target.value || undefined }))}
          leftIcon={<Calendar size={18} />}
        />

        <Input
          label="Due Date"
          type="date"
          value={formData.due_date?.split('T')[0] || ''}
          onChange={(e) => setFormData((prev) => ({ ...prev, due_date: e.target.value || undefined }))}
          leftIcon={<Calendar size={18} />}
        />
      </div>

      <div className="flex justify-end pt-4 border-t border-secondary-200">
        <Button onClick={onSave} isLoading={isSaving} leftIcon={<Save size={16} />}>
          Save Changes
        </Button>
      </div>
    </div>
  </Card>
);

interface DangerTabProps {
  project: KanbanProject;
  onArchive: () => void;
  onDelete: () => void;
  isArchiving: boolean;
  isDeleting: boolean;
}

const DangerTab = ({ project, onArchive, onDelete, isArchiving, isDeleting }: DangerTabProps) => (
  <Card>
    <div className="p-6 border-b border-secondary-200">
      <h2 className="text-lg font-semibold text-error-600">Danger Zone</h2>
      <p className="text-sm text-secondary-500 mt-1">Irreversible and destructive actions</p>
    </div>

    <div className="p-6 space-y-6">
      {/* Archive Project */}
      <div className="flex items-center justify-between p-4 border border-secondary-200 rounded-xl">
        <div>
          <h3 className="font-semibold text-secondary-900">Archive Project</h3>
          <p className="text-sm text-secondary-500 mt-1">
            Hide this project from active projects. You can restore it later.
          </p>
        </div>
        <Button
          variant="outline"
          onClick={onArchive}
          isLoading={isArchiving}
          disabled={project.status === 'archived'}
        >
          {project.status === 'archived' ? 'Already Archived' : 'Archive'}
        </Button>
      </div>

      {/* Delete Project */}
      <div className="flex items-center justify-between p-4 border border-error-200 bg-error-50 rounded-xl">
        <div>
          <h3 className="font-semibold text-error-700">Delete Project</h3>
          <p className="text-sm text-error-600 mt-1">
            Permanently delete this project and all its data. This action cannot be undone.
          </p>
        </div>
        <Button variant="danger" onClick={onDelete} isLoading={isDeleting} leftIcon={<Trash2 size={16} />}>
          Delete Project
        </Button>
      </div>
    </div>
  </Card>
);

// ============================================
// Main Settings Page Component
// ============================================

export default function ProjectSettingsPage() {
  const params = useParams();
  const router = useRouter();
  const projectUuid = params.uuid as string;

  // State
  const [activeTab, setActiveTab] = useState<SettingsTab>('general');
  const [project, setProject] = useState<KanbanProject | null>(null);
  const [members, setMembers] = useState<KanbanProjectMember[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [isSaving, setIsSaving] = useState(false);
  const [isArchiving, setIsArchiving] = useState(false);
  const [isDeleting, setIsDeleting] = useState(false);
  const [showInviteModal, setShowInviteModal] = useState(false);
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false);
  const [memberToRemove, setMemberToRemove] = useState<string | null>(null);

  // Form data
  const [formData, setFormData] = useState<UpdateKanbanProjectDto>({});

  // Get current user from auth store (assuming it exists)
  const currentUserUuid = useMemo(() => {
    // This would typically come from auth store
    // For now, check if current user is owner based on project data
    return project?.owner_user_uuid || '';
  }, [project]);

  const isOwner = useMemo(() => {
    return project?.current_user_role === 'owner' || project?.owner_user_uuid === currentUserUuid;
  }, [project, currentUserUuid]);

  // Load project data
  useEffect(() => {
    const loadData = async () => {
      setIsLoading(true);
      try {
        const [projectData, membersData] = await Promise.all([
          kanbanService.getProject(projectUuid),
          kanbanService.getProjectMembers(projectUuid),
        ]);

        setProject(projectData);
        setMembers(membersData);
        setFormData({
          name: projectData.name,
          description: projectData.description,
          slug: projectData.slug,
          status: projectData.status,
          visibility: projectData.visibility,
          color: projectData.color,
          budget: projectData.budget,
          budget_currency: projectData.budget_currency,
          hourly_rate: projectData.hourly_rate,
          start_date: projectData.start_date,
          due_date: projectData.due_date,
        });
      } catch (error) {
        console.error('Failed to load project:', error);
        toast.error('Failed to load project settings');
      } finally {
        setIsLoading(false);
      }
    };

    if (projectUuid) {
      loadData();
    }
  }, [projectUuid]);

  // Handlers
  const handleSave = useCallback(async () => {
    if (!project) return;

    setIsSaving(true);
    try {
      const updated = await kanbanService.updateProject(project.uuid, formData);
      setProject(updated);
      toast.success('Project settings saved');
    } catch (error) {
      console.error('Failed to save:', error);
      toast.error('Failed to save settings');
    } finally {
      setIsSaving(false);
    }
  }, [project, formData]);

  const handleInviteMember = useCallback(
    async (userUuid: string, role: KanbanMemberRole) => {
      if (!project) return;

      try {
        await kanbanService.addProjectMember(project.uuid, { user_uuid: userUuid, role });
        const updatedMembers = await kanbanService.getProjectMembers(project.uuid);
        setMembers(updatedMembers);
        toast.success('Member added successfully');
      } catch (error) {
        console.error('Failed to add member:', error);
        toast.error('Failed to add member');
        throw error;
      }
    },
    [project]
  );

  const existingMemberUuids = useMemo(() => {
    return members.map((m) => m.user_uuid);
  }, [members]);

  const handleUpdateMemberRole = useCallback(
    async (userUuid: string, role: KanbanMemberRole) => {
      if (!project) return;

      try {
        await kanbanService.updateProjectMember(project.uuid, userUuid, { role });
        setMembers((prev) =>
          prev.map((m) => (m.user_uuid === userUuid ? { ...m, role } : m))
        );
        toast.success('Member role updated');
      } catch (error) {
        console.error('Failed to update role:', error);
        toast.error('Failed to update member role');
        throw error;
      }
    },
    [project]
  );

  const handleRemoveMember = useCallback(
    async (userUuid: string) => {
      if (!project) return;

      try {
        await kanbanService.removeProjectMember(project.uuid, userUuid);
        setMembers((prev) => prev.filter((m) => m.user_uuid !== userUuid));
        toast.success('Member removed from project');
      } catch (error) {
        console.error('Failed to remove member:', error);
        toast.error('Failed to remove member');
      }
      setMemberToRemove(null);
    },
    [project]
  );

  const handleArchive = useCallback(async () => {
    if (!project) return;

    setIsArchiving(true);
    try {
      await kanbanService.updateProject(project.uuid, { status: 'archived' });
      setProject((prev) => (prev ? { ...prev, status: 'archived' } : null));
      toast.success('Project archived');
    } catch (error) {
      console.error('Failed to archive:', error);
      toast.error('Failed to archive project');
    } finally {
      setIsArchiving(false);
    }
  }, [project]);

  const handleDelete = useCallback(async () => {
    if (!project) return;

    setIsDeleting(true);
    try {
      await kanbanService.deleteProject(project.uuid);
      toast.success('Project deleted');
      router.push('/dashboard/projects');
    } catch (error) {
      console.error('Failed to delete:', error);
      toast.error('Failed to delete project');
    } finally {
      setIsDeleting(false);
      setShowDeleteConfirm(false);
    }
  }, [project, router]);

  // Loading state
  if (isLoading) {
    return (
      <div className="h-full flex items-center justify-center">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary-500" />
      </div>
    );
  }

  if (!project) {
    return (
      <div className="h-full flex flex-col items-center justify-center text-secondary-500">
        <AlertTriangle size={48} className="mb-4" />
        <p className="text-lg font-medium">Project not found</p>
        <Button variant="outline" onClick={() => router.push('/dashboard/projects')} className="mt-4">
          Back to Projects
        </Button>
      </div>
    );
  }

  return (
    <div className="h-full overflow-auto">
      <div className="max-w-6xl mx-auto p-6 space-y-6">
        {/* Header */}
        <div className="flex items-center gap-4">
          <Button
            variant="ghost"
            size="sm"
            onClick={() => router.push(`/dashboard/projects/${projectUuid}`)}
          >
            <ArrowLeft size={18} />
          </Button>
          <div className="flex-1">
            <div className="flex items-center gap-3">
              {project.color && (
                <div
                  className="w-4 h-4 rounded-full"
                  style={{ backgroundColor: project.color }}
                />
              )}
              <h1 className="text-2xl font-bold text-secondary-900">{project.name}</h1>
              <Badge variant={project.status === 'active' ? 'success' : 'secondary'}>
                {PROJECT_STATUSES.find((s) => s.value === project.status)?.label || project.status}
              </Badge>
            </div>
            <p className="text-secondary-500 mt-1">Project Settings</p>
          </div>
        </div>

        {/* Main Content */}
        <div className="flex flex-col lg:flex-row gap-6">
          {/* Sidebar Navigation */}
          <div className="lg:w-64 flex-shrink-0">
            <Card padding="sm">
              <nav className="space-y-1">
                {TABS.map((tab) => {
                  const Icon = tab.icon;
                  const isActive = activeTab === tab.id;
                  const isDanger = tab.id === 'danger';

                  return (
                    <button
                      key={tab.id}
                      onClick={() => setActiveTab(tab.id)}
                      className={cn(
                        'w-full flex items-center gap-3 px-4 py-3 rounded-lg text-left transition-colors',
                        isActive
                          ? isDanger
                            ? 'bg-error-50 text-error-600 font-medium'
                            : 'bg-primary-50 text-primary-600 font-medium'
                          : isDanger
                          ? 'text-error-600 hover:bg-error-50'
                          : 'text-secondary-600 hover:bg-secondary-50'
                      )}
                    >
                      <Icon size={20} />
                      <span>{tab.label}</span>
                    </button>
                  );
                })}
              </nav>
            </Card>
          </div>

          {/* Content Area */}
          <div className="flex-1 min-w-0">
            {activeTab === 'general' && (
              <GeneralTab
                project={project}
                formData={formData}
                setFormData={setFormData}
                onSave={handleSave}
                isSaving={isSaving}
              />
            )}

            {activeTab === 'members' && (
              <MembersTab
                members={members}
                currentUserUuid={currentUserUuid}
                isOwner={isOwner}
                onInvite={() => setShowInviteModal(true)}
                onUpdateRole={handleUpdateMemberRole}
                onRemove={(uuid) => setMemberToRemove(uuid)}
              />
            )}

            {activeTab === 'visibility' && (
              <VisibilityTab
                formData={formData}
                setFormData={setFormData}
                onSave={handleSave}
                isSaving={isSaving}
              />
            )}

            {activeTab === 'budget' && (
              <BudgetTab
                project={project}
                formData={formData}
                setFormData={setFormData}
                onSave={handleSave}
                isSaving={isSaving}
              />
            )}

            {activeTab === 'dates' && (
              <DatesTab
                formData={formData}
                setFormData={setFormData}
                onSave={handleSave}
                isSaving={isSaving}
              />
            )}

            {activeTab === 'danger' && (
              <DangerTab
                project={project}
                onArchive={handleArchive}
                onDelete={() => setShowDeleteConfirm(true)}
                isArchiving={isArchiving}
                isDeleting={isDeleting}
              />
            )}
          </div>
        </div>
      </div>

      {/* Invite Member Modal */}
      <InviteMemberModal
        isOpen={showInviteModal}
        onClose={() => setShowInviteModal(false)}
        onInvite={handleInviteMember}
        existingMemberUuids={existingMemberUuids}
      />

      {/* Delete Confirmation */}
      <ConfirmDialog
        isOpen={showDeleteConfirm}
        onClose={() => setShowDeleteConfirm(false)}
        onConfirm={handleDelete}
        title="Delete Project"
        message={`Are you sure you want to delete "${project.name}"? This will permanently delete all boards, tasks, and comments. This action cannot be undone.`}
        variant="danger"
        confirmText="Delete Project"
        isLoading={isDeleting}
      />

      {/* Remove Member Confirmation */}
      <ConfirmDialog
        isOpen={!!memberToRemove}
        onClose={() => setMemberToRemove(null)}
        onConfirm={() => memberToRemove && handleRemoveMember(memberToRemove)}
        title="Remove Member"
        message="Are you sure you want to remove this member from the project? They will lose access to all project content."
        variant="warning"
        confirmText="Remove Member"
      />
    </div>
  );
}

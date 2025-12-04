'use client';

import React, { useState, useEffect, useCallback } from 'react';
import {
  ShieldCheck,
  Plus,
  Edit,
  Trash2,
  Users,
  Loader2,
  Lock,
  Star,
} from 'lucide-react';
import { Button, Card, Badge, ConfirmDialog } from '@/components/ui';
import { useNamespace } from '@/contexts/NamespaceContext';
import { namespaceService } from '@/services';
import type { NamespaceRole, NamespacePermissions, NamespaceModuleMeta, NamespaceActionMeta } from '@/types';
import toast from 'react-hot-toast';

export default function NamespaceRolesPage() {
  const { currentNamespace, isNamespaceOwner, hasPermission } = useNamespace();
  const [roles, setRoles] = useState<NamespaceRole[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [modules, setModules] = useState<NamespaceModuleMeta[]>([]);
  const [actions, setActions] = useState<NamespaceActionMeta[]>([]);
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);
  const [roleToDelete, setRoleToDelete] = useState<NamespaceRole | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);
  const [editModalOpen, setEditModalOpen] = useState(false);
  const [selectedRole, setSelectedRole] = useState<NamespaceRole | null>(null);
  const [createModalOpen, setCreateModalOpen] = useState(false);

  const canManageRoles = isNamespaceOwner || hasPermission('roles', 'manage');

  const fetchRoles = useCallback(async () => {
    if (!currentNamespace) return;
    setIsLoading(true);
    try {
      const data = await namespaceService.getRoles({ include_member_count: true });
      setRoles(data);
    } catch (error) {
      console.error('Failed to fetch roles:', error);
      toast.error('Failed to load roles');
    } finally {
      setIsLoading(false);
    }
  }, [currentNamespace]);

  const fetchMeta = useCallback(async () => {
    if (!currentNamespace) return;
    try {
      const meta = await namespaceService.getPermissionsMeta();
      setModules(meta.modules);
      setActions(meta.actions);
    } catch (error) {
      console.error('Failed to fetch permissions meta:', error);
    }
  }, [currentNamespace]);

  useEffect(() => {
    fetchRoles();
    fetchMeta();
  }, [fetchRoles, fetchMeta]);

  const handleEditClick = (role: NamespaceRole) => {
    setSelectedRole(role);
    setEditModalOpen(true);
  };

  const handleDeleteClick = (role: NamespaceRole) => {
    setRoleToDelete(role);
    setDeleteDialogOpen(true);
  };

  const handleDeleteConfirm = async () => {
    if (!roleToDelete) return;
    setIsDeleting(true);
    try {
      await namespaceService.deleteRole(roleToDelete.uuid);
      toast.success('Role deleted successfully');
      fetchRoles();
    } catch (error) {
      toast.error('Failed to delete role');
    } finally {
      setIsDeleting(false);
      setDeleteDialogOpen(false);
      setRoleToDelete(null);
    }
  };

  if (!currentNamespace) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-bold text-secondary-900">Roles & Permissions</h1>
        <Card className="p-8 text-center">
          <ShieldCheck className="w-12 h-12 text-secondary-300 mx-auto mb-4" />
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
          <h1 className="text-2xl font-bold text-secondary-900">Roles & Permissions</h1>
          <p className="text-secondary-500 mt-1">
            Manage roles for {currentNamespace.name}
          </p>
        </div>

        {canManageRoles && (
          <Button onClick={() => setCreateModalOpen(true)}>
            <Plus className="w-4 h-4 mr-2" />
            Create Role
          </Button>
        )}
      </div>

      {/* Roles Grid */}
      {isLoading ? (
        <div className="flex items-center justify-center py-12">
          <Loader2 className="w-8 h-8 animate-spin text-primary-500" />
        </div>
      ) : roles.length === 0 ? (
        <Card className="p-8 text-center">
          <ShieldCheck className="w-12 h-12 text-secondary-300 mx-auto mb-4" />
          <p className="text-secondary-500">No roles found</p>
        </Card>
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          {roles.map((role) => (
            <RoleCard
              key={role.uuid}
              role={role}
              canManage={canManageRoles}
              onEdit={() => handleEditClick(role)}
              onDelete={() => handleDeleteClick(role)}
            />
          ))}
        </div>
      )}

      {/* Delete Confirmation */}
      <ConfirmDialog
        isOpen={deleteDialogOpen}
        onClose={() => setDeleteDialogOpen(false)}
        onConfirm={handleDeleteConfirm}
        title="Delete Role"
        message={`Are you sure you want to delete the "${roleToDelete?.display_name || roleToDelete?.role_name}" role? This action cannot be undone.`}
        confirmText="Delete"
        variant="danger"
        isLoading={isDeleting}
      />

      {/* Create Modal */}
      {createModalOpen && (
        <RoleModal
          modules={modules}
          actions={actions}
          onClose={() => setCreateModalOpen(false)}
          onSuccess={() => {
            setCreateModalOpen(false);
            fetchRoles();
          }}
        />
      )}

      {/* Edit Modal */}
      {editModalOpen && selectedRole && (
        <RoleModal
          role={selectedRole}
          modules={modules}
          actions={actions}
          onClose={() => {
            setEditModalOpen(false);
            setSelectedRole(null);
          }}
          onSuccess={() => {
            setEditModalOpen(false);
            setSelectedRole(null);
            fetchRoles();
          }}
        />
      )}
    </div>
  );
}

// Role Card Component
function RoleCard({
  role,
  canManage,
  onEdit,
  onDelete,
}: {
  role: NamespaceRole;
  canManage: boolean;
  onEdit: () => void;
  onDelete: () => void;
}) {
  const permissions = typeof role.permissions === 'string'
    ? JSON.parse(role.permissions || '{}')
    : role.permissions || {};

  const permissionCount = Object.values(permissions).reduce(
    (acc: number, perms: unknown) => acc + (Array.isArray(perms) ? perms.length : 0),
    0
  );

  return (
    <Card className="p-5">
      <div className="flex items-start justify-between mb-4">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 rounded-lg bg-primary-100 flex items-center justify-center">
            <ShieldCheck className="w-5 h-5 text-primary-600" />
          </div>
          <div>
            <div className="flex items-center gap-2">
              <h3 className="font-semibold text-secondary-900">
                {role.display_name || role.role_name}
              </h3>
              {role.is_system && (
                <span title="System role">
                  <Lock className="w-3.5 h-3.5 text-secondary-400" />
                </span>
              )}
              {role.is_default && (
                <span title="Default role">
                  <Star className="w-3.5 h-3.5 text-amber-500" />
                </span>
              )}
            </div>
            <p className="text-sm text-secondary-500">{role.role_name}</p>
          </div>
        </div>

        {canManage && !role.is_system && (
          <div className="flex items-center gap-1">
            <button
              onClick={onEdit}
              className="p-1.5 text-secondary-500 hover:text-primary-600 hover:bg-primary-50 rounded-lg transition-colors"
              title="Edit role"
            >
              <Edit className="w-4 h-4" />
            </button>
            <button
              onClick={onDelete}
              className="p-1.5 text-secondary-500 hover:text-error-600 hover:bg-error-50 rounded-lg transition-colors"
              title="Delete role"
            >
              <Trash2 className="w-4 h-4" />
            </button>
          </div>
        )}
      </div>

      {role.description && (
        <p className="text-sm text-secondary-600 mb-4">{role.description}</p>
      )}

      <div className="flex items-center justify-between text-sm">
        <div className="flex items-center gap-1.5 text-secondary-500">
          <Users className="w-4 h-4" />
          <span>{role.member_count || 0} members</span>
        </div>
        <Badge variant="default">{permissionCount} permissions</Badge>
      </div>
    </Card>
  );
}

// Role Create/Edit Modal
function RoleModal({
  role,
  modules,
  actions,
  onClose,
  onSuccess,
}: {
  role?: NamespaceRole;
  modules: NamespaceModuleMeta[];
  actions: NamespaceActionMeta[];
  onClose: () => void;
  onSuccess: () => void;
}) {
  const isEdit = !!role;
  const [formData, setFormData] = useState({
    role_name: role?.role_name || '',
    display_name: role?.display_name || '',
    description: role?.description || '',
    is_default: role?.is_default || false,
    priority: role?.priority || 0,
  });
  const [permissions, setPermissions] = useState<NamespacePermissions>(() => {
    if (role?.permissions) {
      return typeof role.permissions === 'string'
        ? JSON.parse(role.permissions)
        : role.permissions;
    }
    return {} as NamespacePermissions;
  });
  const [isSubmitting, setIsSubmitting] = useState(false);

  const handlePermissionToggle = (module: string, action: string) => {
    setPermissions((prev) => {
      const modulePerms = prev[module as keyof NamespacePermissions] || [];
      const newPerms = modulePerms.includes(action as never)
        ? modulePerms.filter((p) => p !== action)
        : [...modulePerms, action];
      return { ...prev, [module]: newPerms };
    });
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!formData.role_name.trim()) {
      toast.error('Role name is required');
      return;
    }

    setIsSubmitting(true);
    try {
      if (isEdit && role) {
        await namespaceService.updateRole(role.uuid, {
          ...formData,
          permissions,
        });
        toast.success('Role updated successfully');
      } else {
        await namespaceService.createRole({
          ...formData,
          permissions,
        });
        toast.success('Role created successfully');
      }
      onSuccess();
    } catch (error) {
      toast.error(isEdit ? 'Failed to update role' : 'Failed to create role');
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center overflow-y-auto">
      <div className="absolute inset-0 bg-secondary-900/50 backdrop-blur-sm" onClick={onClose} />
      <div className="relative bg-white rounded-xl shadow-2xl w-full max-w-2xl mx-4 my-8 max-h-[90vh] overflow-y-auto">
        <div className="sticky top-0 bg-white px-6 py-4 border-b border-secondary-200">
          <h2 className="text-xl font-semibold text-secondary-900">
            {isEdit ? 'Edit Role' : 'Create New Role'}
          </h2>
        </div>

        <form onSubmit={handleSubmit} className="p-6 space-y-6">
          {/* Basic Info */}
          <div className="space-y-4">
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <div>
                <label className="block text-sm font-medium text-secondary-700 mb-1.5">
                  Role Name <span className="text-error-500">*</span>
                </label>
                <input
                  type="text"
                  value={formData.role_name}
                  onChange={(e) =>
                    setFormData((prev) => ({ ...prev, role_name: e.target.value }))
                  }
                  placeholder="manager"
                  disabled={isEdit && role?.is_system}
                  className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 disabled:bg-secondary-50"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-secondary-700 mb-1.5">
                  Display Name
                </label>
                <input
                  type="text"
                  value={formData.display_name}
                  onChange={(e) =>
                    setFormData((prev) => ({ ...prev, display_name: e.target.value }))
                  }
                  placeholder="Manager"
                  className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
                />
              </div>
            </div>

            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1.5">
                Description
              </label>
              <textarea
                value={formData.description}
                onChange={(e) =>
                  setFormData((prev) => ({ ...prev, description: e.target.value }))
                }
                placeholder="Role description..."
                rows={2}
                className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 resize-none"
              />
            </div>

            <div className="flex items-center gap-4">
              <label className="flex items-center gap-2 cursor-pointer">
                <input
                  type="checkbox"
                  checked={formData.is_default}
                  onChange={(e) =>
                    setFormData((prev) => ({ ...prev, is_default: e.target.checked }))
                  }
                  className="w-4 h-4 text-primary-600 border-secondary-300 rounded focus:ring-primary-500"
                />
                <span className="text-sm text-secondary-700">Default role for new members</span>
              </label>
            </div>
          </div>

          {/* Permissions */}
          <div>
            <h3 className="text-sm font-semibold text-secondary-900 mb-3">Permissions</h3>
            <div className="border border-secondary-200 rounded-lg overflow-hidden">
              <table className="w-full">
                <thead className="bg-secondary-50">
                  <tr>
                    <th className="px-4 py-2 text-left text-xs font-medium text-secondary-500 uppercase">
                      Module
                    </th>
                    {actions.map((action) => (
                      <th
                        key={action.name}
                        className="px-2 py-2 text-center text-xs font-medium text-secondary-500 uppercase"
                      >
                        {action.display_name}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody className="divide-y divide-secondary-200">
                  {modules.map((module) => (
                    <tr key={module.name} className="hover:bg-secondary-50">
                      <td className="px-4 py-3">
                        <p className="text-sm font-medium text-secondary-900">
                          {module.display_name}
                        </p>
                        <p className="text-xs text-secondary-500">{module.description}</p>
                      </td>
                      {actions.map((action) => {
                        const modulePerms =
                          permissions[module.name as keyof NamespacePermissions] || [];
                        const isChecked = modulePerms.includes(action.name as never);
                        return (
                          <td key={action.name} className="px-2 py-3 text-center">
                            <input
                              type="checkbox"
                              checked={isChecked}
                              onChange={() =>
                                handlePermissionToggle(module.name, action.name)
                              }
                              className="w-4 h-4 text-primary-600 border-secondary-300 rounded focus:ring-primary-500"
                            />
                          </td>
                        );
                      })}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>

          {/* Actions */}
          <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
            <Button type="button" variant="secondary" onClick={onClose}>
              Cancel
            </Button>
            <Button type="submit" disabled={isSubmitting || !formData.role_name.trim()}>
              {isSubmitting && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}
              {isEdit ? 'Update Role' : 'Create Role'}
            </Button>
          </div>
        </form>
      </div>
    </div>
  );
}

'use client';

import React, { useState, useCallback, useEffect, memo, useMemo } from 'react';
import Modal from '@/components/ui/Modal';
import { Button } from '@/components/ui';
import { RoleBadge } from '@/components/permissions';
import {
  Shield,
  Check,
  X,
  LayoutDashboard,
  Users,
  Store,
  Package,
  ShoppingCart,
  UserCheck,
  Settings,
  Loader2,
  Rocket,
  Building2,
  MessageCircle,
  Truck,
  BarChart,
  Kanban,
} from 'lucide-react';
import {
  rolesService,
  NAMESPACE_MODULES,
  PERMISSION_ACTIONS,
  type NamespaceRole,
} from '@/services';
import { cn } from '@/lib/utils';
import toast from 'react-hot-toast';
import type { PermissionAction, NamespacePermissions, NamespaceModule } from '@/types';

export interface EditRolePermissionsModalProps {
  isOpen: boolean;
  onClose: () => void;
  role: NamespaceRole;
  onSuccess?: () => void;
}

// Icon mapping for modules
const MODULE_ICONS: Record<string, React.FC<{ className?: string }>> = {
  dashboard: LayoutDashboard,
  users: Users,
  roles: Shield,
  stores: Store,
  products: Package,
  orders: ShoppingCart,
  customers: UserCheck,
  settings: Settings,
  namespace: Building2,
  services: Rocket,
  chat: MessageCircle,
  delivery: Truck,
  reports: BarChart,
  projects: Kanban,
};

const EditRolePermissionsModal: React.FC<EditRolePermissionsModalProps> = memo(
  function EditRolePermissionsModal({ isOpen, onClose, role, onSuccess }) {
    const [permissions, setPermissions] = useState<NamespacePermissions>({});
    const [isLoading, setIsLoading] = useState(true);
    const [isSaving, setIsSaving] = useState(false);

    // Check if this is the owner role (read-only, full access)
    const isOwnerRole = useMemo(() => {
      return role.role_name.toLowerCase() === 'owner';
    }, [role.role_name]);

    // Check if this is a system role
    const isSystemRole = useMemo(() => {
      return role.is_system;
    }, [role.is_system]);

    // Load current permissions when modal opens
    useEffect(() => {
      if (isOpen && role) {
        loadPermissions();
      }
    }, [isOpen, role]);

    const loadPermissions = async () => {
      setIsLoading(true);
      try {
        // Get role details with permissions
        const response = await rolesService.getRole(role.id);
        const roleData = response.role;

        if (roleData.permissions) {
          // Parse permissions if they're stored as a string
          let parsed: NamespacePermissions;
          if (typeof roleData.permissions === 'string') {
            try {
              parsed = JSON.parse(roleData.permissions);
            } catch {
              parsed = {};
            }
          } else {
            parsed = roleData.permissions as NamespacePermissions;
          }
          setPermissions(parsed);
        } else {
          // Initialize with empty permissions
          const empty: NamespacePermissions = {};
          NAMESPACE_MODULES.forEach(module => {
            empty[module.value as NamespaceModule] = [];
          });
          setPermissions(empty);
        }
      } catch (error) {
        console.error('Failed to load permissions:', error);
        // Initialize with empty permissions
        const empty: NamespacePermissions = {};
        NAMESPACE_MODULES.forEach(module => {
          empty[module.value as NamespaceModule] = [];
        });
        setPermissions(empty);
      } finally {
        setIsLoading(false);
      }
    };

    const togglePermission = useCallback(
      (module: NamespaceModule, action: PermissionAction) => {
        if (isOwnerRole) return; // Don't allow changes to owner role

        setPermissions((prev) => {
          const modulePerms = [...(prev[module] || [])];

          // Handle "manage" (full access) toggle
          if (action === 'manage') {
            if (modulePerms.includes('manage')) {
              // Remove manage
              return { ...prev, [module]: modulePerms.filter((p) => p !== 'manage') };
            } else {
              // Add manage (gives all permissions)
              return { ...prev, [module]: ['manage'] };
            }
          }

          // If manage is already set, remove it when toggling individual permissions
          const permsWithoutManage = modulePerms.filter((p) => p !== 'manage');

          if (permsWithoutManage.includes(action)) {
            // Remove the action
            return { ...prev, [module]: permsWithoutManage.filter((p) => p !== action) };
          } else {
            // Add the action
            return { ...prev, [module]: [...permsWithoutManage, action] };
          }
        });
      },
      [isOwnerRole]
    );

    const hasPermission = useCallback(
      (module: NamespaceModule, action: PermissionAction): boolean => {
        const modulePerms = permissions[module] || [];
        return modulePerms.includes(action) || modulePerms.includes('manage');
      },
      [permissions]
    );

    const handleSave = useCallback(async () => {
      if (isOwnerRole) {
        toast.error('Cannot modify owner role permissions');
        return;
      }

      setIsSaving(true);
      try {
        // Update role permissions via namespace roles API
        await rolesService.updateRole(role.id, {
          permissions: permissions as Record<string, string[]>,
        });

        toast.success('Role permissions updated successfully');
        onClose();
        onSuccess?.();
      } catch (error: unknown) {
        const errorMessage =
          error instanceof Error ? error.message : 'Failed to update permissions';
        toast.error(errorMessage);
      } finally {
        setIsSaving(false);
      }
    }, [permissions, role, isOwnerRole, onClose, onSuccess]);

    const handleClose = useCallback(() => {
      if (!isSaving) {
        onClose();
      }
    }, [isSaving, onClose]);

    // Set all permissions for a module
    const setAllModulePermissions = useCallback(
      (module: NamespaceModule, enabled: boolean) => {
        if (isOwnerRole) return;

        setPermissions((prev) => ({
          ...prev,
          [module]: enabled ? ['create', 'read', 'update', 'delete'] : [],
        }));
      },
      [isOwnerRole]
    );

    return (
      <Modal
        isOpen={isOpen}
        onClose={handleClose}
        title="Edit Role Permissions"
        size="2xl"
      >
        <div className="space-y-6">
          {/* Role Header */}
          <div className="flex items-center justify-between bg-secondary-50 rounded-lg p-4 border border-secondary-200">
            <div className="flex items-center gap-3">
              <div className="w-12 h-12 bg-white rounded-lg flex items-center justify-center shadow-sm">
                <Shield className="w-6 h-6 text-primary-600" />
              </div>
              <div>
                <RoleBadge roleName={role.role_name} size="lg" />
                <p className="text-sm text-secondary-500 mt-1">
                  {role.display_name || role.role_name}
                </p>
                {role.description && (
                  <p className="text-xs text-secondary-400 mt-0.5">{role.description}</p>
                )}
              </div>
            </div>
            <div className="flex flex-col items-end gap-1">
              {isOwnerRole && (
                <span className="text-xs bg-red-100 text-red-700 px-2 py-1 rounded-full font-medium">
                  Owner (Full Access)
                </span>
              )}
              {isSystemRole && !isOwnerRole && (
                <span className="text-xs bg-purple-100 text-purple-700 px-2 py-1 rounded-full font-medium">
                  System Role
                </span>
              )}
              <span className="text-xs text-secondary-400">
                Priority: {role.priority}
              </span>
            </div>
          </div>

          {/* Loading State */}
          {isLoading ? (
            <div className="flex items-center justify-center py-12">
              <Loader2 className="w-8 h-8 animate-spin text-primary-500" />
            </div>
          ) : (
            <>
              {/* Permissions Matrix */}
              <div className="border border-secondary-200 rounded-lg overflow-hidden">
                {/* Header */}
                <div className="bg-secondary-50 border-b border-secondary-200 px-4 py-3">
                  <div className="grid grid-cols-[200px_repeat(5,1fr)] gap-2 text-xs font-semibold text-secondary-600 uppercase tracking-wider">
                    <div>Module</div>
                    {PERMISSION_ACTIONS.map((action) => (
                      <div key={action.value} className="text-center">
                        {action.label}
                      </div>
                    ))}
                  </div>
                </div>

                {/* Permission Rows */}
                <div className="divide-y divide-secondary-200 max-h-[400px] overflow-y-auto">
                  {NAMESPACE_MODULES.map((module) => {
                    const Icon = MODULE_ICONS[module.value] || Shield;
                    const hasFullAccess = hasPermission(module.value as NamespaceModule, 'manage');

                    return (
                      <div
                        key={module.value}
                        className={cn(
                          'px-4 py-3 hover:bg-secondary-50 transition-colors',
                          isOwnerRole && 'bg-red-50/50'
                        )}
                      >
                        <div className="grid grid-cols-[200px_repeat(5,1fr)] gap-2 items-center">
                          {/* Module Name */}
                          <div className="flex items-center gap-2">
                            <Icon className="w-4 h-4 text-secondary-500" />
                            <div className="flex-1 min-w-0">
                              <span className="font-medium text-secondary-900 text-sm">
                                {module.label}
                              </span>
                              <p className="text-xs text-secondary-400 truncate">
                                {module.description}
                              </p>
                            </div>
                            {!isOwnerRole && (
                              <button
                                type="button"
                                onClick={() =>
                                  setAllModulePermissions(
                                    module.value as NamespaceModule,
                                    !hasPermission(module.value as NamespaceModule, 'read')
                                  )
                                }
                                className="text-xs text-primary-600 hover:text-primary-700 hover:underline whitespace-nowrap"
                              >
                                {hasPermission(module.value as NamespaceModule, 'read') ? 'Clear' : 'All'}
                              </button>
                            )}
                          </div>

                          {/* Permission Toggles */}
                          {PERMISSION_ACTIONS.map((action) => {
                            const isChecked =
                              isOwnerRole || hasPermission(module.value as NamespaceModule, action.value);
                            const isManageAction = action.value === 'manage';

                            return (
                              <div key={action.value} className="flex justify-center">
                                <button
                                  type="button"
                                  onClick={() =>
                                    togglePermission(module.value as NamespaceModule, action.value)
                                  }
                                  disabled={isOwnerRole}
                                  className={cn(
                                    'w-8 h-8 rounded-lg flex items-center justify-center transition-all duration-200',
                                    isChecked
                                      ? isManageAction
                                        ? 'bg-purple-100 text-purple-600 border-2 border-purple-300'
                                        : 'bg-success-100 text-success-600 border-2 border-success-300'
                                      : 'bg-secondary-100 text-secondary-400 border-2 border-secondary-200 hover:border-secondary-300',
                                    !isOwnerRole && 'cursor-pointer hover:scale-110',
                                    isOwnerRole && 'cursor-not-allowed opacity-75',
                                    hasFullAccess &&
                                      !isManageAction &&
                                      'bg-purple-50 border-purple-200 text-purple-500'
                                  )}
                                  title={`${action.label} permission for ${module.label}`}
                                >
                                  {isChecked ? (
                                    <Check className="w-4 h-4" strokeWidth={3} />
                                  ) : (
                                    <X className="w-4 h-4" strokeWidth={2} />
                                  )}
                                </button>
                              </div>
                            );
                          })}
                        </div>
                      </div>
                    );
                  })}
                </div>
              </div>

              {/* Legend */}
              <div className="flex items-center gap-6 text-xs text-secondary-500">
                <div className="flex items-center gap-2">
                  <div className="w-6 h-6 rounded bg-success-100 flex items-center justify-center border border-success-300">
                    <Check className="w-3 h-3 text-success-600" />
                  </div>
                  <span>Permission Granted</span>
                </div>
                <div className="flex items-center gap-2">
                  <div className="w-6 h-6 rounded bg-purple-100 flex items-center justify-center border border-purple-300">
                    <Check className="w-3 h-3 text-purple-600" />
                  </div>
                  <span>Full Access (Manage)</span>
                </div>
                <div className="flex items-center gap-2">
                  <div className="w-6 h-6 rounded bg-secondary-100 flex items-center justify-center border border-secondary-200">
                    <X className="w-3 h-3 text-secondary-400" />
                  </div>
                  <span>No Permission</span>
                </div>
              </div>

              {/* Owner Notice */}
              {isOwnerRole && (
                <div className="bg-red-50 rounded-lg p-4 border border-red-200">
                  <div className="flex items-start gap-3">
                    <Shield className="w-5 h-5 text-red-600 mt-0.5" />
                    <div>
                      <p className="text-sm font-medium text-red-900">
                        Owner Role
                      </p>
                      <p className="text-sm text-red-700 mt-1">
                        The owner role has full access to all namespace features and cannot
                        be modified. This ensures there is always a role with complete
                        namespace access.
                      </p>
                    </div>
                  </div>
                </div>
              )}

              {/* Info about permission hierarchy */}
              <div className="bg-blue-50 rounded-lg p-4 border border-blue-200">
                <div className="flex items-start gap-3">
                  <Shield className="w-5 h-5 text-blue-600 mt-0.5" />
                  <div>
                    <p className="text-sm font-medium text-blue-900">
                      Permission Hierarchy
                    </p>
                    <p className="text-sm text-blue-700 mt-1">
                      <strong>Manage</strong> grants all permissions (create, read, update, delete) for that module.
                      Users with multiple roles get the combined permissions from all their roles.
                    </p>
                  </div>
                </div>
              </div>
            </>
          )}

          {/* Actions */}
          <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
            <Button type="button" variant="ghost" onClick={handleClose} disabled={isSaving}>
              {isOwnerRole ? 'Close' : 'Cancel'}
            </Button>
            {!isOwnerRole && (
              <Button onClick={handleSave} isLoading={isSaving}>
                Save Permissions
              </Button>
            )}
          </div>
        </div>
      </Modal>
    );
  }
);

export default EditRolePermissionsModal;

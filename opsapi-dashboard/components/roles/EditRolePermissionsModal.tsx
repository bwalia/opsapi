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
} from 'lucide-react';
import {
  permissionsService,
  DASHBOARD_MODULES,
  PERMISSION_ACTIONS,
} from '@/services';
import { cn } from '@/lib/utils';
import toast from 'react-hot-toast';
import type { Role, DashboardModule, PermissionAction, UserPermissions, Permission } from '@/types';

export interface EditRolePermissionsModalProps {
  isOpen: boolean;
  onClose: () => void;
  role: Role;
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
};

const EditRolePermissionsModal: React.FC<EditRolePermissionsModalProps> = memo(
  function EditRolePermissionsModal({ isOpen, onClose, role, onSuccess }) {
    const [permissions, setPermissions] = useState<UserPermissions>({
      dashboard: [],
      users: [],
      roles: [],
      stores: [],
      products: [],
      orders: [],
      customers: [],
      settings: [],
    });
    const [originalPermissions, setOriginalPermissions] = useState<Permission[]>([]);
    const [isLoading, setIsLoading] = useState(true);
    const [isSaving, setIsSaving] = useState(false);

    // Check if this is the administrative role (read-only, full access)
    const isAdminRole = useMemo(() => {
      return ['administrative', 'admin'].includes(role.role_name.toLowerCase());
    }, [role.role_name]);

    // Load current permissions when modal opens
    useEffect(() => {
      if (isOpen && role) {
        loadPermissions();
      }
    }, [isOpen, role]);

    const loadPermissions = async () => {
      setIsLoading(true);
      try {
        // First try to get permissions from API
        const response = await permissionsService.getPermissions({
          role: role.role_name,
          perPage: 100,
        });

        setOriginalPermissions(response.data);

        if (response.data.length > 0) {
          // Parse permissions from API
          const parsed: UserPermissions = {
            dashboard: [],
            users: [],
            roles: [],
            stores: [],
            products: [],
            orders: [],
            customers: [],
            settings: [],
          };

          for (const perm of response.data) {
            const moduleName = perm.module_machine_name as DashboardModule;
            if (parsed[moduleName] !== undefined) {
              parsed[moduleName] = perm.permissions
                .split(',')
                .map((a) => a.trim()) as PermissionAction[];
            }
          }

          setPermissions(parsed);
        } else {
          // Use default permissions if none in database
          const defaults = permissionsService.getDefaultPermissions(role.role_name);
          setPermissions(defaults);
        }
      } catch (error) {
        console.error('Failed to load permissions:', error);
        // Fall back to defaults
        const defaults = permissionsService.getDefaultPermissions(role.role_name);
        setPermissions(defaults);
      } finally {
        setIsLoading(false);
      }
    };

    const togglePermission = useCallback(
      (module: DashboardModule, action: PermissionAction) => {
        if (isAdminRole) return; // Don't allow changes to admin role

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
      [isAdminRole]
    );

    const hasPermission = useCallback(
      (module: DashboardModule, action: PermissionAction): boolean => {
        const modulePerms = permissions[module] || [];
        return modulePerms.includes(action) || modulePerms.includes('manage');
      },
      [permissions]
    );

    const handleSave = useCallback(async () => {
      if (isAdminRole) {
        toast.error('Cannot modify administrative role permissions');
        return;
      }

      setIsSaving(true);
      try {
        // For each module, create or update permission
        for (const moduleConfig of DASHBOARD_MODULES) {
          const moduleName = moduleConfig.value;
          const modulePerms = permissions[moduleName] || [];
          const permString = modulePerms.join(',');

          // Find existing permission for this role + module
          const existingPerm = originalPermissions.find(
            (p) => p.module_machine_name === moduleName
          );

          if (existingPerm) {
            // Update existing permission
            if (permString) {
              await permissionsService.updatePermission(existingPerm.uuid, {
                permissions: permString,
              });
            } else {
              // Delete if no permissions
              await permissionsService.deletePermission(existingPerm.uuid);
            }
          } else if (permString) {
            // Create new permission
            await permissionsService.createPermission({
              role: role.role_name,
              module_machine_name: moduleName,
              permissions: permString,
            });
          }
        }

        toast.success('Permissions updated successfully');
        onClose();
        onSuccess?.();
      } catch (error: unknown) {
        const errorMessage =
          error instanceof Error ? error.message : 'Failed to update permissions';
        toast.error(errorMessage);
      } finally {
        setIsSaving(false);
      }
    }, [permissions, originalPermissions, role, isAdminRole, onClose, onSuccess]);

    const handleClose = useCallback(() => {
      if (!isSaving) {
        onClose();
      }
    }, [isSaving, onClose]);

    // Set all permissions for a module
    const setAllModulePermissions = useCallback(
      (module: DashboardModule, enabled: boolean) => {
        if (isAdminRole) return;

        setPermissions((prev) => ({
          ...prev,
          [module]: enabled ? ['create', 'read', 'update', 'delete'] : [],
        }));
      },
      [isAdminRole]
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
                {role.description && (
                  <p className="text-sm text-secondary-500 mt-1">{role.description}</p>
                )}
              </div>
            </div>
            {isAdminRole && (
              <span className="text-xs bg-purple-100 text-purple-700 px-2 py-1 rounded-full font-medium">
                Full Access (Read-Only)
              </span>
            )}
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
                <div className="divide-y divide-secondary-200">
                  {DASHBOARD_MODULES.map((module) => {
                    const Icon = MODULE_ICONS[module.value] || Shield;
                    const hasFullAccess = hasPermission(module.value, 'manage');

                    return (
                      <div
                        key={module.value}
                        className={cn(
                          'px-4 py-3 hover:bg-secondary-50 transition-colors',
                          isAdminRole && 'bg-purple-50/50'
                        )}
                      >
                        <div className="grid grid-cols-[200px_repeat(5,1fr)] gap-2 items-center">
                          {/* Module Name */}
                          <div className="flex items-center gap-2">
                            <Icon className="w-4 h-4 text-secondary-500" />
                            <span className="font-medium text-secondary-900">
                              {module.label}
                            </span>
                            {!isAdminRole && (
                              <button
                                type="button"
                                onClick={() =>
                                  setAllModulePermissions(
                                    module.value,
                                    !hasPermission(module.value, 'read')
                                  )
                                }
                                className="ml-auto text-xs text-primary-600 hover:text-primary-700 hover:underline"
                              >
                                {hasPermission(module.value, 'read') ? 'Clear' : 'Enable All'}
                              </button>
                            )}
                          </div>

                          {/* Permission Toggles */}
                          {PERMISSION_ACTIONS.map((action) => {
                            const isChecked =
                              isAdminRole || hasPermission(module.value, action.value);
                            const isManageAction = action.value === 'manage';

                            return (
                              <div key={action.value} className="flex justify-center">
                                <button
                                  type="button"
                                  onClick={() =>
                                    togglePermission(module.value, action.value)
                                  }
                                  disabled={isAdminRole}
                                  className={cn(
                                    'w-8 h-8 rounded-lg flex items-center justify-center transition-all duration-200',
                                    isChecked
                                      ? isManageAction
                                        ? 'bg-purple-100 text-purple-600 border-2 border-purple-300'
                                        : 'bg-success-100 text-success-600 border-2 border-success-300'
                                      : 'bg-secondary-100 text-secondary-400 border-2 border-secondary-200 hover:border-secondary-300',
                                    !isAdminRole && 'cursor-pointer hover:scale-110',
                                    isAdminRole && 'cursor-not-allowed opacity-75',
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
                  <span>Full Access</span>
                </div>
                <div className="flex items-center gap-2">
                  <div className="w-6 h-6 rounded bg-secondary-100 flex items-center justify-center border border-secondary-200">
                    <X className="w-3 h-3 text-secondary-400" />
                  </div>
                  <span>No Permission</span>
                </div>
              </div>

              {/* Admin Notice */}
              {isAdminRole && (
                <div className="bg-purple-50 rounded-lg p-4 border border-purple-200">
                  <div className="flex items-start gap-3">
                    <Shield className="w-5 h-5 text-purple-600 mt-0.5" />
                    <div>
                      <p className="text-sm font-medium text-purple-900">
                        Administrative Role
                      </p>
                      <p className="text-sm text-purple-700 mt-1">
                        The administrative role has full access to all features and cannot
                        be modified. This ensures there is always a role with complete
                        system access.
                      </p>
                    </div>
                  </div>
                </div>
              )}
            </>
          )}

          {/* Actions */}
          <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
            <Button type="button" variant="ghost" onClick={handleClose} disabled={isSaving}>
              {isAdminRole ? 'Close' : 'Cancel'}
            </Button>
            {!isAdminRole && (
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

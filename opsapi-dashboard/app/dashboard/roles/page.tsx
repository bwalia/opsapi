"use client";

import React, { useState, useEffect, useCallback, useRef } from "react";
import { Plus, Search, Trash2, Edit, Shield, Users, Settings } from "lucide-react";
import {
  Button,
  Input,
  Table,
  Pagination,
  Card,
  ConfirmDialog,
} from "@/components/ui";
import { RoleBadge } from "@/components/permissions";
import { AddRoleModal, EditRolePermissionsModal } from "@/components/roles";
import { usePermissions } from "@/contexts/PermissionsContext";
import { rolesService } from "@/services";
import { formatDate } from "@/lib/utils";
import type { Role, TableColumn, PaginatedResponse } from "@/types";
import toast from "react-hot-toast";

export default function RolesPage() {
  const { canCreate, canUpdate, canDelete, isAdmin } = usePermissions();
  const [roles, setRoles] = useState<Role[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState("");
  const [currentPage, setCurrentPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [sortColumn, setSortColumn] = useState("created_at");
  const [sortDirection, setSortDirection] = useState<"asc" | "desc">("desc");
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);
  const [roleToDelete, setRoleToDelete] = useState<Role | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);
  const [addRoleModalOpen, setAddRoleModalOpen] = useState(false);
  const [editPermissionsModalOpen, setEditPermissionsModalOpen] = useState(false);
  const [selectedRole, setSelectedRole] = useState<Role | null>(null);
  const fetchIdRef = useRef(0);

  const perPage = 10;

  const fetchRoles = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);
    try {
      const response: PaginatedResponse<Role> = await rolesService.getRoles({
        page: currentPage,
        perPage,
        orderBy: sortColumn,
        orderDir: sortDirection,
      });

      if (fetchId === fetchIdRef.current) {
        setRoles(response.data || []);
        setTotalPages(response.totalPages || 1);
        setTotalItems(response.total || 0);
      }
    } catch (error) {
      if (fetchId === fetchIdRef.current) {
        console.error("Failed to fetch roles:", error);
        toast.error("Failed to load roles");
      }
    } finally {
      if (fetchId === fetchIdRef.current) {
        setIsLoading(false);
      }
    }
  }, [currentPage, sortColumn, sortDirection]);

  useEffect(() => {
    fetchRoles();
  }, [fetchRoles]);

  const handleSort = (column: string) => {
    if (sortColumn === column) {
      setSortDirection(sortDirection === "asc" ? "desc" : "asc");
    } else {
      setSortColumn(column);
      setSortDirection("asc");
    }
    setCurrentPage(1);
  };

  const handleDeleteClick = (role: Role) => {
    // Prevent deleting system roles
    if (isSystemRole(role.role_name)) {
      toast.error("Cannot delete system roles");
      return;
    }
    setRoleToDelete(role);
    setDeleteDialogOpen(true);
  };

  const handleDeleteConfirm = async () => {
    if (!roleToDelete) return;

    setIsDeleting(true);
    try {
      await rolesService.deleteRole(roleToDelete.uuid);
      toast.success("Role deleted successfully");
      fetchRoles();
    } catch (error) {
      toast.error("Failed to delete role");
    } finally {
      setIsDeleting(false);
      setDeleteDialogOpen(false);
      setRoleToDelete(null);
    }
  };

  const handleEditPermissions = (role: Role) => {
    setSelectedRole(role);
    setEditPermissionsModalOpen(true);
  };

  const isSystemRole = (roleName: string): boolean => {
    const systemRoles = ["administrative", "admin"];
    return systemRoles.includes(roleName.toLowerCase());
  };

  const columns: TableColumn<Role>[] = [
    {
      key: "role_name",
      header: "Role",
      sortable: true,
      render: (role) => (
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 bg-secondary-100 rounded-lg flex items-center justify-center">
            <Shield className="w-5 h-5 text-secondary-600" />
          </div>
          <div>
            <RoleBadge roleName={role.role_name} size="md" />
            {role.description && (
              <p className="text-xs text-secondary-500 mt-1">{role.description}</p>
            )}
          </div>
        </div>
      ),
    },
    {
      key: "users_count",
      header: "Users",
      render: () => (
        <div className="flex items-center gap-2 text-secondary-600">
          <Users className="w-4 h-4 text-secondary-400" />
          <span className="text-sm">-</span>
        </div>
      ),
    },
    {
      key: "created_at",
      header: "Created",
      sortable: true,
      render: (role) => (
        <span className="text-sm text-secondary-600">
          {formatDate(role.created_at)}
        </span>
      ),
    },
    {
      key: "actions",
      header: "",
      width: "w-32",
      render: (role) => (
        <div className="flex items-center gap-2">
          {isAdmin && (
            <button
              onClick={(e) => {
                e.stopPropagation();
                handleEditPermissions(role);
              }}
              className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg transition-colors"
              title="Edit Permissions"
            >
              <Settings className="w-4 h-4" />
            </button>
          )}
          {canUpdate("roles") && (
            <button
              onClick={(e) => {
                e.stopPropagation();
                handleEditPermissions(role);
              }}
              className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg transition-colors"
              title="Edit Role"
            >
              <Edit className="w-4 h-4" />
            </button>
          )}
          {canDelete("roles") && !isSystemRole(role.role_name) && (
            <button
              onClick={(e) => {
                e.stopPropagation();
                handleDeleteClick(role);
              }}
              className="p-1.5 text-secondary-500 hover:text-error-500 hover:bg-error-50 rounded-lg transition-colors"
              title="Delete Role"
            >
              <Trash2 className="w-4 h-4" />
            </button>
          )}
        </div>
      ),
    },
  ];

  const filteredRoles = searchQuery
    ? roles.filter(
        (role) =>
          role.role_name?.toLowerCase().includes(searchQuery.toLowerCase()) ||
          role.description?.toLowerCase().includes(searchQuery.toLowerCase())
      )
    : roles;

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Roles & Permissions</h1>
          <p className="text-secondary-500 mt-1">
            Manage user roles and their access permissions
          </p>
        </div>
        {canCreate("roles") && (
          <Button
            leftIcon={<Plus className="w-4 h-4" />}
            onClick={() => setAddRoleModalOpen(true)}
          >
            Add Role
          </Button>
        )}
      </div>

      {/* Info Card */}
      <Card padding="md" className="bg-primary-50 border-primary-200">
        <div className="flex items-start gap-3">
          <Shield className="w-5 h-5 text-primary-600 mt-0.5" />
          <div>
            <p className="text-sm font-medium text-primary-900">
              Role-Based Access Control
            </p>
            <p className="text-sm text-primary-700 mt-1">
              Assign permissions to roles, then assign roles to users. Users inherit all
              permissions from their assigned role. Administrative role has full access to
              all features.
            </p>
          </div>
        </div>
      </Card>

      {/* Filters */}
      <Card padding="md">
        <div className="flex flex-wrap items-center gap-4">
          <div className="flex-1 min-w-[200px] max-w-sm">
            <Input
              placeholder="Search roles..."
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              leftIcon={<Search className="w-4 h-4" />}
            />
          </div>
        </div>
      </Card>

      {/* Roles Table */}
      <div>
        <Table
          columns={columns}
          data={filteredRoles}
          keyExtractor={(role) => role.uuid}
          onRowClick={(role) => {
            if (isAdmin) {
              handleEditPermissions(role);
            }
          }}
          sortColumn={sortColumn}
          sortDirection={sortDirection}
          onSort={handleSort}
          isLoading={isLoading}
          emptyMessage="No roles found"
        />

        <Pagination
          currentPage={currentPage}
          totalPages={totalPages}
          totalItems={totalItems}
          perPage={perPage}
          onPageChange={setCurrentPage}
        />
      </div>

      {/* Delete Confirmation Dialog */}
      <ConfirmDialog
        isOpen={deleteDialogOpen}
        onClose={() => setDeleteDialogOpen(false)}
        onConfirm={handleDeleteConfirm}
        title="Delete Role"
        message={`Are you sure you want to delete the "${roleToDelete?.role_name}" role? Users with this role will need to be reassigned.`}
        confirmText="Delete"
        variant="danger"
        isLoading={isDeleting}
      />

      {/* Add Role Modal */}
      <AddRoleModal
        isOpen={addRoleModalOpen}
        onClose={() => setAddRoleModalOpen(false)}
        onSuccess={fetchRoles}
      />

      {/* Edit Role Permissions Modal */}
      {selectedRole && (
        <EditRolePermissionsModal
          isOpen={editPermissionsModalOpen}
          onClose={() => {
            setEditPermissionsModalOpen(false);
            setSelectedRole(null);
          }}
          role={selectedRole}
          onSuccess={fetchRoles}
        />
      )}
    </div>
  );
}

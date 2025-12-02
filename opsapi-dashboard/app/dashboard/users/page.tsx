"use client";

import React, { useState, useEffect, useCallback, useRef } from "react";
import { Plus, Search, Trash2, Edit, Mail } from "lucide-react";
import {
  Button,
  Input,
  Table,
  Badge,
  Pagination,
  Card,
  ConfirmDialog,
} from "@/components/ui";
import { AddUserModal } from "@/components/users";
import { RoleBadge } from "@/components/permissions";
import { usePermissions } from "@/contexts/PermissionsContext";
import { usersService } from "@/services";
import { formatDate, getInitials, getFullName } from "@/lib/utils";
import type { User, TableColumn, PaginatedResponse } from "@/types";
import toast from "react-hot-toast";

export default function UsersPage() {
  const { canCreate, canUpdate, canDelete } = usePermissions();
  const [users, setUsers] = useState<User[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState("");
  const [currentPage, setCurrentPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [sortColumn, setSortColumn] = useState("created_at");
  const [sortDirection, setSortDirection] = useState<"asc" | "desc">("desc");
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);
  const [userToDelete, setUserToDelete] = useState<User | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);
  const [addUserModalOpen, setAddUserModalOpen] = useState(false);
  const fetchIdRef = useRef(0);

  const perPage = 10;

  const fetchUsers = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);
    try {
      const response: PaginatedResponse<User> = await usersService.getUsers({
        page: currentPage,
        perPage,
        orderBy: sortColumn,
        orderDir: sortDirection,
      });

      // Only update state if this is still the latest fetch
      if (fetchId === fetchIdRef.current) {
        setUsers(response.data || []);
        setTotalPages(response.totalPages || 1);
        setTotalItems(response.total || 0);
      }
    } catch (error) {
      if (fetchId === fetchIdRef.current) {
        console.error("Failed to fetch users:", error);
        toast.error("Failed to load users");
      }
    } finally {
      if (fetchId === fetchIdRef.current) {
        setIsLoading(false);
      }
    }
  }, [currentPage, sortColumn, sortDirection]);

  useEffect(() => {
    fetchUsers();
  }, [fetchUsers]);

  const handleSort = (column: string) => {
    if (sortColumn === column) {
      setSortDirection(sortDirection === "asc" ? "desc" : "asc");
    } else {
      setSortColumn(column);
      setSortDirection("asc");
    }
    setCurrentPage(1);
  };

  const handleDeleteClick = (user: User) => {
    setUserToDelete(user);
    setDeleteDialogOpen(true);
  };

  const handleDeleteConfirm = async () => {
    if (!userToDelete) return;

    setIsDeleting(true);
    try {
      await usersService.deleteUser(userToDelete.uuid);
      toast.success("User deleted successfully");
      fetchUsers();
    } catch (error) {
      toast.error("Failed to delete user");
    } finally {
      setIsDeleting(false);
      setDeleteDialogOpen(false);
      setUserToDelete(null);
    }
  };

  const columns: TableColumn<User>[] = [
    {
      key: "name",
      header: "User",
      sortable: true,
      render: (user) => (
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 gradient-primary rounded-lg flex items-center justify-center text-white font-semibold text-sm shadow-md shadow-primary-500/25">
            {getInitials(user.first_name, user.last_name)}
          </div>
          <div>
            <p className="font-medium text-secondary-900">
              {getFullName(user.first_name, user.last_name)}
            </p>
            <p className="text-xs text-secondary-500">@{user.username}</p>
          </div>
        </div>
      ),
    },
    {
      key: "email",
      header: "Email",
      sortable: true,
      render: (user) => (
        <div className="flex items-center gap-2 text-secondary-600">
          <Mail className="w-4 h-4 text-secondary-400" />
          <span className="text-sm">{user.email}</span>
        </div>
      ),
    },
    {
      key: "roles",
      header: "Role",
      render: (user) => (
        <RoleBadge
          roleName={user.roles?.[0]?.role_name || user.roles?.[0]?.name || "user"}
          size="sm"
        />
      ),
    },
    {
      key: "active",
      header: "Status",
      render: (user) => (
        <Badge size="sm" status={user.active ? "active" : "inactive"} />
      ),
    },
    {
      key: "created_at",
      header: "Joined",
      sortable: true,
      render: (user) => (
        <span className="text-sm text-secondary-600">
          {formatDate(user.created_at)}
        </span>
      ),
    },
    {
      key: "actions",
      header: "",
      width: "w-20",
      render: (user) => (
        <div className="flex items-center gap-2">
          {canUpdate("users") && (
            <button
              onClick={(e) => {
                e.stopPropagation();
                window.location.href = `/dashboard/users/${user.uuid}`;
              }}
              className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg transition-colors"
            >
              <Edit className="w-4 h-4" />
            </button>
          )}
          {canDelete("users") && (
            <button
              onClick={(e) => {
                e.stopPropagation();
                handleDeleteClick(user);
              }}
              className="p-1.5 text-secondary-500 hover:text-error-500 hover:bg-error-50 rounded-lg transition-colors"
            >
              <Trash2 className="w-4 h-4" />
            </button>
          )}
        </div>
      ),
    },
  ];

  const filteredUsers = searchQuery
    ? users.filter(
        (user) =>
          user.email?.toLowerCase().includes(searchQuery.toLowerCase()) ||
          user.username?.toLowerCase().includes(searchQuery.toLowerCase()) ||
          user.first_name?.toLowerCase().includes(searchQuery.toLowerCase()) ||
          user.last_name?.toLowerCase().includes(searchQuery.toLowerCase())
      )
    : users;

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Users</h1>
          <p className="text-secondary-500 mt-1">Manage your user accounts</p>
        </div>
        {canCreate("users") && (
          <Button leftIcon={<Plus className="w-4 h-4" />} onClick={() => setAddUserModalOpen(true)}>
            Add User
          </Button>
        )}
      </div>

      {/* Filters */}
      <Card padding="md">
        <div className="flex flex-wrap items-center gap-4">
          <div className="flex-1 min-w-[200px] max-w-sm">
            <Input
              placeholder="Search users..."
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              leftIcon={<Search className="w-4 h-4" />}
            />
          </div>
        </div>
      </Card>

      {/* Users Table */}
      <div>
        <Table
          columns={columns}
          data={filteredUsers}
          keyExtractor={(user) => user.uuid}
          onRowClick={(user) => {
            window.location.href = `/dashboard/users/${user.uuid}`;
          }}
          sortColumn={sortColumn}
          sortDirection={sortDirection}
          onSort={handleSort}
          isLoading={isLoading}
          emptyMessage="No users found"
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
        title="Delete User"
        message={`Are you sure you want to delete "${getFullName(
          userToDelete?.first_name,
          userToDelete?.last_name
        )}"? This action cannot be undone.`}
        confirmText="Delete"
        variant="danger"
        isLoading={isDeleting}
      />

      {/* Add User Modal */}
      <AddUserModal
        isOpen={addUserModalOpen}
        onClose={() => setAddUserModalOpen(false)}
        onSuccess={fetchUsers}
      />
    </div>
  );
}

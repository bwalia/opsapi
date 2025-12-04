"use client";

import React, { useState, useEffect, useCallback, useRef, memo } from "react";
import {
  Plus,
  Search,
  Trash2,
  Edit,
  Building2,
  Users,
  Store,
  MoreVertical,
  Eye,
  Crown,
  AlertTriangle,
} from "lucide-react";
import {
  Button,
  Input,
  Table,
  Badge,
  Pagination,
  Card,
  ConfirmDialog,
} from "@/components/ui";
import { CreateNamespaceModal } from "@/components/namespace";
import { RequireAdmin } from "@/components/permissions/PermissionGate";
import { usePermissions } from "@/contexts/PermissionsContext";
import { namespaceService } from "@/services";
import { formatDate, cn } from "@/lib/utils";
import type {
  Namespace,
  TableColumn,
  PaginatedResponse,
  NamespaceStatus,
  NamespacePlan,
} from "@/types";
import toast from "react-hot-toast";
import Link from "next/link";

// ============================================
// Types
// ============================================

interface NamespaceWithCounts extends Namespace {
  member_count?: number;
  store_count?: number;
}

// ============================================
// Sub-components
// ============================================

const StatusBadge = memo(function StatusBadge({
  status,
}: {
  status: NamespaceStatus;
}) {
  const statusConfig: Record<
    NamespaceStatus,
    { variant: "success" | "warning" | "error" | "default"; label: string }
  > = {
    active: { variant: "success", label: "Active" },
    pending: { variant: "warning", label: "Pending" },
    suspended: { variant: "error", label: "Suspended" },
    archived: { variant: "default", label: "Archived" },
  };

  const config = statusConfig[status] || { variant: "default", label: status };

  return <Badge variant={config.variant}>{config.label}</Badge>;
});

const PlanBadge = memo(function PlanBadge({ plan }: { plan: NamespacePlan }) {
  const planConfig: Record<NamespacePlan, { color: string; label: string }> = {
    free: {
      color: "bg-secondary-100 text-secondary-700 border-secondary-200",
      label: "Free",
    },
    starter: {
      color: "bg-info-100 text-info-700 border-info-200",
      label: "Starter",
    },
    professional: {
      color: "bg-primary-100 text-primary-700 border-primary-200",
      label: "Professional",
    },
    enterprise: {
      color: "bg-warning-100 text-warning-700 border-warning-200",
      label: "Enterprise",
    },
  };

  const config = planConfig[plan] || planConfig.free;

  return (
    <span
      className={cn(
        "px-2 py-0.5 rounded text-xs font-medium border",
        config.color
      )}
    >
      {config.label}
    </span>
  );
});

const NamespaceActionsMenu = memo(function NamespaceActionsMenu({
  namespace,
  onView,
  onEdit,
  onDelete,
}: {
  namespace: NamespaceWithCounts;
  onView: () => void;
  onEdit: () => void;
  onDelete: () => void;
}) {
  const [isOpen, setIsOpen] = useState(false);

  useEffect(() => {
    const handleClickOutside = (e: MouseEvent) => {
      const target = e.target as HTMLElement;
      if (!target.closest(`[data-actions-menu="${namespace.uuid}"]`)) {
        setIsOpen(false);
      }
    };

    if (isOpen) {
      document.addEventListener("mousedown", handleClickOutside);
      return () =>
        document.removeEventListener("mousedown", handleClickOutside);
    }
  }, [isOpen, namespace.uuid]);

  const isSystemNamespace =
    namespace.slug === "system" || namespace.slug === "default";

  return (
    <div className="relative" data-actions-menu={namespace.uuid}>
      <button
        onClick={(e) => {
          e.stopPropagation();
          setIsOpen((prev) => !prev);
        }}
        className="p-1.5 text-secondary-500 hover:text-secondary-700 hover:bg-secondary-100 rounded-lg transition-colors"
      >
        <MoreVertical className="w-4 h-4" />
      </button>

      {isOpen && (
        <div className="absolute right-0 z-50 mt-1 w-48 bg-white border border-secondary-200 rounded-lg shadow-lg py-1">
          <button
            onClick={(e) => {
              e.stopPropagation();
              onView();
              setIsOpen(false);
            }}
            className="w-full flex items-center gap-2 px-4 py-2 text-sm text-secondary-700 hover:bg-secondary-50 transition-colors"
          >
            <Eye className="w-4 h-4" />
            View Details
          </button>
          <button
            onClick={(e) => {
              e.stopPropagation();
              onEdit();
              setIsOpen(false);
            }}
            className="w-full flex items-center gap-2 px-4 py-2 text-sm text-secondary-700 hover:bg-secondary-50 transition-colors"
          >
            <Edit className="w-4 h-4" />
            Edit Namespace
          </button>
          {!isSystemNamespace && (
            <>
              <div className="border-t border-secondary-200 my-1" />
              <button
                onClick={(e) => {
                  e.stopPropagation();
                  onDelete();
                  setIsOpen(false);
                }}
                className="w-full flex items-center gap-2 px-4 py-2 text-sm text-error-600 hover:bg-error-50 transition-colors"
              >
                <Trash2 className="w-4 h-4" />
                Archive Namespace
              </button>
            </>
          )}
        </div>
      )}
    </div>
  );
});

const StatusFilter = memo(function StatusFilter({
  value,
  onChange,
}: {
  value: string;
  onChange: (value: string) => void;
}) {
  const options = [
    { value: "", label: "All Statuses" },
    { value: "active", label: "Active" },
    { value: "pending", label: "Pending" },
    { value: "suspended", label: "Suspended" },
    { value: "archived", label: "Archived" },
  ];

  return (
    <select
      value={value}
      onChange={(e) => onChange(e.target.value)}
      className="px-3 py-2.5 rounded-lg border border-secondary-300 text-sm bg-white text-secondary-900 focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
    >
      {options.map((option) => (
        <option key={option.value} value={option.value}>
          {option.label}
        </option>
      ))}
    </select>
  );
});

// ============================================
// Main Page Component
// ============================================

export default function NamespacesAdminPage() {
  const { isAdmin, canCreate } = usePermissions();
  const [namespaces, setNamespaces] = useState<NamespaceWithCounts[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState("");
  const [statusFilter, setStatusFilter] = useState("");
  const [currentPage, setCurrentPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [sortColumn, setSortColumn] = useState("created_at");
  const [sortDirection, setSortDirection] = useState<"asc" | "desc">("desc");
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);
  const [namespaceToDelete, setNamespaceToDelete] =
    useState<NamespaceWithCounts | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);
  const [createModalOpen, setCreateModalOpen] = useState(false);
  const fetchIdRef = useRef(0);

  const perPage = 10;

  const fetchNamespaces = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);
    try {
      const response: PaginatedResponse<NamespaceWithCounts> =
        await namespaceService.getAllNamespaces({
          page: currentPage,
          perPage,
          orderBy: sortColumn,
          orderDir: sortDirection,
          status: statusFilter || undefined,
          search: searchQuery || undefined,
        });

      if (fetchId === fetchIdRef.current) {
        setNamespaces(response.data || []);
        setTotalPages(response.totalPages || 1);
        setTotalItems(response.total || 0);
      }
    } catch (error) {
      if (fetchId === fetchIdRef.current) {
        console.error("Failed to fetch namespaces:", error);
        toast.error("Failed to load namespaces");
      }
    } finally {
      if (fetchId === fetchIdRef.current) {
        setIsLoading(false);
      }
    }
  }, [currentPage, sortColumn, sortDirection, statusFilter, searchQuery]);

  useEffect(() => {
    if (isAdmin) {
      fetchNamespaces();
    }
  }, [fetchNamespaces, isAdmin]);

  // Debounced search
  useEffect(() => {
    const timer = setTimeout(() => {
      setCurrentPage(1);
    }, 300);
    return () => clearTimeout(timer);
  }, [searchQuery]);

  const handleSort = (column: string) => {
    if (sortColumn === column) {
      setSortDirection(sortDirection === "asc" ? "desc" : "asc");
    } else {
      setSortColumn(column);
      setSortDirection("asc");
    }
    setCurrentPage(1);
  };

  const handleDeleteClick = (namespace: NamespaceWithCounts) => {
    setNamespaceToDelete(namespace);
    setDeleteDialogOpen(true);
  };

  const handleDeleteConfirm = async () => {
    if (!namespaceToDelete) return;

    setIsDeleting(true);
    try {
      await namespaceService.deleteNamespaceAdmin(namespaceToDelete.uuid);
      toast.success("Namespace archived successfully");
      fetchNamespaces();
    } catch (error) {
      const message =
        error instanceof Error ? error.message : "Failed to archive namespace";
      toast.error(message);
    } finally {
      setIsDeleting(false);
      setDeleteDialogOpen(false);
      setNamespaceToDelete(null);
    }
  };

  const handleStatusFilterChange = (value: string) => {
    setStatusFilter(value);
    setCurrentPage(1);
  };

  const columns: TableColumn<NamespaceWithCounts>[] = [
    {
      key: "name",
      header: "Namespace",
      sortable: true,
      render: (namespace) => (
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 rounded-lg bg-primary-100 flex items-center justify-center text-primary-600 font-semibold text-sm">
            {namespace.logo_url ? (
              <img
                src={namespace.logo_url}
                alt={namespace.name}
                className="w-full h-full object-cover rounded-lg"
              />
            ) : (
              namespace.name.charAt(0).toUpperCase()
            )}
          </div>
          <div>
            <div className="flex items-center gap-2">
              <p className="font-medium text-secondary-900">{namespace.name}</p>
              {(namespace.slug === "system" ||
                namespace.slug === "default") && (
                <Crown className="w-3.5 h-3.5 text-warning-500" />
              )}
            </div>
            <p className="text-xs text-secondary-500">{namespace.slug}</p>
          </div>
        </div>
      ),
    },
    {
      key: "status",
      header: "Status",
      sortable: true,
      render: (namespace) => <StatusBadge status={namespace.status} />,
    },
    {
      key: "plan",
      header: "Plan",
      sortable: true,
      render: (namespace) => <PlanBadge plan={namespace.plan} />,
    },
    {
      key: "member_count",
      header: "Members",
      render: (namespace) => (
        <div className="flex items-center gap-1.5 text-secondary-600">
          <Users className="w-4 h-4 text-secondary-400" />
          <span className="text-sm">{namespace.member_count || 0}</span>
        </div>
      ),
    },
    {
      key: "store_count",
      header: "Stores",
      render: (namespace) => (
        <div className="flex items-center gap-1.5 text-secondary-600">
          <Store className="w-4 h-4 text-secondary-400" />
          <span className="text-sm">{namespace.store_count || 0}</span>
        </div>
      ),
    },
    {
      key: "created_at",
      header: "Created",
      sortable: true,
      render: (namespace) => (
        <span className="text-sm text-secondary-600">
          {formatDate(namespace.created_at)}
        </span>
      ),
    },
    {
      key: "actions",
      header: "",
      width: "w-12",
      render: (namespace) => (
        <NamespaceActionsMenu
          namespace={namespace}
          onView={() => {
            window.location.href = `/dashboard/namespaces/${namespace.uuid}`;
          }}
          onEdit={() => {
            window.location.href = `/dashboard/namespaces/${namespace.uuid}/edit`;
          }}
          onDelete={() => handleDeleteClick(namespace)}
        />
      ),
    },
  ];

  // Access denied view for non-admins
  if (!isAdmin) {
    return (
      <div className="space-y-6">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Namespaces</h1>
          <p className="text-secondary-500 mt-1">
            Platform namespace management
          </p>
        </div>

        <Card className="p-8 text-center">
          <AlertTriangle className="w-12 h-12 text-warning-500 mx-auto mb-4" />
          <h2 className="text-lg font-semibold text-secondary-900 mb-2">
            Access Restricted
          </h2>
          <p className="text-secondary-500 mb-4">
            You need platform administrator access to manage namespaces.
          </p>
          <p className="text-xs text-secondary-400">
            Your current role must be &quot;administrative&quot; to access this page.
            Try logging out and logging back in to refresh your permissions.
          </p>
        </Card>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Namespaces</h1>
          <p className="text-secondary-500 mt-1">
            Manage platform namespaces and tenants
          </p>
        </div>
        {(isAdmin || canCreate("namespaces")) && (
          <Button
            leftIcon={<Plus className="w-4 h-4" />}
            onClick={() => setCreateModalOpen(true)}
          >
            Create Namespace
          </Button>
        )}
      </div>

      {/* Stats Cards */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <Card className="p-4">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-lg bg-primary-100 flex items-center justify-center">
              <Building2 className="w-5 h-5 text-primary-600" />
            </div>
            <div>
              <p className="text-sm text-secondary-500">Total Namespaces</p>
              <p className="text-xl font-bold text-secondary-900">
                {totalItems}
              </p>
            </div>
          </div>
        </Card>
        <Card className="p-4">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-lg bg-success-100 flex items-center justify-center">
              <Building2 className="w-5 h-5 text-success-600" />
            </div>
            <div>
              <p className="text-sm text-secondary-500">Active</p>
              <p className="text-xl font-bold text-secondary-900">
                {namespaces.filter((n) => n.status === "active").length}
              </p>
            </div>
          </div>
        </Card>
        <Card className="p-4">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-lg bg-warning-100 flex items-center justify-center">
              <Building2 className="w-5 h-5 text-warning-600" />
            </div>
            <div>
              <p className="text-sm text-secondary-500">Pending</p>
              <p className="text-xl font-bold text-secondary-900">
                {namespaces.filter((n) => n.status === "pending").length}
              </p>
            </div>
          </div>
        </Card>
        <Card className="p-4">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-lg bg-error-100 flex items-center justify-center">
              <Building2 className="w-5 h-5 text-error-600" />
            </div>
            <div>
              <p className="text-sm text-secondary-500">Suspended</p>
              <p className="text-xl font-bold text-secondary-900">
                {namespaces.filter((n) => n.status === "suspended").length}
              </p>
            </div>
          </div>
        </Card>
      </div>

      {/* Filters */}
      <Card padding="md">
        <div className="flex flex-wrap items-center gap-4">
          <div className="flex-1 min-w-[200px] max-w-sm">
            <Input
              placeholder="Search namespaces..."
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              leftIcon={<Search className="w-4 h-4" />}
            />
          </div>
          <StatusFilter
            value={statusFilter}
            onChange={handleStatusFilterChange}
          />
        </div>
      </Card>

      {/* Namespaces Table */}
      <div>
        <Table
          columns={columns}
          data={namespaces}
          keyExtractor={(namespace) => namespace.uuid}
          onRowClick={(namespace) => {
            window.location.href = `/dashboard/namespaces/${namespace.uuid}`;
          }}
          sortColumn={sortColumn}
          sortDirection={sortDirection}
          onSort={handleSort}
          isLoading={isLoading}
          emptyMessage="No namespaces found"
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
        title="Archive Namespace"
        message={`Are you sure you want to archive "${namespaceToDelete?.name}"? This will deactivate the namespace and all its resources. This action can be reversed by an administrator.`}
        confirmText="Archive"
        variant="warning"
        isLoading={isDeleting}
      />

      {/* Create Namespace Modal */}
      <CreateNamespaceModal
        isOpen={createModalOpen}
        onClose={() => setCreateModalOpen(false)}
        onSuccess={fetchNamespaces}
        isAdminMode={true}
      />
    </div>
  );
}

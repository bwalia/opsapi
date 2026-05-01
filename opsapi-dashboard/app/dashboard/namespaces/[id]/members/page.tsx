"use client";

import React, { useState, useEffect, useCallback } from "react";
import { useParams, useRouter, useSearchParams } from "next/navigation";
import {
  ArrowLeft,
  Users,
  UserPlus,
  Search,
  RefreshCw,
  AlertTriangle,
  Loader2,
  Filter,
} from "lucide-react";
import {
  Card,
  Button,
  Input,
  Select,
  Badge,
  ConfirmDialog,
} from "@/components/ui";
import {
  MembersTable,
  MemberActions,
  InviteMemberModal,
  InvitationsTable,
} from "@/components/namespace";
import type { MemberActionType } from "@/components/namespace";
import { RequireAdmin } from "@/components/permissions/PermissionGate";
import { usePermissions } from "@/contexts/PermissionsContext";
import { useAuthStore } from "@/store/auth.store";
import { namespaceService } from "@/services";
import type {
  Namespace,
  NamespaceMember,
  NamespaceInvitation,
  PaginatedResponse,
} from "@/types";
import toast from "react-hot-toast";
import Link from "next/link";

type TabType = "members" | "invitations";

export default function NamespaceMembersPage() {
  const params = useParams();
  const router = useRouter();
  const searchParams = useSearchParams();
  const { isAdmin } = usePermissions();
  const { user: currentUser } = useAuthStore();

  const namespaceId = params.id as string;
  const shouldOpenInvite = searchParams.get("invite") === "true";

  // State
  const [namespace, setNamespace] = useState<Namespace | null>(null);
  const [members, setMembers] = useState<NamespaceMember[]>([]);
  const [invitations, setInvitations] = useState<NamespaceInvitation[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [isLoadingMembers, setIsLoadingMembers] = useState(false);
  const [isLoadingInvitations, setIsLoadingInvitations] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // UI State
  const [activeTab, setActiveTab] = useState<TabType>("members");
  const [searchQuery, setSearchQuery] = useState("");
  const [statusFilter, setStatusFilter] = useState<string>("all");
  const [isInviteModalOpen, setIsInviteModalOpen] = useState(shouldOpenInvite);
  const [selectedMember, setSelectedMember] = useState<NamespaceMember | null>(
    null
  );
  const [confirmAction, setConfirmAction] = useState<{
    type: MemberActionType;
    member: NamespaceMember;
  } | null>(null);

  // Pagination
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalMembers, setTotalMembers] = useState(0);

  // Check if current user is namespace owner
  const isNamespaceOwner = namespace?.owner_user_id === currentUser?.id;

  // Fetch namespace details
  const fetchNamespace = useCallback(async () => {
    if (!namespaceId) return;

    try {
      const ns = await namespaceService.getNamespaceById(namespaceId);
      setNamespace(ns);
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to load namespace";
      setError(message);
      toast.error(message);
    }
  }, [namespaceId]);

  // Fetch members
  const fetchMembers = useCallback(async () => {
    if (!namespaceId) return;

    setIsLoadingMembers(true);
    try {
      const response = await namespaceService.getMembers({
        page,
        perPage: 10,
        search: searchQuery || undefined,
        status: statusFilter !== "all" ? statusFilter : undefined,
      });

      // Handle both camelCase and snake_case response formats
      const data = Array.isArray(response?.data) ? response.data : [];
      const total = response?.total ?? 0;
      const totalPagesValue =
        response?.totalPages ??
        (response as unknown as { total_pages?: number })?.total_pages ??
        1;

      setMembers(data);
      setTotalPages(totalPagesValue);
      setTotalMembers(total);
    } catch (err) {
      console.error("Failed to fetch members:", err);
      toast.error("Failed to load members");
      setMembers([]); // Reset to empty array on error
    } finally {
      setIsLoadingMembers(false);
    }
  }, [namespaceId, page, searchQuery, statusFilter]);

  // Fetch invitations
  const fetchInvitations = useCallback(async () => {
    if (!namespaceId) return;

    setIsLoadingInvitations(true);
    try {
      const response = await namespaceService.getInvitations({
        page: 1,
        perPage: 50,
        status: "pending",
      });

      // Ensure we always have an array
      const data = Array.isArray(response?.data) ? response.data : [];
      setInvitations(data);
    } catch (err) {
      console.error("Failed to fetch invitations:", err);
      setInvitations([]); // Reset to empty array on error
    } finally {
      setIsLoadingInvitations(false);
    }
  }, [namespaceId]);

  // Initial load
  useEffect(() => {
    const load = async () => {
      setIsLoading(true);
      await fetchNamespace();
      await Promise.all([fetchMembers(), fetchInvitations()]);
      setIsLoading(false);
    };

    if (isAdmin) {
      load();
    }
  }, [fetchNamespace, fetchMembers, fetchInvitations, isAdmin]);

  // Refetch when filters change
  useEffect(() => {
    if (!isLoading && namespaceId) {
      fetchMembers();
    }
  }, [page, searchQuery, statusFilter]);

  // Handle member actions
  const handleMemberAction = useCallback(
    (action: string, member: NamespaceMember) => {
      setSelectedMember(member);

      if (action === "menu") {
        // Menu is handled by MemberActions component
        return;
      }

      setConfirmAction({ type: action as MemberActionType, member });
    },
    []
  );

  // Execute member action
  const executeAction = useCallback(async () => {
    if (!confirmAction) return;

    const { type, member } = confirmAction;

    try {
      switch (type) {
        case "remove":
          await namespaceService.removeMember(member.uuid);
          toast.success("Member removed successfully");
          break;

        case "suspend":
          await namespaceService.updateMember(member.uuid, {
            status: "suspended",
          });
          toast.success("Member suspended");
          break;

        case "activate":
          await namespaceService.updateMember(member.uuid, {
            status: "active",
          });
          toast.success("Member activated");
          break;

        case "transfer-ownership":
          await namespaceService.transferOwnership(member.uuid);
          toast.success("Ownership transferred successfully");
          break;

        default:
          break;
      }

      // Refresh data
      await fetchMembers();
      await fetchNamespace();
    } catch (err) {
      const message = err instanceof Error ? err.message : "Action failed";
      toast.error(message);
    } finally {
      setConfirmAction(null);
      setSelectedMember(null);
    }
  }, [confirmAction, fetchMembers, fetchNamespace]);

  // Handle invitation actions
  const handleResendInvitation = useCallback(
    async (invitation: NamespaceInvitation) => {
      try {
        await namespaceService.resendInvitation(invitation.uuid);
        toast.success("Invitation resent");
        await fetchInvitations();
      } catch (err) {
        const message =
          err instanceof Error ? err.message : "Failed to resend invitation";
        toast.error(message);
      }
    },
    [fetchInvitations]
  );

  const handleRevokeInvitation = useCallback(
    async (invitation: NamespaceInvitation) => {
      try {
        await namespaceService.revokeInvitation(invitation.uuid);
        toast.success("Invitation revoked");
        await fetchInvitations();
      } catch (err) {
        const message =
          err instanceof Error ? err.message : "Failed to revoke invitation";
        toast.error(message);
      }
    },
    [fetchInvitations]
  );

  // Handle successful invite
  const handleInviteSuccess = useCallback(() => {
    fetchInvitations();
    // Remove invite query param
    router.replace(`/dashboard/namespaces/${namespaceId}/members`);
  }, [fetchInvitations, router, namespaceId]);

  // Get confirmation dialog config
  const getConfirmConfig = () => {
    if (!confirmAction) return null;

    const { type, member } = confirmAction;
    const memberName =
      member.user?.full_name || member.user?.email || "this member";

    const configs: Record<
      MemberActionType,
      { title: string; message: string; variant: "danger" | "warning" | "info" }
    > = {
      remove: {
        title: "Remove Member",
        message: `Are you sure you want to remove ${memberName} from this namespace? They will lose access immediately.`,
        variant: "danger",
      },
      suspend: {
        title: "Suspend Member",
        message: `Are you sure you want to suspend ${memberName}? They will temporarily lose access to this namespace.`,
        variant: "warning",
      },
      activate: {
        title: "Activate Member",
        message: `Are you sure you want to activate ${memberName}? They will regain access to this namespace.`,
        variant: "info",
      },
      "transfer-ownership": {
        title: "Transfer Ownership",
        message: `Are you sure you want to transfer ownership to ${memberName}? You will lose owner privileges.`,
        variant: "danger",
      },
      "edit-roles": {
        title: "Edit Roles",
        message: "",
        variant: "info",
      },
    };

    return configs[type];
  };

  // Access denied view
  if (!isAdmin) {
    return (
      <div className="space-y-6">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">
            Namespace Members
          </h1>
          <p className="text-secondary-500 mt-1">Manage namespace members</p>
        </div>

        <Card className="p-8 text-center">
          <AlertTriangle className="w-12 h-12 text-warning-500 mx-auto mb-4" />
          <h2 className="text-lg font-semibold text-secondary-900 mb-2">
            Access Restricted
          </h2>
          <p className="text-secondary-500 mb-4">
            You need platform administrator access to manage namespace members.
          </p>
          <Link href="/dashboard/namespaces">
            <Button variant="outline">Back to Namespaces</Button>
          </Link>
        </Card>
      </div>
    );
  }

  // Loading state
  if (isLoading) {
    return (
      <div className="space-y-6">
        <div className="flex items-center gap-4">
          <div className="h-10 w-10 bg-secondary-200 rounded animate-pulse" />
          <div className="space-y-2">
            <div className="h-6 w-48 bg-secondary-200 rounded animate-pulse" />
            <div className="h-4 w-32 bg-secondary-200 rounded animate-pulse" />
          </div>
        </div>
        <Card className="p-8 flex items-center justify-center">
          <Loader2 className="w-8 h-8 animate-spin text-primary-500" />
        </Card>
      </div>
    );
  }

  // Error state
  if (error || !namespace) {
    return (
      <div className="space-y-6">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">
            Namespace Members
          </h1>
          <p className="text-secondary-500 mt-1">Manage namespace members</p>
        </div>

        <Card className="p-8 text-center">
          <AlertTriangle className="w-12 h-12 text-error-500 mx-auto mb-4" />
          <h2 className="text-lg font-semibold text-secondary-900 mb-2">
            {error || "Namespace Not Found"}
          </h2>
          <p className="text-secondary-500 mb-4">
            Unable to load namespace members.
          </p>
          <Link href="/dashboard/namespaces">
            <Button variant="outline">Back to Namespaces</Button>
          </Link>
        </Card>
      </div>
    );
  }

  const confirmConfig = getConfirmConfig();
  const pendingInvitationsCount = invitations.filter(
    (inv) => inv.status === "pending"
  ).length;

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-4">
          <Link href={`/dashboard/namespaces/${namespaceId}`}>
            <Button variant="ghost" size="sm" className="p-2">
              <ArrowLeft className="w-5 h-5" />
            </Button>
          </Link>
          <div>
            <div className="flex items-center gap-2">
              <h1 className="text-2xl font-bold text-secondary-900">Members</h1>
              <Badge variant="secondary">{totalMembers}</Badge>
            </div>
            <p className="text-secondary-500 mt-0.5">
              Manage members of{" "}
              <span className="font-medium">{namespace.name}</span>
            </p>
          </div>
        </div>

        <Button onClick={() => setIsInviteModalOpen(true)}>
          <UserPlus className="w-4 h-4 mr-2" />
          Invite Member
        </Button>
      </div>

      {/* Tabs */}
      <div className="flex items-center gap-1 border-b border-secondary-200">
        <button
          className={`px-4 py-2 text-sm font-medium border-b-2 transition-colors ${
            activeTab === "members"
              ? "border-primary-500 text-primary-600"
              : "border-transparent text-secondary-500 hover:text-secondary-700"
          }`}
          onClick={() => setActiveTab("members")}
        >
          <div className="flex items-center gap-2">
            <Users className="w-4 h-4" />
            <span>Members</span>
            <Badge variant="secondary" size="sm">
              {totalMembers}
            </Badge>
          </div>
        </button>
        <button
          className={`px-4 py-2 text-sm font-medium border-b-2 transition-colors ${
            activeTab === "invitations"
              ? "border-primary-500 text-primary-600"
              : "border-transparent text-secondary-500 hover:text-secondary-700"
          }`}
          onClick={() => setActiveTab("invitations")}
        >
          <div className="flex items-center gap-2">
            <UserPlus className="w-4 h-4" />
            <span>Invitations</span>
            {pendingInvitationsCount > 0 && (
              <Badge variant="warning" size="sm">
                {pendingInvitationsCount}
              </Badge>
            )}
          </div>
        </button>
      </div>

      {/* Members Tab Content */}
      {activeTab === "members" && (
        <>
          {/* Filters */}
          <Card className="p-4">
            <div className="flex flex-wrap items-center gap-4">
              {/* Search */}
              <div className="flex-1 min-w-[200px]">
                <div className="relative">
                  <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-secondary-400" />
                  <Input
                    type="text"
                    placeholder="Search members..."
                    value={searchQuery}
                    onChange={(e) => {
                      setSearchQuery(e.target.value);
                      setPage(1);
                    }}
                    className="pl-9"
                  />
                </div>
              </div>

              {/* Status Filter */}
              <div className="w-40">
                <Select
                  value={statusFilter}
                  onChange={(e) => {
                    setStatusFilter(e.target.value);
                    setPage(1);
                  }}
                >
                  <option value="all">All Status</option>
                  <option value="active">Active</option>
                  <option value="invited">Invited</option>
                  <option value="suspended">Suspended</option>
                </Select>
              </div>

              {/* Refresh */}
              <Button
                variant="outline"
                size="sm"
                onClick={() => fetchMembers()}
                disabled={isLoadingMembers}
              >
                <RefreshCw
                  className={`w-4 h-4 ${
                    isLoadingMembers ? "animate-spin" : ""
                  }`}
                />
              </Button>
            </div>
          </Card>

          {/* Members Table */}
          <MembersTable
            members={members}
            isLoading={isLoadingMembers}
            onMemberAction={handleMemberAction}
            currentUserUuid={currentUser?.uuid}
            isOwner={isNamespaceOwner || isAdmin}
          />

          {/* Pagination */}
          {totalPages > 1 && (
            <div className="flex items-center justify-between">
              <p className="text-sm text-secondary-500">
                Page {page} of {totalPages} ({totalMembers} members)
              </p>
              <div className="flex items-center gap-2">
                <Button
                  variant="outline"
                  size="sm"
                  onClick={() => setPage((p) => Math.max(1, p - 1))}
                  disabled={page === 1}
                >
                  Previous
                </Button>
                <Button
                  variant="outline"
                  size="sm"
                  onClick={() => setPage((p) => Math.min(totalPages, p + 1))}
                  disabled={page === totalPages}
                >
                  Next
                </Button>
              </div>
            </div>
          )}
        </>
      )}

      {/* Invitations Tab Content */}
      {activeTab === "invitations" && (
        <InvitationsTable
          invitations={invitations}
          isLoading={isLoadingInvitations}
          onResend={handleResendInvitation}
          onRevoke={handleRevokeInvitation}
        />
      )}

      {/* Invite Modal */}
      <InviteMemberModal
        isOpen={isInviteModalOpen}
        onClose={() => {
          setIsInviteModalOpen(false);
          router.replace(`/dashboard/namespaces/${namespaceId}/members`);
        }}
        onSuccess={handleInviteSuccess}
        namespaceId={namespaceId}
      />

      {/* Confirm Dialog */}
      {confirmConfig && (
        <ConfirmDialog
          isOpen={!!confirmAction}
          onClose={() => setConfirmAction(null)}
          onConfirm={executeAction}
          title={confirmConfig.title}
          message={confirmConfig.message}
          variant={confirmConfig.variant}
          confirmText={confirmAction?.type === "remove" ? "Remove" : "Confirm"}
        />
      )}
    </div>
  );
}

"use client";

import React, { useState, useEffect, useCallback } from "react";
import { useParams, useRouter } from "next/navigation";
import {
  ArrowLeft,
  Rocket,
  Settings,
  Key,
  Variable,
  Clock,
  Server,
  Cloud,
  Database,
  Code,
  Globe,
  Shield,
  Zap,
  Box,
  Cpu,
  HardDrive,
  Terminal,
  Package,
  Layers,
  GitBranch,
  Plus,
  Trash2,
  Edit,
  Eye,
  EyeOff,
  AlertTriangle,
  CheckCircle,
  XCircle,
  RefreshCw,
  ExternalLink,
  Loader2,
  Github,
  FileCode,
  Save,
  X,
  Palette,
} from "lucide-react";
import { Card, Button, Badge, Input } from "@/components/ui";
import { usePermissions } from "@/contexts/PermissionsContext";
import {
  servicesService,
  getServiceStatusColor,
  getDeploymentStatusColor,
  formatServiceStatus,
  formatDeploymentStatus,
} from "@/services";
import { formatDate, cn, getFullName } from "@/lib/utils";
import type {
  NamespaceService,
  ServiceSecret,
  ServiceVariable,
  ServiceDeployment,
  GithubIntegration,
} from "@/types";
import toast from "react-hot-toast";
import Link from "next/link";

// Icon mapping
const iconMap: Record<string, React.ElementType> = {
  server: Server,
  cloud: Cloud,
  database: Database,
  code: Code,
  globe: Globe,
  shield: Shield,
  zap: Zap,
  box: Box,
  cpu: Cpu,
  "hard-drive": HardDrive,
  terminal: Terminal,
  package: Package,
  layers: Layers,
  "git-branch": GitBranch,
  rocket: Rocket,
};

const iconOptions = [
  { value: "server", label: "Server", Icon: Server },
  { value: "cloud", label: "Cloud", Icon: Cloud },
  { value: "database", label: "Database", Icon: Database },
  { value: "code", label: "Code", Icon: Code },
  { value: "globe", label: "Globe", Icon: Globe },
  { value: "shield", label: "Shield", Icon: Shield },
  { value: "zap", label: "Zap", Icon: Zap },
  { value: "box", label: "Box", Icon: Box },
  { value: "cpu", label: "CPU", Icon: Cpu },
  { value: "hard-drive", label: "Hard Drive", Icon: HardDrive },
  { value: "terminal", label: "Terminal", Icon: Terminal },
  { value: "package", label: "Package", Icon: Package },
  { value: "layers", label: "Layers", Icon: Layers },
  { value: "git-branch", label: "Git Branch", Icon: GitBranch },
  { value: "rocket", label: "Rocket", Icon: Rocket },
];

const colorOptions = [
  { value: "blue", label: "Blue", class: "bg-blue-500" },
  { value: "green", label: "Green", class: "bg-green-500" },
  { value: "purple", label: "Purple", class: "bg-purple-500" },
  { value: "orange", label: "Orange", class: "bg-orange-500" },
  { value: "red", label: "Red", class: "bg-red-500" },
  { value: "cyan", label: "Cyan", class: "bg-cyan-500" },
  { value: "pink", label: "Pink", class: "bg-pink-500" },
  { value: "indigo", label: "Indigo", class: "bg-indigo-500" },
  { value: "yellow", label: "Yellow", class: "bg-yellow-500" },
  { value: "teal", label: "Teal", class: "bg-teal-500" },
];

const colorMap: Record<string, string> = {
  blue: "bg-blue-500",
  green: "bg-green-500",
  purple: "bg-purple-500",
  orange: "bg-orange-500",
  red: "bg-red-500",
  cyan: "bg-cyan-500",
  pink: "bg-pink-500",
  indigo: "bg-indigo-500",
  yellow: "bg-yellow-500",
  teal: "bg-teal-500",
};

const statusOptions = [
  { value: "active", label: "Active" },
  { value: "inactive", label: "Inactive" },
  { value: "archived", label: "Archived" },
];

export default function ServiceDetailsPage() {
  const params = useParams();
  const router = useRouter();
  const { canUpdate, canDelete } = usePermissions();
  const serviceId = params.id as string;

  const [service, setService] = useState<NamespaceService | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [isDeploying, setIsDeploying] = useState(false);

  // Edit mode
  const [isEditing, setIsEditing] = useState(false);
  const [isSaving, setIsSaving] = useState(false);
  const [editForm, setEditForm] = useState({
    name: "",
    description: "",
    github_owner: "",
    github_repo: "",
    github_workflow_file: "",
    github_branch: "",
    icon: "server",
    color: "blue",
    status: "active",
    github_integration_id: "",
  });

  // GitHub integrations for dropdown
  const [githubIntegrations, setGithubIntegrations] = useState<
    GithubIntegration[]
  >([]);

  // Delete confirmation
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false);
  const [isDeleting, setIsDeleting] = useState(false);

  // Secret management
  const [showAddSecret, setShowAddSecret] = useState(false);
  const [newSecretKey, setNewSecretKey] = useState("");
  const [newSecretValue, setNewSecretValue] = useState("");
  const [newSecretDesc, setNewSecretDesc] = useState("");
  const [isAddingSecret, setIsAddingSecret] = useState(false);

  // Variable management
  const [showAddVariable, setShowAddVariable] = useState(false);
  const [newVariableKey, setNewVariableKey] = useState("");
  const [newVariableValue, setNewVariableValue] = useState("");
  const [newVariableDesc, setNewVariableDesc] = useState("");
  const [isAddingVariable, setIsAddingVariable] = useState(false);

  // Syncing state
  const [isSyncing, setIsSyncing] = useState(false);

  const fetchService = useCallback(async () => {
    if (!serviceId) return;

    setIsLoading(true);
    setError(null);

    try {
      const data = await servicesService.getService(serviceId);
      setService(data);
      // Initialize edit form with current values
      setEditForm({
        name: data.name || "",
        description: data.description || "",
        github_owner: data.github_owner || "",
        github_repo: data.github_repo || "",
        github_workflow_file: data.github_workflow_file || "",
        github_branch: data.github_branch || "main",
        icon: data.icon || "server",
        color: data.color || "blue",
        status: data.status || "active",
        github_integration_id: data.github_integration_id?.toString() || "",
      });
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Failed to load service";
      setError(message);
      toast.error(message);
    } finally {
      setIsLoading(false);
    }
  }, [serviceId]);

  const fetchGithubIntegrations = useCallback(async () => {
    try {
      const data = await servicesService.getGithubIntegrations();
      setGithubIntegrations(data);
    } catch (err) {
      console.error("Failed to fetch GitHub integrations:", err);
    }
  }, []);

  // Optimized: Update only deployment statuses without full service refetch
  const syncDeploymentStatuses = useCallback(async () => {
    if (!service || isSyncing) return;

    const pendingDeployments = service.deployments?.filter((d) =>
      ["triggered", "pending", "running"].includes(d.status)
    );

    if (!pendingDeployments || pendingDeployments.length === 0) return;

    setIsSyncing(true);
    try {
      // Sync each pending deployment individually and update state
      const updatedDeployments = await Promise.all(
        pendingDeployments.map(async (deployment) => {
          try {
            const result = await servicesService.syncDeploymentStatus(
              service.uuid,
              deployment.uuid
            );
            return result.data;
          } catch {
            return deployment; // Keep original if sync fails
          }
        })
      );

      // Update only the deployments in state (no full refetch)
      setService((prev) => {
        if (!prev || !prev.deployments) return prev;

        const updatedDeploymentsMap = new Map(
          updatedDeployments.map((d) => [d.uuid, d])
        );

        const newDeployments = prev.deployments.map((d) =>
          updatedDeploymentsMap.has(d.uuid)
            ? updatedDeploymentsMap.get(d.uuid)!
            : d
        );

        // Update service stats based on completed deployments
        let successDelta = 0;
        let failureDelta = 0;
        updatedDeployments.forEach((updated, idx) => {
          const original = pendingDeployments[idx];
          if (original.status !== updated.status) {
            if (updated.status === "success") successDelta++;
            if (updated.status === "failure" || updated.status === "error")
              failureDelta++;
          }
        });

        return {
          ...prev,
          deployments: newDeployments,
          success_count: (prev.success_count || 0) + successDelta,
          failure_count: (prev.failure_count || 0) + failureDelta,
        };
      });
    } catch {
      // Silently fail
    } finally {
      setIsSyncing(false);
    }
  }, [service, isSyncing]);

  // Sync single deployment and update state
  const syncSingleDeployment = useCallback(
    async (deploymentUuid: string) => {
      if (!service) return;

      try {
        const result = await servicesService.syncDeploymentStatus(
          service.uuid,
          deploymentUuid
        );

        // Update only this deployment in state
        setService((prev) => {
          if (!prev || !prev.deployments) return prev;

          const originalDeployment = prev.deployments.find(
            (d) => d.uuid === deploymentUuid
          );
          const updatedDeployment = result.data;

          const newDeployments = prev.deployments.map((d) =>
            d.uuid === deploymentUuid ? updatedDeployment : d
          );

          // Update stats if status changed to final state
          let successDelta = 0;
          let failureDelta = 0;
          if (
            originalDeployment &&
            originalDeployment.status !== updatedDeployment.status
          ) {
            if (updatedDeployment.status === "success") successDelta = 1;
            if (
              updatedDeployment.status === "failure" ||
              updatedDeployment.status === "error"
            )
              failureDelta = 1;
          }

          return {
            ...prev,
            deployments: newDeployments,
            success_count: (prev.success_count || 0) + successDelta,
            failure_count: (prev.failure_count || 0) + failureDelta,
          };
        });
      } catch {
        // Silently fail
      }
    },
    [service]
  );

  useEffect(() => {
    fetchService();
    fetchGithubIntegrations();
  }, [fetchService, fetchGithubIntegrations]);

  // Auto-poll for deployment status updates when there are pending deployments
  useEffect(() => {
    if (!service) return;

    const hasPendingDeployments = service.deployments?.some((d) =>
      ["triggered", "pending", "running"].includes(d.status)
    );

    if (!hasPendingDeployments) return;

    // Poll every 15 seconds for status updates (optimized - no full page reload)
    const pollInterval = setInterval(() => {
      syncDeploymentStatuses();
    }, 15000);

    // Also sync immediately on first render with pending deployments
    syncDeploymentStatuses();

    return () => clearInterval(pollInterval);
  }, [service?.deployments?.length, syncDeploymentStatuses]);

  const handleDeploy = async () => {
    if (!service) return;

    setIsDeploying(true);
    try {
      const result = await servicesService.triggerDeployment(service.uuid);
      if (result.error) {
        toast.error(result.error);
      } else {
        toast.success(result.message || "Deployment triggered successfully");
        // Add new deployment to state without full refetch
        if (result.data) {
          setService((prev) => {
            if (!prev) return prev;
            const newDeployment = result.data;
            return {
              ...prev,
              deployments: [newDeployment, ...(prev.deployments || [])],
              deployment_count: (prev.deployment_count || 0) + 1,
              last_deployment_at: newDeployment.created_at,
            };
          });
        } else {
          // Fallback to full refetch if no deployment data returned
          fetchService();
        }
      }
    } catch (error) {
      toast.error("Failed to trigger deployment");
    } finally {
      setIsDeploying(false);
    }
  };

  const handleSaveEdit = async () => {
    if (!service) return;

    setIsSaving(true);
    try {
      await servicesService.updateService(service.uuid, {
        name: editForm.name,
        description: editForm.description || undefined,
        github_owner: editForm.github_owner,
        github_repo: editForm.github_repo,
        github_workflow_file: editForm.github_workflow_file,
        github_branch: editForm.github_branch,
        icon: editForm.icon,
        color: editForm.color,
        status: editForm.status as "active" | "inactive" | "archived",
        github_integration_id: editForm.github_integration_id
          ? parseInt(editForm.github_integration_id)
          : undefined,
      });
      toast.success("Service updated successfully");
      setIsEditing(false);
      fetchService();
    } catch (error) {
      toast.error("Failed to update service");
    } finally {
      setIsSaving(false);
    }
  };

  const handleDelete = async () => {
    if (!service) return;

    setIsDeleting(true);
    try {
      await servicesService.deleteService(service.uuid);
      toast.success("Service deleted successfully");
      router.push("/dashboard/services");
    } catch (error) {
      toast.error("Failed to delete service");
    } finally {
      setIsDeleting(false);
      setShowDeleteConfirm(false);
    }
  };

  const handleCancelEdit = () => {
    if (service) {
      setEditForm({
        name: service.name || "",
        description: service.description || "",
        github_owner: service.github_owner || "",
        github_repo: service.github_repo || "",
        github_workflow_file: service.github_workflow_file || "",
        github_branch: service.github_branch || "main",
        icon: service.icon || "server",
        color: service.color || "blue",
        status: service.status || "active",
        github_integration_id: service.github_integration_id?.toString() || "",
      });
    }
    setIsEditing(false);
  };

  const handleAddSecret = async () => {
    if (!service || !newSecretKey || !newSecretValue) return;

    setIsAddingSecret(true);
    try {
      await servicesService.addSecret(service.uuid, {
        key: newSecretKey,
        value: newSecretValue,
        description: newSecretDesc || undefined,
      });
      toast.success("Secret added successfully");
      setNewSecretKey("");
      setNewSecretValue("");
      setNewSecretDesc("");
      setShowAddSecret(false);
      fetchService();
    } catch (error) {
      toast.error("Failed to add secret");
    } finally {
      setIsAddingSecret(false);
    }
  };

  const handleDeleteSecret = async (secretId: string) => {
    if (!service) return;
    if (!confirm("Are you sure you want to delete this secret?")) return;

    try {
      await servicesService.deleteSecret(service.uuid, secretId);
      toast.success("Secret deleted");
      fetchService();
    } catch (error) {
      toast.error("Failed to delete secret");
    }
  };

  const handleAddVariable = async () => {
    if (!service || !newVariableKey) return;

    setIsAddingVariable(true);
    try {
      await servicesService.addVariable(service.uuid, {
        key: newVariableKey,
        value: newVariableValue,
        description: newVariableDesc || undefined,
      });
      toast.success("Variable added successfully");
      setNewVariableKey("");
      setNewVariableValue("");
      setNewVariableDesc("");
      setShowAddVariable(false);
      fetchService();
    } catch (error) {
      toast.error("Failed to add variable");
    } finally {
      setIsAddingVariable(false);
    }
  };

  const handleDeleteVariable = async (variableId: string) => {
    if (!service) return;
    if (!confirm("Are you sure you want to delete this variable?")) return;

    try {
      await servicesService.deleteVariable(service.uuid, variableId);
      toast.success("Variable deleted");
      fetchService();
    } catch (error) {
      toast.error("Failed to delete variable");
    }
  };

  const getDeploymentStatusIcon = (status: string) => {
    switch (status) {
      case "success":
        return <CheckCircle className="w-5 h-5 text-success-500" />;
      case "failure":
      case "error":
        return <XCircle className="w-5 h-5 text-error-500" />;
      case "running":
      case "triggered":
        return <RefreshCw className="w-5 h-5 text-primary-500 animate-spin" />;
      case "pending":
        return <Clock className="w-5 h-5 text-secondary-400" />;
      default:
        return <AlertTriangle className="w-5 h-5 text-warning-500" />;
    }
  };

  // Loading state
  if (isLoading) {
    return (
      <div className="space-y-6">
        <div className="bg-white rounded-xl border border-secondary-200 overflow-hidden animate-pulse">
          <div className="h-24 bg-secondary-200" />
          <div className="px-6 pb-6">
            <div className="flex items-start gap-4 -mt-8">
              <div className="w-16 h-16 rounded-xl bg-secondary-300" />
              <div className="pt-10 space-y-2">
                <div className="h-6 bg-secondary-200 rounded w-48" />
                <div className="h-4 bg-secondary-200 rounded w-32" />
              </div>
            </div>
          </div>
        </div>
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <div className="lg:col-span-2 space-y-6">
            <Card className="p-6 animate-pulse">
              <div className="h-6 bg-secondary-200 rounded w-32 mb-4" />
              <div className="space-y-3">
                {[1, 2, 3].map((i) => (
                  <div key={i} className="h-12 bg-secondary-200 rounded" />
                ))}
              </div>
            </Card>
          </div>
          <div className="space-y-6">
            <Card className="p-6 animate-pulse">
              <div className="h-6 bg-secondary-200 rounded w-24 mb-4" />
              <div className="h-10 bg-secondary-200 rounded" />
            </Card>
          </div>
        </div>
      </div>
    );
  }

  // Error state
  if (error || !service) {
    return (
      <div className="space-y-6">
        <Card className="p-8 text-center">
          <AlertTriangle className="w-12 h-12 text-error-500 mx-auto mb-4" />
          <h2 className="text-lg font-semibold text-secondary-900 mb-2">
            {error || "Service Not Found"}
          </h2>
          <p className="text-secondary-500 mb-4">
            The service you&apos;re looking for doesn&apos;t exist or you
            don&apos;t have permission to view it.
          </p>
          <div className="flex items-center justify-center gap-3">
            <Link href="/dashboard/services">
              <Button variant="outline">Back to Services</Button>
            </Link>
            <Button onClick={fetchService}>Try Again</Button>
          </div>
        </Card>
      </div>
    );
  }

  const IconComponent = iconMap[service.icon || "server"] || Server;
  const bgColor = colorMap[service.color || "blue"] || colorMap.blue;
  const EditIconComponent = iconMap[editForm.icon || "server"] || Server;
  const editBgColor = colorMap[editForm.color || "blue"] || colorMap.blue;

  return (
    <div className="space-y-6">
      {/* Delete Confirmation Modal */}
      {showDeleteConfirm && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50">
          <Card className="p-6 max-w-md w-full mx-4">
            <div className="flex items-start gap-4">
              <div className="w-10 h-10 rounded-full bg-error-100 flex items-center justify-center flex-shrink-0">
                <AlertTriangle className="w-5 h-5 text-error-600" />
              </div>
              <div className="flex-1">
                <h3 className="text-lg font-semibold text-secondary-900 mb-2">
                  Delete Service
                </h3>
                <p className="text-sm text-secondary-600 mb-4">
                  Are you sure you want to delete{" "}
                  <strong>{service.name}</strong>? This action cannot be undone.
                  All secrets, variables, and deployment history will be
                  permanently removed.
                </p>
                <div className="flex items-center justify-end gap-3">
                  <Button
                    variant="outline"
                    onClick={() => setShowDeleteConfirm(false)}
                    disabled={isDeleting}
                  >
                    Cancel
                  </Button>
                  <Button
                    variant="danger"
                    onClick={handleDelete}
                    isLoading={isDeleting}
                  >
                    Delete Service
                  </Button>
                </div>
              </div>
            </div>
          </Card>
        </div>
      )}

      {/* Header */}
      <div className="bg-white rounded-xl border border-secondary-200 overflow-hidden">
        <div
          className={cn(
            "h-24",
            (isEditing ? editBgColor : bgColor)
              .replace("bg-", "bg-gradient-to-r from-")
              .concat(
                " to-" + (isEditing ? editForm.color : service.color) + "-600"
              )
          )}
        />
        <div className="px-6 pb-6">
          <div className="flex items-start justify-between -mt-8">
            <div className="flex items-end gap-4">
              <div
                className={cn(
                  "w-16 h-16 rounded-xl border-4 border-white shadow-md flex items-center justify-center text-white",
                  isEditing ? editBgColor : bgColor
                )}
              >
                {isEditing ? (
                  <EditIconComponent className="w-8 h-8" />
                ) : (
                  <IconComponent className="w-8 h-8" />
                )}
              </div>
              <div className="pb-1">
                {isEditing ? (
                  <Input
                    value={editForm.name}
                    onChange={(e) =>
                      setEditForm({ ...editForm, name: e.target.value })
                    }
                    className="text-xl font-bold mb-1"
                    placeholder="Service name"
                  />
                ) : (
                  <h1 className="text-xl font-bold text-secondary-900">
                    {service.name}
                  </h1>
                )}
                <p className="text-sm text-secondary-500">
                  {isEditing
                    ? `${editForm.github_owner}/${editForm.github_repo}`
                    : `${service.github_owner}/${service.github_repo}`}
                </p>
              </div>
            </div>
            <div className="pt-10 flex items-center gap-2">
              <Link href="/dashboard/services">
                <Button
                  variant="ghost"
                  size="sm"
                  leftIcon={<ArrowLeft className="w-4 h-4" />}
                >
                  Back
                </Button>
              </Link>
              {isEditing ? (
                <>
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={handleCancelEdit}
                    disabled={isSaving}
                  >
                    Cancel
                  </Button>
                  <Button
                    size="sm"
                    leftIcon={
                      isSaving ? (
                        <Loader2 className="w-4 h-4 animate-spin" />
                      ) : (
                        <Save className="w-4 h-4" />
                      )
                    }
                    onClick={handleSaveEdit}
                    disabled={isSaving}
                  >
                    Save Changes
                  </Button>
                </>
              ) : (
                <>
                  {canUpdate("services") && (
                    <Button
                      variant="outline"
                      size="sm"
                      leftIcon={<Edit className="w-4 h-4" />}
                      onClick={() => setIsEditing(true)}
                    >
                      Edit
                    </Button>
                  )}
                  {canDelete("services") && (
                    <Button
                      variant="ghost"
                      size="sm"
                      className="text-error-600 hover:text-error-700 hover:bg-error-50"
                      leftIcon={<Trash2 className="w-4 h-4" />}
                      onClick={() => setShowDeleteConfirm(true)}
                    >
                      Delete
                    </Button>
                  )}
                  {service.status === "active" && (
                    <Button
                      size="sm"
                      leftIcon={
                        isDeploying ? (
                          <Loader2 className="w-4 h-4 animate-spin" />
                        ) : (
                          <Rocket className="w-4 h-4" />
                        )
                      }
                      onClick={handleDeploy}
                      disabled={isDeploying}
                    >
                      Deploy
                    </Button>
                  )}
                </>
              )}
            </div>
          </div>
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Main Content */}
        <div className="lg:col-span-2 space-y-6">
          {/* Configuration */}
          <Card className="p-6">
            <div className="flex items-center justify-between mb-4">
              <h3 className="text-sm font-semibold text-secondary-500 uppercase tracking-wider">
                Configuration
              </h3>
              {isEditing && (
                <Badge size="sm" className="bg-primary-100 text-primary-700">
                  Editing
                </Badge>
              )}
            </div>

            {isEditing ? (
              <div className="space-y-4">
                <div className="grid grid-cols-2 gap-4">
                  <Input
                    label="GitHub Owner"
                    value={editForm.github_owner}
                    onChange={(e) =>
                      setEditForm({ ...editForm, github_owner: e.target.value })
                    }
                    placeholder="organization or username"
                  />
                  <Input
                    label="Repository"
                    value={editForm.github_repo}
                    onChange={(e) =>
                      setEditForm({ ...editForm, github_repo: e.target.value })
                    }
                    placeholder="repository-name"
                  />
                </div>
                <div className="grid grid-cols-2 gap-4">
                  <div>
                    <Input
                      label="Workflow File"
                      value={editForm.github_workflow_file}
                      onChange={(e) =>
                        setEditForm({
                          ...editForm,
                          github_workflow_file: e.target.value,
                        })
                      }
                      placeholder="deploy.yml"
                    />
                    <p className="text-xs text-secondary-500 mt-1">
                      The workflow file name in .github/workflows/
                    </p>
                  </div>
                  <Input
                    label="Branch"
                    value={editForm.github_branch}
                    onChange={(e) =>
                      setEditForm({
                        ...editForm,
                        github_branch: e.target.value,
                      })
                    }
                    placeholder="main"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-secondary-700 mb-1.5">
                    Description
                  </label>
                  <textarea
                    value={editForm.description}
                    onChange={(e) =>
                      setEditForm({ ...editForm, description: e.target.value })
                    }
                    placeholder="What does this service do?"
                    rows={2}
                    className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:ring-2 focus:ring-primary-500 focus:border-primary-500"
                  />
                </div>

                {/* GitHub Integration */}
                <div>
                  <label className="block text-sm font-medium text-secondary-700 mb-1.5">
                    GitHub Integration
                  </label>
                  <select
                    value={editForm.github_integration_id}
                    onChange={(e) =>
                      setEditForm({
                        ...editForm,
                        github_integration_id: e.target.value,
                      })
                    }
                    className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:ring-2 focus:ring-primary-500 focus:border-primary-500"
                  >
                    <option value="">Select GitHub Integration</option>
                    {githubIntegrations.map((integration) => (
                      <option key={integration.id} value={integration.id}>
                        {integration.name}{" "}
                        {integration.github_username &&
                          `(@${integration.github_username})`}
                      </option>
                    ))}
                  </select>
                </div>

                {/* Icon Selection */}
                <div>
                  <label className="block text-sm font-medium text-secondary-700 mb-1.5">
                    Icon
                  </label>
                  <div className="flex flex-wrap gap-2">
                    {iconOptions.map(({ value, label, Icon }) => (
                      <button
                        key={value}
                        type="button"
                        onClick={() =>
                          setEditForm({ ...editForm, icon: value })
                        }
                        className={cn(
                          "p-2 rounded-lg border transition-all",
                          editForm.icon === value
                            ? "border-primary-500 bg-primary-50 text-primary-600"
                            : "border-secondary-200 hover:border-secondary-300 text-secondary-500"
                        )}
                        title={label}
                      >
                        <Icon className="w-5 h-5" />
                      </button>
                    ))}
                  </div>
                </div>

                {/* Color Selection */}
                <div>
                  <label className="block text-sm font-medium text-secondary-700 mb-1.5">
                    Color
                  </label>
                  <div className="flex flex-wrap gap-2">
                    {colorOptions.map(({ value, label, class: colorClass }) => (
                      <button
                        key={value}
                        type="button"
                        onClick={() =>
                          setEditForm({ ...editForm, color: value })
                        }
                        className={cn(
                          "w-8 h-8 rounded-lg transition-all",
                          colorClass,
                          editForm.color === value
                            ? "ring-2 ring-offset-2 ring-secondary-400"
                            : "hover:opacity-80"
                        )}
                        title={label}
                      />
                    ))}
                  </div>
                </div>

                {/* Status Selection */}
                <div>
                  <label className="block text-sm font-medium text-secondary-700 mb-1.5">
                    Status
                  </label>
                  <select
                    value={editForm.status}
                    onChange={(e) =>
                      setEditForm({ ...editForm, status: e.target.value })
                    }
                    className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:ring-2 focus:ring-primary-500 focus:border-primary-500"
                  >
                    {statusOptions.map(({ value, label }) => (
                      <option key={value} value={value}>
                        {label}
                      </option>
                    ))}
                  </select>
                </div>
              </div>
            ) : (
              <div className="space-y-4">
                <div className="grid grid-cols-2 gap-4">
                  <div>
                    <p className="text-xs text-secondary-500 mb-1">
                      Workflow File
                    </p>
                    <div className="flex items-center gap-2">
                      <FileCode className="w-4 h-4 text-secondary-400" />
                      <span className="font-mono text-sm">
                        {service.github_workflow_file}
                      </span>
                    </div>
                  </div>
                  <div>
                    <p className="text-xs text-secondary-500 mb-1">Branch</p>
                    <div className="flex items-center gap-2">
                      <GitBranch className="w-4 h-4 text-secondary-400" />
                      <span className="font-mono text-sm">
                        {service.github_branch}
                      </span>
                    </div>
                  </div>
                </div>
                {service.description && (
                  <div>
                    <p className="text-xs text-secondary-500 mb-1">
                      Description
                    </p>
                    <p className="text-sm text-secondary-700">
                      {service.description}
                    </p>
                  </div>
                )}
              </div>
            )}
          </Card>

          {/* Workflow Inputs Header Card */}
          <Card className="p-6 border-2 border-primary-200 bg-gradient-to-br from-primary-50/50 to-white">
            <div className="flex items-center gap-3 mb-2">
              <div className="w-10 h-10 rounded-lg bg-primary-100 flex items-center justify-center">
                <Zap className="w-5 h-5 text-primary-600" />
              </div>
              <div>
                <h3 className="text-lg font-semibold text-secondary-900">
                  Workflow Inputs
                </h3>
                <p className="text-sm text-secondary-500">
                  Secrets &amp; variables passed to GitHub workflow dispatch
                </p>
              </div>
            </div>
            <div className="mt-3 p-3 bg-primary-50 rounded-lg border border-primary-100">
              <div className="flex items-start gap-2">
                <Shield className="w-4 h-4 text-primary-600 mt-0.5 flex-shrink-0" />
                <p className="text-xs text-primary-700">
                  <strong>How it works:</strong> Both secrets and variables are passed as <code className="bg-primary-100 px-1 rounded">workflow_dispatch.inputs</code> to your GitHub workflow. They must match the inputs defined in your workflow YAML file. Secrets are masked in GitHub logs using <code className="bg-primary-100 px-1 rounded">::add-mask::</code>.
                </p>
              </div>
            </div>
          </Card>

          {/* Secrets - Sent to GitHub (for dynamic workflows) */}
          <Card className="p-6 border-2 border-warning-200 bg-gradient-to-br from-warning-50/30 to-white">
            <div className="flex items-center justify-between mb-4">
              <div className="flex items-center gap-3">
                <div className="w-8 h-8 rounded-lg bg-warning-500 flex items-center justify-center">
                  <Key className="w-4 h-4 text-white" />
                </div>
                <div>
                  <h3 className="text-sm font-semibold text-secondary-900 flex items-center gap-2">
                    Workflow Secrets
                    <Badge size="sm" className="bg-warning-100 text-warning-700 border-warning-200">
                      Sent to GitHub (masked)
                    </Badge>
                  </h3>
                  <p className="text-xs text-secondary-500">
                    Encrypted secrets passed as workflow inputs
                  </p>
                </div>
              </div>
              {canUpdate("services") && !isEditing && (
                <Button
                  size="sm"
                  variant="outline"
                  leftIcon={<Plus className="w-4 h-4" />}
                  onClick={() => setShowAddSecret(!showAddSecret)}
                >
                  Add Secret
                </Button>
              )}
            </div>

            <div className="mb-4 p-3 bg-warning-50 rounded-lg border border-warning-200">
              <div className="flex items-start gap-2">
                <Shield className="w-4 h-4 text-warning-600 mt-0.5 flex-shrink-0" />
                <p className="text-xs text-warning-700">
                  <strong>Security:</strong> Secrets are encrypted at rest and decrypted only when triggering deployments. They are sent as workflow inputs and must be defined in your <code className="bg-warning-100 px-1 rounded">workflow_dispatch.inputs</code>. The workflow should use <code className="bg-warning-100 px-1 rounded">::add-mask::</code> to hide them in logs.
                </p>
              </div>
            </div>

            {showAddSecret && (
              <div className="mb-4 p-4 bg-warning-50 rounded-lg border border-warning-200">
                <div className="flex items-start gap-2 mb-3">
                  <Key className="w-4 h-4 text-warning-600 mt-0.5" />
                  <p className="text-xs text-warning-700">
                    Secrets are encrypted at rest and sent to GitHub as workflow inputs. Key must match your workflow&apos;s input name.
                  </p>
                </div>
                <div className="space-y-3">
                  <Input
                    label="Secret Key"
                    value={newSecretKey}
                    onChange={(e) => setNewSecretKey(e.target.value.toUpperCase().replace(/[^A-Z0-9_]/g, '_'))}
                    placeholder="INTERNAL_API_KEY"
                  />
                  <Input
                    label="Secret Value"
                    type="password"
                    value={newSecretValue}
                    onChange={(e) => setNewSecretValue(e.target.value)}
                    placeholder="Enter secret value"
                  />
                  <Input
                    label="Description (optional)"
                    value={newSecretDesc}
                    onChange={(e) => setNewSecretDesc(e.target.value)}
                    placeholder="What is this secret for?"
                  />
                  <div className="flex justify-end gap-2">
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => {
                        setShowAddSecret(false);
                        setNewSecretKey("");
                        setNewSecretValue("");
                        setNewSecretDesc("");
                      }}
                    >
                      Cancel
                    </Button>
                    <Button
                      size="sm"
                      onClick={handleAddSecret}
                      disabled={
                        !newSecretKey || !newSecretValue || isAddingSecret
                      }
                      isLoading={isAddingSecret}
                    >
                      Add Secret
                    </Button>
                  </div>
                </div>
              </div>
            )}

            {service.secrets && service.secrets.length > 0 ? (
              <div className="space-y-2">
                {service.secrets.map((secret) => (
                  <div
                    key={secret.uuid}
                    className="flex items-center justify-between p-3 bg-warning-50/50 rounded-lg border border-warning-100 hover:border-warning-200 transition-colors"
                  >
                    <div className="flex items-center gap-3">
                      <Key className="w-4 h-4 text-warning-500" />
                      <div>
                        <p className="font-mono text-sm font-medium text-secondary-900">
                          {secret.key}
                        </p>
                        {secret.description && (
                          <p className="text-xs text-secondary-500">
                            {secret.description}
                          </p>
                        )}
                      </div>
                    </div>
                    <div className="flex items-center gap-2">
                      <span className="font-mono text-sm text-warning-600 bg-warning-100 px-2 py-0.5 rounded">
                        ********
                      </span>
                      {canDelete("services") && !isEditing && (
                        <button
                          onClick={() => handleDeleteSecret(secret.uuid)}
                          className="p-1.5 text-secondary-400 hover:text-error-500 hover:bg-error-50 rounded transition-colors"
                          title="Delete secret"
                        >
                          <Trash2 className="w-4 h-4" />
                        </button>
                      )}
                    </div>
                  </div>
                ))}
              </div>
            ) : (
              <div className="text-center py-6 bg-warning-50/30 rounded-lg border-2 border-dashed border-warning-200">
                <Key className="w-8 h-8 text-warning-300 mx-auto mb-2" />
                <p className="text-sm font-medium text-secondary-600 mb-1">
                  No secrets configured
                </p>
                <p className="text-xs text-secondary-500 mb-3">
                  Add secrets like DOCKER_USERNAME, DOCKER_PASSWD for dynamic workflows
                </p>
                {canUpdate("services") && !isEditing && (
                  <Button
                    size="sm"
                    variant="outline"
                    leftIcon={<Plus className="w-4 h-4" />}
                    onClick={() => setShowAddSecret(true)}
                  >
                    Add Your First Secret
                  </Button>
                )}
              </div>
            )}
          </Card>

          {/* Variables - IMPORTANT: These ARE sent to GitHub */}
          <Card className="p-6 border-2 border-primary-300 bg-white">
            <div className="flex items-center justify-between mb-4">
              <div className="flex items-center gap-3">
                <div className="w-8 h-8 rounded-lg bg-primary-500 flex items-center justify-center">
                  <Variable className="w-4 h-4 text-white" />
                </div>
                <div>
                  <h3 className="text-sm font-semibold text-secondary-900 flex items-center gap-2">
                    Workflow Variables
                    <Badge size="sm" className="bg-success-100 text-success-700 border-success-200">
                      Sent to GitHub
                    </Badge>
                  </h3>
                  <p className="text-xs text-secondary-500">
                    These values are passed as inputs when triggering the workflow
                  </p>
                </div>
              </div>
              {canUpdate("services") && !isEditing && (
                <Button
                  size="sm"
                  leftIcon={<Plus className="w-4 h-4" />}
                  onClick={() => setShowAddVariable(!showAddVariable)}
                >
                  Add Variable
                </Button>
              )}
            </div>

            <div className="mb-4 p-3 bg-success-50 rounded-lg border border-success-100">
              <div className="flex items-start gap-2">
                <CheckCircle className="w-4 h-4 text-success-600 mt-0.5 flex-shrink-0" />
                <p className="text-xs text-success-700">
                  <strong>Important:</strong> Variable keys must match the <code className="bg-success-100 px-1 rounded">workflow_dispatch.inputs</code> defined in your GitHub workflow YAML. For example: <code className="bg-success-100 px-1 rounded">TARGET_ENV</code>, <code className="bg-success-100 px-1 rounded">DEPLOYMENT_TYPE</code>
                </p>
              </div>
            </div>

            {showAddVariable && (
              <div className="mb-4 p-4 bg-primary-50 rounded-lg border border-primary-200">
                <div className="flex items-start gap-2 mb-3">
                  <Variable className="w-4 h-4 text-primary-600 mt-0.5" />
                  <p className="text-xs text-primary-700">
                    Add variables that match your workflow&apos;s <code className="bg-primary-100 px-1 rounded">workflow_dispatch.inputs</code> section.
                  </p>
                </div>
                <div className="space-y-3">
                  <Input
                    label="Variable Key"
                    value={newVariableKey}
                    onChange={(e) => setNewVariableKey(e.target.value.toUpperCase().replace(/[^A-Z0-9_]/g, '_'))}
                    placeholder="ENVIRONMENT"
                  />
                  <Input
                    label="Variable Value"
                    value={newVariableValue}
                    onChange={(e) => setNewVariableValue(e.target.value)}
                    placeholder="production"
                  />
                  <Input
                    label="Description (optional)"
                    value={newVariableDesc}
                    onChange={(e) => setNewVariableDesc(e.target.value)}
                    placeholder="What is this variable for?"
                  />
                  <div className="flex justify-end gap-2">
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => {
                        setShowAddVariable(false);
                        setNewVariableKey("");
                        setNewVariableValue("");
                        setNewVariableDesc("");
                      }}
                    >
                      Cancel
                    </Button>
                    <Button
                      size="sm"
                      onClick={handleAddVariable}
                      disabled={!newVariableKey || isAddingVariable}
                      isLoading={isAddingVariable}
                    >
                      Add Variable
                    </Button>
                  </div>
                </div>
              </div>
            )}

            {service.variables && service.variables.length > 0 ? (
              <div className="space-y-2">
                {service.variables.map((variable) => (
                  <div
                    key={variable.uuid}
                    className="flex items-center justify-between p-3 bg-primary-50/50 rounded-lg border border-primary-100 hover:border-primary-200 transition-colors"
                  >
                    <div className="flex items-center gap-3">
                      <Variable className="w-4 h-4 text-primary-500" />
                      <div>
                        <p className="font-mono text-sm font-medium text-secondary-900">
                          {variable.key}
                        </p>
                        {variable.description && (
                          <p className="text-xs text-secondary-500">
                            {variable.description}
                          </p>
                        )}
                      </div>
                    </div>
                    <div className="flex items-center gap-2">
                      <span className="font-mono text-sm text-secondary-700 bg-secondary-100 px-2 py-0.5 rounded">
                        {variable.value || <span className="text-secondary-400 italic">empty</span>}
                      </span>
                      {canDelete("services") && !isEditing && (
                        <button
                          onClick={() => handleDeleteVariable(variable.uuid)}
                          className="p-1.5 text-secondary-400 hover:text-error-500 hover:bg-error-50 rounded transition-colors"
                          title="Delete variable"
                        >
                          <Trash2 className="w-4 h-4" />
                        </button>
                      )}
                    </div>
                  </div>
                ))}
              </div>
            ) : (
              <div className="text-center py-6 bg-secondary-50 rounded-lg border-2 border-dashed border-secondary-200">
                <Variable className="w-8 h-8 text-secondary-300 mx-auto mb-2" />
                <p className="text-sm font-medium text-secondary-600 mb-1">
                  No variables configured
                </p>
                <p className="text-xs text-secondary-500 mb-3">
                  Add variables like environment, version, or feature flags
                </p>
                {canUpdate("services") && !isEditing && (
                  <Button
                    size="sm"
                    variant="outline"
                    leftIcon={<Plus className="w-4 h-4" />}
                    onClick={() => setShowAddVariable(true)}
                  >
                    Add Your First Variable
                  </Button>
                )}
              </div>
            )}
          </Card>

          {/* Recent Deployments */}
          <Card className="p-6">
            <div className="flex items-center justify-between mb-4">
              <h3 className="text-sm font-semibold text-secondary-500 uppercase tracking-wider flex items-center gap-2">
                <Clock className="w-4 h-4" />
                Recent Deployments
              </h3>
              {service.deployments &&
                service.deployments.some((d) =>
                  ["triggered", "pending", "running"].includes(d.status)
                ) && (
                  <Button
                    size="sm"
                    variant="ghost"
                    leftIcon={
                      <RefreshCw
                        className={cn("w-4 h-4", isSyncing && "animate-spin")}
                      />
                    }
                    onClick={async () => {
                      await syncDeploymentStatuses();
                      toast.success("Deployment status synced");
                    }}
                    disabled={isSyncing}
                  >
                    {isSyncing ? "Syncing..." : "Sync Status"}
                  </Button>
                )}
            </div>

            {service.deployments && service.deployments.length > 0 ? (
              <div className="space-y-3">
                {service.deployments.map((deployment) => (
                  <div
                    key={deployment.uuid}
                    className="flex items-center justify-between p-3 bg-secondary-50 rounded-lg"
                  >
                    <div className="flex items-center gap-3">
                      {getDeploymentStatusIcon(deployment.status)}
                      <div>
                        <p className="text-sm font-medium">
                          <Badge
                            size="sm"
                            className={cn(
                              "border",
                              getDeploymentStatusColor(deployment.status)
                            )}
                          >
                            {formatDeploymentStatus(deployment.status)}
                          </Badge>
                        </p>
                        <p className="text-xs text-secondary-500">
                          {deployment.first_name
                            ? `by ${getFullName(
                                deployment.first_name,
                                deployment.last_name
                              )}`
                            : "Unknown user"}{" "}
                          &middot; {formatDate(deployment.created_at)}
                        </p>
                        {deployment.error_message && (
                          <p className="text-xs text-error-500 mt-1">
                            {deployment.error_message}
                          </p>
                        )}
                      </div>
                    </div>
                    <div className="flex items-center gap-2">
                      {["triggered", "pending", "running"].includes(
                        deployment.status
                      ) && (
                        <button
                          onClick={() => syncSingleDeployment(deployment.uuid)}
                          className="p-2 text-secondary-400 hover:text-primary-500 rounded"
                          title="Sync status"
                        >
                          <RefreshCw className="w-4 h-4" />
                        </button>
                      )}
                      {deployment.github_run_url && (
                        <a
                          href={deployment.github_run_url}
                          target="_blank"
                          rel="noopener noreferrer"
                          className="p-2 text-secondary-400 hover:text-primary-500 rounded"
                          title="View on GitHub"
                        >
                          <ExternalLink className="w-4 h-4" />
                        </a>
                      )}
                    </div>
                  </div>
                ))}
              </div>
            ) : (
              <p className="text-sm text-secondary-500 text-center py-4">
                No deployments yet. Click the Deploy button to trigger your
                first deployment.
              </p>
            )}
          </Card>
        </div>

        {/* Sidebar */}
        <div className="space-y-6">
          {/* Status */}
          <Card className="p-6">
            <h3 className="text-sm font-semibold text-secondary-500 uppercase tracking-wider mb-4">
              Status
            </h3>
            <Badge
              size="md"
              className={cn(
                "border w-full justify-center py-2",
                getServiceStatusColor(service.status)
              )}
            >
              {formatServiceStatus(service.status)}
            </Badge>
          </Card>

          {/* Stats */}
          <Card className="p-6">
            <h3 className="text-sm font-semibold text-secondary-500 uppercase tracking-wider mb-4">
              Statistics
            </h3>
            <div className="space-y-3">
              <div className="flex items-center justify-between">
                <span className="text-sm text-secondary-600">
                  Total Deployments
                </span>
                <span className="font-medium">
                  {service.deployment_count || 0}
                </span>
              </div>
              <div className="flex items-center justify-between">
                <span className="text-sm text-success-600">Successful</span>
                <span className="font-medium text-success-600">
                  {service.success_count || 0}
                </span>
              </div>
              <div className="flex items-center justify-between">
                <span className="text-sm text-error-600">Failed</span>
                <span className="font-medium text-error-600">
                  {service.failure_count || 0}
                </span>
              </div>
              {service.deployment_count > 0 && (
                <div className="pt-2 border-t border-secondary-200">
                  <div className="flex items-center justify-between">
                    <span className="text-sm text-secondary-600">
                      Success Rate
                    </span>
                    <span className="font-medium">
                      {Math.round(
                        ((service.success_count || 0) /
                          service.deployment_count) *
                          100
                      )}
                      %
                    </span>
                  </div>
                </div>
              )}
            </div>
          </Card>

          {/* GitHub Integration */}
          {service.github_integration && (
            <Card className="p-6">
              <h3 className="text-sm font-semibold text-secondary-500 uppercase tracking-wider mb-4">
                GitHub Integration
              </h3>
              <div className="flex items-center gap-3">
                <div className="w-10 h-10 bg-secondary-900 rounded-lg flex items-center justify-center">
                  <Github className="w-5 h-5 text-white" />
                </div>
                <div>
                  <p className="font-medium text-sm">
                    {service.github_integration.name}
                  </p>
                  {service.github_integration.github_username && (
                    <p className="text-xs text-secondary-500">
                      @{service.github_integration.github_username}
                    </p>
                  )}
                </div>
              </div>
            </Card>
          )}

          {/* Quick Links */}
          <Card className="p-6">
            <h3 className="text-sm font-semibold text-secondary-500 uppercase tracking-wider mb-4">
              Quick Links
            </h3>
            <div className="space-y-2">
              <a
                href={`https://github.com/${service.github_owner}/${service.github_repo}`}
                target="_blank"
                rel="noopener noreferrer"
                className="flex items-center gap-2 p-2 text-sm text-secondary-600 hover:text-primary-600 hover:bg-secondary-50 rounded-lg transition-colors"
              >
                <Github className="w-4 h-4" />
                View Repository
                <ExternalLink className="w-3 h-3 ml-auto" />
              </a>
              <a
                href={`https://github.com/${service.github_owner}/${service.github_repo}/actions/workflows/${service.github_workflow_file}`}
                target="_blank"
                rel="noopener noreferrer"
                className="flex items-center gap-2 p-2 text-sm text-secondary-600 hover:text-primary-600 hover:bg-secondary-50 rounded-lg transition-colors"
              >
                <Rocket className="w-4 h-4" />
                View Workflow
                <ExternalLink className="w-3 h-3 ml-auto" />
              </a>
              <a
                href={`https://github.com/${service.github_owner}/${service.github_repo}/actions`}
                target="_blank"
                rel="noopener noreferrer"
                className="flex items-center gap-2 p-2 text-sm text-secondary-600 hover:text-primary-600 hover:bg-secondary-50 rounded-lg transition-colors"
              >
                <Clock className="w-4 h-4" />
                View All Actions
                <ExternalLink className="w-3 h-3 ml-auto" />
              </a>
            </div>
          </Card>

          {/* Timestamps */}
          <Card className="p-6">
            <h3 className="text-sm font-semibold text-secondary-500 uppercase tracking-wider mb-4">
              Timestamps
            </h3>
            <div className="space-y-2 text-sm">
              <div className="flex items-center justify-between">
                <span className="text-secondary-500">Created</span>
                <span>{formatDate(service.created_at)}</span>
              </div>
              <div className="flex items-center justify-between">
                <span className="text-secondary-500">Updated</span>
                <span>{formatDate(service.updated_at)}</span>
              </div>
              {service.last_deployment_at && (
                <div className="flex items-center justify-between">
                  <span className="text-secondary-500">Last Deploy</span>
                  <span>{formatDate(service.last_deployment_at)}</span>
                </div>
              )}
            </div>
          </Card>
        </div>
      </div>
    </div>
  );
}

'use client';

import React, { useState, useEffect, useCallback, useRef } from 'react';
import {
  Plus,
  Search,
  Trash2,
  Edit,
  Rocket,
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
  Settings,
  RefreshCw,
  CheckCircle,
  XCircle,
  Clock,
  AlertTriangle,
} from 'lucide-react';
import {
  Button,
  Input,
  Table,
  Badge,
  Pagination,
  Card,
  ConfirmDialog,
} from '@/components/ui';
import { usePermissions } from '@/contexts/PermissionsContext';
import {
  servicesService,
  getServiceStatusColor,
  getDeploymentStatusColor,
  formatServiceStatus,
  formatDeploymentStatus,
} from '@/services';
import { formatDate, cn } from '@/lib/utils';
import type { NamespaceService, TableColumn } from '@/types';
import toast from 'react-hot-toast';
import Link from 'next/link';
import { AddServiceModal } from '@/components/services';

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
  'hard-drive': HardDrive,
  terminal: Terminal,
  package: Package,
  layers: Layers,
  'git-branch': GitBranch,
  rocket: Rocket,
};

// Color mapping
const colorMap: Record<string, string> = {
  blue: 'bg-blue-500',
  green: 'bg-green-500',
  purple: 'bg-purple-500',
  orange: 'bg-orange-500',
  red: 'bg-red-500',
  cyan: 'bg-cyan-500',
  pink: 'bg-pink-500',
  indigo: 'bg-indigo-500',
  yellow: 'bg-yellow-500',
  teal: 'bg-teal-500',
};

export default function ServicesPage() {
  const { canCreate, canUpdate, canDelete } = usePermissions();
  const [services, setServices] = useState<NamespaceService[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState('');
  const [currentPage, setCurrentPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [totalItems, setTotalItems] = useState(0);
  const [sortColumn, setSortColumn] = useState('created_at');
  const [sortDirection, setSortDirection] = useState<'asc' | 'desc'>('desc');
  const [statusFilter, setStatusFilter] = useState<string>('all');
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);
  const [serviceToDelete, setServiceToDelete] = useState<NamespaceService | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);
  const [addServiceModalOpen, setAddServiceModalOpen] = useState(false);
  const [deployDialogOpen, setDeployDialogOpen] = useState(false);
  const [serviceToDeploy, setServiceToDeploy] = useState<NamespaceService | null>(null);
  const [isDeploying, setIsDeploying] = useState(false);
  const fetchIdRef = useRef(0);

  const perPage = 10;

  const fetchServices = useCallback(async () => {
    const fetchId = ++fetchIdRef.current;
    setIsLoading(true);
    try {
      const response = await servicesService.getServices({
        page: currentPage,
        perPage,
        orderBy: sortColumn,
        orderDir: sortDirection,
        status: statusFilter !== 'all' ? statusFilter : undefined,
        search: searchQuery || undefined,
      });

      if (fetchId === fetchIdRef.current) {
        setServices(response.data || []);
        setTotalPages(response.total_pages || 1);
        setTotalItems(response.total || 0);
      }
    } catch (error) {
      if (fetchId === fetchIdRef.current) {
        console.error('Failed to fetch services:', error);
        toast.error('Failed to load services');
      }
    } finally {
      if (fetchId === fetchIdRef.current) {
        setIsLoading(false);
      }
    }
  }, [currentPage, sortColumn, sortDirection, statusFilter, searchQuery]);

  useEffect(() => {
    fetchServices();
  }, [fetchServices]);

  const handleSort = (column: string) => {
    if (sortColumn === column) {
      setSortDirection(sortDirection === 'asc' ? 'desc' : 'asc');
    } else {
      setSortColumn(column);
      setSortDirection('asc');
    }
    setCurrentPage(1);
  };

  const handleDeleteClick = (service: NamespaceService) => {
    setServiceToDelete(service);
    setDeleteDialogOpen(true);
  };

  const handleDeleteConfirm = async () => {
    if (!serviceToDelete) return;

    setIsDeleting(true);
    try {
      await servicesService.deleteService(serviceToDelete.uuid);
      toast.success('Service deleted successfully');
      fetchServices();
    } catch (error) {
      toast.error('Failed to delete service');
    } finally {
      setIsDeleting(false);
      setDeleteDialogOpen(false);
      setServiceToDelete(null);
    }
  };

  const handleDeployClick = (service: NamespaceService) => {
    setServiceToDeploy(service);
    setDeployDialogOpen(true);
  };

  const handleDeployConfirm = async () => {
    if (!serviceToDeploy) return;

    setIsDeploying(true);
    try {
      const result = await servicesService.triggerDeployment(serviceToDeploy.uuid);
      if (result.error) {
        toast.error(result.error);
      } else {
        toast.success(result.message || 'Deployment triggered successfully');
      }
      fetchServices();
    } catch (error) {
      toast.error('Failed to trigger deployment');
    } finally {
      setIsDeploying(false);
      setDeployDialogOpen(false);
      setServiceToDeploy(null);
    }
  };

  const getDeploymentStatusIcon = (status?: string) => {
    switch (status) {
      case 'success':
        return <CheckCircle className="w-4 h-4 text-success-500" />;
      case 'failure':
      case 'error':
        return <XCircle className="w-4 h-4 text-error-500" />;
      case 'running':
      case 'triggered':
        return <RefreshCw className="w-4 h-4 text-primary-500 animate-spin" />;
      case 'pending':
        return <Clock className="w-4 h-4 text-secondary-400" />;
      default:
        return <AlertTriangle className="w-4 h-4 text-warning-500" />;
    }
  };

  const columns: TableColumn<NamespaceService>[] = [
    {
      key: 'name',
      header: 'Service',
      sortable: true,
      render: (service) => {
        const IconComponent = iconMap[service.icon || 'server'] || Server;
        const bgColor = colorMap[service.color || 'blue'] || colorMap.blue;
        return (
          <div className="flex items-center gap-3">
            <div
              className={cn(
                'w-10 h-10 rounded-lg flex items-center justify-center text-white shadow-md',
                bgColor
              )}
            >
              <IconComponent className="w-5 h-5" />
            </div>
            <div>
              <p className="font-medium text-secondary-900">{service.name}</p>
              <p className="text-xs text-secondary-500">
                {service.github_owner}/{service.github_repo}
              </p>
            </div>
          </div>
        );
      },
    },
    {
      key: 'workflow',
      header: 'Workflow',
      render: (service) => (
        <div className="flex items-center gap-2 text-secondary-600">
          <GitBranch className="w-4 h-4 text-secondary-400" />
          <span className="text-sm font-mono">{service.github_workflow_file}</span>
        </div>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      render: (service) => (
        <Badge
          size="sm"
          className={cn('border', getServiceStatusColor(service.status))}
        >
          {formatServiceStatus(service.status)}
        </Badge>
      ),
    },
    {
      key: 'deployments',
      header: 'Deployments',
      sortable: true,
      render: (service) => (
        <div className="flex items-center gap-2">
          <span className="text-sm font-medium text-secondary-900">
            {service.deployment_count || 0}
          </span>
          <div className="flex items-center gap-1 text-xs">
            <span className="text-success-600">{service.success_count || 0}</span>
            <span className="text-secondary-400">/</span>
            <span className="text-error-600">{service.failure_count || 0}</span>
          </div>
        </div>
      ),
    },
    {
      key: 'last_deployment',
      header: 'Last Deployment',
      sortable: true,
      render: (service) => (
        <div className="flex items-center gap-2">
          {service.last_deployment_at ? (
            <>
              {getDeploymentStatusIcon(service.last_deployment_status)}
              <span className="text-sm text-secondary-600">
                {formatDate(service.last_deployment_at)}
              </span>
            </>
          ) : (
            <span className="text-sm text-secondary-400">Never</span>
          )}
        </div>
      ),
    },
    {
      key: 'actions',
      header: '',
      width: 'w-32',
      render: (service) => (
        <div className="flex items-center gap-1">
          {/* Deploy button - requires deploy permission */}
          {service.status === 'active' && (
            <button
              onClick={(e) => {
                e.stopPropagation();
                handleDeployClick(service);
              }}
              className="p-1.5 text-primary-500 hover:text-primary-600 hover:bg-primary-50 rounded-lg transition-colors"
              title="Deploy"
            >
              <Rocket className="w-4 h-4" />
            </button>
          )}
          {canUpdate('services') && (
            <Link
              href={`/dashboard/services/${service.uuid}`}
              onClick={(e) => e.stopPropagation()}
              className="p-1.5 text-secondary-500 hover:text-primary-500 hover:bg-primary-50 rounded-lg transition-colors"
              title="Edit"
            >
              <Edit className="w-4 h-4" />
            </Link>
          )}
          {canDelete('services') && (
            <button
              onClick={(e) => {
                e.stopPropagation();
                handleDeleteClick(service);
              }}
              className="p-1.5 text-secondary-500 hover:text-error-500 hover:bg-error-50 rounded-lg transition-colors"
              title="Delete"
            >
              <Trash2 className="w-4 h-4" />
            </button>
          )}
        </div>
      ),
    },
  ];

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Services</h1>
          <p className="text-secondary-500 mt-1">
            Manage your deployment services and trigger GitHub workflows
          </p>
        </div>
        <div className="flex items-center gap-3">
          <Link href="/dashboard/services/settings">
            <Button variant="outline" leftIcon={<Settings className="w-4 h-4" />}>
              Settings
            </Button>
          </Link>
          {canCreate('services') && (
            <Button
              leftIcon={<Plus className="w-4 h-4" />}
              onClick={() => setAddServiceModalOpen(true)}
            >
              Add Service
            </Button>
          )}
        </div>
      </div>

      {/* Filters */}
      <Card padding="md">
        <div className="flex flex-wrap items-center gap-4">
          <div className="flex-1 min-w-[200px] max-w-sm">
            <Input
              placeholder="Search services..."
              value={searchQuery}
              onChange={(e) => {
                setSearchQuery(e.target.value);
                setCurrentPage(1);
              }}
              leftIcon={<Search className="w-4 h-4" />}
            />
          </div>
          <div className="flex items-center gap-2">
            <select
              value={statusFilter}
              onChange={(e) => {
                setStatusFilter(e.target.value);
                setCurrentPage(1);
              }}
              className="px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500"
            >
              <option value="all">All Status</option>
              <option value="active">Active</option>
              <option value="inactive">Inactive</option>
              <option value="archived">Archived</option>
            </select>
          </div>
        </div>
      </Card>

      {/* Services Table */}
      <div>
        <Table
          columns={columns}
          data={services}
          keyExtractor={(service) => service.uuid}
          onRowClick={(service) => {
            window.location.href = `/dashboard/services/${service.uuid}`;
          }}
          sortColumn={sortColumn}
          sortDirection={sortDirection}
          onSort={handleSort}
          isLoading={isLoading}
          emptyMessage="No services found. Create your first service to get started."
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
        title="Delete Service"
        message={`Are you sure you want to delete "${serviceToDelete?.name}"? This will also delete all associated secrets, variables, and deployment history. This action cannot be undone.`}
        confirmText="Delete"
        variant="danger"
        isLoading={isDeleting}
      />

      {/* Deploy Confirmation Dialog */}
      <ConfirmDialog
        isOpen={deployDialogOpen}
        onClose={() => setDeployDialogOpen(false)}
        onConfirm={handleDeployConfirm}
        title="Trigger Deployment"
        message={`Are you sure you want to trigger a deployment for "${serviceToDeploy?.name}"? This will run the GitHub workflow "${serviceToDeploy?.github_workflow_file}" on branch "${serviceToDeploy?.github_branch}".`}
        confirmText="Deploy"
        variant="info"
        isLoading={isDeploying}
      />

      {/* Add Service Modal */}
      <AddServiceModal
        isOpen={addServiceModalOpen}
        onClose={() => setAddServiceModalOpen(false)}
        onSuccess={fetchServices}
      />
    </div>
  );
}

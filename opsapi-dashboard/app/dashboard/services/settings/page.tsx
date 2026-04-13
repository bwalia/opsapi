'use client';

import React, { useState, useEffect, useCallback } from 'react';
import {
  ArrowLeft,
  Github,
  Plus,
  Trash2,
  Edit,
  Eye,
  EyeOff,
  AlertTriangle,
  CheckCircle,
  Key,
  Loader2,
  ExternalLink,
} from 'lucide-react';
import { Card, Button, Badge, Input } from '@/components/ui';
import { usePermissions } from '@/contexts/PermissionsContext';
import { servicesService } from '@/services';
import { formatDate, cn } from '@/lib/utils';
import type { GithubIntegration, ServiceStats } from '@/types';
import toast from 'react-hot-toast';
import Link from 'next/link';

export default function ServiceSettingsPage() {
  const { canCreate, canUpdate, canDelete } = usePermissions();
  const [integrations, setIntegrations] = useState<GithubIntegration[]>([]);
  const [stats, setStats] = useState<ServiceStats | null>(null);
  const [isLoading, setIsLoading] = useState(true);

  // Add integration form
  const [showAddForm, setShowAddForm] = useState(false);
  const [newName, setNewName] = useState('');
  const [newToken, setNewToken] = useState('');
  const [newUsername, setNewUsername] = useState('');
  const [isAdding, setIsAdding] = useState(false);
  const [showToken, setShowToken] = useState(false);

  // Edit integration
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editName, setEditName] = useState('');
  const [editToken, setEditToken] = useState('');
  const [editUsername, setEditUsername] = useState('');
  const [isUpdating, setIsUpdating] = useState(false);

  const fetchData = useCallback(async () => {
    setIsLoading(true);
    try {
      const [integrationsData, statsData] = await Promise.all([
        servicesService.getGithubIntegrations(),
        servicesService.getStats(),
      ]);
      setIntegrations(integrationsData);
      setStats(statsData);
    } catch (error) {
      console.error('Failed to fetch data:', error);
      toast.error('Failed to load settings');
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchData();
  }, [fetchData]);

  const handleAdd = async () => {
    if (!newName || !newToken) {
      toast.error('Name and token are required');
      return;
    }

    setIsAdding(true);
    try {
      await servicesService.createGithubIntegration({
        name: newName,
        github_token: newToken,
        github_username: newUsername || undefined,
      });
      toast.success('GitHub integration added successfully');
      setNewName('');
      setNewToken('');
      setNewUsername('');
      setShowAddForm(false);
      fetchData();
    } catch (error) {
      toast.error('Failed to add integration');
    } finally {
      setIsAdding(false);
    }
  };

  const handleStartEdit = (integration: GithubIntegration) => {
    setEditingId(integration.uuid);
    setEditName(integration.name);
    setEditToken('');
    setEditUsername(integration.github_username || '');
  };

  const handleCancelEdit = () => {
    setEditingId(null);
    setEditName('');
    setEditToken('');
    setEditUsername('');
  };

  const handleUpdate = async (id: string) => {
    if (!editName) {
      toast.error('Name is required');
      return;
    }

    setIsUpdating(true);
    try {
      await servicesService.updateGithubIntegration(id, {
        name: editName,
        github_token: editToken || undefined,
        github_username: editUsername || undefined,
      });
      toast.success('Integration updated');
      handleCancelEdit();
      fetchData();
    } catch (error) {
      toast.error('Failed to update integration');
    } finally {
      setIsUpdating(false);
    }
  };

  const handleDelete = async (id: string) => {
    if (!confirm('Are you sure you want to delete this GitHub integration? Services using it will no longer be able to deploy.')) {
      return;
    }

    try {
      await servicesService.deleteGithubIntegration(id);
      toast.success('Integration deleted');
      fetchData();
    } catch (error) {
      toast.error('Failed to delete integration');
    }
  };

  if (isLoading) {
    return (
      <div className="space-y-6">
        <div className="flex items-center gap-4">
          <div className="h-8 w-48 bg-secondary-200 rounded animate-pulse" />
        </div>
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <div className="lg:col-span-2">
            <Card className="p-6 animate-pulse">
              <div className="h-6 w-40 bg-secondary-200 rounded mb-4" />
              <div className="space-y-3">
                {[1, 2].map((i) => (
                  <div key={i} className="h-20 bg-secondary-200 rounded" />
                ))}
              </div>
            </Card>
          </div>
          <div>
            <Card className="p-6 animate-pulse">
              <div className="h-6 w-32 bg-secondary-200 rounded mb-4" />
              <div className="space-y-3">
                {[1, 2, 3].map((i) => (
                  <div key={i} className="h-8 bg-secondary-200 rounded" />
                ))}
              </div>
            </Card>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-4">
          <Link href="/dashboard/services">
            <Button variant="ghost" size="sm" leftIcon={<ArrowLeft className="w-4 h-4" />}>
              Back
            </Button>
          </Link>
          <div>
            <h1 className="text-2xl font-bold text-secondary-900">Service Settings</h1>
            <p className="text-secondary-500 mt-1">Manage GitHub integrations and service configuration</p>
          </div>
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Main Content */}
        <div className="lg:col-span-2 space-y-6">
          {/* GitHub Integrations */}
          <Card className="p-6">
            <div className="flex items-center justify-between mb-4">
              <h3 className="text-sm font-semibold text-secondary-500 uppercase tracking-wider flex items-center gap-2">
                <Github className="w-4 h-4" />
                GitHub Integrations
              </h3>
              {canCreate('services') && (
                <Button
                  size="sm"
                  variant="outline"
                  leftIcon={<Plus className="w-4 h-4" />}
                  onClick={() => setShowAddForm(!showAddForm)}
                >
                  Add Integration
                </Button>
              )}
            </div>

            {/* Add Form */}
            {showAddForm && (
              <div className="mb-6 p-4 bg-secondary-50 rounded-lg border border-secondary-200">
                <h4 className="font-medium text-secondary-900 mb-4">Add GitHub Integration</h4>
                <div className="space-y-4">
                  <Input
                    label="Name"
                    value={newName}
                    onChange={(e) => setNewName(e.target.value)}
                    placeholder="e.g., Production, Staging"
                    leftIcon={<Github className="w-4 h-4" />}
                  />
                  <div>
                    <label className="block text-sm font-medium text-secondary-700 mb-1.5">
                      Personal Access Token <span className="text-error-500">*</span>
                    </label>
                    <div className="relative">
                      <Input
                        type={showToken ? 'text' : 'password'}
                        value={newToken}
                        onChange={(e) => setNewToken(e.target.value)}
                        placeholder="ghp_xxxxxxxxxxxxxxxxxxxx"
                        leftIcon={<Key className="w-4 h-4" />}
                      />
                      <button
                        type="button"
                        onClick={() => setShowToken(!showToken)}
                        className="absolute right-3 top-1/2 -translate-y-1/2 text-secondary-400 hover:text-secondary-600"
                      >
                        {showToken ? <EyeOff className="w-4 h-4" /> : <Eye className="w-4 h-4" />}
                      </button>
                    </div>
                    <p className="mt-1.5 text-xs text-secondary-500">
                      Create a token with <code className="bg-secondary-100 px-1 rounded">repo</code> and{' '}
                      <code className="bg-secondary-100 px-1 rounded">workflow</code> scopes.{' '}
                      <a
                        href="https://github.com/settings/tokens/new?scopes=repo,workflow"
                        target="_blank"
                        rel="noopener noreferrer"
                        className="text-primary-500 hover:underline inline-flex items-center gap-1"
                      >
                        Create token <ExternalLink className="w-3 h-3" />
                      </a>
                    </p>
                  </div>
                  <Input
                    label="GitHub Username (optional)"
                    value={newUsername}
                    onChange={(e) => setNewUsername(e.target.value)}
                    placeholder="your-github-username"
                  />
                  <div className="flex justify-end gap-2 pt-2">
                    <Button variant="ghost" size="sm" onClick={() => setShowAddForm(false)}>
                      Cancel
                    </Button>
                    <Button
                      size="sm"
                      onClick={handleAdd}
                      disabled={!newName || !newToken || isAdding}
                      isLoading={isAdding}
                    >
                      Add Integration
                    </Button>
                  </div>
                </div>
              </div>
            )}

            {/* Integrations List */}
            {integrations.length > 0 ? (
              <div className="space-y-3">
                {integrations.map((integration) => (
                  <div
                    key={integration.uuid}
                    className="p-4 bg-secondary-50 rounded-lg border border-secondary-200"
                  >
                    {editingId === integration.uuid ? (
                      // Edit Mode
                      <div className="space-y-3">
                        <Input
                          label="Name"
                          value={editName}
                          onChange={(e) => setEditName(e.target.value)}
                          placeholder="Integration name"
                        />
                        <Input
                          label="New Token (leave blank to keep existing)"
                          type="password"
                          value={editToken}
                          onChange={(e) => setEditToken(e.target.value)}
                          placeholder="ghp_xxxxxxxxxxxxxxxxxxxx"
                        />
                        <Input
                          label="GitHub Username"
                          value={editUsername}
                          onChange={(e) => setEditUsername(e.target.value)}
                          placeholder="your-github-username"
                        />
                        <div className="flex justify-end gap-2">
                          <Button variant="ghost" size="sm" onClick={handleCancelEdit}>
                            Cancel
                          </Button>
                          <Button
                            size="sm"
                            onClick={() => handleUpdate(integration.uuid)}
                            disabled={isUpdating}
                            isLoading={isUpdating}
                          >
                            Save
                          </Button>
                        </div>
                      </div>
                    ) : (
                      // View Mode
                      <div className="flex items-center justify-between">
                        <div className="flex items-center gap-3">
                          <div className="w-10 h-10 bg-secondary-900 rounded-lg flex items-center justify-center">
                            <Github className="w-5 h-5 text-white" />
                          </div>
                          <div>
                            <div className="flex items-center gap-2">
                              <p className="font-medium text-secondary-900">{integration.name}</p>
                              <Badge
                                size="sm"
                                className={cn(
                                  'border',
                                  integration.status === 'active'
                                    ? 'bg-success-100 text-success-700 border-success-200'
                                    : 'bg-secondary-100 text-secondary-700 border-secondary-200'
                                )}
                              >
                                {integration.status}
                              </Badge>
                            </div>
                            <p className="text-sm text-secondary-500">
                              {integration.github_username ? `@${integration.github_username}` : 'No username'}{' '}
                              &middot; Added {formatDate(integration.created_at)}
                            </p>
                          </div>
                        </div>
                        <div className="flex items-center gap-2">
                          {canUpdate('services') && (
                            <button
                              onClick={() => handleStartEdit(integration)}
                              className="p-2 text-secondary-400 hover:text-primary-500 rounded"
                            >
                              <Edit className="w-4 h-4" />
                            </button>
                          )}
                          {canDelete('services') && (
                            <button
                              onClick={() => handleDelete(integration.uuid)}
                              className="p-2 text-secondary-400 hover:text-error-500 rounded"
                            >
                              <Trash2 className="w-4 h-4" />
                            </button>
                          )}
                        </div>
                      </div>
                    )}
                  </div>
                ))}
              </div>
            ) : (
              <div className="text-center py-8">
                <Github className="w-12 h-12 text-secondary-300 mx-auto mb-3" />
                <p className="text-secondary-500 mb-4">No GitHub integrations configured</p>
                <p className="text-sm text-secondary-400 max-w-md mx-auto">
                  Add a GitHub Personal Access Token to enable deployment triggering for your services.
                </p>
              </div>
            )}
          </Card>

          {/* Security Notice */}
          <Card className="p-6 bg-warning-50 border-warning-200">
            <div className="flex items-start gap-3">
              <AlertTriangle className="w-5 h-5 text-warning-500 mt-0.5" />
              <div>
                <h4 className="font-medium text-warning-900">Security Notice</h4>
                <p className="text-sm text-warning-700 mt-1">
                  GitHub tokens are encrypted at rest using AES-128-CBC encryption. They are never
                  exposed in API responses or logs. Tokens are only decrypted server-side when
                  triggering GitHub workflow dispatches.
                </p>
              </div>
            </div>
          </Card>
        </div>

        {/* Sidebar */}
        <div className="space-y-6">
          {/* Overview Stats */}
          {stats && (
            <Card className="p-6">
              <h3 className="text-sm font-semibold text-secondary-500 uppercase tracking-wider mb-4">
                Overview
              </h3>
              <div className="space-y-3">
                <div className="flex items-center justify-between">
                  <span className="text-sm text-secondary-600">Total Services</span>
                  <span className="font-medium">{stats.total_services}</span>
                </div>
                <div className="flex items-center justify-between">
                  <span className="text-sm text-secondary-600">Active Integrations</span>
                  <span className="font-medium">{stats.active_integrations}</span>
                </div>
                <div className="flex items-center justify-between">
                  <span className="text-sm text-secondary-600">Total Deployments</span>
                  <span className="font-medium">{stats.total_deployments}</span>
                </div>
                <div className="pt-2 border-t border-secondary-200">
                  <div className="flex items-center justify-between">
                    <span className="text-sm text-success-600">Successful</span>
                    <span className="font-medium text-success-600">{stats.total_successes}</span>
                  </div>
                  <div className="flex items-center justify-between mt-1">
                    <span className="text-sm text-error-600">Failed</span>
                    <span className="font-medium text-error-600">{stats.total_failures}</span>
                  </div>
                </div>
              </div>
            </Card>
          )}

          {/* Help */}
          <Card className="p-6">
            <h3 className="text-sm font-semibold text-secondary-500 uppercase tracking-wider mb-4">
              Getting Started
            </h3>
            <div className="space-y-3 text-sm text-secondary-600">
              <div className="flex items-start gap-2">
                <span className="w-5 h-5 rounded-full bg-primary-100 text-primary-600 flex items-center justify-center text-xs font-medium">
                  1
                </span>
                <span>Add a GitHub integration with a Personal Access Token</span>
              </div>
              <div className="flex items-start gap-2">
                <span className="w-5 h-5 rounded-full bg-primary-100 text-primary-600 flex items-center justify-center text-xs font-medium">
                  2
                </span>
                <span>Create a service linked to your GitHub repository</span>
              </div>
              <div className="flex items-start gap-2">
                <span className="w-5 h-5 rounded-full bg-primary-100 text-primary-600 flex items-center justify-center text-xs font-medium">
                  3
                </span>
                <span>Add secrets and variables for your workflow</span>
              </div>
              <div className="flex items-start gap-2">
                <span className="w-5 h-5 rounded-full bg-primary-100 text-primary-600 flex items-center justify-center text-xs font-medium">
                  4
                </span>
                <span>Click Deploy to trigger the GitHub workflow</span>
              </div>
            </div>
          </Card>
        </div>
      </div>
    </div>
  );
}

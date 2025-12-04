'use client';

import React, { useState, useEffect } from 'react';
import {
  Settings,
  Building2,
  Save,
  Loader2,
  AlertTriangle,
  Globe,
  Image,
  FileText,
} from 'lucide-react';
import { Button, Input, Card, Badge } from '@/components/ui';
import { useNamespace } from '@/contexts/NamespaceContext';
import { namespaceService } from '@/services';
import type { UpdateNamespaceDto } from '@/types';
import toast from 'react-hot-toast';
import { useRouter } from 'next/navigation';

export default function NamespaceSettingsPage() {
  const router = useRouter();
  const { currentNamespace, isNamespaceOwner, refreshNamespaces } = useNamespace();
  const [formData, setFormData] = useState<UpdateNamespaceDto>({
    name: '',
    description: '',
    domain: '',
    logo_url: '',
    banner_url: '',
  });
  const [isLoading, setIsLoading] = useState(false);
  const [isSaving, setIsSaving] = useState(false);

  useEffect(() => {
    if (currentNamespace) {
      setFormData({
        name: currentNamespace.name || '',
        description: currentNamespace.description || '',
        domain: currentNamespace.domain || '',
        logo_url: currentNamespace.logo_url || '',
        banner_url: currentNamespace.banner_url || '',
      });
    }
  }, [currentNamespace]);

  const handleInputChange = (
    e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>
  ) => {
    const { name, value } = e.target;
    setFormData((prev) => ({ ...prev, [name]: value }));
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!currentNamespace) return;

    setIsSaving(true);
    try {
      await namespaceService.updateCurrentNamespace(formData);
      toast.success('Namespace settings updated successfully');
      refreshNamespaces();
    } catch (error) {
      toast.error('Failed to update settings');
    } finally {
      setIsSaving(false);
    }
  };

  // Redirect if not owner
  if (!isNamespaceOwner && currentNamespace) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-bold text-secondary-900">Namespace Settings</h1>
        <Card className="p-8 text-center">
          <AlertTriangle className="w-12 h-12 text-warning-500 mx-auto mb-4" />
          <h2 className="text-lg font-semibold text-secondary-900 mb-2">
            Access Restricted
          </h2>
          <p className="text-secondary-500">
            Only namespace owners can access settings.
          </p>
        </Card>
      </div>
    );
  }

  if (!currentNamespace) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-bold text-secondary-900">Namespace Settings</h1>
        <Card className="p-8 text-center">
          <Building2 className="w-12 h-12 text-secondary-300 mx-auto mb-4" />
          <p className="text-secondary-500">No namespace selected</p>
        </Card>
      </div>
    );
  }

  return (
    <div className="space-y-6 max-w-3xl">
      {/* Header */}
      <div>
        <h1 className="text-2xl font-bold text-secondary-900">Namespace Settings</h1>
        <p className="text-secondary-500 mt-1">
          Configure settings for {currentNamespace.name}
        </p>
      </div>

      {/* Settings Form */}
      <form onSubmit={handleSubmit} className="space-y-6">
        {/* General Settings */}
        <Card className="p-6">
          <div className="flex items-center gap-3 mb-6">
            <div className="w-10 h-10 rounded-lg bg-primary-100 flex items-center justify-center">
              <Settings className="w-5 h-5 text-primary-600" />
            </div>
            <div>
              <h2 className="text-lg font-semibold text-secondary-900">
                General Settings
              </h2>
              <p className="text-sm text-secondary-500">
                Basic namespace information
              </p>
            </div>
          </div>

          <div className="space-y-4">
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1.5">
                Namespace Name <span className="text-error-500">*</span>
              </label>
              <Input
                name="name"
                value={formData.name}
                onChange={handleInputChange}
                placeholder="My Company"
                required
              />
            </div>

            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1.5">
                Slug
              </label>
              <Input
                value={currentNamespace.slug}
                disabled
                className="bg-secondary-50"
              />
              <p className="text-xs text-secondary-500 mt-1">
                Slug cannot be changed after creation
              </p>
            </div>

            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1.5">
                Description
              </label>
              <textarea
                name="description"
                value={formData.description}
                onChange={handleInputChange}
                placeholder="A brief description of your namespace..."
                rows={3}
                className="w-full px-3 py-2 border border-secondary-300 rounded-lg text-sm focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 resize-none"
              />
            </div>
          </div>
        </Card>

        {/* Branding */}
        <Card className="p-6">
          <div className="flex items-center gap-3 mb-6">
            <div className="w-10 h-10 rounded-lg bg-warning-100 flex items-center justify-center">
              <Image className="w-5 h-5 text-warning-600" />
            </div>
            <div>
              <h2 className="text-lg font-semibold text-secondary-900">Branding</h2>
              <p className="text-sm text-secondary-500">
                Customize namespace appearance
              </p>
            </div>
          </div>

          <div className="space-y-4">
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1.5">
                Logo URL
              </label>
              <Input
                name="logo_url"
                value={formData.logo_url}
                onChange={handleInputChange}
                placeholder="https://example.com/logo.png"
                leftIcon={<Image className="w-4 h-4" />}
              />
            </div>

            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1.5">
                Banner URL
              </label>
              <Input
                name="banner_url"
                value={formData.banner_url}
                onChange={handleInputChange}
                placeholder="https://example.com/banner.png"
                leftIcon={<Image className="w-4 h-4" />}
              />
            </div>
          </div>
        </Card>

        {/* Domain Settings */}
        <Card className="p-6">
          <div className="flex items-center gap-3 mb-6">
            <div className="w-10 h-10 rounded-lg bg-success-100 flex items-center justify-center">
              <Globe className="w-5 h-5 text-success-600" />
            </div>
            <div>
              <h2 className="text-lg font-semibold text-secondary-900">
                Custom Domain
              </h2>
              <p className="text-sm text-secondary-500">
                Configure a custom domain for your namespace
              </p>
            </div>
          </div>

          <div className="space-y-4">
            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1.5">
                Custom Domain
              </label>
              <Input
                name="domain"
                value={formData.domain}
                onChange={handleInputChange}
                placeholder="app.mycompany.com"
                leftIcon={<Globe className="w-4 h-4" />}
              />
              <p className="text-xs text-secondary-500 mt-1">
                Point your domain&apos;s DNS to our servers to enable this feature
              </p>
            </div>
          </div>
        </Card>

        {/* Plan Info */}
        <Card className="p-6">
          <div className="flex items-center gap-3 mb-6">
            <div className="w-10 h-10 rounded-lg bg-secondary-100 flex items-center justify-center">
              <FileText className="w-5 h-5 text-secondary-600" />
            </div>
            <div>
              <h2 className="text-lg font-semibold text-secondary-900">
                Plan & Limits
              </h2>
              <p className="text-sm text-secondary-500">
                Your current plan details
              </p>
            </div>
          </div>

          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div className="p-4 bg-secondary-50 rounded-lg">
              <p className="text-sm text-secondary-500">Current Plan</p>
              <Badge variant="default" className="mt-1 capitalize">
                {currentNamespace.plan}
              </Badge>
            </div>
            <div className="p-4 bg-secondary-50 rounded-lg">
              <p className="text-sm text-secondary-500">Status</p>
              <Badge
                variant={currentNamespace.status === 'active' ? 'success' : 'warning'}
                className="mt-1 capitalize"
              >
                {currentNamespace.status}
              </Badge>
            </div>
            <div className="p-4 bg-secondary-50 rounded-lg">
              <p className="text-sm text-secondary-500">Max Users</p>
              <p className="text-lg font-semibold text-secondary-900 mt-1">
                {currentNamespace.max_users}
              </p>
            </div>
            <div className="p-4 bg-secondary-50 rounded-lg">
              <p className="text-sm text-secondary-500">Max Stores</p>
              <p className="text-lg font-semibold text-secondary-900 mt-1">
                {currentNamespace.max_stores}
              </p>
            </div>
          </div>
        </Card>

        {/* Save Button */}
        <div className="flex justify-end gap-3">
          <Button
            type="button"
            variant="secondary"
            onClick={() => router.push('/dashboard/namespace')}
          >
            Cancel
          </Button>
          <Button type="submit" disabled={isSaving}>
            {isSaving ? (
              <>
                <Loader2 className="w-4 h-4 mr-2 animate-spin" />
                Saving...
              </>
            ) : (
              <>
                <Save className="w-4 h-4 mr-2" />
                Save Changes
              </>
            )}
          </Button>
        </div>
      </form>
    </div>
  );
}

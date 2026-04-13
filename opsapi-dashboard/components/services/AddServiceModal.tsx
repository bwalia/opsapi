'use client';

import React, { useState, useCallback, useEffect, memo } from 'react';
import Modal from '@/components/ui/Modal';
import { Input, Button } from '@/components/ui';
import {
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
  Rocket,
  ChevronDown,
  Github,
  FileCode,
} from 'lucide-react';
import { servicesService } from '@/services';
import { cn } from '@/lib/utils';
import toast from 'react-hot-toast';
import type { GithubIntegration } from '@/types';

export interface AddServiceModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSuccess?: () => void;
}

interface FormData {
  name: string;
  description: string;
  github_owner: string;
  github_repo: string;
  github_workflow_file: string;
  github_branch: string;
  github_integration_id: string;
  icon: string;
  color: string;
}

interface FormErrors {
  name?: string;
  github_owner?: string;
  github_repo?: string;
  github_workflow_file?: string;
  github_integration_id?: string;
}

const initialFormData: FormData = {
  name: '',
  description: '',
  github_owner: '',
  github_repo: '',
  github_workflow_file: '',
  github_branch: 'main',
  github_integration_id: '',
  icon: 'server',
  color: 'blue',
};

const iconOptions = [
  { value: 'server', label: 'Server', icon: Server },
  { value: 'cloud', label: 'Cloud', icon: Cloud },
  { value: 'database', label: 'Database', icon: Database },
  { value: 'code', label: 'Code', icon: Code },
  { value: 'globe', label: 'Globe', icon: Globe },
  { value: 'shield', label: 'Shield', icon: Shield },
  { value: 'zap', label: 'Zap', icon: Zap },
  { value: 'box', label: 'Box', icon: Box },
  { value: 'cpu', label: 'CPU', icon: Cpu },
  { value: 'hard-drive', label: 'Hard Drive', icon: HardDrive },
  { value: 'terminal', label: 'Terminal', icon: Terminal },
  { value: 'package', label: 'Package', icon: Package },
  { value: 'layers', label: 'Layers', icon: Layers },
  { value: 'git-branch', label: 'Git Branch', icon: GitBranch },
  { value: 'rocket', label: 'Rocket', icon: Rocket },
];

const colorOptions = [
  { value: 'blue', label: 'Blue', class: 'bg-blue-500' },
  { value: 'green', label: 'Green', class: 'bg-green-500' },
  { value: 'purple', label: 'Purple', class: 'bg-purple-500' },
  { value: 'orange', label: 'Orange', class: 'bg-orange-500' },
  { value: 'red', label: 'Red', class: 'bg-red-500' },
  { value: 'cyan', label: 'Cyan', class: 'bg-cyan-500' },
  { value: 'pink', label: 'Pink', class: 'bg-pink-500' },
  { value: 'indigo', label: 'Indigo', class: 'bg-indigo-500' },
  { value: 'yellow', label: 'Yellow', class: 'bg-yellow-500' },
  { value: 'teal', label: 'Teal', class: 'bg-teal-500' },
];

const AddServiceModal: React.FC<AddServiceModalProps> = memo(function AddServiceModal({
  isOpen,
  onClose,
  onSuccess,
}) {
  const [formData, setFormData] = useState<FormData>(initialFormData);
  const [errors, setErrors] = useState<FormErrors>({});
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [integrations, setIntegrations] = useState<GithubIntegration[]>([]);
  const [isLoadingIntegrations, setIsLoadingIntegrations] = useState(false);
  const [isIntegrationDropdownOpen, setIsIntegrationDropdownOpen] = useState(false);

  // Load GitHub integrations when modal opens
  useEffect(() => {
    if (isOpen && integrations.length === 0) {
      loadIntegrations();
    }
  }, [isOpen, integrations.length]);

  const loadIntegrations = async () => {
    setIsLoadingIntegrations(true);
    try {
      const data = await servicesService.getGithubIntegrations();
      setIntegrations(data);
      // Auto-select first integration if available
      if (data.length > 0 && !formData.github_integration_id) {
        setFormData((prev) => ({ ...prev, github_integration_id: data[0].id.toString() }));
      }
    } catch (error) {
      console.error('Failed to load GitHub integrations:', error);
    } finally {
      setIsLoadingIntegrations(false);
    }
  };

  const validateForm = useCallback((): boolean => {
    const newErrors: FormErrors = {};

    if (!formData.name.trim()) {
      newErrors.name = 'Service name is required';
    } else if (formData.name.length < 2) {
      newErrors.name = 'Name must be at least 2 characters';
    }

    if (!formData.github_owner.trim()) {
      newErrors.github_owner = 'GitHub owner is required';
    }

    if (!formData.github_repo.trim()) {
      newErrors.github_repo = 'GitHub repository is required';
    }

    if (!formData.github_workflow_file.trim()) {
      newErrors.github_workflow_file = 'Workflow file is required';
    } else if (!formData.github_workflow_file.endsWith('.yml') && !formData.github_workflow_file.endsWith('.yaml')) {
      newErrors.github_workflow_file = 'Workflow file must end with .yml or .yaml';
    }

    if (!formData.github_integration_id) {
      newErrors.github_integration_id = 'GitHub integration is required';
    }

    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  }, [formData]);

  const handleInputChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>) => {
      const { name, value } = e.target;
      setFormData((prev) => ({ ...prev, [name]: value }));
      if (errors[name as keyof FormErrors]) {
        setErrors((prev) => ({ ...prev, [name]: undefined }));
      }
    },
    [errors]
  );

  const handleIntegrationSelect = useCallback((integrationId: string) => {
    setFormData((prev) => ({ ...prev, github_integration_id: integrationId }));
    setIsIntegrationDropdownOpen(false);
    setErrors((prev) => ({ ...prev, github_integration_id: undefined }));
  }, []);

  const handleSubmit = useCallback(
    async (e: React.FormEvent) => {
      e.preventDefault();

      if (!validateForm()) {
        return;
      }

      setIsSubmitting(true);
      try {
        await servicesService.createService({
          name: formData.name,
          description: formData.description || undefined,
          github_owner: formData.github_owner,
          github_repo: formData.github_repo,
          github_workflow_file: formData.github_workflow_file,
          github_branch: formData.github_branch || 'main',
          github_integration_id: parseInt(formData.github_integration_id),
          icon: formData.icon,
          color: formData.color,
        });

        toast.success('Service created successfully');
        setFormData(initialFormData);
        setErrors({});
        onClose();
        onSuccess?.();
      } catch (error: unknown) {
        const errorMessage =
          error instanceof Error ? error.message : 'Failed to create service';
        toast.error(errorMessage);
      } finally {
        setIsSubmitting(false);
      }
    },
    [formData, validateForm, onClose, onSuccess]
  );

  const handleClose = useCallback(() => {
    if (!isSubmitting) {
      setFormData(initialFormData);
      setErrors({});
      setIsIntegrationDropdownOpen(false);
      onClose();
    }
  }, [isSubmitting, onClose]);

  // Close dropdown when clicking outside
  useEffect(() => {
    const handleClickOutside = (e: MouseEvent) => {
      const target = e.target as HTMLElement;
      if (!target.closest('[data-integration-dropdown]')) {
        setIsIntegrationDropdownOpen(false);
      }
    };

    if (isIntegrationDropdownOpen) {
      document.addEventListener('mousedown', handleClickOutside);
      return () => document.removeEventListener('mousedown', handleClickOutside);
    }
  }, [isIntegrationDropdownOpen]);

  const selectedIntegration = integrations.find(
    (i) => i.id.toString() === formData.github_integration_id
  );

  const selectedIcon = iconOptions.find((i) => i.value === formData.icon);
  const SelectedIconComponent = selectedIcon?.icon || Server;
  const selectedColor = colorOptions.find((c) => c.value === formData.color);

  return (
    <Modal isOpen={isOpen} onClose={handleClose} title="Add New Service" size="lg">
      <form onSubmit={handleSubmit} className="space-y-4">
        {/* Service Name and Description */}
        <Input
          label="Service Name"
          name="name"
          value={formData.name}
          onChange={handleInputChange}
          placeholder="e.g., Production API"
          leftIcon={<Server className="w-4 h-4" />}
          error={errors.name}
          disabled={isSubmitting}
          required
        />

        <div>
          <label className="block text-sm font-medium text-secondary-700 mb-1.5">
            Description
          </label>
          <textarea
            name="description"
            value={formData.description}
            onChange={handleInputChange}
            placeholder="Brief description of this service..."
            disabled={isSubmitting}
            rows={2}
            className={cn(
              'w-full px-4 py-2.5 rounded-lg border text-sm transition-all duration-200',
              'bg-white text-secondary-900 placeholder-secondary-400',
              'focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500',
              'disabled:bg-secondary-50 disabled:text-secondary-500 disabled:cursor-not-allowed',
              'border-secondary-300 hover:border-secondary-400',
              'resize-none'
            )}
          />
        </div>

        {/* GitHub Integration Select */}
        <div className="w-full" data-integration-dropdown>
          <label className="block text-sm font-medium text-secondary-700 mb-1.5">
            GitHub Integration <span className="text-error-500">*</span>
          </label>
          <div className="relative">
            <button
              type="button"
              onClick={() => setIsIntegrationDropdownOpen((prev) => !prev)}
              disabled={isSubmitting || isLoadingIntegrations}
              className={cn(
                'w-full flex items-center justify-between px-4 py-2.5 rounded-lg border text-sm transition-all duration-200',
                'bg-white text-secondary-900',
                'focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500',
                'disabled:bg-secondary-50 disabled:text-secondary-500 disabled:cursor-not-allowed',
                errors.github_integration_id
                  ? 'border-error-500 focus:ring-error-500/20 focus:border-error-500'
                  : 'border-secondary-300 hover:border-secondary-400'
              )}
            >
              <div className="flex items-center gap-2">
                <Github className="w-4 h-4 text-secondary-400" />
                {isLoadingIntegrations ? (
                  <span className="text-secondary-400">Loading integrations...</span>
                ) : selectedIntegration ? (
                  <span>{selectedIntegration.name}</span>
                ) : integrations.length === 0 ? (
                  <span className="text-secondary-400">No integrations configured</span>
                ) : (
                  <span className="text-secondary-400">Select a GitHub integration</span>
                )}
              </div>
              <ChevronDown
                className={cn(
                  'w-4 h-4 text-secondary-400 transition-transform',
                  isIntegrationDropdownOpen && 'rotate-180'
                )}
              />
            </button>

            {isIntegrationDropdownOpen && integrations.length > 0 && (
              <div className="absolute z-50 mt-1 w-full bg-white border border-secondary-200 rounded-lg shadow-lg py-1 max-h-48 overflow-auto">
                {integrations.map((integration) => (
                  <button
                    key={integration.id}
                    type="button"
                    onClick={() => handleIntegrationSelect(integration.id.toString())}
                    className={cn(
                      'w-full flex items-center gap-2 px-4 py-2.5 text-left text-sm transition-colors',
                      'hover:bg-secondary-50',
                      formData.github_integration_id === integration.id.toString() && 'bg-primary-50'
                    )}
                  >
                    <Github className="w-4 h-4 text-secondary-500" />
                    <div>
                      <span className="font-medium">{integration.name}</span>
                      {integration.github_username && (
                        <span className="text-secondary-500 ml-2">@{integration.github_username}</span>
                      )}
                    </div>
                  </button>
                ))}
              </div>
            )}
          </div>
          {errors.github_integration_id && (
            <p className="mt-1.5 text-sm text-error-500">{errors.github_integration_id}</p>
          )}
          {integrations.length === 0 && !isLoadingIntegrations && (
            <p className="mt-1.5 text-sm text-warning-600">
              No GitHub integrations found. Go to Settings to add one.
            </p>
          )}
        </div>

        {/* GitHub Repository Info */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <Input
            label="GitHub Owner"
            name="github_owner"
            value={formData.github_owner}
            onChange={handleInputChange}
            placeholder="e.g., my-org"
            leftIcon={<Github className="w-4 h-4" />}
            error={errors.github_owner}
            disabled={isSubmitting}
            required
          />
          <Input
            label="Repository Name"
            name="github_repo"
            value={formData.github_repo}
            onChange={handleInputChange}
            placeholder="e.g., my-api"
            leftIcon={<Code className="w-4 h-4" />}
            error={errors.github_repo}
            disabled={isSubmitting}
            required
          />
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <Input
            label="Workflow File"
            name="github_workflow_file"
            value={formData.github_workflow_file}
            onChange={handleInputChange}
            placeholder="e.g., deploy.yml"
            leftIcon={<FileCode className="w-4 h-4" />}
            error={errors.github_workflow_file}
            helperText="Name of the workflow file in .github/workflows/"
            disabled={isSubmitting}
            required
          />
          <Input
            label="Branch"
            name="github_branch"
            value={formData.github_branch}
            onChange={handleInputChange}
            placeholder="main"
            leftIcon={<GitBranch className="w-4 h-4" />}
            helperText="Branch to trigger workflow on"
            disabled={isSubmitting}
          />
        </div>

        {/* Icon and Color Selection */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1.5">
              Icon
            </label>
            <div className="flex flex-wrap gap-2">
              {iconOptions.slice(0, 10).map((option) => {
                const IconComponent = option.icon;
                return (
                  <button
                    key={option.value}
                    type="button"
                    onClick={() => setFormData((prev) => ({ ...prev, icon: option.value }))}
                    className={cn(
                      'w-9 h-9 rounded-lg flex items-center justify-center transition-all',
                      formData.icon === option.value
                        ? 'bg-primary-100 text-primary-600 ring-2 ring-primary-500'
                        : 'bg-secondary-100 text-secondary-600 hover:bg-secondary-200'
                    )}
                    title={option.label}
                  >
                    <IconComponent className="w-4 h-4" />
                  </button>
                );
              })}
            </div>
          </div>

          <div>
            <label className="block text-sm font-medium text-secondary-700 mb-1.5">
              Color
            </label>
            <div className="flex flex-wrap gap-2">
              {colorOptions.map((option) => (
                <button
                  key={option.value}
                  type="button"
                  onClick={() => setFormData((prev) => ({ ...prev, color: option.value }))}
                  className={cn(
                    'w-9 h-9 rounded-lg transition-all',
                    option.class,
                    formData.color === option.value
                      ? 'ring-2 ring-offset-2 ring-secondary-400'
                      : 'opacity-70 hover:opacity-100'
                  )}
                  title={option.label}
                />
              ))}
            </div>
          </div>
        </div>

        {/* Preview */}
        <div className="bg-secondary-50 rounded-lg p-4 border border-secondary-200">
          <p className="text-sm font-medium text-secondary-700 mb-2">Preview</p>
          <div className="flex items-center gap-3">
            <div
              className={cn(
                'w-10 h-10 rounded-lg flex items-center justify-center text-white',
                selectedColor?.class || 'bg-blue-500'
              )}
            >
              <SelectedIconComponent className="w-5 h-5" />
            </div>
            <div>
              <p className="font-medium text-secondary-900">
                {formData.name || 'Service Name'}
              </p>
              <p className="text-xs text-secondary-500">
                {formData.github_owner || 'owner'}/{formData.github_repo || 'repo'}
              </p>
            </div>
          </div>
        </div>

        {/* Actions */}
        <div className="flex justify-end gap-3 pt-4 border-t border-secondary-200">
          <Button
            type="button"
            variant="ghost"
            onClick={handleClose}
            disabled={isSubmitting}
          >
            Cancel
          </Button>
          <Button type="submit" isLoading={isSubmitting}>
            Create Service
          </Button>
        </div>
      </form>
    </Modal>
  );
});

export default AddServiceModal;

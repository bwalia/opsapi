'use client';

import React, { useState, useCallback, useEffect, memo } from 'react';
import Modal from '@/components/ui/Modal';
import { Input, Button } from '@/components/ui';
import {
  Building2,
  Globe,
  FileText,
  Image,
  Users,
  Store,
  ChevronDown,
  AlertCircle,
} from 'lucide-react';
import { namespaceService, usersService } from '@/services';
import { cn } from '@/lib/utils';
import toast from 'react-hot-toast';
import type { User, NamespacePlan, NamespaceStatus } from '@/types';

// ============================================
// Types
// ============================================

export interface CreateNamespaceModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSuccess?: () => void;
  /** If true, shows admin-only fields like owner selection, status, plan */
  isAdminMode?: boolean;
}

interface FormData {
  name: string;
  slug: string;
  description: string;
  domain: string;
  logo_url: string;
  banner_url: string;
  owner_uuid: string;
  status: NamespaceStatus;
  plan: NamespacePlan;
  max_users: number;
  max_stores: number;
}

interface FormErrors {
  name?: string;
  slug?: string;
  owner_uuid?: string;
  max_users?: string;
  max_stores?: string;
}

const initialFormData: FormData = {
  name: '',
  slug: '',
  description: '',
  domain: '',
  logo_url: '',
  banner_url: '',
  owner_uuid: '',
  status: 'active',
  plan: 'free',
  max_users: 10,
  max_stores: 5,
};

// ============================================
// Plan Options
// ============================================

const PLAN_OPTIONS: { value: NamespacePlan; label: string; description: string }[] = [
  { value: 'free', label: 'Free', description: 'Basic features, limited resources' },
  { value: 'starter', label: 'Starter', description: 'For small teams getting started' },
  { value: 'professional', label: 'Professional', description: 'Advanced features for growing businesses' },
  { value: 'enterprise', label: 'Enterprise', description: 'Full features, custom limits' },
];

const STATUS_OPTIONS: { value: NamespaceStatus; label: string; color: string }[] = [
  { value: 'active', label: 'Active', color: 'text-success-600 bg-success-50' },
  { value: 'pending', label: 'Pending', color: 'text-warning-600 bg-warning-50' },
  { value: 'suspended', label: 'Suspended', color: 'text-error-600 bg-error-50' },
];

// ============================================
// Sub-components
// ============================================

interface SelectDropdownProps<T extends string> {
  label: string;
  value: T;
  options: { value: T; label: string; description?: string; color?: string }[];
  onChange: (value: T) => void;
  icon?: React.ReactNode;
  disabled?: boolean;
  error?: string;
}

const SelectDropdown = memo(function SelectDropdown<T extends string>({
  label,
  value,
  options,
  onChange,
  icon,
  disabled,
  error,
}: SelectDropdownProps<T>) {
  const [isOpen, setIsOpen] = useState(false);
  const selectedOption = options.find((o) => o.value === value);

  useEffect(() => {
    const handleClickOutside = (e: MouseEvent) => {
      const target = e.target as HTMLElement;
      if (!target.closest(`[data-dropdown="${label}"]`)) {
        setIsOpen(false);
      }
    };

    if (isOpen) {
      document.addEventListener('mousedown', handleClickOutside);
      return () => document.removeEventListener('mousedown', handleClickOutside);
    }
  }, [isOpen, label]);

  return (
    <div className="w-full" data-dropdown={label}>
      <label className="block text-sm font-medium text-secondary-700 mb-1.5">
        {label}
      </label>
      <div className="relative">
        <button
          type="button"
          onClick={() => setIsOpen((prev) => !prev)}
          disabled={disabled}
          className={cn(
            'w-full flex items-center justify-between px-4 py-2.5 rounded-lg border text-sm transition-all duration-200',
            'bg-white text-secondary-900',
            'focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500',
            'disabled:bg-secondary-50 disabled:text-secondary-500 disabled:cursor-not-allowed',
            error
              ? 'border-error-500 focus:ring-error-500/20 focus:border-error-500'
              : 'border-secondary-300 hover:border-secondary-400'
          )}
        >
          <div className="flex items-center gap-2">
            {icon && <span className="text-secondary-400">{icon}</span>}
            {selectedOption ? (
              <span className={cn('px-2 py-0.5 rounded text-xs font-medium', selectedOption.color)}>
                {selectedOption.label}
              </span>
            ) : (
              <span className="text-secondary-400">Select {label.toLowerCase()}</span>
            )}
          </div>
          <ChevronDown
            className={cn(
              'w-4 h-4 text-secondary-400 transition-transform',
              isOpen && 'rotate-180'
            )}
          />
        </button>

        {isOpen && (
          <div className="absolute z-50 mt-1 w-full bg-white border border-secondary-200 rounded-lg shadow-lg py-1 max-h-48 overflow-auto">
            {options.map((option) => (
              <button
                key={option.value}
                type="button"
                onClick={() => {
                  onChange(option.value);
                  setIsOpen(false);
                }}
                className={cn(
                  'w-full flex flex-col items-start px-4 py-2.5 text-left text-sm transition-colors',
                  'hover:bg-secondary-50',
                  value === option.value && 'bg-primary-50'
                )}
              >
                <span className={cn('px-2 py-0.5 rounded text-xs font-medium', option.color)}>
                  {option.label}
                </span>
                {option.description && (
                  <span className="text-xs text-secondary-500 mt-0.5 pl-2">
                    {option.description}
                  </span>
                )}
              </button>
            ))}
          </div>
        )}
      </div>
      {error && <p className="mt-1.5 text-sm text-error-500">{error}</p>}
    </div>
  );
}) as <T extends string>(props: SelectDropdownProps<T>) => React.ReactElement;

// Owner Search Dropdown
const OwnerSearchDropdown = memo(function OwnerSearchDropdown({
  value,
  onChange,
  disabled,
  error,
}: {
  value: string;
  onChange: (uuid: string, name: string) => void;
  disabled?: boolean;
  error?: string;
}) {
  const [isOpen, setIsOpen] = useState(false);
  const [searchQuery, setSearchQuery] = useState('');
  const [users, setUsers] = useState<User[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [selectedUserName, setSelectedUserName] = useState('');

  const searchUsers = useCallback(async (query: string) => {
    if (query.length < 2) {
      setUsers([]);
      return;
    }

    setIsLoading(true);
    try {
      const response = await usersService.getUsers({ perPage: 10 });
      // Filter users client-side for now
      const filtered = response.data.filter(
        (user) =>
          user.email?.toLowerCase().includes(query.toLowerCase()) ||
          user.first_name?.toLowerCase().includes(query.toLowerCase()) ||
          user.last_name?.toLowerCase().includes(query.toLowerCase()) ||
          user.username?.toLowerCase().includes(query.toLowerCase())
      );
      setUsers(filtered);
    } catch {
      setUsers([]);
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    const timer = setTimeout(() => {
      if (searchQuery) {
        searchUsers(searchQuery);
      }
    }, 300);

    return () => clearTimeout(timer);
  }, [searchQuery, searchUsers]);

  useEffect(() => {
    const handleClickOutside = (e: MouseEvent) => {
      const target = e.target as HTMLElement;
      if (!target.closest('[data-owner-dropdown]')) {
        setIsOpen(false);
      }
    };

    if (isOpen) {
      document.addEventListener('mousedown', handleClickOutside);
      return () => document.removeEventListener('mousedown', handleClickOutside);
    }
  }, [isOpen]);

  const handleSelect = (user: User) => {
    const fullName = `${user.first_name} ${user.last_name}`.trim() || user.email;
    onChange(user.uuid, fullName);
    setSelectedUserName(fullName);
    setSearchQuery('');
    setIsOpen(false);
  };

  return (
    <div className="w-full" data-owner-dropdown>
      <label className="block text-sm font-medium text-secondary-700 mb-1.5">
        Owner <span className="text-secondary-400">(optional)</span>
      </label>
      <div className="relative">
        <Input
          placeholder={selectedUserName || "Search users by name or email..."}
          value={searchQuery}
          onChange={(e) => {
            setSearchQuery(e.target.value);
            setIsOpen(true);
          }}
          onFocus={() => setIsOpen(true)}
          leftIcon={<Users className="w-4 h-4" />}
          disabled={disabled}
          error={error}
        />

        {value && !searchQuery && (
          <div className="absolute right-3 top-1/2 -translate-y-1/2">
            <button
              type="button"
              onClick={() => {
                onChange('', '');
                setSelectedUserName('');
              }}
              className="text-secondary-400 hover:text-secondary-600 text-xs"
            >
              Clear
            </button>
          </div>
        )}

        {isOpen && (searchQuery.length >= 2 || users.length > 0) && (
          <div className="absolute z-50 mt-1 w-full bg-white border border-secondary-200 rounded-lg shadow-lg py-1 max-h-48 overflow-auto">
            {isLoading ? (
              <div className="px-4 py-3 text-sm text-secondary-500 text-center">
                Searching...
              </div>
            ) : users.length === 0 ? (
              <div className="px-4 py-3 text-sm text-secondary-500 text-center">
                {searchQuery.length < 2 ? 'Type at least 2 characters' : 'No users found'}
              </div>
            ) : (
              users.map((user) => (
                <button
                  key={user.uuid}
                  type="button"
                  onClick={() => handleSelect(user)}
                  className="w-full flex items-center gap-3 px-4 py-2.5 text-left text-sm transition-colors hover:bg-secondary-50"
                >
                  <div className="w-8 h-8 rounded-full bg-primary-100 flex items-center justify-center text-primary-600 font-medium text-xs">
                    {user.first_name?.charAt(0) || user.email?.charAt(0) || '?'}
                  </div>
                  <div className="flex-1 min-w-0">
                    <p className="font-medium text-secondary-900 truncate">
                      {user.first_name} {user.last_name}
                    </p>
                    <p className="text-xs text-secondary-500 truncate">{user.email}</p>
                  </div>
                </button>
              ))
            )}
          </div>
        )}
      </div>
      <p className="mt-1 text-xs text-secondary-500">
        Leave empty to set yourself as owner
      </p>
    </div>
  );
});

// ============================================
// Main Component
// ============================================

const CreateNamespaceModal: React.FC<CreateNamespaceModalProps> = memo(
  function CreateNamespaceModal({ isOpen, onClose, onSuccess, isAdminMode = false }) {
    const [formData, setFormData] = useState<FormData>(initialFormData);
    const [errors, setErrors] = useState<FormErrors>({});
    const [isSubmitting, setIsSubmitting] = useState(false);
    const [showAdvanced, setShowAdvanced] = useState(false);

    // Reset form when modal closes
    useEffect(() => {
      if (!isOpen) {
        setFormData(initialFormData);
        setErrors({});
        setShowAdvanced(false);
      }
    }, [isOpen]);

    // Auto-generate slug from name
    const generateSlug = useCallback((name: string): string => {
      return name
        .toLowerCase()
        .replace(/\s+/g, '-')
        .replace(/[^a-z0-9-]/g, '')
        .replace(/-+/g, '-')
        .replace(/^-|-$/g, '');
    }, []);

    const validateForm = useCallback((): boolean => {
      const newErrors: FormErrors = {};

      if (!formData.name.trim()) {
        newErrors.name = 'Namespace name is required';
      } else if (formData.name.length < 2) {
        newErrors.name = 'Name must be at least 2 characters';
      } else if (formData.name.length > 100) {
        newErrors.name = 'Name must be less than 100 characters';
      }

      if (formData.slug && !/^[a-z0-9-]+$/.test(formData.slug)) {
        newErrors.slug = 'Slug can only contain lowercase letters, numbers, and hyphens';
      }

      if (isAdminMode) {
        if (formData.max_users < 1) {
          newErrors.max_users = 'Must have at least 1 user';
        }
        if (formData.max_stores < 0) {
          newErrors.max_stores = 'Cannot be negative';
        }
      }

      setErrors(newErrors);
      return Object.keys(newErrors).length === 0;
    }, [formData, isAdminMode]);

    const handleInputChange = useCallback(
      (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) => {
        const { name, value } = e.target;
        setFormData((prev) => {
          const updated = { ...prev, [name]: value };
          // Auto-generate slug when name changes (only if slug is empty or matches previous auto-generated)
          if (name === 'name' && (!prev.slug || prev.slug === generateSlug(prev.name))) {
            updated.slug = generateSlug(value);
          }
          return updated;
        });
        // Clear error when user starts typing
        if (errors[name as keyof FormErrors]) {
          setErrors((prev) => ({ ...prev, [name]: undefined }));
        }
      },
      [errors, generateSlug]
    );

    const handleNumberChange = useCallback(
      (e: React.ChangeEvent<HTMLInputElement>) => {
        const { name, value } = e.target;
        const numValue = parseInt(value, 10);
        if (!isNaN(numValue)) {
          setFormData((prev) => ({ ...prev, [name]: numValue }));
        }
        if (errors[name as keyof FormErrors]) {
          setErrors((prev) => ({ ...prev, [name]: undefined }));
        }
      },
      [errors]
    );

    const handleOwnerChange = useCallback((uuid: string) => {
      setFormData((prev) => ({ ...prev, owner_uuid: uuid }));
    }, []);

    const handleSubmit = useCallback(
      async (e: React.FormEvent) => {
        e.preventDefault();

        if (!validateForm()) {
          return;
        }

        setIsSubmitting(true);
        try {
          if (isAdminMode) {
            await namespaceService.createNamespaceAdmin({
              name: formData.name.trim(),
              slug: formData.slug.trim() || undefined,
              description: formData.description.trim() || undefined,
              domain: formData.domain.trim() || undefined,
              logo_url: formData.logo_url.trim() || undefined,
              banner_url: formData.banner_url.trim() || undefined,
              owner_uuid: formData.owner_uuid || undefined,
              status: formData.status,
              plan: formData.plan,
              max_users: formData.max_users,
              max_stores: formData.max_stores,
            });
          } else {
            await namespaceService.createNamespace({
              name: formData.name.trim(),
              slug: formData.slug.trim() || undefined,
              description: formData.description.trim() || undefined,
              domain: formData.domain.trim() || undefined,
              logo_url: formData.logo_url.trim() || undefined,
              banner_url: formData.banner_url.trim() || undefined,
            });
          }

          toast.success('Namespace created successfully');
          onClose();
          onSuccess?.();
        } catch (error: unknown) {
          const errorMessage =
            error instanceof Error ? error.message : 'Failed to create namespace';
          toast.error(errorMessage);
        } finally {
          setIsSubmitting(false);
        }
      },
      [formData, validateForm, isAdminMode, onClose, onSuccess]
    );

    const handleClose = useCallback(() => {
      if (!isSubmitting) {
        onClose();
      }
    }, [isSubmitting, onClose]);

    return (
      <Modal
        isOpen={isOpen}
        onClose={handleClose}
        title={isAdminMode ? 'Create New Namespace (Admin)' : 'Create New Namespace'}
        size="lg"
      >
        <form onSubmit={handleSubmit} className="space-y-5">
          {/* Basic Information */}
          <div className="space-y-4">
            <div className="flex items-center gap-2 text-sm font-medium text-secondary-700">
              <Building2 className="w-4 h-4" />
              <span>Basic Information</span>
            </div>

            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <Input
                label="Name"
                name="name"
                value={formData.name}
                onChange={handleInputChange}
                placeholder="My Company"
                leftIcon={<Building2 className="w-4 h-4" />}
                error={errors.name}
                disabled={isSubmitting}
                required
              />
              <Input
                label="Slug"
                name="slug"
                value={formData.slug}
                onChange={handleInputChange}
                placeholder="my-company"
                leftIcon={<Globe className="w-4 h-4" />}
                error={errors.slug}
                helperText="URL-friendly identifier"
                disabled={isSubmitting}
              />
            </div>

            <div>
              <label className="block text-sm font-medium text-secondary-700 mb-1.5">
                Description
              </label>
              <textarea
                name="description"
                value={formData.description}
                onChange={handleInputChange}
                placeholder="A brief description of this namespace..."
                rows={3}
                disabled={isSubmitting}
                className={cn(
                  'w-full px-4 py-2.5 rounded-lg border text-sm transition-all duration-200',
                  'bg-white text-secondary-900 placeholder:text-secondary-400',
                  'focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500',
                  'disabled:bg-secondary-50 disabled:text-secondary-500 disabled:cursor-not-allowed',
                  'border-secondary-300 hover:border-secondary-400 resize-none'
                )}
              />
            </div>
          </div>

          {/* Admin-only fields */}
          {isAdminMode && (
            <>
              <div className="border-t border-secondary-200 pt-5 space-y-4">
                <div className="flex items-center gap-2 text-sm font-medium text-secondary-700">
                  <Users className="w-4 h-4" />
                  <span>Owner & Configuration</span>
                </div>

                <OwnerSearchDropdown
                  value={formData.owner_uuid}
                  onChange={handleOwnerChange}
                  disabled={isSubmitting}
                  error={errors.owner_uuid}
                />

                <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                  <SelectDropdown
                    label="Status"
                    value={formData.status}
                    options={STATUS_OPTIONS}
                    onChange={(value) => setFormData((prev) => ({ ...prev, status: value }))}
                    disabled={isSubmitting}
                  />
                  <SelectDropdown
                    label="Plan"
                    value={formData.plan}
                    options={PLAN_OPTIONS}
                    onChange={(value) => setFormData((prev) => ({ ...prev, plan: value }))}
                    disabled={isSubmitting}
                  />
                </div>

                <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                  <Input
                    label="Max Users"
                    name="max_users"
                    type="number"
                    min={1}
                    value={formData.max_users.toString()}
                    onChange={handleNumberChange}
                    leftIcon={<Users className="w-4 h-4" />}
                    error={errors.max_users}
                    disabled={isSubmitting}
                  />
                  <Input
                    label="Max Stores"
                    name="max_stores"
                    type="number"
                    min={0}
                    value={formData.max_stores.toString()}
                    onChange={handleNumberChange}
                    leftIcon={<Store className="w-4 h-4" />}
                    error={errors.max_stores}
                    disabled={isSubmitting}
                  />
                </div>
              </div>
            </>
          )}

          {/* Advanced Settings (Collapsible) */}
          <div className="border-t border-secondary-200 pt-4">
            <button
              type="button"
              onClick={() => setShowAdvanced((prev) => !prev)}
              className="flex items-center gap-2 text-sm font-medium text-secondary-600 hover:text-secondary-900 transition-colors"
            >
              <ChevronDown
                className={cn(
                  'w-4 h-4 transition-transform',
                  showAdvanced && 'rotate-180'
                )}
              />
              Advanced Settings
            </button>

            {showAdvanced && (
              <div className="mt-4 space-y-4">
                <Input
                  label="Custom Domain"
                  name="domain"
                  value={formData.domain}
                  onChange={handleInputChange}
                  placeholder="app.mycompany.com"
                  leftIcon={<Globe className="w-4 h-4" />}
                  helperText="Configure DNS to point to our servers"
                  disabled={isSubmitting}
                />

                <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                  <Input
                    label="Logo URL"
                    name="logo_url"
                    value={formData.logo_url}
                    onChange={handleInputChange}
                    placeholder="https://example.com/logo.png"
                    leftIcon={<Image className="w-4 h-4" />}
                    disabled={isSubmitting}
                  />
                  <Input
                    label="Banner URL"
                    name="banner_url"
                    value={formData.banner_url}
                    onChange={handleInputChange}
                    placeholder="https://example.com/banner.png"
                    leftIcon={<Image className="w-4 h-4" />}
                    disabled={isSubmitting}
                  />
                </div>
              </div>
            )}
          </div>

          {/* Info Banner */}
          <div className="bg-info-50 border border-info-200 rounded-lg p-4 flex gap-3">
            <AlertCircle className="w-5 h-5 text-info-600 flex-shrink-0 mt-0.5" />
            <div className="text-sm text-info-700">
              <p className="font-medium">What happens next?</p>
              <p className="mt-1 text-info-600">
                {isAdminMode
                  ? 'The namespace will be created with the specified owner. Default roles (owner, admin, member, viewer) will be automatically set up.'
                  : 'You will become the owner of this namespace. You can then invite team members and configure roles.'}
              </p>
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
              Create Namespace
            </Button>
          </div>
        </form>
      </Modal>
    );
  }
);

export default CreateNamespaceModal;

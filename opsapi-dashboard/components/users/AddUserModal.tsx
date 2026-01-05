'use client';

import React, { useState, useCallback, useEffect, memo } from 'react';
import Modal from '@/components/ui/Modal';
import { Input, Button } from '@/components/ui';
import { User, Mail, Lock, Phone, MapPin, Shield, ChevronDown } from 'lucide-react';
import { usersService, rolesService, formatRoleName, getRoleColor, type NamespaceRole } from '@/services';
import { cn } from '@/lib/utils';
import toast from 'react-hot-toast';

export interface AddUserModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSuccess?: () => void;
}

interface FormData {
  email: string;
  password: string;
  username: string;
  first_name: string;
  last_name: string;
  phone_no: string;
  address: string;
  role: string;
}

interface FormErrors {
  email?: string;
  password?: string;
  username?: string;
  first_name?: string;
  last_name?: string;
  role?: string;
}

const initialFormData: FormData = {
  email: '',
  password: '',
  username: '',
  first_name: '',
  last_name: '',
  phone_no: '',
  address: '',
  role: 'buyer',
};

const AddUserModal: React.FC<AddUserModalProps> = memo(function AddUserModal({
  isOpen,
  onClose,
  onSuccess,
}) {
  const [formData, setFormData] = useState<FormData>(initialFormData);
  const [errors, setErrors] = useState<FormErrors>({});
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [roles, setRoles] = useState<NamespaceRole[]>([]);
  const [isLoadingRoles, setIsLoadingRoles] = useState(false);
  const [isRoleDropdownOpen, setIsRoleDropdownOpen] = useState(false);

  // Load roles when modal opens
  useEffect(() => {
    if (isOpen && roles.length === 0) {
      loadRoles();
    }
  }, [isOpen, roles.length]);

  const loadRoles = async () => {
    setIsLoadingRoles(true);
    try {
      const response = await rolesService.getRoles({ perPage: 100 });
      setRoles(response.data);
    } catch (error) {
      console.error('Failed to load roles:', error);
      toast.error('Failed to load roles');
    } finally {
      setIsLoadingRoles(false);
    }
  };

  const validateForm = useCallback((): boolean => {
    const newErrors: FormErrors = {};

    if (!formData.email.trim()) {
      newErrors.email = 'Email is required';
    } else if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(formData.email)) {
      newErrors.email = 'Please enter a valid email address';
    }

    if (!formData.password.trim()) {
      newErrors.password = 'Password is required';
    } else if (formData.password.length < 6) {
      newErrors.password = 'Password must be at least 6 characters';
    }

    if (!formData.username.trim()) {
      newErrors.username = 'Username is required';
    } else if (formData.username.length < 3) {
      newErrors.username = 'Username must be at least 3 characters';
    }

    if (!formData.first_name.trim()) {
      newErrors.first_name = 'First name is required';
    }

    if (!formData.last_name.trim()) {
      newErrors.last_name = 'Last name is required';
    }

    if (!formData.role) {
      newErrors.role = 'Role is required';
    }

    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  }, [formData]);

  const handleInputChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      const { name, value } = e.target;
      setFormData((prev) => ({ ...prev, [name]: value }));
      // Clear error when user starts typing
      if (errors[name as keyof FormErrors]) {
        setErrors((prev) => ({ ...prev, [name]: undefined }));
      }
    },
    [errors]
  );

  const handleRoleSelect = useCallback((roleName: string) => {
    setFormData((prev) => ({ ...prev, role: roleName }));
    setIsRoleDropdownOpen(false);
    setErrors((prev) => ({ ...prev, role: undefined }));
  }, []);

  const handleSubmit = useCallback(
    async (e: React.FormEvent) => {
      e.preventDefault();

      if (!validateForm()) {
        return;
      }

      setIsSubmitting(true);
      try {
        await usersService.createUser({
          email: formData.email,
          password: formData.password,
          username: formData.username,
          first_name: formData.first_name,
          last_name: formData.last_name,
          phone_no: formData.phone_no || undefined,
          address: formData.address || undefined,
          role: formData.role,
          active: true,
        });

        toast.success('User created successfully');
        setFormData(initialFormData);
        setErrors({});
        onClose();
        onSuccess?.();
      } catch (error: unknown) {
        const errorMessage =
          error instanceof Error ? error.message : 'Failed to create user';
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
      setIsRoleDropdownOpen(false);
      onClose();
    }
  }, [isSubmitting, onClose]);

  // Close dropdown when clicking outside
  useEffect(() => {
    const handleClickOutside = (e: MouseEvent) => {
      const target = e.target as HTMLElement;
      if (!target.closest('[data-role-dropdown]')) {
        setIsRoleDropdownOpen(false);
      }
    };

    if (isRoleDropdownOpen) {
      document.addEventListener('mousedown', handleClickOutside);
      return () => document.removeEventListener('mousedown', handleClickOutside);
    }
  }, [isRoleDropdownOpen]);

  const selectedRole = roles.find((r) => r.role_name === formData.role);

  return (
    <Modal isOpen={isOpen} onClose={handleClose} title="Add New User" size="lg">
      <form onSubmit={handleSubmit} className="space-y-4">
        {/* Name Row */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <Input
            label="First Name"
            name="first_name"
            value={formData.first_name}
            onChange={handleInputChange}
            placeholder="Enter first name"
            leftIcon={<User className="w-4 h-4" />}
            error={errors.first_name}
            disabled={isSubmitting}
            required
          />
          <Input
            label="Last Name"
            name="last_name"
            value={formData.last_name}
            onChange={handleInputChange}
            placeholder="Enter last name"
            leftIcon={<User className="w-4 h-4" />}
            error={errors.last_name}
            disabled={isSubmitting}
            required
          />
        </div>

        {/* Email */}
        <Input
          label="Email"
          name="email"
          type="email"
          value={formData.email}
          onChange={handleInputChange}
          placeholder="Enter email address"
          leftIcon={<Mail className="w-4 h-4" />}
          error={errors.email}
          disabled={isSubmitting}
          required
        />

        {/* Username and Role Row */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <Input
            label="Username"
            name="username"
            value={formData.username}
            onChange={handleInputChange}
            placeholder="Enter username"
            leftIcon={<User className="w-4 h-4" />}
            error={errors.username}
            disabled={isSubmitting}
            required
          />

          {/* Role Select */}
          <div className="w-full" data-role-dropdown>
            <label className="block text-sm font-medium text-secondary-700 mb-1.5">
              Role <span className="text-error-500">*</span>
            </label>
            <div className="relative">
              <button
                type="button"
                onClick={() => setIsRoleDropdownOpen((prev) => !prev)}
                disabled={isSubmitting || isLoadingRoles}
                className={cn(
                  'w-full flex items-center justify-between px-4 py-2.5 rounded-lg border text-sm transition-all duration-200',
                  'bg-white text-secondary-900',
                  'focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500',
                  'disabled:bg-secondary-50 disabled:text-secondary-500 disabled:cursor-not-allowed',
                  errors.role
                    ? 'border-error-500 focus:ring-error-500/20 focus:border-error-500'
                    : 'border-secondary-300 hover:border-secondary-400'
                )}
              >
                <div className="flex items-center gap-2">
                  <Shield className="w-4 h-4 text-secondary-400" />
                  {isLoadingRoles ? (
                    <span className="text-secondary-400">Loading roles...</span>
                  ) : selectedRole ? (
                    <span
                      className={cn(
                        'px-2 py-0.5 rounded-full text-xs font-medium border',
                        getRoleColor(selectedRole.role_name)
                      )}
                    >
                      {formatRoleName(selectedRole.role_name)}
                    </span>
                  ) : (
                    <span className="text-secondary-400">Select a role</span>
                  )}
                </div>
                <ChevronDown
                  className={cn(
                    'w-4 h-4 text-secondary-400 transition-transform',
                    isRoleDropdownOpen && 'rotate-180'
                  )}
                />
              </button>

              {/* Dropdown Menu */}
              {isRoleDropdownOpen && (
                <div className="absolute z-50 mt-1 w-full bg-white border border-secondary-200 rounded-lg shadow-lg py-1 max-h-48 overflow-auto">
                  {roles.map((role) => (
                    <button
                      key={role.uuid || role.id}
                      type="button"
                      onClick={() => handleRoleSelect(role.role_name)}
                      className={cn(
                        'w-full flex items-center gap-2 px-4 py-2.5 text-left text-sm transition-colors',
                        'hover:bg-secondary-50',
                        formData.role === role.role_name && 'bg-primary-50'
                      )}
                    >
                      <span
                        className={cn(
                          'px-2 py-0.5 rounded-full text-xs font-medium border',
                          getRoleColor(role.role_name)
                        )}
                      >
                        {formatRoleName(role.role_name)}
                      </span>
                    </button>
                  ))}
                </div>
              )}
            </div>
            {errors.role && <p className="mt-1.5 text-sm text-error-500">{errors.role}</p>}
          </div>
        </div>

        {/* Password */}
        <Input
          label="Password"
          name="password"
          type="password"
          value={formData.password}
          onChange={handleInputChange}
          placeholder="Enter password"
          leftIcon={<Lock className="w-4 h-4" />}
          error={errors.password}
          helperText="Must be at least 6 characters"
          disabled={isSubmitting}
          required
        />

        {/* Phone and Address Row */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <Input
            label="Phone Number"
            name="phone_no"
            type="tel"
            value={formData.phone_no}
            onChange={handleInputChange}
            placeholder="Phone (optional)"
            leftIcon={<Phone className="w-4 h-4" />}
            disabled={isSubmitting}
          />
          <Input
            label="Address"
            name="address"
            value={formData.address}
            onChange={handleInputChange}
            placeholder="Address (optional)"
            leftIcon={<MapPin className="w-4 h-4" />}
            disabled={isSubmitting}
          />
        </div>

        {/* Role Description */}
        {selectedRole && (
          <div className="bg-secondary-50 rounded-lg p-3 border border-secondary-200">
            <div className="flex items-start gap-2">
              <Shield className="w-4 h-4 text-secondary-500 mt-0.5" />
              <div>
                <p className="text-sm font-medium text-secondary-700">
                  {formatRoleName(selectedRole.role_name)} Role
                </p>
                <p className="text-xs text-secondary-500 mt-0.5">
                  {getRoleDescription(selectedRole.role_name)}
                </p>
              </div>
            </div>
          </div>
        )}

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
            Create User
          </Button>
        </div>
      </form>
    </Modal>
  );
});

/**
 * Get description for each role
 */
function getRoleDescription(roleName: string): string {
  const descriptions: Record<string, string> = {
    administrative: 'Full access to all dashboard features and settings',
    admin: 'Full access to all dashboard features and settings',
    seller: 'Can manage stores, products, and view orders',
    buyer: 'Can view products and manage their own orders',
    delivery_partner: 'Can view and update assigned delivery orders',
  };
  return descriptions[roleName.toLowerCase()] || 'Standard user permissions';
}

export default AddUserModal;

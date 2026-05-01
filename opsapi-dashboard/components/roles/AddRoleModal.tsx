'use client';

import React, { useState, useCallback, memo } from 'react';
import Modal from '@/components/ui/Modal';
import { Input, Button } from '@/components/ui';
import { Shield, FileText } from 'lucide-react';
import { rolesService } from '@/services';
import toast from 'react-hot-toast';

export interface AddRoleModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSuccess?: () => void;
}

interface FormData {
  name: string;
  description: string;
}

interface FormErrors {
  name?: string;
}

const initialFormData: FormData = {
  name: '',
  description: '',
};

const AddRoleModal: React.FC<AddRoleModalProps> = memo(function AddRoleModal({
  isOpen,
  onClose,
  onSuccess,
}) {
  const [formData, setFormData] = useState<FormData>(initialFormData);
  const [errors, setErrors] = useState<FormErrors>({});
  const [isSubmitting, setIsSubmitting] = useState(false);

  const validateForm = useCallback((): boolean => {
    const newErrors: FormErrors = {};

    if (!formData.name.trim()) {
      newErrors.name = 'Role name is required';
    } else if (formData.name.length < 2) {
      newErrors.name = 'Role name must be at least 2 characters';
    } else if (!/^[a-zA-Z_][a-zA-Z0-9_]*$/.test(formData.name)) {
      newErrors.name = 'Role name must start with a letter and contain only letters, numbers, and underscores';
    }

    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  }, [formData]);

  const handleInputChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) => {
      const { name, value } = e.target;
      setFormData((prev) => ({ ...prev, [name]: value }));
      if (errors[name as keyof FormErrors]) {
        setErrors((prev) => ({ ...prev, [name]: undefined }));
      }
    },
    [errors]
  );

  const handleSubmit = useCallback(
    async (e: React.FormEvent) => {
      e.preventDefault();

      if (!validateForm()) {
        return;
      }

      setIsSubmitting(true);
      try {
        // Use role_name for namespace-specific roles API
        const roleName = formData.name.toLowerCase().replace(/\s+/g, '_');
        await rolesService.createRole({
          role_name: roleName,
          display_name: formData.name.charAt(0).toUpperCase() + formData.name.slice(1),
          description: formData.description || undefined,
        });

        toast.success('Role created successfully');
        setFormData(initialFormData);
        setErrors({});
        onClose();
        onSuccess?.();
      } catch (error: unknown) {
        const errorMessage =
          error instanceof Error ? error.message : 'Failed to create role';
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
      onClose();
    }
  }, [isSubmitting, onClose]);

  return (
    <Modal isOpen={isOpen} onClose={handleClose} title="Create New Role" size="md">
      <form onSubmit={handleSubmit} className="space-y-4">
        {/* Role Name */}
        <Input
          label="Role Name"
          name="name"
          value={formData.name}
          onChange={handleInputChange}
          placeholder="e.g., manager, viewer, editor"
          leftIcon={<Shield className="w-4 h-4" />}
          error={errors.name}
          helperText="Use lowercase letters and underscores (e.g., store_manager)"
          disabled={isSubmitting}
          required
        />

        {/* Description */}
        <div className="w-full">
          <label className="block text-sm font-medium text-secondary-700 mb-1.5">
            Description
          </label>
          <div className="relative">
            <FileText className="absolute left-3 top-3 w-4 h-4 text-secondary-400" />
            <textarea
              name="description"
              value={formData.description}
              onChange={handleInputChange}
              placeholder="Describe what this role can do..."
              rows={3}
              disabled={isSubmitting}
              className="w-full pl-10 pr-4 py-2.5 rounded-lg border border-secondary-300 text-sm transition-all duration-200 focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500 disabled:bg-secondary-50 disabled:text-secondary-500 disabled:cursor-not-allowed resize-none"
            />
          </div>
        </div>

        {/* Info */}
        <div className="bg-secondary-50 rounded-lg p-3 border border-secondary-200">
          <p className="text-xs text-secondary-600">
            After creating the role, you can configure its permissions from the Roles list.
            Click on a role to edit its access permissions for each module.
          </p>
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
            Create Role
          </Button>
        </div>
      </form>
    </Modal>
  );
});

export default AddRoleModal;

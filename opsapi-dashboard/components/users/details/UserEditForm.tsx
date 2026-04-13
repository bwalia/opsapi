'use client';

import React, { useState, useCallback, useEffect, memo } from 'react';
import { useRouter } from 'next/navigation';
import { User as UserIcon, Mail, Phone, MapPin, AtSign, ArrowLeft, Save, Loader2 } from 'lucide-react';
import { Card, Input, Button, Badge } from '@/components/ui';
import { cn, getInitials, getFullName } from '@/lib/utils';
import { usersService } from '@/services';
import toast from 'react-hot-toast';
import Link from 'next/link';
import type { User } from '@/types';

export interface UserEditFormProps {
  user: User;
  onSuccess?: (user: User) => void;
}

interface FormData {
  email: string;
  username: string;
  first_name: string;
  last_name: string;
  phone_no: string;
  address: string;
  active: boolean;
}

interface FormErrors {
  email?: string;
  username?: string;
  first_name?: string;
  last_name?: string;
}

const UserEditForm: React.FC<UserEditFormProps> = memo(function UserEditForm({
  user,
  onSuccess,
}) {
  const router = useRouter();
  const [formData, setFormData] = useState<FormData>({
    email: user.email || '',
    username: user.username || '',
    first_name: user.first_name || '',
    last_name: user.last_name || '',
    phone_no: user.phone_no || '',
    address: user.address || '',
    active: user.active ?? true,
  });
  const [errors, setErrors] = useState<FormErrors>({});
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [hasChanges, setHasChanges] = useState(false);

  // Track changes
  useEffect(() => {
    const changed =
      formData.email !== (user.email || '') ||
      formData.username !== (user.username || '') ||
      formData.first_name !== (user.first_name || '') ||
      formData.last_name !== (user.last_name || '') ||
      formData.phone_no !== (user.phone_no || '') ||
      formData.address !== (user.address || '') ||
      formData.active !== (user.active ?? true);
    setHasChanges(changed);
  }, [formData, user]);

  const validateForm = useCallback((): boolean => {
    const newErrors: FormErrors = {};

    if (!formData.email.trim()) {
      newErrors.email = 'Email is required';
    } else if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(formData.email)) {
      newErrors.email = 'Please enter a valid email address';
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

    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
  }, [formData]);

  const handleInputChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) => {
      const { name, value, type } = e.target;
      const newValue = type === 'checkbox' ? (e.target as HTMLInputElement).checked : value;
      setFormData((prev) => ({ ...prev, [name]: newValue }));
      // Clear error when user starts typing
      if (errors[name as keyof FormErrors]) {
        setErrors((prev) => ({ ...prev, [name]: undefined }));
      }
    },
    [errors]
  );

  const handleToggleActive = useCallback(() => {
    setFormData((prev) => ({ ...prev, active: !prev.active }));
  }, []);

  const handleSubmit = useCallback(
    async (e: React.FormEvent) => {
      e.preventDefault();

      if (!validateForm()) {
        return;
      }

      setIsSubmitting(true);
      try {
        const updatedUser = await usersService.updateUser(user.uuid, {
          email: formData.email,
          username: formData.username,
          first_name: formData.first_name,
          last_name: formData.last_name,
          phone_no: formData.phone_no || undefined,
          address: formData.address || undefined,
          active: formData.active,
        });

        toast.success('User updated successfully');
        onSuccess?.(updatedUser);
        router.push(`/dashboard/users/${user.uuid}`);
      } catch (error: unknown) {
        const errorMessage =
          error instanceof Error ? error.message : 'Failed to update user';
        toast.error(errorMessage);
      } finally {
        setIsSubmitting(false);
      }
    },
    [formData, validateForm, user.uuid, onSuccess, router]
  );

  const handleCancel = useCallback(() => {
    router.push(`/dashboard/users/${user.uuid}`);
  }, [router, user.uuid]);

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="bg-white rounded-xl border border-secondary-200 overflow-hidden">
        {/* Banner */}
        <div className="h-20 bg-gradient-to-r from-primary-500 to-primary-600" />

        {/* Content */}
        <div className="px-6 pb-6">
          <div className="flex items-start justify-between -mt-8">
            <div className="flex items-end gap-4">
              {/* Avatar */}
              <div className="w-16 h-16 rounded-xl bg-white border-4 border-white shadow-md flex items-center justify-center overflow-hidden">
                <div className="w-full h-full gradient-primary flex items-center justify-center text-white font-bold text-xl">
                  {getInitials(formData.first_name, formData.last_name)}
                </div>
              </div>
              <div className="pb-1">
                <h1 className="text-xl font-bold text-secondary-900">
                  Edit User
                </h1>
                <p className="text-sm text-secondary-500">
                  {getFullName(user.first_name, user.last_name)}
                </p>
              </div>
            </div>

            {/* Back button */}
            <div className="pt-10">
              <Link href={`/dashboard/users/${user.uuid}`}>
                <Button variant="ghost" size="sm" leftIcon={<ArrowLeft className="w-4 h-4" />}>
                  Back to Details
                </Button>
              </Link>
            </div>
          </div>
        </div>
      </div>

      {/* Form */}
      <form onSubmit={handleSubmit}>
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          {/* Main form - 2 columns */}
          <div className="lg:col-span-2 space-y-6">
            {/* Personal Information */}
            <Card className="p-6">
              <h3 className="text-sm font-semibold text-secondary-500 uppercase tracking-wider mb-4">
                Personal Information
              </h3>

              <div className="space-y-4">
                {/* Name Row */}
                <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                  <Input
                    label="First Name"
                    name="first_name"
                    value={formData.first_name}
                    onChange={handleInputChange}
                    placeholder="Enter first name"
                    leftIcon={<UserIcon className="w-4 h-4" />}
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
                    leftIcon={<UserIcon className="w-4 h-4" />}
                    error={errors.last_name}
                    disabled={isSubmitting}
                    required
                  />
                </div>

                {/* Email */}
                <Input
                  label="Email Address"
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

                {/* Username */}
                <Input
                  label="Username"
                  name="username"
                  value={formData.username}
                  onChange={handleInputChange}
                  placeholder="Enter username"
                  leftIcon={<AtSign className="w-4 h-4" />}
                  error={errors.username}
                  disabled={isSubmitting}
                  required
                />
              </div>
            </Card>

            {/* Contact Information */}
            <Card className="p-6">
              <h3 className="text-sm font-semibold text-secondary-500 uppercase tracking-wider mb-4">
                Contact Information
              </h3>

              <div className="space-y-4">
                <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                  <Input
                    label="Phone Number"
                    name="phone_no"
                    type="tel"
                    value={formData.phone_no}
                    onChange={handleInputChange}
                    placeholder="Enter phone number"
                    leftIcon={<Phone className="w-4 h-4" />}
                    disabled={isSubmitting}
                  />
                  <div className="sm:col-span-1" />
                </div>

                <div>
                  <label className="block text-sm font-medium text-secondary-700 mb-1.5">
                    Address
                  </label>
                  <div className="relative">
                    <div className="absolute left-3 top-3 text-secondary-400">
                      <MapPin className="w-4 h-4" />
                    </div>
                    <textarea
                      name="address"
                      value={formData.address}
                      onChange={handleInputChange}
                      placeholder="Enter address"
                      disabled={isSubmitting}
                      rows={3}
                      className={cn(
                        'w-full pl-10 pr-4 py-2.5 rounded-lg border text-sm transition-all duration-200',
                        'bg-white text-secondary-900 placeholder-secondary-400',
                        'focus:outline-none focus:ring-2 focus:ring-primary-500/20 focus:border-primary-500',
                        'disabled:bg-secondary-50 disabled:text-secondary-500 disabled:cursor-not-allowed',
                        'border-secondary-300 hover:border-secondary-400',
                        'resize-none'
                      )}
                    />
                  </div>
                </div>
              </div>
            </Card>
          </div>

          {/* Sidebar - 1 column */}
          <div className="space-y-6">
            {/* Account Status */}
            <Card className="p-6">
              <h3 className="text-sm font-semibold text-secondary-500 uppercase tracking-wider mb-4">
                Account Status
              </h3>

              <div className="flex items-center justify-between">
                <div>
                  <p className="text-sm font-medium text-secondary-900">Account Active</p>
                  <p className="text-xs text-secondary-500 mt-0.5">
                    {formData.active ? 'User can log in' : 'User cannot log in'}
                  </p>
                </div>
                <button
                  type="button"
                  onClick={handleToggleActive}
                  disabled={isSubmitting}
                  className={cn(
                    'relative inline-flex h-6 w-11 items-center rounded-full transition-colors',
                    'focus:outline-none focus:ring-2 focus:ring-primary-500 focus:ring-offset-2',
                    'disabled:opacity-50 disabled:cursor-not-allowed',
                    formData.active ? 'bg-success-500' : 'bg-secondary-300'
                  )}
                >
                  <span
                    className={cn(
                      'inline-block h-4 w-4 transform rounded-full bg-white transition-transform shadow-sm',
                      formData.active ? 'translate-x-6' : 'translate-x-1'
                    )}
                  />
                </button>
              </div>

              <div className="mt-4 pt-4 border-t border-secondary-100">
                <Badge size="sm" status={formData.active ? 'active' : 'inactive'} />
              </div>
            </Card>

            {/* Actions */}
            <Card className="p-6">
              <h3 className="text-sm font-semibold text-secondary-500 uppercase tracking-wider mb-4">
                Actions
              </h3>

              <div className="space-y-3">
                <Button
                  type="submit"
                  className="w-full"
                  disabled={!hasChanges || isSubmitting}
                  isLoading={isSubmitting}
                  leftIcon={!isSubmitting ? <Save className="w-4 h-4" /> : undefined}
                >
                  Save Changes
                </Button>
                <Button
                  type="button"
                  variant="outline"
                  className="w-full"
                  onClick={handleCancel}
                  disabled={isSubmitting}
                >
                  Cancel
                </Button>
              </div>

              {hasChanges && (
                <p className="text-xs text-warning-600 mt-3 text-center">
                  You have unsaved changes
                </p>
              )}
            </Card>
          </div>
        </div>
      </form>
    </div>
  );
});

export default UserEditForm;

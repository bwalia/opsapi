'use client';

import React, { useState, useEffect, useCallback } from 'react';
import { useParams, useRouter } from 'next/navigation';
import { AlertTriangle, Loader2 } from 'lucide-react';
import { Card, Button } from '@/components/ui';
import { UserEditForm } from '@/components/users';
import { usePermissions } from '@/contexts/PermissionsContext';
import { usersService } from '@/services';
import type { User } from '@/types';
import toast from 'react-hot-toast';
import Link from 'next/link';

export default function UserEditPage() {
  const params = useParams();
  const router = useRouter();
  const { canRead, canUpdate } = usePermissions();

  const userId = params.id as string;

  const [user, setUser] = useState<User | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const fetchUser = useCallback(async () => {
    if (!userId) return;

    setIsLoading(true);
    setError(null);

    try {
      const userData = await usersService.getUser(userId);
      setUser(userData);
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Failed to load user';
      setError(message);
      toast.error(message);
    } finally {
      setIsLoading(false);
    }
  }, [userId]);

  useEffect(() => {
    fetchUser();
  }, [fetchUser]);

  // Access denied view - no update permission
  if (!canUpdate('users')) {
    return (
      <div className="space-y-6">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Edit User</h1>
          <p className="text-secondary-500 mt-1">Update user information</p>
        </div>

        <Card className="p-8 text-center">
          <AlertTriangle className="w-12 h-12 text-warning-500 mx-auto mb-4" />
          <h2 className="text-lg font-semibold text-secondary-900 mb-2">
            Access Restricted
          </h2>
          <p className="text-secondary-500 mb-4">
            You don&apos;t have permission to edit users.
          </p>
          <Link href="/dashboard/users">
            <Button variant="outline">Back to Users</Button>
          </Link>
        </Card>
      </div>
    );
  }

  // Loading state
  if (isLoading) {
    return (
      <div className="space-y-6">
        {/* Header skeleton */}
        <div className="bg-white rounded-xl border border-secondary-200 overflow-hidden animate-pulse">
          <div className="h-20 bg-secondary-200" />
          <div className="px-6 pb-6">
            <div className="flex items-start justify-between -mt-8">
              <div className="flex items-end gap-4">
                <div className="w-16 h-16 rounded-xl bg-secondary-300" />
                <div className="pb-1 space-y-2">
                  <div className="h-6 bg-secondary-200 rounded w-32" />
                  <div className="h-4 bg-secondary-200 rounded w-24" />
                </div>
              </div>
            </div>
          </div>
        </div>

        {/* Form skeleton */}
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <div className="lg:col-span-2 space-y-6">
            <Card className="p-6 animate-pulse">
              <div className="h-4 bg-secondary-200 rounded w-40 mb-6" />
              <div className="space-y-4">
                <div className="grid grid-cols-2 gap-4">
                  <div className="h-10 bg-secondary-200 rounded" />
                  <div className="h-10 bg-secondary-200 rounded" />
                </div>
                <div className="h-10 bg-secondary-200 rounded" />
                <div className="h-10 bg-secondary-200 rounded" />
              </div>
            </Card>
          </div>
          <div className="space-y-6">
            <Card className="p-6 animate-pulse">
              <div className="h-4 bg-secondary-200 rounded w-32 mb-6" />
              <div className="h-10 bg-secondary-200 rounded" />
            </Card>
          </div>
        </div>
      </div>
    );
  }

  // Error state
  if (error || !user) {
    return (
      <div className="space-y-6">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">Edit User</h1>
          <p className="text-secondary-500 mt-1">Update user information</p>
        </div>

        <Card className="p-8 text-center">
          <AlertTriangle className="w-12 h-12 text-error-500 mx-auto mb-4" />
          <h2 className="text-lg font-semibold text-secondary-900 mb-2">
            {error || 'User Not Found'}
          </h2>
          <p className="text-secondary-500 mb-4">
            The user you&apos;re looking for doesn&apos;t exist or you don&apos;t have permission to edit it.
          </p>
          <div className="flex items-center justify-center gap-3">
            <Link href="/dashboard/users">
              <Button variant="outline">Back to Users</Button>
            </Link>
            <Button onClick={fetchUser}>Try Again</Button>
          </div>
        </Card>
      </div>
    );
  }

  return <UserEditForm user={user} />;
}

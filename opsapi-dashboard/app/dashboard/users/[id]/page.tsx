'use client';

import React, { useState, useEffect, useCallback } from 'react';
import { useParams, useRouter } from 'next/navigation';
import { AlertTriangle, Loader2 } from 'lucide-react';
import { Card, Button } from '@/components/ui';
import {
  UserHeader,
  UserInfoCard,
  UserRolesCard,
  UserNamespacesCard,
  UserActivityCard,
} from '@/components/users';
import { usePermissions } from '@/contexts/PermissionsContext';
import { usersService } from '@/services';
import type { User } from '@/types';
import toast from 'react-hot-toast';
import Link from 'next/link';

export default function UserDetailsPage() {
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
      const userData = await usersService.getUser(userId, { detailed: true });
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

  const handleEdit = useCallback(() => {
    router.push(`/dashboard/users/${userId}/edit`);
  }, [router, userId]);

  // Access denied view
  if (!canRead('users')) {
    return (
      <div className="space-y-6">
        <div>
          <h1 className="text-2xl font-bold text-secondary-900">User Details</h1>
          <p className="text-secondary-500 mt-1">View user information</p>
        </div>

        <Card className="p-8 text-center">
          <AlertTriangle className="w-12 h-12 text-warning-500 mx-auto mb-4" />
          <h2 className="text-lg font-semibold text-secondary-900 mb-2">
            Access Restricted
          </h2>
          <p className="text-secondary-500 mb-4">
            You don&apos;t have permission to view user details.
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
        <UserHeader user={{} as User} isLoading={true} />
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <div className="lg:col-span-2 space-y-6">
            <UserInfoCard user={{} as User} isLoading={true} />
            <UserNamespacesCard user={{} as User} isLoading={true} />
          </div>
          <div className="space-y-6">
            <UserRolesCard user={{} as User} isLoading={true} />
            <UserActivityCard user={{} as User} isLoading={true} />
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
          <h1 className="text-2xl font-bold text-secondary-900">User Details</h1>
          <p className="text-secondary-500 mt-1">View user information</p>
        </div>

        <Card className="p-8 text-center">
          <AlertTriangle className="w-12 h-12 text-error-500 mx-auto mb-4" />
          <h2 className="text-lg font-semibold text-secondary-900 mb-2">
            {error || 'User Not Found'}
          </h2>
          <p className="text-secondary-500 mb-4">
            The user you&apos;re looking for doesn&apos;t exist or you don&apos;t have permission to view it.
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

  return (
    <div className="space-y-6">
      {/* Header with user info and actions */}
      <UserHeader
        user={user}
        onEdit={canUpdate('users') ? handleEdit : undefined}
      />

      {/* Main content grid */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Left column - Info and Namespaces */}
        <div className="lg:col-span-2 space-y-6">
          <UserInfoCard user={user} />
          <UserNamespacesCard user={user} />
        </div>

        {/* Right column - Roles and Activity */}
        <div className="space-y-6">
          <UserRolesCard user={user} />
          <UserActivityCard user={user} />
        </div>
      </div>
    </div>
  );
}
